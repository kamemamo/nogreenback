// カメラの取り込み (SPEC.md 3 章「カメラ」)
// Windows.Media.Capture の MediaFrameReader で、BGRA の画素をコマごとに受け取る。
// - 形式は「横長で幅 1920 以下のうち最も大きいもの」。フレームレートはカメラが示す値のうち、選んだ値に最も近いもの
// - 遅れたコマは捨てる (Realtime)
// - 2 秒ごとに調べ、3 秒以上コマが届いていなければ、同じ機器を探して開き直す
// - カメラがなくても待っていて、あとからつなげば自動で開く

using System.Collections.ObjectModel;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Windows.Threading;
using Windows.Devices.Enumeration;
using Windows.Graphics.Imaging;
using Windows.Media.Capture;
using Windows.Media.Capture.Frames;
using Windows.Media.MediaProperties;

namespace NoGreenBack.Video;

public sealed record CameraInfo(string Id, string Name)
{
    public override string ToString() => Name;
}

public sealed class CameraCapture : Observable, IDisposable
{
    /// コマが届いた (取り込みのスレッドで呼ばれる。pixels は次のコマで上書きされるので、呼ばれている間に使い切る)
    public event Action<byte[], int, int>? FrameArrived;

    public ObservableCollection<CameraInfo> Cameras { get; } = [];

    string? selectedId;
    /// 選んでいるカメラ (保存しない。起動時は一覧の先頭)
    public string? SelectedId
    {
        get => selectedId;
        set
        {
            // 一覧から消えたときに選択が空になっても、開いているカメラはそのまま (戻ってきたら開き直す)
            if (value != null && Set(ref selectedId, value))
            {
                Log.Write($"カメラを選びました: {Cameras.FirstOrDefault(c => c.Id == value)?.Name}");
                _ = OpenAsync(value);
            }
        }
    }

    string message = "";
    /// 操作ウィンドウに出すお知らせ (空なら出さない)
    public string Message { get => message; private set => Set(ref message, value); }

    readonly Settings settings;
    readonly Dispatcher dispatcher;
    readonly DeviceWatcher watcher;
    readonly DispatcherTimer watchdog;
    readonly SemaphoreSlim openLock = new(1, 1);

    MediaCapture? capture;
    MediaFrameReader? reader;
    string? openId;
    volatile bool needsReopen;
    long lastFrameTicks;
    byte[] pixels = [];

