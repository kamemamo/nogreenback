// ATEM スイッチャー (SPEC.md 12 章)
// - Blackmagic Design の USB 機器 (メーカー番号 0x1EDB) のうち、名前に「ATEM」が入っているものがつながったら、自動でつなぐ。外れたら切る
//   (同じメーカーのキャプチャー機器には反応しない。名前が読めないときは ATEM とみなす)
// - 操作は ATEM Software Control に入っている SDK (BMDSwitcherAPI。COM) で USB 越しに行う。
//   入っていないときは、サイドバーに「ATEM Software Control を入れると、USB で操作できます」と出す
// - つながったら、上部に入力ボタン (外部の入力の名前) と「ミックス」を出し、サイドバーに状態を出す
// - ボタンを押すと、その入力を本番 (PGM) に出す。「ミックス」がオンなら ATEM で設定している切り替え効果で移り (長さ 0.5 秒)、オフならすぐ切り替える
// - ATEM 本体などで切り替えたときも、ボタンの表示を追従させる (0.2 秒ごとに本番の入力を読む)
// SDK の呼び出しは、すべて専用の 1 本のスレッドで行う (COM のスレッドの決まりで詰まらないように。Mac 版の queue と同じ考え方)。

using System.Collections.Concurrent;
using System.Collections.ObjectModel;
using System.Runtime.InteropServices;
using System.Windows.Threading;
using Windows.Devices.Enumeration;

namespace NoGreenBack.Atem;

/// 入力ボタン 1 つ
public sealed class AtemInput(long id, string name) : Observable
{
    public long Id { get; } = id;
    public string Name { get; } = name;
    /// ボタンに出す文字 (長い名前は番号にする)
    public string Label => Name.Length <= 6 ? Name : Id.ToString();
    bool isProgram;
    public bool IsProgram { get => isProgram; set => Set(ref isProgram, value); }
}

public sealed class AtemController : Observable, IDisposable
{
    readonly Settings settings;
    readonly Dispatcher dispatcher;
    readonly DeviceWatcher usbWatcher;
    readonly Dictionary<string, string> usbDevices = [];   // ID → 名前 (Blackmagic の USB 機器)
    readonly BlockingCollection<Action> work = new();
    readonly Thread worker;
    volatile bool wanted;   // つないでいたい (USB の ATEM がある)
    bool disposed;

    // ここから下の SDK のものは worker のスレッドだけで触る
    IBMDSwitcher? switcher;
    IBMDSwitcherMixEffectBlock? me;
    SwitcherCallback? callback;
    DateTime retryAt = DateTime.MinValue;
    long program = -1;

    public ObservableCollection<AtemInput> Inputs { get; } = [];

    bool present;
    /// USB で ATEM がつながっている (サイドバーの項目を出す)
    public bool Present { get => present; private set => Set(ref present, value); }

    bool connected;
    /// SDK でつながっている (上部の入力ボタンを出す)
    public bool Connected { get => connected; private set => Set(ref connected, value); }

    string status = "";
    public string Status { get => status; private set => Set(ref status, value); }

    /// SDK が使えるか (ATEM Software Control が入っているか)
    public static bool SdkAvailable { get; } = Type.GetTypeFromCLSID(AtemSdk.CLSID_CBMDSwitcherDiscovery, throwOnError: false) is { } t
        && Microsoft.Win32.Registry.ClassesRoot.OpenSubKey($@"CLSID\{{{AtemSdk.CLSID_CBMDSwitcherDiscovery}}}") != null;

    public AtemController(Settings settings)
    {
        this.settings = settings;
        dispatcher = Dispatcher.CurrentDispatcher;
        worker = new Thread(Run) { IsBackground = true, Name = "ATEM" };
        worker.SetApartmentState(ApartmentState.MTA);
        worker.Start();

        // Blackmagic の USB 機器の出入りを見張る (名前で ATEM を選ぶ)
        usbWatcher = DeviceInformation.CreateWatcher("System.Devices.DeviceInstanceId:~~\"VID_1EDB\"", null, DeviceInformationKind.Device);
        usbWatcher.Added += (_, d) => dispatcher.BeginInvoke(() => { usbDevices[d.Id] = d.Name ?? ""; Refresh(); });
        usbWatcher.Removed += (_, u) => dispatcher.BeginInvoke(() => { usbDevices.Remove(u.Id); Refresh(); });
        usbWatcher.Updated += (_, _) => { };
        usbWatcher.EnumerationCompleted += (_, _) => dispatcher.BeginInvoke(Refresh);
        usbWatcher.Start();
    }

    void Refresh()
    {
        bool found = usbDevices.Values.Any(n => n.Length == 0 || n.Contains("ATEM", StringComparison.OrdinalIgnoreCase));
        if (found == Present) return;
        Present = found;
        Log.Write(found ? "ATEM: USB でつながりました" : "ATEM: USB が外れました");
        if (found && !SdkAvailable)
        {
            Status = Loc.L("ATEM Software Control を入れると、USB で操作できます");
            return;
        }
        wanted = found;
        Status = found ? Loc.L("つないでいます…") : Loc.L("つないでいません");
        if (!found) work.Add(CloseSdk);
    }

    /// 入力ボタンを押した: 「ミックス」なら次に出す入力にしてから切り替え効果で移る。そうでなければすぐ切り替える
    public void Select(long input)
    {
        bool mix = settings.AtemMix;
        work.Add(() =>
        {
            if (me == null || switcher == null) return;
            if (mix)
            {
                me.SetPreviewInput(input);
                SetMixSeconds(0.5);
                me.PerformAutoTransition();
            }
            else me.SetProgramInput(input);
        });
    }

