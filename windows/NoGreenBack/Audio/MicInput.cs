// マイク (SPEC.md 11 章「マイク」、9 章「録画の音声」)
// - 選択肢は「なし」「システムの設定に合わせる」(その時点の既定の入力の名前を添える) と、つながっているマイク。既定は「システムの設定に合わせる」
// - 選んだマイクが外れていたら「システムの設定に合わせる」に戻す。システムの既定の入力が変わったら、表示とメーターを合わせる
// - マイクを選んでいる間は、録画していなくてもメーターのためにマイクを開く。録画もこの同じ入力を使う
//   (同じ Bluetooth マイクを 2 か所から開くと途切れるため、別には開かない)
// - 音は AudioGraph で 48 kHz・モノラル・32 bit 浮動小数にそろえる (マイクごとに形式が違うため)

using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Threading;
using Windows.Devices.Enumeration;
using Windows.Media;
using Windows.Media.Audio;
using Windows.Media.Capture;
using Windows.Media.Devices;
using Windows.Media.MediaProperties;
using Windows.Media.Render;
using WinRT;

namespace NoGreenBack.Audio;

public sealed record MicChoice(string Id, string Label)
{
    public override string ToString() => Label;
}

public sealed class MicInput : Observable, IDisposable
{
    public const int SampleRate = 48000;
    const string NoneId = "none", SystemId = "";

    readonly Settings settings;
    readonly Dispatcher dispatcher;
    readonly DeviceWatcher watcher;
    readonly List<DeviceInformation> devices = [];
    string systemName = "";

    AudioGraph? graph;
    AudioFrameOutputNode? output;
    string? openId;   // 開いている機器の ID (null は開いていない)
    int openVersion;

    public ObservableCollection<MicChoice> Choices { get; } = [];

    /// 音が届いた (音声のスレッドで呼ばれる)。samples は 48 kHz モノラル。arrivedTicks は届いた時刻 (Stopwatch)
    public event Action<float[], int, long>? SamplesArrived;

    double level = -160;
    /// 直近のレベル (dBFS、無音で -160)
    public double Level => Volatile.Read(ref level);

    /// メーターの値 (0〜30。(dB + 60) / 2。24 が -12 dB、28 が -4 dB)
    double meter;
    public double Meter { get => meter; private set => Set(ref meter, value); }

    string message = "";
    /// 開けなかったときの知らせ
    public string Message { get => message; private set => Set(ref message, value); }

