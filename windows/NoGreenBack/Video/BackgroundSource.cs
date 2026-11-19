// 背景映像 (SPEC.md 6 章)
// 選択肢は「なし（透明）」「画面: ○○」(この PC の画面)「キャプチャー機器やカメラ」。保存する ID は、画面なら screen:画面の名前、機器ならその機器の ID。
// 背景は最新の 1 コマだけを持っておき、合成のたびに使う。
//
// キャプチャー機器
// - 1920×1080 (横長で幅 1920 以下のうち最も大きい形式) で開く。遅れたコマは捨てる
// - カメラと同じ見張りをする (2 秒ごとに調べ、3 秒以上コマがなければ同じ機器を開き直す)
// - カメラと同じ機器を選んだときは、機器を開き直さず、カメラのコマ (切り抜く前) をそのまま使う
//   (同じ機器を 2 つ開くと、カメラと背景が機器を取り合って、交互に止まるため)
//
// この PC の画面
// - Windows.Graphics.Capture で取り込む。コマは GPU の上のまま写す (CPU に読み出さない)。マウスカーソル入り
// - 画面に変化がない間はコマが届かないので、前のコマのままになる
// - このアプリ自身のウィンドウは映さない (合わせ鏡になるため)。手書きとホワイトボードのウィンドウだけは映す。
//   外すのは SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE) で、ほかのアプリの画面共有や録画からも消えるので、
//   画面を背景にしている間だけ付ける (Overlays.OverlayController が 1 秒ごとに付け直す)
// - 長辺 1920 に縮めることはしない (GPU の上で写すだけなので、縮める手間の方が大きい)

using System.Collections.ObjectModel;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Windows;
using System.Windows.Threading;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using Windows.Graphics.Imaging;
using Windows.Media.Capture;
using Windows.Media.Capture.Frames;
using Windows.Media.MediaProperties;
using WinRT;

namespace NoGreenBack.Video;

public sealed record BackgroundChoice(string Id, string Label)
{
    public override string ToString() => Label;
}

public sealed partial class BackgroundSource : Observable, IDisposable
{
    const string ScreenPrefix = "screen:";

    readonly AppModel model;
    readonly Gpu gpu;
    readonly object gate;   // Pipeline の lock (GPU を使うところ)
    readonly Dispatcher dispatcher;
    readonly DispatcherTimer watchdog;
    readonly GpuImage texture = new();
    bool hasFrame;

    public ObservableCollection<BackgroundChoice> Choices { get; } = [];

    /// 背景にしている画面の名前 (画面を背景にしていなければ null)
    public string? ScreenName { get; private set; }

    /// 背景を切り替えた (画面を背景にし始めた・やめた)
    public event Action? Changed;

