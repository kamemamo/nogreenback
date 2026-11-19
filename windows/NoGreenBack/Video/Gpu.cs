// Direct3D 11 での合成と表示 (SPEC.md 4 章)
// - カメラのコマをテクスチャに上げ、キャンバス (合成した映像) に人物を置く
// - キャンバスを、プレビューなどのスワップチェーンに縦横比を保って描く (透明な部分は市松模様、余白は黒)
// いまは人物の切り抜きがないので、カメラの映像をそのまま「人物」として置いている。
// ここで使うものは、すべて Pipeline の lock の中から呼ぶ (Direct3D の immediate context は 1 つのスレッドからしか使えない)。

using System.Numerics;
using System.Runtime.InteropServices;
using Vortice.D3DCompiler;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.Mathematics;

namespace NoGreenBack.Video;

[StructLayout(LayoutKind.Sequential)]
struct ShaderParams
{
    public Vector4 Rect;    // 合成: 人物を置く四角 / 表示: 映像を置く四角 (どちらも左上原点の画素)
    public Vector4 P0;      // 合成: z 左右反転, w 人物を出す / 表示: x 市松模様のます目の大きさ, y 市松模様を敷く
    public Vector4 P1;
}

public sealed class Gpu : IDisposable
{
    // シェーダー。D3DCompiler には ASCII だけを渡す (日本語のコメントを入れると、文字数とバイト数がずれて末尾が切れる)
    // VS: 画面全体を覆う三角形 1 つ
    // PSComposite: 透明の上に人物を置く (出力はプリマルチプライドα)。人物マスクができるまでは不透明
    // PSPresent: 縦横比を保って置き、透明な部分だけ市松模様 (明るい灰 0.8 と暗い灰 0.55)、外は黒
    const string Shaders = """
        cbuffer Params : register(b0) { float4 rect; float4 p0; float4 p1; };
        Texture2D tex : register(t0);
        SamplerState smp : register(s0);

        struct VO { float4 pos : SV_Position; };

        VO VS(uint id : SV_VertexID)
        {
            VO o;
            float2 uv = float2((id << 1) & 2, id & 2);
            o.pos = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
            return o;
        }

        float4 PSComposite(VO i) : SV_Target
        {
            float2 q = (i.pos.xy - rect.xy) / rect.zw;
            if (p0.w < 0.5 || any(q < 0) || any(q > 1)) return 0;
            if (p0.z > 0.5) q.x = 1 - q.x;
            float4 c = tex.Sample(smp, q);
            c.a = 1;
            return float4(c.rgb * c.a, c.a);
        }

        float4 PSPresent(VO i) : SV_Target
        {
            float2 q = (i.pos.xy - rect.xy) / rect.zw;
            if (any(q < 0) || any(q > 1)) return float4(0, 0, 0, 1);
            float4 c = tex.Sample(smp, q);
            float2 cell = floor((i.pos.xy - rect.xy) / p0.x);
            float g = fmod(cell.x + cell.y, 2) < 1 ? 0.8 : 0.55;
            float3 under = p0.y > 0.5 ? g.xxx : float3(0, 0, 0);
            return float4(c.rgb + under * (1 - c.a), 1);
        }
        """;

    public ID3D11Device Device { get; }
    public ID3D11DeviceContext Context { get; }

    readonly ID3D11VertexShader vs;
    readonly ID3D11PixelShader psComposite, psPresent;
    readonly ID3D11SamplerState sampler;
    readonly ID3D11Buffer paramsBuffer;

    ID3D11Texture2D? cameraTex;
    ID3D11ShaderResourceView? cameraSrv;
    int cameraW, cameraH;

    ID3D11Texture2D? canvasTex;
    ID3D11RenderTargetView? canvasRtv;
    public ID3D11ShaderResourceView? CanvasSrv { get; private set; }
    public int CanvasWidth { get; private set; }
    public int CanvasHeight { get; private set; }

