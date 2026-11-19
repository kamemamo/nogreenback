// 映像の処理の流れ (SPEC.md 1 章「処理の流れ」)
// カメラのコマが届くたびに 1 回だけ合成し、各表示を描き直す。
// カメラがないとき (つないでいない、0.5 秒以上コマが届かない) は、25 回/秒で人物なしの合成を続ける。
// 取り込みのスレッドと、カメラがないときのタイマーは同じ lock の中で動かし、同時に動かないようにする。

using System.Numerics;
using System.Windows.Threading;

namespace NoGreenBack.Video;

public sealed class Pipeline : IDisposable
{
    readonly object gate = new();
    readonly AppModel model;
    readonly Gpu gpu;
    readonly Timer idleTimer;
    readonly DispatcherTimer fpsTimer;

    SwapChainTarget? preview;
    bool disposed;
    bool previewVisible = true;

    // 最後に受け取ったカメラの大きさ (最初は 1920×1080)
    int cameraW = 1920, cameraH = 1080;
    int composedCount;
    long lastFpsTicks = Environment.TickCount64;

    public CameraCapture Camera { get; }

    public Pipeline(AppModel model)
    {
        this.model = model;
        gpu = new Gpu();
        Camera = new CameraCapture(model.Settings);
        Camera.FrameArrived += OnCameraFrame;

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
    }

    void OnCameraFrame(byte[] pixels, int width, int height)
    {
        lock (gate)
        {
            if (disposed) return;
            gpu.UploadCamera(pixels, width, height);
            cameraW = width; cameraH = height;
            ComposeAndPresent();
        }
    }

    void OnIdleTick()
    {
        if (Camera.MillisecondsSinceLastFrame < 500) return;
        lock (gate) { if (!disposed) ComposeAndPresent(); }
    }

    void ComposeAndPresent()
    {
        var s = model.Settings;

        // キャンバス: 高さはカメラと同じ。横幅は、いまはカメラと同じ (「出す画面に合わせる」は画面の一覧を作ってから)
        int canvasW = cameraW, canvasH = cameraH;

        // 人物の置き方: 大きさの割合をカメラの幅と高さの両方に掛け、選んだ隅にぴったり付ける (4 章)
        float pw = (float)(cameraW * s.OverlayScale), ph = (float)(cameraH * s.OverlayScale);
        bool right = s.OverlayCorner is 0 or 2, bottom = s.OverlayCorner is 0 or 1;
        var personRect = new Vector4(right ? canvasW - pw : 0, bottom ? canvasH - ph : 0, pw, ph);

        bool hasCamera = Camera.MillisecondsSinceLastFrame < 500;
        gpu.Compose(canvasW, canvasH, personRect, s.Mirror, s.PersonOn && hasCamera);
        Interlocked.Increment(ref composedCount);

        if (preview != null && previewVisible) preview.Present(checkerboard: true);
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
        lock (gate)
        {
            disposed = true;
            preview?.Dispose();
            preview = null;
            gpu.Dispose();
        }
    }
}