    public BackgroundSource(AppModel model, Gpu gpu, object gate, CameraCapture camera)
    {
        this.model = model;
        this.gpu = gpu;
        this.gate = gate;
        dispatcher = Dispatcher.CurrentDispatcher;

        model.Settings.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(Settings.BackgroundID)) { Raise(nameof(SelectedId)); Apply(); }
        };
        // 画面の構成が変わったら、一覧と画面の取り込みを作り直す
        model.Displays.Changed += _ => { RefreshChoices(); Apply(restartScreen: true); };
        // 機器をつないだり外したりしたら一覧を作り直す (選んでいた機器がつながったら開く)
        camera.Cameras.CollectionChanged += (_, _) => { RefreshChoices(); Apply(); };

        watchdog = new DispatcherTimer(TimeSpan.FromSeconds(2), DispatcherPriority.Background, (_, _) => Watch(), dispatcher);
        watchdog.Start();

        this.camera = camera;
        this.cameras = camera.Cameras;
        // カメラを替えたら、背景がカメラと同じ機器かどうかが変わる
        camera.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(CameraCapture.SelectedId)) Apply(); };
        RefreshChoices();
        Apply();
    }

    readonly ObservableCollection<CameraInfo> cameras;
    readonly CameraCapture camera;
    bool useCameraFrames;

    /// 選んでいる背景 (空なら「なし」)。一覧から消えて選択が空になっても、覚えた ID は消さない
    public string SelectedId
    {
        get => model.Settings.BackgroundID is { } id && Choices.Any(c => c.Id == id) ? id : "";
        set { if (value != null) model.Settings.BackgroundID = value.Length == 0 ? null : value; }
    }

    void RefreshChoices()
    {
        Choices.Clear();
        Choices.Add(new BackgroundChoice("", Loc.L("なし（透明）")));
        foreach (var d in model.Displays.All) Choices.Add(new BackgroundChoice(ScreenPrefix + d.Name, Loc.L("画面: %@", d.Name)));
        foreach (var c in cameras) Choices.Add(new BackgroundChoice(c.Id, c.Name));
        Raise(nameof(SelectedId));
    }

    /// 選んでいる背景を使い始める (restartScreen: 画面の構成が変わったので、画面の取り込みをやり直す)
    void Apply(bool restartScreen = false)
    {
        string? id = model.Settings.BackgroundID;
        if (id != null && id.StartsWith(ScreenPrefix))
        {
            string name = id[ScreenPrefix.Length..];
            var display = model.Displays.Find(name);
            if (display == null) { Stop(); return; }   // その画面がつながったら始める
            if (!restartScreen && ScreenName == name) return;
            Stop();
            StartScreen(display);
            return;
        }
        if (id != null && id == camera.SelectedId)
        {
            if (useCameraFrames) return;
            Stop();
            useCameraFrames = true;
            Log.Write("背景: カメラと同じ機器なので、カメラのコマを使います");
            return;
        }
        if (id != null && cameras.Any(c => c.Id == id))
        {
            if (deviceId == id) return;
            Stop();
            _ = OpenDeviceAsync(id);
            return;
        }
        Stop();
    }

    /// カメラのコマが届いた (Pipeline の lock の中から呼ぶ)。背景がカメラと同じ機器なら、それを背景にする
    public void OfferCameraFrame(byte[] pixels, int width, int height)
    {
        if (!useCameraFrames) return;
        texture.Update(gpu, pixels, width, height);
        hasFrame = true;
    }

    /// 合成のときに Pipeline の lock の中から呼ぶ。新しいコマがあればテクスチャに写し、背景があればそのテクスチャを返す
    public GpuImage? Pull()
    {
        if (useCameraFrames) { }
        else if (pool != null)
        {
            // 届いているうちの最新のコマだけを使う
            Direct3D11CaptureFrame? latest = null;
            while (pool.TryGetNextFrame() is { } f) { latest?.Dispose(); latest = f; }
            if (latest != null)
            {
                using (latest)
                {
                    var size = latest.ContentSize;
                    if (size.Width != poolSize.Width || size.Height != poolSize.Height)
                    {
                        // 画面の大きさが変わった。次のコマから新しい大きさで受け取る
                        poolSize = size;
                        pool.Recreate(d3dDevice, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, size);
                    }
                    else
                    {
                        var access = latest.Surface.As<IDirect3DDxgiInterfaceAccess>();
                        var iid = typeof(ID3D11Texture2D).GUID;
                        using var tex = new ID3D11Texture2D(access.GetInterface(ref iid));
                        texture.CopyFrom(gpu, tex, size.Width, size.Height);
                        hasFrame = true;
                    }
                }
            }
        }
        else if (deviceId != null)
        {
            lock (frameLock)
            {
                if (frameIsNew)
                {
                    frameIsNew = false;
                    texture.Update(gpu, frame, frameW, frameH);
                    hasFrame = true;
                }
            }
        }
        return hasFrame ? texture : null;
    }

    // ── この PC の画面 ──

    IDirect3DDevice? d3dDevice;
    Direct3D11CaptureFramePool? pool;
    GraphicsCaptureSession? session;
    Windows.Graphics.SizeInt32 poolSize;

    void StartScreen(DisplayInfo display)
    {
        try
        {
            if (!GraphicsCaptureSession.IsSupported()) throw new NotSupportedException("Windows.Graphics.Capture");
            var item = CreateItemForMonitor(display);
            d3dDevice ??= CreateDirect3DDevice(gpu.Device);
            lock (gate)
            {
                poolSize = item.Size;
                pool = Direct3D11CaptureFramePool.CreateFreeThreaded(d3dDevice, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, item.Size);
                session = pool.CreateCaptureSession(item);
                session.IsCursorCaptureEnabled = true;
                try { session.IsBorderRequired = false; } catch { }   // 取り込み中の黄色い枠を出さない (出せない環境では出る)
                session.StartCapture();
                hasFrame = false;
            }
            ScreenName = display.Name;
            Log.Write($"背景: 画面 {display.Name} {item.Size.Width}x{item.Size.Height}");
            Changed?.Invoke();
        }
        catch (Exception e)
        {
            Log.Write($"画面を背景にできません: {e}");
            Stop();
            MessageBox.Show(Loc.L("画面を背景にできません: %@", e.Message), "NoGreenBack", MessageBoxButton.OK, MessageBoxImage.Warning);
            model.Settings.BackgroundID = null;
        }
    }

    static GraphicsCaptureItem CreateItemForMonitor(DisplayInfo d)
    {
        var monitor = MonitorFromPoint(new POINT { X = d.Left + d.Width / 2, Y = d.Top + d.Height / 2 }, 2 /* MONITOR_DEFAULTTONEAREST */);
        var interop = GraphicsCaptureItem.As<IGraphicsCaptureItemInterop>();
        var iid = new Guid("79C3F95B-31F7-4EC2-A464-632EF5D30760");   // IGraphicsCaptureItem
        var ptr = interop.CreateForMonitor(monitor, ref iid);
        try { return GraphicsCaptureItem.FromAbi(ptr); }
        finally { Marshal.Release(ptr); }
    }

    static IDirect3DDevice CreateDirect3DDevice(ID3D11Device device)
    {
        using var dxgi = device.QueryInterface<IDXGIDevice>();
        Marshal.ThrowExceptionForHR(CreateDirect3D11DeviceFromDXGIDevice(dxgi.NativePointer, out var ptr));
        try { return MarshalInterface<IDirect3DDevice>.FromAbi(ptr); }
        finally { Marshal.Release(ptr); }
    }

    // ── キャプチャー機器 ──

    readonly object frameLock = new();
    byte[] frame = [];
    int frameW, frameH;
    bool frameIsNew;
    long lastFrameTicks;
    string? deviceId;
    MediaCapture? capture;
    MediaFrameReader? reader;
    int generation;   // 止めたり切り替えたりするたびに増やす (遅れて終わった開始処理を捨てるため)

    async Task OpenDeviceAsync(string id)
    {
        int gen = ++generation;
        deviceId = id;
        Interlocked.Exchange(ref lastFrameTicks, Environment.TickCount64);
        var mc = new MediaCapture();
        try
        {
            try
            {
                await mc.InitializeAsync(new MediaCaptureInitializationSettings
                {
                    VideoDeviceId = id, StreamingCaptureMode = StreamingCaptureMode.Video,
                    MemoryPreference = MediaCaptureMemoryPreference.Cpu, SharingMode = MediaCaptureSharingMode.ExclusiveControl,
                });
            }
            catch (Exception) when (gen == generation)
            {
                // ほかのアプリが使っているなどで独占できないときは、読み取りだけで開く
                mc.Dispose();
                mc = new MediaCapture();
                await mc.InitializeAsync(new MediaCaptureInitializationSettings
                {
                    VideoDeviceId = id, StreamingCaptureMode = StreamingCaptureMode.Video,
                    MemoryPreference = MediaCaptureMemoryPreference.Cpu, SharingMode = MediaCaptureSharingMode.SharedReadOnly,
                });
            }
            if (gen != generation) { mc.Dispose(); return; }

            var source = mc.FrameSources.Values
                .Where(s => s.Info.SourceKind == MediaFrameSourceKind.Color)
                .OrderBy(s => s.Info.MediaStreamType switch { MediaStreamType.VideoRecord => 0, MediaStreamType.VideoPreview => 1, _ => 2 })
                .FirstOrDefault() ?? throw new InvalidOperationException("no color stream");
            if (CameraCapture.ChooseFormat(source.SupportedFormats, 30) is { } format)
            {
                try { await source.SetFormatAsync(format); Log.Write($"背景: 機器の形式 {CameraCapture.Describe(format)}"); }
                catch (Exception e) { Log.Write($"背景: 形式を決められません ({e.Message})"); }   // 読み取りだけで開いたときなど
            }
            var r = await mc.CreateFrameReaderAsync(source, MediaEncodingSubtypes.Bgra8);
            r.AcquisitionMode = MediaFrameReaderAcquisitionMode.Realtime;   // 遅れたコマは捨てる
            r.FrameArrived += OnDeviceFrame;
            var status = await r.StartAsync();
            if (gen != generation) { r.FrameArrived -= OnDeviceFrame; r.Dispose(); mc.Dispose(); return; }
            if (status != MediaFrameReaderStartStatus.Success) throw new InvalidOperationException(status.ToString());
            capture = mc;
            reader = r;
            Log.Write($"背景: 機器 {cameras.FirstOrDefault(c => c.Id == id)?.Name}");
        }
        catch (Exception e)
        {
            mc.Dispose();
            if (gen != generation) return;
            // 開けなかった。見張りがもう一度開く (外れている間など)
            Log.Write($"背景映像を開けません: {e.Message}");
            CloseDevice();
            deviceId = id;
        }
    }

    void OnDeviceFrame(MediaFrameReader sender, MediaFrameArrivedEventArgs args)
    {
        using var f = sender.TryAcquireLatestFrame();
        var bitmap = f?.VideoMediaFrame?.SoftwareBitmap;
        if (bitmap == null) return;
        SoftwareBitmap? converted = null;
        try
        {
            if (bitmap.BitmapPixelFormat != BitmapPixelFormat.Bgra8)
                bitmap = converted = SoftwareBitmap.Convert(bitmap, BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore);
            int w = bitmap.PixelWidth, h = bitmap.PixelHeight;
            lock (frameLock)
            {
                if (frame.Length != w * h * 4) frame = new byte[w * h * 4];
                bitmap.CopyToBuffer(frame.AsBuffer());
                frameW = w; frameH = h; frameIsNew = true;
            }
            Interlocked.Exchange(ref lastFrameTicks, Environment.TickCount64);
        }
        catch (Exception e) { System.Diagnostics.Debug.WriteLine($"背景のコマを読めません: {e.Message}"); }
        finally
        {
            converted?.Dispose();
            f?.VideoMediaFrame?.SoftwareBitmap?.Dispose();
        }
    }

    /// 見張り: 3 秒以上コマが届いていなければ、同じ機器を開き直す (スイッチャーは形式を変えると一度消えて出直すことがある)
    void Watch()
    {
        if (deviceId is not { } id) return;
        if (Environment.TickCount64 - Interlocked.Read(ref lastFrameTicks) <= 3000) return;
        if (!cameras.Any(c => c.Id == id)) return;
        Log.Write("背景: コマが届かないので開き直します");
        CloseDevice();
        _ = OpenDeviceAsync(id);
    }

    void CloseDevice()
    {
        generation++;
        var r = reader; reader = null;
        var c = capture; capture = null;
        deviceId = null;
        if (r != null) r.FrameArrived -= OnDeviceFrame;
        if (r != null || c != null)
            _ = Task.Run(async () =>
            {
                if (r != null) { try { await r.StopAsync(); } catch { } r.Dispose(); }
                c?.Dispose();
            });
    }

    /// 背景をやめる (透明に戻す)
    void Stop()
    {
        CloseDevice();
        bool wasScreen = ScreenName != null;
        lock (gate)
        {
            useCameraFrames = false;
            session?.Dispose(); session = null;
            pool?.Dispose(); pool = null;
            hasFrame = false;
            lock (frameLock) frameIsNew = false;
        }
        ScreenName = null;
        if (wasScreen) Changed?.Invoke();
    }

    public void Dispose()
    {
        watchdog.Stop();
        Stop();
        lock (gate) texture.Dispose();
    }

    [ComImport, Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IGraphicsCaptureItemInterop
    {
        IntPtr CreateForWindow(IntPtr window, ref Guid iid);
        IntPtr CreateForMonitor(IntPtr monitor, ref Guid iid);
    }

    [ComImport, Guid("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDirect3DDxgiInterfaceAccess
    {
        IntPtr GetInterface(ref Guid iid);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int X, Y; }

    [LibraryImport("user32.dll")]
    private static partial IntPtr MonitorFromPoint(POINT pt, uint flags);

    [LibraryImport("d3d11.dll")]
    private static partial int CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice, out IntPtr graphicsDevice);
}