    void Run()
    {
        while (!disposed)
        {
            // 頼まれた操作をこなし、0.2 秒ごとに見回る
            if (work.TryTake(out var action, 200))
            {
                try { action(); } catch (Exception e) { Log.Write($"ATEM: {e.Message}"); }
                continue;
            }
            try { Tick(); } catch (Exception e) { Log.Write($"ATEM: {e.Message}"); CloseSdk(); }
        }
        CloseSdk();
    }

    /// つながるまで呼びかけ、つながっている間は本番の入力を読む
    void Tick()
    {
        if (!wanted) { if (switcher != null) CloseSdk(); return; }
        if (switcher != null)
        {
            if (callback!.Disconnected)
            {
                Log.Write("ATEM: 切れました");
                CloseSdk();
                retryAt = DateTime.Now.AddSeconds(1);
                Post(() => { Connected = false; Status = Loc.L("つないでいます…"); });
                return;
            }
            if (me != null && me.GetProgramInput(out long p) == 0 && p != program)
            {
                program = p;
                Post(() => { foreach (var i in Inputs) i.IsProgram = i.Id == p; });
            }
            return;
        }
        if (DateTime.Now < retryAt) return;

        var type = Type.GetTypeFromCLSID(AtemSdk.CLSID_CBMDSwitcherDiscovery)!;
        var discovery = (IBMDSwitcherDiscovery)Activator.CreateInstance(type)!;
        int hr = discovery.ConnectTo("", out var sw, out uint fail);   // 空なら USB でつなぐ
        Marshal.ReleaseComObject(discovery);
        if (hr != 0 || sw == null)
        {
            retryAt = DateTime.Now.AddSeconds(3);
            Log.Write($"ATEM: つなげません (0x{hr:X8}, 0x{fail:X8})");
            string why = fail == AtemSdk.ConnectToFailureIncompatibleFirmware ? Loc.L("ATEM のソフトと本体のバージョンが合いません") : Loc.L("見つかりません。もう一度試しています…");
            Post(() => Status = why);
            return;
        }
        switcher = sw;
        callback = new SwitcherCallback();
        sw.AddCallback(callback);
        sw.GetProductName(out string product);

        // 最初の M/E (ATEM Mini は 1 つだけ)
        var iid = AtemSdk.IID_IBMDSwitcherMixEffectBlockIterator;
        if (sw.CreateIterator(ref iid, out IntPtr mePtr) == 0 && mePtr != IntPtr.Zero)
        {
            var it = (IBMDSwitcherMixEffectBlockIterator)Marshal.GetObjectForIUnknown(mePtr);
            Marshal.Release(mePtr);
            if (it.Next(out var block) == 0) me = block;
            Marshal.ReleaseComObject(it);
        }
        // 外部の入力 (HDMI / SDI)
        var list = new List<AtemInput>();
        iid = AtemSdk.IID_IBMDSwitcherInputIterator;
        if (sw.CreateIterator(ref iid, out IntPtr inPtr) == 0 && inPtr != IntPtr.Zero)
        {
            var it = (IBMDSwitcherInputIterator)Marshal.GetObjectForIUnknown(inPtr);
            Marshal.Release(inPtr);
            while (it.Next(out var input) == 0 && input != null)
            {
                if (input.GetPortType(out uint port) == 0 && port == AtemSdk.PortTypeExternal && input.GetInputId(out long id) == 0)
                {
                    input.GetLongName(out string name);
                    list.Add(new AtemInput(id, string.IsNullOrEmpty(name) ? id.ToString() : name));
                }
                Marshal.ReleaseComObject(input);
            }
            Marshal.ReleaseComObject(it);
        }
        program = -1;
        Log.Write($"ATEM: つながりました ({product}、入力 {list.Count})");
        string detail = string.IsNullOrEmpty(product) ? "USB" : $"{product}・USB";
        Post(() =>
        {
            Inputs.Clear();
            foreach (var i in list) Inputs.Add(i);
            Connected = true;
            Status = Loc.L("つながりました（%@）", detail);
        });
    }

    /// ミックスの長さを秒で決める (映像のフレームレートからフレーム数に直す)
    void SetMixSeconds(double seconds)
    {
        if (switcher == null || me is not IBMDSwitcherTransitionMixParameters mix) return;
        double fps = switcher.GetVideoMode(out uint mode) == 0 ? AtemSdk.FramesPerSecond(mode) : 30;
        uint frames = (uint)Math.Max(1, Math.Round(seconds * fps));
        if (mix.GetRate(out uint current) != 0 || current != frames) mix.SetRate(frames);
    }

    void CloseSdk()
    {
        if (me != null) { Marshal.ReleaseComObject(me); me = null; }
        if (switcher != null)
        {
            try { if (callback != null) switcher.RemoveCallback(callback); } catch { }
            Marshal.ReleaseComObject(switcher);
            switcher = null;
        }
        callback = null;
        program = -1;
        Post(() => { Connected = false; Inputs.Clear(); });
    }

    void Post(Action a) => dispatcher.BeginInvoke(a);

    public void Dispose()
    {
        try { usbWatcher.Stop(); } catch { }
        wanted = false;
        disposed = true;
        worker.Join(TimeSpan.FromSeconds(2));
    }

    /// 切れたことを知るための受け口
    [ComVisible(true)]
    sealed class SwitcherCallback : IBMDSwitcherCallback
    {
        public volatile bool Disconnected;
        public int Notify(uint eventType, uint coreVideoMode)
        {
            if (eventType == AtemSdk.EventTypeDisconnected) Disconnected = true;
            return 0;
        }
    }
}
