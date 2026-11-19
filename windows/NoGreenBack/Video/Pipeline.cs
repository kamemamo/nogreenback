// 映像の処理の流れ (SPEC.md 1 章「処理の流れ」)
// カメラのコマが届くたびに 1 回だけ合成し、各表示を描き直す。
// カメラがないとき (つないでいない、0.5 秒以上コマが届かない) は、25 回/秒で人物なしの合成を続ける。
// 取り込みのスレッドと、カメラがないときのタイマーは同じ lock の中で動かし、同時に動かないようにする。

using System.Numerics;
using System.Windows.Threading;

namespace NoGreenBack.Video;

/// 合成に重ねる画像の種類 (この順で重ねる)
public enum LayerKind { Keyboard, Annotation, Pointer }

/// 合成に重ねる画像 (BGRA、プリマルチプライドα)。キャンバスの (X, Y) に置く。
/// CanvasWidth × CanvasHeight のキャンバスに合わせて作ったもので、キャンバスの大きさが違えば重ねない
public sealed record LayerImage(byte[] Pixels, int Width, int Height, int X, int Y, int CanvasWidth, int CanvasHeight);

/// 合成したキャンバスの大きさと、人物を置いた枠 (キャンバスの画素)
public sealed record CanvasInfo(int Width, int Height, double PersonX, double PersonY, double PersonWidth, double PersonHeight);

public sealed class Pipeline : Observable, IDisposable
{
    readonly object gate = new();
    readonly AppModel model;
    readonly Gpu gpu;
    readonly Timer idleTimer;
    readonly DispatcherTimer fpsTimer;

    SwapChainTarget? preview;
    SwapChainTarget? fullScreen;
    SwapChainTarget? overlay;
    SpoutSender? spout;
    readonly GpuTarget spoutPerson = new();   // 背景がないときに Spout へ送る、元の大きさの人物
    bool disposed;
    bool previewVisible = true;

    // 最後に受け取ったカメラの大きさ (最初は 1920×1080)
    int cameraW = 1920, cameraH = 1080;
    // 出す画面の横縦比 (UI のスレッドで書き、合成で読む。0 なら画面がない)
    double outputAspect;

    // 重ねる画像とホワイトボード (UI のスレッドで入れ、合成のときに GPU に上げる。layerGate で守る)
    readonly object layerGate = new();
    readonly LayerImage?[] pendingLayers = new LayerImage?[3];
    readonly bool[] layerDirty = new bool[3];
    readonly LayerImage?[] currentLayers = new LayerImage?[3];
    readonly GpuImage[] layerImages = [new(), new(), new()];
    float boardOpacity;
    CanvasInfo? canvasInfo;
    readonly Dispatcher uiDispatcher = Dispatcher.CurrentDispatcher;

    /// 合成したキャンバスの大きさや人物の枠が変わった (UI のスレッドで呼ばれる)
    public event Action<CanvasInfo>? CanvasChanged;

    /// いまのキャンバスの大きさと人物の枠 (まだ合成していなければ null)
    public CanvasInfo? Canvas => Volatile.Read(ref canvasInfo);

    /// 重ねる画像を入れる (null で消す)
    public void SetLayer(LayerKind kind, LayerImage? image)
    {
        lock (layerGate) { pendingLayers[(int)kind] = image; layerDirty[(int)kind] = true; }
    }

    /// ホワイトボードの板の濃さ (0 なら出さない)
    public float BoardOpacity { set => Volatile.Write(ref boardOpacity, value); }
    int composedCount;
    long lastFpsTicks = Environment.TickCount64;

    // 人物の切り抜き
    readonly string? modelsDir = ModelSpec.FindModelsDir();
    readonly BrightnessStabilizer brightness = new();
    readonly MaskProcessor maskProcessor = new();
    Segmenter? segmenter;
    int modelVersion;
    float gain = 1;

    public CameraCapture Camera { get; }

    /// 背景映像 (キャプチャー機器・この PC の画面)
    public BackgroundSource Background { get; }

    /// 操作ウィンドウに出すお知らせ (切り抜きのモデルがないとき。空なら出さない)
    public string Message { get; }

