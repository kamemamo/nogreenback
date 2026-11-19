// Direct3D で描くための、枠のない Win32 のウィンドウ (全画面出力とワイプに使う)
// WPF のウィンドウにすると DPI の換算 (論理と物理の画素) や透明の扱いが絡むので、画素の座標でそのまま作る。
// UI のスレッドで作り、UI のスレッドで閉じる。

using System.Runtime.InteropServices;

namespace NoGreenBack.Video;

public sealed partial class SurfaceWindow : IDisposable
{
    public const int WS_POPUP = unchecked((int)0x80000000);
    public const int WS_EX_TOPMOST = 0x8, WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80,
        WS_EX_LAYERED = 0x80000, WS_EX_NOACTIVATE = 0x8000000, WS_EX_NOREDIRECTIONBITMAP = 0x200000;

    const string ClassName = "NoGreenBackSurface";
    const uint WM_KEYDOWN = 0x100, WM_CLOSE = 0x10, WM_MOUSEACTIVATE = 0x21;
    const int MA_NOACTIVATE = 3;

    static readonly WndProc wndProc = Proc;   // GC に回収されないように持っておく
    static readonly Dictionary<IntPtr, SurfaceWindow> windows = [];
    static bool registered;

    public IntPtr Hwnd { get; }
    readonly bool noActivate;

    /// キーが押された (仮想キーコード)
    public event Action<int>? KeyDown;

    public SurfaceWindow(string title, int exStyle, int x, int y, int width, int height)
    {
        Register();
        noActivate = (exStyle & WS_EX_NOACTIVATE) != 0;
        Hwnd = CreateWindowExW(exStyle, ClassName, title, WS_POPUP, x, y, width, height,
            IntPtr.Zero, IntPtr.Zero, GetModuleHandleW(null), IntPtr.Zero);
        if (Hwnd == IntPtr.Zero) throw new InvalidOperationException($"ウィンドウを作れません ({Marshal.GetLastPInvokeError()})");
        windows[Hwnd] = this;
        if ((exStyle & WS_EX_LAYERED) != 0) SetLayeredWindowAttributes(Hwnd, 0, 255, 2 /* LWA_ALPHA */);
    }

    static void Register()
    {
        if (registered) return;
        var wc = new WNDCLASSEXW
        {
            cbSize = Marshal.SizeOf<WNDCLASSEXW>(),
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(wndProc),
            hInstance = GetModuleHandleW(null),
            hCursor = LoadCursorW(IntPtr.Zero, 32512 /* IDC_ARROW */),
            hbrBackground = GetStockObject(4 /* BLACK_BRUSH */),
            lpszClassName = ClassName,
        };
        if (RegisterClassExW(ref wc) == 0) throw new InvalidOperationException($"ウィンドウの種類を登録できません ({Marshal.GetLastPInvokeError()})");
        registered = true;
    }

    static IntPtr Proc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        windows.TryGetValue(hwnd, out var w);
        switch (msg)
        {
            case WM_KEYDOWN:
                w?.KeyDown?.Invoke((int)wParam);
                return IntPtr.Zero;
            case WM_MOUSEACTIVATE when w is { noActivate: true }:
                return MA_NOACTIVATE;
            case WM_CLOSE:
                return IntPtr.Zero;   // Alt+F4 では閉じない (閉じるのはアプリが決める)
        }
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }

    /// 見せる。activate なら前面に出してキー入力を受ける
    public void Show(bool activate)
    {
        ShowWindow(Hwnd, activate ? 5 /* SW_SHOW */ : 8 /* SW_SHOWNA */);
        if (activate) SetForegroundWindow(Hwnd);
    }

    /// 位置と大きさを変え、最前面に置き直す
    public void Place(int x, int y, int width, int height) =>
        SetWindowPos(Hwnd, HWND_TOPMOST, x, y, width, height, SWP_NOACTIVATE);

    /// 最前面を取り直す (スライドショーなど、あとから最前面に出たウィンドウに隠されないように)
    public void BringToTop() =>
        SetWindowPos(Hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE);

    public void Dispose()
    {
        windows.Remove(Hwnd);
        DestroyWindow(Hwnd);
    }

    /// いま前面にあるウィンドウが、このアプリのものか
    public static bool AppIsForeground()
    {
        GetWindowThreadProcessId(GetForegroundWindow(), out uint pid);
        return pid == Environment.ProcessId;
    }

    static readonly IntPtr HWND_TOPMOST = new(-1);
    const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOACTIVATE = 0x10;

    delegate IntPtr WndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASSEXW
    {
        public int cbSize;
        public uint style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra, cbWndExtra;
        public IntPtr hInstance, hIcon, hCursor, hbrBackground;
        public string? lpszMenuName;
        public string lpszClassName;
        public IntPtr hIconSm;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern ushort RegisterClassExW(ref WNDCLASSEXW wc);

    [LibraryImport("user32.dll", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    private static partial IntPtr CreateWindowExW(int exStyle, string className, string windowName, int style,
        int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);

    [LibraryImport("user32.dll")]
    private static partial IntPtr DefWindowProcW(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DestroyWindow(IntPtr hwnd);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ShowWindow(IntPtr hwnd, int cmd);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetForegroundWindow(IntPtr hwnd);

    [LibraryImport("user32.dll")]
    private static partial IntPtr GetForegroundWindow();

    [LibraryImport("user32.dll")]
    private static partial uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetLayeredWindowAttributes(IntPtr hwnd, uint key, byte alpha, uint flags);

    [LibraryImport("user32.dll")]
    private static partial IntPtr LoadCursorW(IntPtr instance, int id);

    [LibraryImport("gdi32.dll")]
    private static partial IntPtr GetStockObject(int obj);

    [LibraryImport("kernel32.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial IntPtr GetModuleHandleW(string? name);
}