    public Gpu()
    {
        D3D11.D3D11CreateDevice(null, DriverType.Hardware, DeviceCreationFlags.BgraSupport,
            [FeatureLevel.Level_11_1, FeatureLevel.Level_11_0], out ID3D11Device device, out ID3D11DeviceContext context).CheckError();
        Device = device;
        Context = context;

        vs = Device.CreateVertexShader(Compile("VS", "vs_5_0"));
        psComposite = Device.CreatePixelShader(Compile("PSComposite", "ps_5_0"));
        psPresent = Device.CreatePixelShader(Compile("PSPresent", "ps_5_0"));
        sampler = Device.CreateSamplerState(SamplerDescription.LinearClamp);
        paramsBuffer = Device.CreateBuffer(new BufferDescription((uint)Marshal.SizeOf<ShaderParams>(), BindFlags.ConstantBuffer));
    }

    static byte[] Compile(string entry, string profile) =>
        Compiler.Compile(Shaders, entry, "NoGreenBack.hlsl", profile, ShaderFlags.OptimizationLevel3).ToArray();

    /// カメラのコマ (BGRA) をテクスチャに上げる
    public unsafe void UploadCamera(byte[] pixels, int width, int height)
    {
        if (cameraTex == null || cameraW != width || cameraH != height)
        {
            cameraSrv?.Dispose(); cameraTex?.Dispose();
            cameraTex = Device.CreateTexture2D(new Texture2DDescription
            {
                Width = (uint)width, Height = (uint)height, MipLevels = 1, ArraySize = 1,
                Format = Format.B8G8R8A8_UNorm, SampleDescription = new SampleDescription(1, 0),
                Usage = ResourceUsage.Default, BindFlags = BindFlags.ShaderResource,
            });
            cameraSrv = Device.CreateShaderResourceView(cameraTex);
            cameraW = width; cameraH = height;
        }
        fixed (byte* p = pixels)
            Context.UpdateSubresource(cameraTex, 0, null, (IntPtr)p, (uint)(width * 4), 0);
    }

    /// 人物をキャンバスの personRect (x, y, 幅, 高さ) に置く。カメラのコマがまだないか showPerson が false なら、人物なし (透明)
    public void Compose(int canvasW, int canvasH, Vector4 personRect, bool mirror, bool showPerson)
    {
        EnsureCanvas(canvasW, canvasH);
        Context.OMSetRenderTargets(canvasRtv!);
        Context.RSSetViewport(new Viewport(0, 0, canvasW, canvasH));
        Draw(psComposite, cameraSrv, new ShaderParams
        {
            Rect = personRect,
            P0 = new Vector4(0, 0, mirror ? 1 : 0, showPerson && cameraSrv != null ? 1 : 0),
        });
        Context.OMSetRenderTargets((ID3D11RenderTargetView)null!);
    }

    /// キャンバスを target に、縦横比を保って描く
    public void Present(ID3D11RenderTargetView target, int targetW, int targetH, bool checkerboard)
    {
        if (CanvasSrv == null) return;
        double scale = Math.Min((double)targetW / CanvasWidth, (double)targetH / CanvasHeight);
        float w = (float)(CanvasWidth * scale), h = (float)(CanvasHeight * scale);
        Context.OMSetRenderTargets(target);
        Context.RSSetViewport(new Viewport(0, 0, targetW, targetH));
        Draw(psPresent, CanvasSrv, new ShaderParams
        {
            Rect = new Vector4((targetW - w) / 2, (targetH - h) / 2, w, h),
            P0 = new Vector4(16, checkerboard ? 1 : 0, 0, 0),
        });
        Context.OMSetRenderTargets((ID3D11RenderTargetView)null!);
    }

