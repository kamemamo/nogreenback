// 画面の一覧 (SPEC.md 5 章「表示する画面」「出す画面」「録画する画面」)
// - 画面は名前で覚える。名前はモニターの名前 (DisplayConfig の monitorFriendlyDeviceName)。同じ名前が並ぶときは「(2)」を付ける
// - 一覧の最初は主ディスプレイ。あとは左から順
// - 覚えた名前の画面がないときの既定: 表示する画面は主ディスプレイ、出す画面はメイン以外の画面 (なければ主ディスプレイ)
// - 画面をつないだり外したりしたら一覧を作り直し、Changed で知らせる
// 座標と大きさは物理的な画素 (アプリは Per-Monitor V2)。

using System.Collections.ObjectModel;
using System.Runtime.InteropServices;
using System.Windows.Threading;
using Microsoft.Win32;

namespace NoGreenBack;

/// Name は設定に保存する名前 (表示の言語によらない)。Label は画面に出す名前 (名前のない画面は訳した名前になる)
public sealed record DisplayInfo(string Name, string Label, string DeviceName, int Left, int Top, int Width, int Height, bool IsPrimary)
{
    public override string ToString() => Label;
}

public sealed partial class Displays : Observable, IDisposable
{
    readonly Settings settings;
    readonly Dispatcher dispatcher;

    public ObservableCollection<DisplayInfo> All { get; } = [];

    /// 画面の一覧が変わった (引数は画面の数が減ったか)
    public event Action<bool>? Changed;

