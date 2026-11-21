// デスクトップに出す指し棒 (SPEC.md 8 章「指し棒」)
// 画面の描き変えに合わせて、なめらかに動かす:
// - すべての画面を覆う、透明でクリックを通す最前面のウィンドウに、DirectComposition で指し棒の絵を置く
// - 専用のスレッドで、画面の合成 (DWM) の 1 回ごとにマウスの位置を読み、絵の位置 (ビジュアルのずらし量) だけを変える。
//   画面の合成と同じ回数だけ動き (この PC では、全画面出力の上で 1 秒に 240 回、デスクトップで約 150 回)、マウスより 1 回分しか遅れない
// - 絵は傾き (0.5 度きざみ) と画面の高さで決まるので、作った絵を使い回す。新しい傾きの絵は UI のスレッドで作り (WPF で描くため)、
//   できるまでは前の絵のまま動かす
// - 全画面出力の画面の上にも、このウィンドウで出す (全画面出力より手前)。プレビューと Spout には、映像の中にも描く (OverlayController)

using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Threading;
using NoGreenBack.Video;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DirectComposition;
using Vortice.DXGI;

namespace NoGreenBack.Overlays;

public sealed partial class PointerSurface : IDisposable
{
    readonly Dispatcher ui;
    readonly SurfaceWindow window;
    readonly object gate = new();
    readonly AutoResetEvent wake = new(false);
    readonly ConcurrentDictionary<string, PointerRenderer.Rendered?> cache = new();
    readonly ConcurrentDictionary<string, bool> pending = new();
    Thread? thread;
    volatile bool quit;

    // UI のスレッドで書き、描くスレッドで読む (gate で守る)
    bool enabled;
    DisplayInfo[] displays = [];
    int vx, vy;   // ウィンドウの左上 (すべての画面を覆う四角の左上)

    /// ウィンドウ (重なり順と、画面の取り込みから外すため)
    public IntPtr Hwnd => window.Hwnd;

    public PointerSurface()
    {
        ui = Dispatcher.CurrentDispatcher;
        window = new SurfaceWindow("NoGreenBack Pointer",
            SurfaceWindow.WS_EX_LAYERED | SurfaceWindow.WS_EX_TRANSPARENT | SurfaceWindow.WS_EX_TOPMOST
            | SurfaceWindow.WS_EX_NOACTIVATE | SurfaceWindow.WS_EX_TOOLWINDOW | SurfaceWindow.WS_EX_NOREDIRECTIONBITMAP,
            0, 0, 1, 1);
    }

    /// 画面の一覧が変わった: ウィンドウですべての画面を覆い直す (UI のスレッドから呼ぶ)
    public void SetDisplays(IReadOnlyList<DisplayInfo> list)
    {
        if (list.Count == 0) return;
        int l = list.Min(d => d.Left), t = list.Min(d => d.Top);
        int r = list.Max(d => d.Left + d.Width), b = list.Max(d => d.Top + d.Height);
        lock (gate) { displays = [.. list]; vx = l; vy = t; }
        window.Place(l, t, r - l, b - t);
        cache.Clear();
    }

    /// 出す・隠す (UI のスレッドから呼ぶ)
    public void SetEnabled(bool on)
    {
        lock (gate) enabled = on;
        if (on)
        {
            window.Show(activate: false);
            window.BringToTop();
            if (thread == null)
            {
                thread = new Thread(Run) { IsBackground = true, Name = "NoGreenBack Pointer", Priority = ThreadPriority.AboveNormal };
                thread.Start();
            }
        }
        wake.Set();
    }

    // ── 描くスレッド ──

    ID3D11Device? device;
    ID3D11DeviceContext? context;
    IDXGISwapChain1? swapChain;
    IDCompositionDevice? dcomp;
    IDCompositionTarget? target;
    IDCompositionVisual? visual;
    PointerRenderer.Rendered? shown;      // いまのせている絵
    int swapW, swapH;
    bool attached;                        // スワップチェーンをビジュアルにつけているか (隠すときに外す)