    public CameraCapture(Settings settings)
    {
        this.settings = settings;
        dispatcher = Dispatcher.CurrentDispatcher;

        // フレームレートを変えたら設定し直す
        settings.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(Settings.FrameRate) && openId != null) _ = OpenAsync(openId);
        };

        watcher = DeviceInformation.CreateWatcher(DeviceClass.VideoCapture);
        watcher.Added += (_, info) => dispatcher.BeginInvoke(() => OnAdded(info));
        watcher.Removed += (_, update) => dispatcher.BeginInvoke(() => OnRemoved(update.Id));
        watcher.Updated += (_, _) => { };
        watcher.EnumerationCompleted += (_, _) => dispatcher.BeginInvoke(OnEnumerated);
        watcher.Start();

        watchdog = new DispatcherTimer(TimeSpan.FromSeconds(2), DispatcherPriority.Background, (_, _) => Watch(), dispatcher);
        watchdog.Start();
    }

    bool enumerated;

    void OnAdded(DeviceInformation info)
    {
        if (!info.IsEnabled || Cameras.Any(c => c.Id == info.Id)) return;
        Cameras.Add(new CameraInfo(info.Id, info.Name));
        if (enumerated) Log.Write($"カメラがつながりました: {info.Name}");
        if (info.Id == openId && selectedId != info.Id)
        {
            // 抜いていたカメラが戻ってきた (開き直しは見張りが行う)
            selectedId = info.Id;
            Raise(nameof(SelectedId));
        }
        else if (enumerated && !Cameras.Any(c => c.Id == selectedId)
                 && openLock.CurrentCount == 1 && MillisecondsSinceLastFrame > 3000)
        {
            // 選んでいるカメラがない (最初からない・抜かれて映像が止まっている) ときにつながれたら、自動で開く。
            // 開いている最中や映像が届いている間は、ほかのカメラの知らせが届いても乗り換えない
            // (仮想カメラが実物のカメラを使い始めると、機器が一度消えて出直すことがある)
            SelectedId = info.Id;
        }
        if (Message == Loc.L("カメラが見つかりません。カメラをつなぐと、自動で映ります。")) Message = "";
    }

    void OnRemoved(string id)
    {
        var cam = Cameras.FirstOrDefault(c => c.Id == id);
        if (cam != null)
        {
            Cameras.Remove(cam);
            Log.Write($"カメラが外れました: {cam.Name}");
        }
        if (Cameras.Count == 0) Message = Loc.L("カメラが見つかりません。カメラをつなぐと、自動で映ります。");
    }

    void OnEnumerated()
    {
        enumerated = true;
        if (Cameras.Count == 0) Message = Loc.L("カメラが見つかりません。カメラをつなぐと、自動で映ります。");
        else if (SelectedId == null) SelectedId = Cameras[0].Id;
    }

    /// 見張り: 3 秒以上コマが届いていない・取り込みが失敗したら、同じ機器を開き直す
    void Watch()
    {
        if (openId == null) return;
        bool stalled = Environment.TickCount64 - Interlocked.Read(ref lastFrameTicks) > 3000;
        if (!stalled && !needsReopen) return;
        if (Cameras.Any(c => c.Id == openId)) _ = OpenAsync(openId);
    }

    async Task OpenAsync(string id)
    {
        await openLock.WaitAsync();
        try
        {
            await CloseAsync();
            openId = id;
            needsReopen = false;
            Interlocked.Exchange(ref lastFrameTicks, Environment.TickCount64);   // 開いている最中に見張りが開き直さないように

            var mc = new MediaCapture();
            mc.Failed += (_, _) => needsReopen = true;
            try
            {
                await mc.InitializeAsync(new MediaCaptureInitializationSettings
                {
                    VideoDeviceId = id,
                    StreamingCaptureMode = StreamingCaptureMode.Video,
                    MemoryPreference = MediaCaptureMemoryPreference.Cpu,
                    SharingMode = MediaCaptureSharingMode.ExclusiveControl,
                });
            }
            catch (UnauthorizedAccessException)
            {
                mc.Dispose();
                openId = null;
                Message = Loc.L("カメラへのアクセスが許可されていません。\n設定 > プライバシーとセキュリティ > カメラ で、「デスクトップ アプリがカメラにアクセスできるようにする」をオンにしてください。");
                return;
            }
            catch (Exception e)
            {
                // ほかのアプリが使っているなど。次の見張りでもう一度開く
                mc.Dispose();
                needsReopen = true;
                Message = Loc.L("カメラを開けません: %@", e.Message);
                return;
            }
            capture = mc;

            var source = mc.FrameSources.Values
                .Where(s => s.Info.SourceKind == MediaFrameSourceKind.Color)
                .OrderBy(s => s.Info.MediaStreamType switch { MediaStreamType.VideoRecord => 0, MediaStreamType.VideoPreview => 1, _ => 2 })
                .FirstOrDefault();
            if (source == null) { Message = Loc.L("カメラを開けません: %@", "no color stream"); return; }

            var format = ChooseFormat(source.SupportedFormats, settings.FrameRate);
            Log.Write($"カメラ {Cameras.FirstOrDefault(c => c.Id == id)?.Name}: 形式 " +
                string.Join(", ", source.SupportedFormats.Select(Describe).Distinct()));
            if (format != null)
            {
                try
                {
                    await source.SetFormatAsync(format);
                    Log.Write($"  選んだ形式 {Describe(format)} (指定 {settings.FrameRate} fps)");
                }
                catch (Exception e) { Log.Write($"  形式を決められません: {e.Message}"); }   // カメラの既定のまま
            }

            reader = await mc.CreateFrameReaderAsync(source, MediaEncodingSubtypes.Bgra8);
            reader.AcquisitionMode = MediaFrameReaderAcquisitionMode.Realtime;   // 遅れたコマは捨てる
            reader.FrameArrived += OnFrameArrived;
            var status = await reader.StartAsync();
            if (status != MediaFrameReaderStartStatus.Success)
            {
                needsReopen = true;
                Message = Loc.L("カメラを開けません: %@", status.ToString());
                return;
            }
            Message = "";
        }
        finally { openLock.Release(); }
    }

    static string Describe(MediaFrameFormat f) =>
        $"{f.VideoFormat.Width}x{f.VideoFormat.Height} {f.Subtype} {(f.FrameRate.Denominator > 0 ? (double)f.FrameRate.Numerator / f.FrameRate.Denominator : 0):0.##}fps";

    /// 横長で幅 1920 以下のうち最も大きい形式。その中で、フレームレートが選んだ値に最も近いもの、同じなら NV12 を選ぶ
    /// (縦横どちらも出せるカメラは、指定しないと縦長の枠に横長の映像を入れて送ってくるため)
    static MediaFrameFormat? ChooseFormat(IReadOnlyList<MediaFrameFormat> formats, int targetFps)
    {
        static double Fps(MediaFrameFormat f) =>
            f.FrameRate is { Denominator: > 0 } r ? (double)r.Numerator / r.Denominator : 0;

        var landscape = formats.Where(f => f.VideoFormat.Width > f.VideoFormat.Height && f.VideoFormat.Width <= 1920).ToList();
        if (landscape.Count == 0) landscape = formats.ToList();
        if (landscape.Count == 0) return null;
        long maxArea = landscape.Max(f => (long)f.VideoFormat.Width * f.VideoFormat.Height);
        return landscape
            .Where(f => (long)f.VideoFormat.Width * f.VideoFormat.Height == maxArea)
            .OrderBy(f => Math.Round(Math.Abs(Fps(f) - targetFps), 1))
            .ThenBy(f => string.Equals(f.Subtype, MediaEncodingSubtypes.Nv12, StringComparison.OrdinalIgnoreCase) ? 0 : 1)
            .First();
    }

    void OnFrameArrived(MediaFrameReader sender, MediaFrameArrivedEventArgs args)
    {
        using var frame = sender.TryAcquireLatestFrame();
        var bitmap = frame?.VideoMediaFrame?.SoftwareBitmap;
        if (bitmap == null) return;
        SoftwareBitmap? converted = null;
        try
        {
            if (bitmap.BitmapPixelFormat != BitmapPixelFormat.Bgra8)
                bitmap = converted = SoftwareBitmap.Convert(bitmap, BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore);
            int w = bitmap.PixelWidth, h = bitmap.PixelHeight;
            if (pixels.Length != w * h * 4) pixels = new byte[w * h * 4];
            bitmap.CopyToBuffer(pixels.AsBuffer());
            Interlocked.Exchange(ref lastFrameTicks, Environment.TickCount64);
            FrameArrived?.Invoke(pixels, w, h);
        }
        catch (Exception e)
        {
            System.Diagnostics.Debug.WriteLine($"コマを読めません: {e.Message}");
        }
        finally
        {
            converted?.Dispose();
            frame?.VideoMediaFrame?.SoftwareBitmap?.Dispose();
        }
    }

    async Task CloseAsync()
    {
        var r = reader; reader = null;
        var c = capture; capture = null;
        openId = null;
        if (r != null)
        {
            r.FrameArrived -= OnFrameArrived;
            try { await r.StopAsync(); } catch { }
            r.Dispose();
        }
        c?.Dispose();
    }

    /// 最後にコマが届いてからの時間 (ミリ秒)
    public long MillisecondsSinceLastFrame => openId == null ? long.MaxValue : Environment.TickCount64 - Interlocked.Read(ref lastFrameTicks);

    public void Dispose()
    {
        watchdog.Stop();
        try { watcher.Stop(); } catch { }
        reader?.Dispose();
        capture?.Dispose();
    }
}
