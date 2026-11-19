// 外部の音声 (SPEC.md 11 章「外部の音声」)
// キャプチャーボードやオーディオインターフェースの音を取り込み、
// - 選んだスピーカーにそのまま出す (LadioCast のような「聞きながら」)。音量はスピーカーと録画の両方に効く
// - 録画のときはマイクの音と混ぜて 1 本の音声にする (混ぜるのは Video.ScreenRecorder)
// 「入力」を選んでいる間は、アプリが裏にあっても取り込み続ける。48 kHz・モノラル・32 bit 浮動小数にそろえる。

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

public sealed record AudioChoice(string Id, string Label)
{
    public override string ToString() => Label;
}

public sealed class ExternalAudio : Observable, IDisposable
{
    const string NoneOutput = "none";

    readonly Settings settings;
    readonly Dispatcher dispatcher;
    readonly DeviceWatcher inputWatcher, outputWatcher;
    readonly List<DeviceInformation> inputs = [], outputs = [];

    AudioGraph? graph;
    AudioFrameOutputNode? tapNode;
    AudioDeviceOutputNode? speakerNode;
    string openKey = "";   // 開いている「入力|スピーカー」(空は開いていない)
    int openVersion;

    public ObservableCollection<AudioChoice> InputChoices { get; } = [];
    public ObservableCollection<AudioChoice> OutputChoices { get; } = [];

    /// 音が届いた (音声のスレッドで呼ばれる)。48 kHz モノラル。音量はまだ掛けていない
    public event Action<float[], int, long>? SamplesArrived;

    /// 取り込んでいる機器の ID (取り込んでいなければ null。マイクと同じ機器なら録画で混ぜないため)
    public string? OpenInputId { get; private set; }

    /// 音量 (0〜1。スピーカーと録画の両方に効く。録画中に動かしても反映する)
    public double Volume => settings.ExternalVolume;

    /// 声で下げる倍率 (1 下げない, 0.5, 0.25, 0.1)
    public double DuckFactor => settings.ExternalDuck;

    double level = -160;
    public double Level => Volatile.Read(ref level);

    double meter;
    /// メーターの値 (0〜30。(dB + 60) / 2)
    public double Meter { get => meter; private set => Set(ref meter, value); }

    public ExternalAudio(Settings settings)
    {
        this.settings = settings;
        dispatcher = Dispatcher.CurrentDispatcher;
        settings.PropertyChanged += (_, e) =>
        {
            switch (e.PropertyName)
            {
                case nameof(Settings.ExternalInputID): Raise(nameof(InputSelectedId)); Reopen(); break;
                case nameof(Settings.ExternalOutputUID): Raise(nameof(OutputSelectedId)); Reopen(); break;
                case nameof(Settings.ExternalVolume): if (speakerNode != null) speakerNode.OutgoingGain = settings.ExternalVolume; break;
            }
        };

        inputWatcher = Watch(DeviceClass.AudioCapture, inputs);
        outputWatcher = Watch(DeviceClass.AudioRender, outputs);
        MediaDevice.DefaultAudioRenderDeviceChanged += (_, _) => dispatcher.BeginInvoke(() =>
        {
            if (settings.ExternalOutputUID == "") Reopen(force: true);   // システムの出力に合わせているとき
        });

        new DispatcherTimer(TimeSpan.FromMilliseconds(100), DispatcherPriority.Background,
            (_, _) => Meter = Math.Clamp((Level + 60) / 2, 0, 30), dispatcher).Start();
        RefreshChoices();
    }

    DeviceWatcher Watch(DeviceClass kind, List<DeviceInformation> list)
    {
        var w = DeviceInformation.CreateWatcher(kind);
        w.Added += (_, d) => dispatcher.BeginInvoke(() => { if (d.IsEnabled && list.All(x => x.Id != d.Id)) { list.Add(d); RefreshChoices(); Reopen(); } });
        w.Removed += (_, u) => dispatcher.BeginInvoke(() => { list.RemoveAll(x => x.Id == u.Id); RefreshChoices(); Reopen(); });
        w.Updated += (_, _) => { };
        w.EnumerationCompleted += (_, _) => dispatcher.BeginInvoke(() => { RefreshChoices(); Reopen(); });
        w.Start();
        return w;
    }

    /// 入力 (空は「使わない」)
    public string InputSelectedId
    {
        get => settings.ExternalInputID ?? "";
        set { if (value != null) settings.ExternalInputID = value.Length == 0 ? null : value; }
    }

    /// スピーカー ("none" は出さない、空はシステムの出力)
    public string OutputSelectedId
    {
        get => settings.ExternalOutputUID ?? NoneOutput;
        set { if (value != null) settings.ExternalOutputUID = value == NoneOutput ? null : value; }
    }