    public Displays(Settings settings)
    {
        this.settings = settings;
        dispatcher = Dispatcher.CurrentDispatcher;
        Refresh();
        settings.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(Settings.OverlayScreen)) Raise(nameof(OverlayDisplay));
            if (e.PropertyName == nameof(Settings.OutputScreen)) { Raise(nameof(OutputDisplay)); Raise(nameof(OutputAspect)); }
        };
        SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;
    }

    void OnDisplaySettingsChanged(object? sender, EventArgs e) =>
        dispatcher.BeginInvoke(() =>
        {
            int before = All.Count;
            Refresh();
            Changed?.Invoke(All.Count < before);
        });

    /// 表示する画面 (ワイプを出す画面)。一覧から外れて選択が空になっても、覚えた名前は消さない
    public DisplayInfo? OverlayDisplay
    {
        get => Find(settings.OverlayScreen) ?? All.FirstOrDefault();
        set { if (value != null) settings.OverlayScreen = value.Name; }
    }

    /// 出す画面 (全画面出力を出す画面)
    public DisplayInfo? OutputDisplay
    {
        get => Find(settings.OutputScreen) ?? All.FirstOrDefault(d => !d.IsPrimary) ?? All.FirstOrDefault();
        set { if (value != null) settings.OutputScreen = value.Name; }
    }

    /// 出す画面の横縦比 (映像の比率を「出す画面に合わせる」ときに使う。画面がなければ 0)
    public double OutputAspect => OutputDisplay is { Height: > 0 } d ? (double)d.Width / d.Height : 0;

    /// 保存した名前から画面を探す (前の版で、訳した名前で保存していたものも探せるように Label とも比べる)
    public DisplayInfo? Find(string? name) => name == null ? null : All.FirstOrDefault(d => d.Name == name) ?? All.FirstOrDefault(d => d.Label == name);

    void Refresh()
    {
        var list = Enumerate();
        All.Clear();
        foreach (var d in list) All.Add(d);
        Log.Write("画面: " + string.Join(", ", list.Select(d => $"{d.Name} {d.Width}x{d.Height} ({d.Left},{d.Top}){(d.IsPrimary ? " 主" : "")}")));
        Raise(nameof(OverlayDisplay));
        Raise(nameof(OutputDisplay));
        Raise(nameof(OutputAspect));
    }

    static List<DisplayInfo> Enumerate()
    {
        var monitors = new List<(string Device, RECT Rect, bool Primary)>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (h, _, _, _) =>
        {
            var info = new MONITORINFOEXW { cbSize = Marshal.SizeOf<MONITORINFOEXW>() };
            if (GetMonitorInfoW(h, ref info)) monitors.Add((info.szDevice, info.rcMonitor, (info.dwFlags & 1) != 0));
            return true;
        }, IntPtr.Zero);

        var names = FriendlyNames();
        var ordered = monitors.OrderByDescending(m => m.Primary).ThenBy(m => m.Rect.Left).ThenBy(m => m.Rect.Top).ToList();
        var result = new List<DisplayInfo>();
        for (int i = 0; i < ordered.Count; i++)
        {
            var m = ordered[i];
            // モニターの名前がなければ、保存する名前は言語によらない決まった名前にし、画面に出す名前だけ訳す
            // (表示の言語を変えても、覚えた画面がわかるように)
            bool hasName = names.TryGetValue(m.Device, out var n) && n.Name.Length > 0;
            bool isInternal = names.TryGetValue(m.Device, out n) && n.Internal;
            string name = hasName ? n.Name : isInternal ? "Built-in Display" : $"Display {i + 1}";
            string label = hasName ? n.Name : isInternal ? Loc.L("内蔵ディスプレイ") : Loc.L("画面 %d", i + 1);
            // 同じ名前の画面が並ぶときは (2)、(3) を付ける
            string unique = name, uniqueLabel = label;
            for (int k = 2; result.Any(r => r.Name == unique); k++) { unique = $"{name} ({k})"; uniqueLabel = $"{label} ({k})"; }
            result.Add(new DisplayInfo(unique, uniqueLabel, m.Device, m.Rect.Left, m.Rect.Top,
                m.Rect.Right - m.Rect.Left, m.Rect.Bottom - m.Rect.Top, m.Primary));
        }
        return result;
    }

    /// GDI の画面の名前 (\\.\DISPLAY1 など) から、モニターの名前を引く
    static Dictionary<string, (string Name, bool Internal)> FriendlyNames()
    {
        var map = new Dictionary<string, (string, bool)>(StringComparer.OrdinalIgnoreCase);
        const uint QDC_ONLY_ACTIVE_PATHS = 2;
        const int PathSize = 72, ModeSize = 64;
        try
        {
            if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out uint pathCount, out uint modeCount) != 0) return map;
            var paths = new byte[pathCount * PathSize];
            var modes = new byte[modeCount * ModeSize];
            if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero) != 0) return map;
            for (int i = 0; i < pathCount; i++)
            {
                int p = i * PathSize;
                // DISPLAYCONFIG_PATH_INFO: sourceInfo (adapterId 8, id 4, ...) は 0 から、targetInfo (adapterId 8, id 4, ...) は 20 から
                long srcAdapter = BitConverter.ToInt64(paths, p);
                uint srcId = BitConverter.ToUInt32(paths, p + 8);
                long tgtAdapter = BitConverter.ToInt64(paths, p + 20);
                uint tgtId = BitConverter.ToUInt32(paths, p + 28);
                uint tech = BitConverter.ToUInt32(paths, p + 36);

                // DISPLAYCONFIG_SOURCE_DEVICE_NAME: header 20 + viewGdiDeviceName[32]
                var src = new byte[20 + 64];
                WriteHeader(src, 1, srcAdapter, srcId);
                if (DisplayConfigGetDeviceInfo(src) != 0) continue;
                string gdi = ReadString(src, 20, 32);

                // DISPLAYCONFIG_TARGET_DEVICE_NAME: header 20 + flags 4 + tech 4 + edid 2 + 2 + connector 4 + monitorFriendlyDeviceName[64] + monitorDevicePath[128]
                var tgt = new byte[20 + 16 + 128 + 256];
                WriteHeader(tgt, 2, tgtAdapter, tgtId);
                string friendly = DisplayConfigGetDeviceInfo(tgt) == 0 ? ReadString(tgt, 36, 64) : "";
                // 内蔵の画面: INTERNAL (0x80000000)、DISPLAYPORT_EMBEDDED (11)、UDI_EMBEDDED (13)
                bool isInternal = tech == 0x80000000 || tech == 11 || tech == 13;
                map.TryAdd(gdi, (friendly, isInternal));
            }
        }
        catch (Exception e) { Log.Write($"画面の名前を読めません: {e.Message}"); }
        return map;
    }

    static void WriteHeader(byte[] buf, int type, long adapter, uint id)
    {
        BitConverter.TryWriteBytes(buf.AsSpan(0), type);
        BitConverter.TryWriteBytes(buf.AsSpan(4), buf.Length);
        BitConverter.TryWriteBytes(buf.AsSpan(8), adapter);
        BitConverter.TryWriteBytes(buf.AsSpan(16), id);
    }

    static string ReadString(byte[] buf, int offset, int chars)
    {
        var s = System.Text.Encoding.Unicode.GetString(buf, offset, chars * 2);
        int end = s.IndexOf('\0');
        return (end < 0 ? s : s[..end]).Trim();
    }

    public void Dispose() => SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct MONITORINFOEXW
    {
        public int cbSize;
        public RECT rcMonitor, rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }

    delegate bool MonitorEnumProc(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr data);

    [DllImport("user32.dll")]
    static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool GetMonitorInfoW(IntPtr monitor, ref MONITORINFOEXW info);

    [LibraryImport("user32.dll")]
    private static partial int GetDisplayConfigBufferSizes(uint flags, out uint pathCount, out uint modeCount);

    [LibraryImport("user32.dll")]
    private static partial int QueryDisplayConfig(uint flags, ref uint pathCount, [Out] byte[] paths, ref uint modeCount, [Out] byte[] modes, IntPtr topology);

    [LibraryImport("user32.dll")]
    private static partial int DisplayConfigGetDeviceInfo([In, Out] byte[] packet);
}