    void Run()
    {
        try
        {
            Setup();
            DisplayInfo? lastDisplay = null;
            double? angle = null;
            int lastX = int.MinValue, lastY = int.MinValue;
            long lastTicks = Stopwatch.GetTimestamp();
            // 様子 (オフにしたときにログに書く)
            long frames = 0, moves = 0, statStart = Stopwatch.GetTimestamp();
            double maxGap = 0;
            long lastMove = 0;

            while (!quit)
            {
                bool on; DisplayInfo[] list; int ox0, oy0;
                lock (gate) { on = enabled; list = displays; ox0 = vx; oy0 = vy; }
                if (!on)
                {
                    if (frames > 0)
                    {
                        double sec = Stopwatch.GetElapsedTime(statStart).TotalSeconds;
                        Log.Write($"指し棒: 画面の合成 {frames / sec:F0} 回/秒、動かした {moves / sec:F0} 回/秒、動かす間隔の最大 {maxGap:F1} ms");
                        frames = 0; moves = 0; maxGap = 0; lastMove = 0;
                    }
                    if (attached) { visual!.SetContent(null!); dcomp!.Commit(); attached = false; }
                    shown = null;
                    angle = null; lastDisplay = null; lastX = lastY = int.MinValue;
                    // 隠す前に、すぐまたオンにされていないかを確かめる (オンにした後で隠してしまわないため)
                    ui.BeginInvoke(() => { bool onAgain; lock (gate) onAgain = enabled; if (!onAgain) window.Hide(); });
                    wake.WaitOne();
                    statStart = Stopwatch.GetTimestamp();
                    lastTicks = statStart;
                    continue;
                }

                // 画面の合成の 1 回を待つ
                if (DCompositionWaitForCompositorClock(0, IntPtr.Zero, 100) == 0xFFFFFFFF) DwmFlush();
                frames++;
                long now = Stopwatch.GetTimestamp();
                double dt = Stopwatch.GetElapsedTime(lastTicks, now).TotalSeconds;
                lastTicks = now;

                if (!GetCursorPos(out var m)) continue;
                var d = list.FirstOrDefault(x => m.X >= x.Left && m.X < x.Left + x.Width && m.Y >= x.Top && m.Y < x.Top + x.Height);
                if (d == null) continue;
                if (d != lastDisplay) { lastDisplay = d; angle = null; }   // 画面が変わったら、すぐ目標の傾きにする

                var tip = new Point(m.X - d.Left, m.Y - d.Top);
                var area = new Rect(0, 0, d.Width, d.Height);
                double targetAngle = PointerRenderer.Angle(tip, area);
                // 傾きは少し遅れて変わる (1/60 秒ごとに差の 18% ずつ近づける。描き変えの回数によらず同じ速さにする)
                double cur = angle ?? targetAngle;
                double k = 1 - Math.Pow(1 - 0.18, Math.Min(dt, 0.1) * 60);
                cur = Math.Abs(targetAngle - cur) < 0.1 ? targetAngle : cur + (targetAngle - cur) * k;
                angle = cur;

                double q = Math.Round(cur * 2) / 2;
                var art = Art(q, d.Height) ?? shown;
                if (art == null) continue;
                if (art != shown) { Upload(art, d.Height); shown = art; lastX = int.MinValue; }

                int x = d.Left - ox0 + (int)tip.X - art.TipX, y = d.Top - oy0 + (int)tip.Y - art.TipY;
                if (x == lastX && y == lastY) continue;
                visual!.SetOffsetX(x);
                visual.SetOffsetY(y);
                dcomp!.Commit();
                lastX = x; lastY = y;
                moves++;
                // 動かす間隔の最大 (100 ms を超えるのは、マウスを止めていたときなので数えない)
                double gap = lastMove == 0 ? 0 : Stopwatch.GetElapsedTime(lastMove, now).TotalMilliseconds;
                if (gap < 100) maxGap = Math.Max(maxGap, gap);
                lastMove = now;
            }
        }
        catch (Exception e) { Log.Write($"指し棒を描けません: {e}"); }
        finally { Teardown(); }
    }

    /// 傾き q・高さ h の絵 (なければ UI のスレッドに作ってもらい、今は null)
    PointerRenderer.Rendered? Art(double q, int h)
    {
        string key = $"{q} {h}";
        if (cache.TryGetValue(key, out var r)) return r;
        if (pending.TryAdd(key, true))
        {
            ui.BeginInvoke(() =>
            {
                // 使い回す絵は、近い傾きの 60 枚まで (1 枚で数 MB あるため)
                if (cache.Count > 60)
                    foreach (var old in cache.Keys.OrderByDescending(k => Math.Abs(double.Parse(k.Split(' ')[0]) - q)).Take(cache.Count - 60))
                        cache.TryRemove(old, out _);
                cache[key] = PointerRenderer.Render(q, h);
                pending.TryRemove(key, out _);
            }, DispatcherPriority.Render);
        }
        return null;
    }