    void RefreshChoices()
    {
        InputChoices.Clear();
        InputChoices.Add(new AudioChoice("", Loc.L("使わない")));
        foreach (var d in inputs) InputChoices.Add(new AudioChoice(d.Id, d.Name));
        OutputChoices.Clear();
        OutputChoices.Add(new AudioChoice(NoneOutput, Loc.L("出さない")));
        OutputChoices.Add(new AudioChoice("", Loc.L("システムの出力")));
        foreach (var d in outputs) OutputChoices.Add(new AudioChoice(d.Id, d.Name));
        Raise(nameof(InputSelectedId));
        Raise(nameof(OutputSelectedId));
    }

    /// 選んでいる入力とスピーカーで開き直す (同じならそのまま)
    void Reopen(bool force = false)
    {
        string? input = settings.ExternalInputID is { } id && inputs.Any(d => d.Id == id) ? id : null;
        string? output = settings.ExternalOutputUID is { } o && (o == "" || outputs.Any(d => d.Id == o)) ? o : null;
        string key = input == null ? "" : $"{input}|{output ?? NoneOutput}";
        if (!force && key == openKey) return;
        Close();
        openKey = key;
        if (input != null) _ = OpenAsync(input, output, ++openVersion);
    }

    async Task OpenAsync(string inputId, string? outputId, int version)
    {
        try
        {
            var props = AudioEncodingProperties.CreatePcm(MicInput.SampleRate, 1, 32);
            props.Subtype = MediaEncodingSubtypes.Float;
            var gs = new AudioGraphSettings(AudioRenderCategory.Media) { EncodingProperties = props };
            // スピーカーに出すときは、その機器を主の出力にする (出さないときも、時計のために既定の出力を使う)
            if (!string.IsNullOrEmpty(outputId)) gs.PrimaryRenderDevice = await DeviceInformation.CreateFromIdAsync(outputId);
            var gr = await AudioGraph.CreateAsync(gs);
            if (gr.Status != AudioGraphCreationStatus.Success) throw new InvalidOperationException(gr.Status.ToString());
            var g = gr.Graph;
            var device = await DeviceInformation.CreateFromIdAsync(inputId);
            var ir = await g.CreateDeviceInputNodeAsync(MediaCategory.Other, props, device);
            if (ir.Status != AudioDeviceNodeCreationStatus.Success) { g.Dispose(); throw new InvalidOperationException(ir.Status.ToString()); }
            var tap = g.CreateFrameOutputNode(props);
            ir.DeviceInputNode.AddOutgoingConnection(tap);
            AudioDeviceOutputNode? speaker = null;
            if (outputId != null)
            {
                var or = await g.CreateDeviceOutputNodeAsync();
                if (or.Status == AudioDeviceNodeCreationStatus.Success)
                {
                    speaker = or.DeviceOutputNode;
                    speaker.OutgoingGain = settings.ExternalVolume;
                    ir.DeviceInputNode.AddOutgoingConnection(speaker);
                }
                else Log.Write($"外部の音声: スピーカーを開けません ({or.Status})");
            }
            if (version != openVersion) { g.Dispose(); return; }
            graph = g; tapNode = tap; speakerNode = speaker;
            OpenInputId = inputId;
            g.QuantumStarted += OnQuantum;
            g.Start();
            Log.Write($"外部の音声: {device.Name} → {(outputId == null ? "出さない" : g.PrimaryRenderDevice?.Name ?? "システムの出力")}");
        }
        catch (Exception e)
        {
            Log.Write($"外部の音声を開けません: {e.Message}");
        }
    }

    float[] buffer = new float[4800];

    unsafe void OnQuantum(AudioGraph sender, object args)
    {
        var t = tapNode;
        if (t == null) return;
        long now = Stopwatch.GetTimestamp();
        using var frame = t.GetFrame();
        using var buf = frame.LockBuffer(AudioBufferAccessMode.Read);
        using var reference = buf.CreateReference();
        reference.As<IMemoryBufferByteAccess>().GetBuffer(out byte* data, out _);
        int n = (int)(buf.Length / sizeof(float));
        if (n <= 0) return;
        if (buffer.Length < n) buffer = new float[n];
        new ReadOnlySpan<float>(data, n).CopyTo(buffer);
        double sum = 0;
        for (int i = 0; i < n; i++) sum += buffer[i] * buffer[i];
        double rms = Math.Sqrt(sum / n);
        Volatile.Write(ref level, rms > 1e-8 ? 20 * Math.Log10(rms) : -160);
        SamplesArrived?.Invoke(buffer, n, now);
    }

    void Close()
    {
        var g = graph;
        graph = null; tapNode = null; speakerNode = null; OpenInputId = null; openKey = "";
        Volatile.Write(ref level, -160);
        if (g == null) return;
        g.QuantumStarted -= OnQuantum;
        try { g.Stop(); } catch { }
        g.Dispose();
    }

    public void Dispose()
    {
        try { inputWatcher.Stop(); } catch { }
        try { outputWatcher.Stop(); } catch { }
        openVersion++;
        Close();
    }

    [ComImport, Guid("5B0D3235-4DBA-4D44-865E-8F1D0E4FD04D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    unsafe interface IMemoryBufferByteAccess
    {
        void GetBuffer(out byte* buffer, out uint capacity);
    }
}