    public MicInput(Settings settings)
    {
        this.settings = settings;
        dispatcher = Dispatcher.CurrentDispatcher;

        settings.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(Settings.RecordMic) or nameof(Settings.RecordMicID)) { Raise(nameof(SelectedId)); Reopen(); }
        };
        MediaDevice.DefaultAudioCaptureDeviceChanged += (_, _) => dispatcher.BeginInvoke(async () =>
        {
            await RefreshSystemName();
            RefreshChoices();
            if (settings.RecordMic && settings.RecordMicID == null) Reopen(force: true);
        });

        watcher = DeviceInformation.CreateWatcher(DeviceClass.AudioCapture);
        watcher.Added += (_, d) => dispatcher.BeginInvoke(() => { if (d.IsEnabled && devices.All(x => x.Id != d.Id)) { devices.Add(d); RefreshChoices(); Reopen(); } });
        watcher.Removed += (_, u) => dispatcher.BeginInvoke(() =>
        {
            devices.RemoveAll(x => x.Id == u.Id);
            // 選んだマイクが外れたら「システムの設定に合わせる」に戻す
            if (settings.RecordMicID == u.Id) settings.RecordMicID = null;
            RefreshChoices();
        });
        watcher.Updated += (_, _) => { };
        watcher.EnumerationCompleted += (_, _) => dispatcher.BeginInvoke(async () => { await RefreshSystemName(); RefreshChoices(); Reopen(); });
        watcher.Start();

        // メーターは 10 回/秒
        new DispatcherTimer(TimeSpan.FromMilliseconds(100), DispatcherPriority.Background,
            (_, _) => Meter = Math.Clamp((Level + 60) / 2, 0, 30), dispatcher).Start();
    }

    /// 選んでいるもの ("none" はなし、空はシステムの設定に合わせる)
    public string SelectedId
    {
        get => !settings.RecordMic ? NoneId : settings.RecordMicID ?? SystemId;
        set
        {
            if (value == null) return;   // 一覧を作り直している間の空の選択は無視する
            if (value == NoneId) settings.RecordMic = false;
            else { settings.RecordMicID = value.Length == 0 ? null : value; settings.RecordMic = true; }
        }
    }

    /// マイクを使うか (「なし」でなければ使う)
    public bool Enabled => settings.RecordMic;

    async Task RefreshSystemName()
    {
        try
        {
            var id = MediaDevice.GetDefaultAudioCaptureId(AudioDeviceRole.Default);
            systemName = string.IsNullOrEmpty(id) ? "" : (await DeviceInformation.CreateFromIdAsync(id)).Name;
        }
        catch { systemName = ""; }
    }

    void RefreshChoices()
    {
        Choices.Clear();
        Choices.Add(new MicChoice(NoneId, Loc.L("なし")));
        Choices.Add(new MicChoice(SystemId, systemName.Length > 0 ? Loc.L("システムの設定に合わせる（%@）", systemName) : Loc.L("システムの設定に合わせる")));
        foreach (var d in devices) Choices.Add(new MicChoice(d.Id, d.Name));
        Raise(nameof(SelectedId));
    }

    /// 選んでいるマイクを開き直す (同じ機器ならそのまま)
    void Reopen(bool force = false)
    {
        string? want = !settings.RecordMic ? null
            : settings.RecordMicID != null && devices.Any(d => d.Id == settings.RecordMicID) ? settings.RecordMicID
            : MediaDevice.GetDefaultAudioCaptureId(AudioDeviceRole.Default);
        if (string.IsNullOrEmpty(want)) want = null;
        if (!force && want == openId && (want == null || graph != null)) return;
        Close();
        openId = want;
        if (want != null) _ = OpenAsync(want, ++openVersion);
    }

    async Task OpenAsync(string id, int version)
    {
        try
        {
            var props = AudioEncodingProperties.CreatePcm(SampleRate, 1, 32);
            props.Subtype = MediaEncodingSubtypes.Float;
            var gs = new AudioGraphSettings(AudioRenderCategory.Media) { EncodingProperties = props };
            var gr = await AudioGraph.CreateAsync(gs);
            if (gr.Status != AudioGraphCreationStatus.Success) throw new InvalidOperationException(gr.Status.ToString());
            var g = gr.Graph;
            var device = await DeviceInformation.CreateFromIdAsync(id);
            var ir = await g.CreateDeviceInputNodeAsync(MediaCategory.Other, props, device);
            if (ir.Status != AudioDeviceNodeCreationStatus.Success)
            {
                g.Dispose();
                if (ir.Status == AudioDeviceNodeCreationStatus.AccessDenied)
                {
                    Message = Loc.L("マイクへのアクセスが許可されていません。\n設定 > プライバシーとセキュリティ > マイク で、「デスクトップ アプリがマイクにアクセスできるようにする」をオンにしてください。");
                    return;
                }
                throw new InvalidOperationException(ir.Status.ToString());
            }
            var o = g.CreateFrameOutputNode(props);
            ir.DeviceInputNode.AddOutgoingConnection(o);
            if (version != openVersion) { g.Dispose(); return; }
            graph = g; output = o;
            g.QuantumStarted += OnQuantum;
            g.Start();
            Message = "";
            Log.Write($"マイク: {device.Name}");
        }
        catch (Exception e)
        {
            Log.Write($"マイクを開けません: {e.Message}");
            if (version == openVersion) Message = Loc.L("マイクを開けません: %@", e.Message);
        }
    }

    float[] buffer = new float[4800];

    unsafe void OnQuantum(AudioGraph sender, object args)
    {
        var o = output;
        if (o == null) return;
        long now = Stopwatch.GetTimestamp();
        using var frame = o.GetFrame();
        using var buf = frame.LockBuffer(AudioBufferAccessMode.Read);
        using var reference = buf.CreateReference();
        reference.As<IMemoryBufferByteAccess>().GetBuffer(out byte* data, out uint capacity);
        int n = (int)(buf.Length / sizeof(float));
        if (n <= 0) return;
        if (buffer.Length < n) buffer = new float[n];
        new ReadOnlySpan<float>(data, n).CopyTo(buffer);

        // レベル (RMS、dBFS)
        double sum = 0;
        for (int i = 0; i < n; i++) sum += buffer[i] * buffer[i];
        double rms = Math.Sqrt(sum / n);
        Volatile.Write(ref level, rms > 1e-8 ? 20 * Math.Log10(rms) : -160);

        SamplesArrived?.Invoke(buffer, n, now);
    }

    void Close()
    {
        var g = graph;
        graph = null; output = null; openId = null;
        Volatile.Write(ref level, -160);
        if (g != null)
        {
            g.QuantumStarted -= OnQuantum;
            try { g.Stop(); } catch { }
            g.Dispose();
        }
    }

    public void Dispose()
    {
        try { watcher.Stop(); } catch { }
        openVersion++;
        Close();
    }

    [ComImport, Guid("5B0D3235-4DBA-4D44-865E-8F1D0E4FD04D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    unsafe interface IMemoryBufferByteAccess
    {
        void GetBuffer(out byte* buffer, out uint capacity);
    }
}