    void Setup()
    {
        D3D11.D3D11CreateDevice(null, DriverType.Hardware, DeviceCreationFlags.BgraSupport,
            [FeatureLevel.Level_11_1, FeatureLevel.Level_11_0], out ID3D11Device dev, out ID3D11DeviceContext ctx).CheckError();
        device = dev; context = ctx;
        using var dxgi = device.QueryInterface<IDXGIDevice>();
        dcomp = DComp.DCompositionCreateDevice<IDCompositionDevice>(dxgi);
        dcomp.CreateTargetForHwnd(window.Hwnd, true, out target).CheckError();
        dcomp.CreateVisual(out visual).CheckError();
        target!.SetRoot(visual).CheckError();
        dcomp.Commit().CheckError();
    }

    /// 絵をスワップチェーンにのせる。スワップチェーンは、その画面の高さで絵がなりうる最大の大きさ (高さの 51% 四方) で 1 回だけ作る
    /// (傾きが変わるたびに作り直すと、そのたびに動きが止まるため)
    void Upload(PointerRenderer.Rendered art, int displayHeight)
    {
        int aw = art.Bitmap.PixelWidth, ah = art.Bitmap.PixelHeight;
        int max = (int)Math.Ceiling(displayHeight * 0.51) + 4;
        int sw = Math.Max(max, aw), sh = Math.Max(max, ah);
        if (swapChain == null || swapW != sw || swapH != sh)
        {
            visual!.SetContent(null!);
            attached = false;
            swapChain?.Dispose();
            using var dxgi = device!.QueryInterface<IDXGIDevice>();
            using var adapter = dxgi.GetAdapter();
            using var factory = adapter.GetParent<IDXGIFactory2>();
            swapW = sw; swapH = sh;
            swapChain = factory.CreateSwapChainForComposition(device, new SwapChainDescription1
            {
                Width = (uint)sw, Height = (uint)sh, Format = Format.B8G8R8A8_UNorm, BufferCount = 2,
                BufferUsage = Usage.RenderTargetOutput, SampleDescription = new SampleDescription(1, 0),
                SwapEffect = SwapEffect.FlipDiscard, Scaling = Scaling.Stretch, AlphaMode = AlphaMode.Premultiplied,
            }, null);
        }
        // 指し棒を一度隠すと外れているので、出し直すたびにつけ直す
        if (!attached) { visual!.SetContent(swapChain).CheckError(); attached = true; }
        // 絵より大きいスワップチェーンの余りは透明にする
        using var back = swapChain.GetBuffer<ID3D11Texture2D>(0);
        using (var rtv = device!.CreateRenderTargetView(back)) context!.ClearRenderTargetView(rtv, new Vortice.Mathematics.Color4(0, 0, 0, 0));
        unsafe
        {
            fixed (byte* p = art.Pixels)
                context!.UpdateSubresource(back, 0, new Vortice.Mathematics.Box(0, 0, 0, aw, ah, 1), (IntPtr)p, (uint)(aw * 4), 0);
        }
        swapChain.Present(0, PresentFlags.None);
    }

    void Teardown()
    {
        visual?.Dispose(); target?.Dispose(); dcomp?.Dispose();
        swapChain?.Dispose(); context?.Dispose(); device?.Dispose();
    }

    public void Dispose()
    {
        quit = true;
        lock (gate) enabled = false;
        wake.Set();
        thread?.Join(1000);
        window.Dispose();
    }

    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int X, Y; }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetCursorPos(out POINT point);

    [LibraryImport("dwmapi.dll")]
    private static partial int DwmFlush();

    /// 画面の合成の 1 回を待つ (Windows 11)。待てないときは 0xFFFFFFFF
    [LibraryImport("dcomp.dll")]
    private static partial uint DCompositionWaitForCompositorClock(uint count, IntPtr handles, uint timeoutMs);
}