    void Draw(ID3D11PixelShader ps, ID3D11ShaderResourceView? srv, ShaderParams p)
    {
        Context.UpdateSubresource(in p, paramsBuffer);
        Context.IASetPrimitiveTopology(PrimitiveTopology.TriangleList);
        Context.VSSetShader(vs);
        Context.PSSetShader(ps);
        Context.PSSetConstantBuffer(0, paramsBuffer);
        Context.PSSetSampler(0, sampler);
        Context.PSSetShaderResource(0, srv!);
        Context.Draw(3, 0);
        Context.PSSetShaderResource(0, null!);
    }

    void EnsureCanvas(int w, int h)
    {
        if (canvasTex != null && CanvasWidth == w && CanvasHeight == h) return;
        CanvasSrv?.Dispose(); canvasRtv?.Dispose(); canvasTex?.Dispose();
        canvasTex = Device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)w, Height = (uint)h, MipLevels = 1, ArraySize = 1,
            Format = Format.B8G8R8A8_UNorm, SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default, BindFlags = BindFlags.ShaderResource | BindFlags.RenderTarget,
        });
        canvasRtv = Device.CreateRenderTargetView(canvasTex);
        CanvasSrv = Device.CreateShaderResourceView(canvasTex);
        CanvasWidth = w; CanvasHeight = h;
    }

    public void Dispose()
    {
        CanvasSrv?.Dispose(); canvasRtv?.Dispose(); canvasTex?.Dispose();
        cameraSrv?.Dispose(); cameraTex?.Dispose();
        paramsBuffer.Dispose(); sampler.Dispose();
        psPresent.Dispose(); psComposite.Dispose(); vs.Dispose();
        Context.Dispose(); Device.Dispose();
    }
}

/// ウィンドウ (HWND) に描くためのスワップチェーン
public sealed class SwapChainTarget : IDisposable
{
    readonly Gpu gpu;
    readonly IDXGISwapChain1 swapChain;
    ID3D11RenderTargetView? rtv;
    public int Width { get; private set; }
    public int Height { get; private set; }

    public SwapChainTarget(Gpu gpu, IntPtr hwnd, int width, int height)
    {
        this.gpu = gpu;
        Width = Math.Max(1, width); Height = Math.Max(1, height);
        using var dxgiDevice = gpu.Device.QueryInterface<IDXGIDevice>();
        using var adapter = dxgiDevice.GetAdapter();
        using var factory = adapter.GetParent<IDXGIFactory2>();
        swapChain = factory.CreateSwapChainForHwnd(gpu.Device, hwnd, new SwapChainDescription1
        {
            Width = (uint)Width, Height = (uint)Height,
            Format = Format.B8G8R8A8_UNorm,
            BufferCount = 2,
            BufferUsage = Usage.RenderTargetOutput,
            SampleDescription = new SampleDescription(1, 0),
            SwapEffect = SwapEffect.FlipDiscard,
            Scaling = Scaling.Stretch,
            AlphaMode = AlphaMode.Ignore,
        });
        factory.MakeWindowAssociation(hwnd, WindowAssociationFlags.IgnoreAltEnter);
        CreateRtv();
    }

    void CreateRtv()
    {
        using var back = swapChain.GetBuffer<ID3D11Texture2D>(0);
        rtv = gpu.Device.CreateRenderTargetView(back);
    }

    public void Resize(int width, int height)
    {
        width = Math.Max(1, width); height = Math.Max(1, height);
        if (width == Width && height == Height) return;
        gpu.Context.OMSetRenderTargets((ID3D11RenderTargetView)null!);
        rtv?.Dispose(); rtv = null;
        gpu.Context.Flush();
        swapChain.ResizeBuffers(2, (uint)width, (uint)height, Format.B8G8R8A8_UNorm, SwapChainFlags.None).CheckError();
        Width = width; Height = height;
        CreateRtv();
    }

    /// キャンバスを描いて画面に出す
    public void Present(bool checkerboard)
    {
        if (rtv == null) return;
        gpu.Present(rtv, Width, Height, checkerboard);
        swapChain.Present(0, PresentFlags.None);
    }

    public void Dispose()
    {
        rtv?.Dispose();
        swapChain.Dispose();
    }
}