    public Pipeline(AppModel model)
    {
        this.model = model;
        gpu = new Gpu();
        Camera = new CameraCapture(model.Settings);
        Camera.FrameArrived += OnCameraFrame;
        Background = new BackgroundSource(model, gpu, gate, Camera);
        try { spout = new SpoutSender(gpu, "NoGreenBack"); }
        catch (Exception e) { Log.Write($"Spout で送れません: {e.Message}"); }

        idleTimer = new Timer(_ => OnIdleTick(), null, 40, 40);

        // 処理中のフレームレートを 1 秒ごとに数えて出す
        fpsTimer = new DispatcherTimer(TimeSpan.FromSeconds(1), DispatcherPriority.Background, (_, _) =>
        {
            long now = Environment.TickCount64;
            int count = Interlocked.Exchange(ref composedCount, 0);
            double fps = count * 1000.0 / Math.Max(1, now - lastFpsTicks);
            lastFpsTicks = now;
            model.State.FpsText = $"{fps:F1} fps";
        }, Dispatcher.CurrentDispatcher);
        fpsTimer.Start();

        outputAspect = model.Displays.OutputAspect;
        model.Displays.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(Displays.OutputAspect)) outputAspect = model.Displays.OutputAspect;
        };

        Message = modelsDir == null ? Loc.L("切り抜きのモデルが見つかりません (windows\\models\\download.ps1 を実行してください)") : "";
        model.State.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(AppState.Quality)) ReloadModel();
        };
        ReloadModel();
    }

    void OnCameraFrame(byte[] pixels, int width, int height)
    {
        lock (gate)
        {
            if (disposed) return;
            var st = model.State;

            // 1. 明るさ安定化
            gain = brightness.Gain(pixels, width, height, st.BrightnessStabilization);

            // 2〜6. 人物マスクと後処理 (「人物」がオフの間は動かさない)
            if (segmenter != null && model.Settings.PersonOn)
            {
                try
                {
                    var mask = segmenter.Run(pixels, width, height, gain);
                    var bytes = maskProcessor.Process(mask, segmenter.Spec.Width, segmenter.Spec.Height, st);
                    gpu.UploadMask(bytes, segmenter.Spec.Width, segmenter.Spec.Height);
                }
                catch (Exception e)
                {
                    Log.Write($"切り抜きに失敗しました ({segmenter.Spec.Name}): {e.Message}");
                    gpu.ClearMask();
                }
            }

            gpu.UploadCamera(pixels, width, height);
            Background.OfferCameraFrame(pixels, width, height);
            cameraW = width; cameraH = height;
            ComposeAndPresent();
        }
    }

    /// 品質に合わせて、モデルを読み込み直す (読み込みは裏で行い、終わったら差し替える)
    void ReloadModel()
    {
        int quality = model.State.Quality;
        int version = Interlocked.Increment(ref modelVersion);

        if (modelsDir == null) return;   // 上部に「モデルが見つかりません」と出る
        Task.Run(() =>
        {
            Segmenter? loaded = null;
            try { loaded = Segmenter.Load(quality, modelsDir); }
            catch (Exception e) { Log.Write($"切り抜きのモデルを読み込めません: {e.Message}"); }
            lock (gate)
            {
                if (disposed || version != modelVersion) { loaded?.Dispose(); return; }
                segmenter?.Dispose();
                segmenter = loaded;
                maskProcessor.Reset();   // 品質を変えたらマスクの履歴を捨てる
                gpu.ClearMask();
            }
            if (loaded != null) Log.Write($"切り抜き: {loaded.Spec.Name} ({loaded.Provider})");
        });
    }

    void OnIdleTick()
    {
        if (Camera.MillisecondsSinceLastFrame < 500) return;
        lock (gate) { if (!disposed) ComposeAndPresent(); }
    }

    void ComposeAndPresent()
    {
        var s = model.Settings;

        // キャンバス: 高さはカメラと同じ。横幅は「出す画面に合わせる」なら 高さ × 出す画面の横縦比 (偶数に丸める)、でなければカメラと同じ
        int canvasH = cameraH;
        double aspect = outputAspect;
        int canvasW = s.MatchOutputAspect && aspect > 0 ? Math.Max(2, (int)Math.Round(canvasH * aspect / 2) * 2) : cameraW;

        // 人物の置き方: 大きさの割合をカメラの幅と高さの両方に掛け、選んだ隅にぴったり付ける (4 章)
        float pw = (float)(cameraW * s.OverlayScale), ph = (float)(cameraH * s.OverlayScale);
        bool right = s.OverlayCorner is 0 or 2, bottom = s.OverlayCorner is 0 or 1;
        var personRect = new Vector4(right ? canvasW - pw : 0, bottom ? canvasH - ph : 0, pw, ph);

        var info = new CanvasInfo(canvasW, canvasH, personRect.X, personRect.Y, personRect.Z, personRect.W);
        if (info != canvasInfo)
        {
            Volatile.Write(ref canvasInfo, info);
            uiDispatcher.BeginInvoke(() => CanvasChanged?.Invoke(info));
        }

        // 重ねる画像: 新しく入ったものを GPU に上げ、このキャンバスの大きさに合うものだけを重ねる
        var layers = new List<(GpuImage, Vector4)>(3);
        lock (layerGate)
        {
            for (int k = 0; k < 3; k++)
            {
                if (layerDirty[k])
                {
                    layerDirty[k] = false;
                    currentLayers[k] = pendingLayers[k];
                    if (pendingLayers[k] is { } img) layerImages[k].Update(gpu, img.Pixels, img.Width, img.Height);
                }
                if (currentLayers[k] is { } cur && cur.CanvasWidth == canvasW && cur.CanvasHeight == canvasH)
                    layers.Add((layerImages[k], new Vector4(cur.X, cur.Y, cur.Width, cur.Height)));
            }
        }

        bool hasCamera = Camera.MillisecondsSinceLastFrame < 500;
        var background = Background.Pull();
        gpu.Compose(canvasW, canvasH, personRect, s.Mirror, s.PersonOn && hasCamera, gain, Volatile.Read(ref boardOpacity), layers,
            background);

        // Spout: 背景があれば合成と同じものを送る。なければ人物を元の大きさのまま (隅に縮めずに) 送り、受け取る側で自由に置けるようにする
        // (板・キーボード・手書き・指し棒は入れない。字幕は作ったら下の中央に入れる)
        if (spout != null)
        {
            try
            {
                if (background != null) spout.Send(gpu.CanvasSrv!, canvasW, canvasH, s.FlipVertical, s.StraightAlpha);
                else
                {
                    spoutPerson.Ensure(gpu, cameraW, cameraH);
                    gpu.DrawPerson(spoutPerson.Rtv!, cameraW, cameraH, new Vector4(0, 0, cameraW, cameraH), s.Mirror, s.PersonOn && hasCamera, gain);
                    spout.Send(spoutPerson.Srv!, cameraW, cameraH, s.FlipVertical, s.StraightAlpha);
                }
            }
            catch (Exception e)
            {
                Log.Write($"Spout で送れません: {e.Message}");
                spout.Dispose();
                spout = null;
            }
        }
        Interlocked.Increment(ref composedCount);

        if (preview != null && previewVisible) preview.Present(checkerboard: true);
        fullScreen?.Present(checkerboard: false);
        PresentOverlay(s.PersonOn && hasCamera);
    }

    /// ワイプ: 背景なしの切り抜きを幅に収まるように縮め、下端をウィンドウの下にそろえる (はみ出した上は切れる)
    void PresentOverlay(bool showPerson)
    {
        if (overlay == null) return;
        float w = overlay.Width, h = w * cameraH / cameraW;
        overlay.PresentPerson(new Vector4(0, overlay.Height - h, w, h), model.Settings.Mirror, showPerson, gain);
    }

    /// 全画面出力のウィンドウができた (null なら閉じた)。ウィンドウを閉じる前に呼ぶ
    public void SetFullScreenWindow(IntPtr hwnd, int width, int height)
    {
        lock (gate)
        {
            fullScreen?.Dispose();
            fullScreen = null;
            if (disposed || hwnd == IntPtr.Zero) return;
            fullScreen = new SwapChainTarget(gpu, hwnd, width, height);
            if (gpu.CanvasSrv != null) fullScreen.Present(checkerboard: false);
        }
    }

    /// ワイプのウィンドウができた・大きさが変わった (hwnd が 0 なら閉じた)。ウィンドウを閉じる前に呼ぶ
    public void SetOverlayWindow(IntPtr hwnd, int width, int height)
    {
        lock (gate)
        {
            if (hwnd == IntPtr.Zero || disposed)
            {
                overlay?.Dispose();
                overlay = null;
                return;
            }
            if (overlay == null) overlay = new SwapChainTarget(gpu, hwnd, width, height, transparent: true);
            else overlay.Resize(width, height);
            PresentOverlay(model.Settings.PersonOn && Camera.MillisecondsSinceLastFrame < 500);
        }
    }

    /// プレビューの子ウィンドウができた・大きさが変わった
    public void AttachPreview(IntPtr hwnd, int width, int height)
    {
        lock (gate)
        {
            if (disposed) return;
            if (preview == null) preview = new SwapChainTarget(gpu, hwnd, width, height);
            else preview.Resize(width, height);
            if (gpu.CanvasSrv != null) preview.Present(checkerboard: true);
        }
    }

    /// 隠れている (最小化) 間はプレビューを描かない
    public void SetPreviewVisible(bool visible)
    {
        lock (gate) previewVisible = visible;
    }

    public void Dispose()
    {
        fpsTimer.Stop();
        idleTimer.Dispose();
        Camera.FrameArrived -= OnCameraFrame;
        Camera.Dispose();
        Background.Dispose();
        lock (gate)
        {
            disposed = true;
            segmenter?.Dispose();
            segmenter = null;
            preview?.Dispose();
            preview = null;
            fullScreen?.Dispose();
            fullScreen = null;
            overlay?.Dispose();
            overlay = null;
            foreach (var img in layerImages) img.Dispose();
            spout?.Dispose();
            spout = null;
            spoutPerson.Dispose();
            gpu.Dispose();
        }
    }
}
