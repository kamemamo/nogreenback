// WPF の中に Direct3D で描く場所を作る (子ウィンドウを置き、そこにスワップチェーンを作る)
// WPF の要素はこの上に重ねて描けない (airspace) ので、お知らせなどはこの外に出す。

using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace NoGreenBack.Video;

public sealed partial class D3DHost : HwndHost
{
    /// 子ウィンドウができた・大きさ (画素) が変わった
    public event Action<IntPtr, int, int>? PixelSizeChanged;

    public IntPtr Hwnd { get; private set; }

    protected override HandleRef BuildWindowCore(HandleRef hwndParent)
    {
        const int WS_CHILD = 0x40000000, WS_VISIBLE = 0x10000000, WS_CLIPSIBLINGS = 0x04000000, SS_BLACKRECT = 0x4;
        Hwnd = CreateWindowExW(0, "static", "", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | SS_BLACKRECT,
            0, 0, 1, 1, hwndParent.Handle, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        return new HandleRef(this, Hwnd);
    }

    protected override void DestroyWindowCore(HandleRef hwnd) => DestroyWindow(hwnd.Handle);

    protected override void OnWindowPositionChanged(Rect rcBoundingBox)
    {
        base.OnWindowPositionChanged(rcBoundingBox);
        if (Hwnd != IntPtr.Zero && GetClientRect(Hwnd, out var r))
            PixelSizeChanged?.Invoke(Hwnd, r.Right - r.Left, r.Bottom - r.Top);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    [LibraryImport("user32.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial IntPtr CreateWindowExW(int exStyle, string className, string windowName, int style,
        int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DestroyWindow(IntPtr hwnd);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetClientRect(IntPtr hwnd, out RECT rect);
}
