// Windows.Graphics.Capture で画面を取り込むための、COM との橋渡し (背景映像と画面録画で使う)

using System.Runtime.InteropServices;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX.Direct3D11;
using WinRT;

namespace NoGreenBack.Video;

public static partial class CaptureInterop
{
    /// 画面 (モニター) を取り込む対象
    public static GraphicsCaptureItem CreateItemForMonitor(DisplayInfo d)
    {
        var monitor = MonitorFromPoint(new POINT { X = d.Left + d.Width / 2, Y = d.Top + d.Height / 2 }, 2 /* MONITOR_DEFAULTTONEAREST */);
        var interop = GraphicsCaptureItem.As<IGraphicsCaptureItemInterop>();
        var iid = new Guid("79C3F95B-31F7-4EC2-A464-632EF5D30760");   // IGraphicsCaptureItem
        var ptr = interop.CreateForMonitor(monitor, ref iid);
        try { return GraphicsCaptureItem.FromAbi(ptr); }
        finally { Marshal.Release(ptr); }
    }

    /// Direct3D 11 のデバイスを、WinRT の IDirect3DDevice として包む
    public static IDirect3DDevice CreateDirect3DDevice(ID3D11Device device)
    {
        using var dxgi = device.QueryInterface<IDXGIDevice>();
        Marshal.ThrowExceptionForHR(CreateDirect3D11DeviceFromDXGIDevice(dxgi.NativePointer, out var ptr));
        try { return MarshalInterface<IDirect3DDevice>.FromAbi(ptr); }
        finally { Marshal.Release(ptr); }
    }

    /// 取り込んだコマのテクスチャ (呼んだ側で Dispose する)
    public static ID3D11Texture2D GetTexture(Direct3D11CaptureFrame frame)
    {
        var access = frame.Surface.As<IDirect3DDxgiInterfaceAccess>();
        var iid = typeof(ID3D11Texture2D).GUID;
        return new ID3D11Texture2D(access.GetInterface(ref iid));
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
