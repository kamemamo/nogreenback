// デスクトップに重ねる透明なウィンドウの土台 (手書き・ホワイトボード・キーボード・指し棒。SPEC.md 7・8 章)
// - 枠なし・背景透明 (WPF の AllowsTransparency)・アクティブにならない・タスクバーに出ない・最前面
// - クリックを後ろへ通すかどうかを切り替えられる (WS_EX_TRANSPARENT)
// - 位置と大きさは物理的な画素で決める (アプリは Per-Monitor V2。WPF の論理的な単位で決めると、画面の拡大率でずれる)

using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace NoGreenBack.Overlays;

public partial class OverlayWindow : Window
{
    (int X, int Y, int W, int H)? placement;
    bool clickThrough = true;

    public IntPtr Hwnd { get; private set; }

    public OverlayWindow()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Focusable = false;
        Title = "NoGreenBack";

        SourceInitialized += (_, _) =>
        {
            Hwnd = new WindowInteropHelper(this).Handle;
            ApplyExStyle();
            HwndSource.FromHwnd(Hwnd).AddHook(Hook);
            if (placement is { } p) SetWindowPos(Hwnd, HWND_TOPMOST, p.X, p.Y, p.W, p.H, SWP_NOACTIVATE);
        };
        new WindowInteropHelper(this).EnsureHandle();
    }

    /// クリックを後ろへ通すか (既定は通す)
    public bool ClickThrough
    {
        get => clickThrough;
        set { if (clickThrough != value) { clickThrough = value; ApplyExStyle(); } }
    }

    void ApplyExStyle()
    {
        if (Hwnd == IntPtr.Zero) return;
        int ex = GetWindowLongW(Hwnd, GWL_EXSTYLE) | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
        ex = clickThrough ? ex | WS_EX_TRANSPARENT : ex & ~WS_EX_TRANSPARENT;
        SetWindowLongW(Hwnd, GWL_EXSTYLE, ex);
    }

    /// 位置と大きさ (物理的な画素) を決め、最前面に置く
    public void Place(int x, int y, int width, int height)
    {
        placement = (x, y, width, height);
        if (Hwnd != IntPtr.Zero) SetWindowPos(Hwnd, HWND_TOPMOST, x, y, width, height, SWP_NOACTIVATE);
    }

    /// アクティブにせずに見せる
    public void ShowNoActivate()
    {
        if (IsVisible) return;
        Show();
        if (placement is { } p) SetWindowPos(Hwnd, HWND_TOPMOST, p.X, p.Y, p.W, p.H, SWP_NOACTIVATE);
    }

    /// 画面の拡大率 (論理的な単位 1 あたりの画素)
    public double PixelsPerDip => VisualTreeHelper.GetDpi(this).DpiScaleX;

    IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        switch (msg)
        {
            case WM_MOUSEACTIVATE:
                handled = true;
                return MA_NOACTIVATE;
            case WM_DPICHANGED:
                // 拡大率の違う画面に移ると WPF が大きさを変えるので、決めた画素の位置と大きさに戻す
                Dispatcher.BeginInvoke(() =>
                {
                    if (placement is { } p) SetWindowPos(Hwnd, HWND_TOPMOST, p.X, p.Y, p.W, p.H, SWP_NOACTIVATE);
                });
                break;
        }
        return IntPtr.Zero;
    }

    /// 後ろから前へ並べた順に、最前面に置き直す (見えているものだけ)
    public static void Arrange(IEnumerable<IntPtr> backToFront)
    {
        foreach (var h in backToFront)
            if (h != IntPtr.Zero && IsWindowVisible(h))
                SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE);
    }

    const int GWL_EXSTYLE = -20;
    const int WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x8000000;
    const int WM_MOUSEACTIVATE = 0x21, WM_DPICHANGED = 0x2E0, MA_NOACTIVATE = 3;
    static readonly IntPtr HWND_TOPMOST = new(-1);
    const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOACTIVATE = 0x10;

    [LibraryImport("user32.dll")]
    private static partial int GetWindowLongW(IntPtr hwnd, int index);

    [LibraryImport("user32.dll")]
    private static partial int SetWindowLongW(IntPtr hwnd, int index, int value);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool IsWindowVisible(IntPtr hwnd);
}
