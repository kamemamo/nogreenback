// 手書き (SPEC.md 8 章「手書き」)
// - 画面ごとに、画面全体を覆う透明なウィンドウを用意する (液晶タブレットのように別の画面として認識される機器でも描けるように)。
//   画面の数が変わったら作り直す (描いた線は消える)
// - ウィンドウを実際に出しておくのは、描ける状態か、線が残っている画面だけ
// - 描ける間は、ウィンドウがマウスを受け取り、画面の縁に色の枠を出す。描けなくなったら描きかけの線を確定し、クリックを後ろへ通す
// - 描ける間に右クリックで全部消す
// - 線の端とつなぎ目は丸く。「線を消す」なら、描き終えてからの秒数で、最後の 0.5 秒でフェードアウトする
// 線の座標は、ウィンドウの中の論理的な単位 (DIP) で持つ。

using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;

namespace NoGreenBack.Overlays;

/// 線 1 本
public sealed class InkStroke
{
    public List<Point> Points { get; } = [];
    public Color Color { get; init; }
    public double Width { get; init; }
    /// 描き終えた時刻 (描いている途中は null)
    public DateTime? Finished { get; set; }
    public DrawingVisual Visual { get; } = new();

    /// 線の形 (点が 1 つなら丸い点)
    public Geometry Geometry()
    {
        var g = new StreamGeometry();
        using (var ctx = g.Open())
        {
            ctx.BeginFigure(Points[0], false, false);
            if (Points.Count == 1) ctx.LineTo(Points[0], true, false);
            else ctx.PolyLineTo(Points.Skip(1).ToList(), true, true);
        }
        g.Freeze();
        return g;
    }

    public Pen Pen(double alpha = 1) =>
        new(new SolidColorBrush(Color.FromArgb((byte)(255 * alpha), Color.R, Color.G, Color.B)), Width)
        {
            StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round,
        };

    public void Render()
    {
        using var dc = Visual.RenderOpen();
        dc.DrawGeometry(null, Pen(), Geometry());
    }

    /// 消えるまでの濃さ (1 から 0)。fadeAfter が 0 なら消えない
    public double Alpha(DateTime now, double fadeAfter) =>
        fadeAfter <= 0 || Finished is not { } f ? 1 : Math.Clamp((fadeAfter - (now - f).TotalSeconds) / 0.5, 0, 1);
}

/// 線を並べて描く要素 (線ごとに DrawingVisual を持ち、描いている線だけを描き直す)
public sealed class InkLayer : FrameworkElement
{
    readonly VisualCollection visuals;
    public List<InkStroke> Strokes { get; } = [];

    public InkLayer() { visuals = new VisualCollection(this); }

    protected override int VisualChildrenCount => visuals.Count;
    protected override Visual GetVisualChild(int index) => visuals[index];

    public void Add(InkStroke s) { Strokes.Add(s); visuals.Add(s.Visual); s.Render(); }
    public void Remove(InkStroke s) { Strokes.Remove(s); visuals.Remove(s.Visual); }
    public void Clear() { Strokes.Clear(); visuals.Clear(); }
}

/// 1 つの画面を覆う手書きのウィンドウ
public sealed class AnnotationWindow : OverlayWindow
{
    readonly Grid root = new();
    readonly InkLayer ink = new();
    readonly Rectangle frame = new() { StrokeThickness = 4, Margin = new Thickness(0), IsHitTestVisible = false };
    InkStroke? current;
    bool drawingMode;

    public DisplayInfo Display { get; }
    public IReadOnlyList<InkStroke> Strokes => ink.Strokes;
    public Color PenColor { get; set; } = Colors.Red;
    public double PenWidth { get; set; } = 5;

    /// 線が変わった (全画面出力の映像に線を入れるため)
    public event Action<AnnotationWindow>? Changed;
    /// 描ける間に右クリックされた (全部消す)
    public event Action? ClearRequested;

    public AnnotationWindow(DisplayInfo display)
    {
        Display = display;
        Title = "NoGreenBack Annotation";
        // 縁の枠は内側 2 の位置を中心に太さ 4 (WPF の Rectangle は枠を内側に描くので、縁から 0〜4 になる)
        root.Children.Add(ink);
        root.Children.Add(frame);
        Content = root;
        frame.Visibility = Visibility.Collapsed;
        Place(display.Left, display.Top, display.Width, display.Height);

        MouseLeftButtonDown += (_, e) =>
        {
            if (!drawingMode) return;
            CaptureMouse();
            current = new InkStroke { Color = PenColor, Width = PenWidth };
            current.Points.Add(e.GetPosition(ink));
            ink.Add(current);
            Changed?.Invoke(this);
        };
        MouseMove += (_, e) =>
        {
            if (current == null || current.Finished != null) return;   // 押している間はマウスを捕まえているので、離せば MouseUp が届く
            current.Points.Add(e.GetPosition(ink));
            current.Render();
            Changed?.Invoke(this);
        };
        MouseLeftButtonUp += (_, _) => FinishStroke();
        MouseRightButtonDown += (_, _) => { if (drawingMode) ClearRequested?.Invoke(); };
        LostMouseCapture += (_, _) => FinishStroke();
    }

    /// 描ける状態の切り替え。描けなくなったら描きかけの線を確定し、クリックを後ろへ通す
    public void SetDrawing(bool on)
    {
        if (drawingMode == on) return;
        drawingMode = on;
        // 完全に透明な画素はクリックが後ろへ抜けるので、描ける間はほとんど透明な色を敷いて受け止める
        root.Background = on ? new SolidColorBrush(Color.FromArgb(1, 255, 255, 255)) : Brushes.Transparent;
        frame.Stroke = new SolidColorBrush(Color.FromArgb(128, PenColor.R, PenColor.G, PenColor.B));
        frame.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        ClickThrough = !on;
        if (!on) { FinishStroke(); if (IsMouseCaptured) ReleaseMouseCapture(); }
    }

    public void UpdateFrameColor()
    {
        frame.Stroke = new SolidColorBrush(Color.FromArgb(128, PenColor.R, PenColor.G, PenColor.B));
    }

    void FinishStroke()
    {
        if (current is { Finished: null }) current.Finished = DateTime.Now;
        current = null;
        if (IsMouseCaptured) ReleaseMouseCapture();
    }

    public void Clear()
    {
        current = null;
        ink.Clear();
        Changed?.Invoke(this);
    }

    /// 時間がたった線を消し、消えかけの線を薄くする。変わったら true
    public bool Tick(DateTime now, double fadeAfter)
    {
        if (fadeAfter <= 0 || ink.Strokes.Count == 0) return false;
        bool changed = false;
        foreach (var s in ink.Strokes.ToList())
        {
            double a = s.Alpha(now, fadeAfter);
            if (a <= 0) { ink.Remove(s); changed = true; }
            else if (a < 1 && Math.Abs(s.Visual.Opacity - a) > 0.01) { s.Visual.Opacity = a; changed = true; }
        }
        if (changed) Changed?.Invoke(this);
        return changed;
    }
}

/// すべての画面の手書きのウィンドウをまとめる
public sealed class Annotations
{
    readonly List<AnnotationWindow> windows = [];
    bool shown, drawing;
    /// 描ける画面 (null ならすべて)。全画面出力を出している間は、全画面出力の画面などだけにする
    HashSet<string>? allowed;
    Color color = Colors.Red;
    double width = 5, fadeAfter;

    public IReadOnlyList<AnnotationWindow> Windows => windows;
    public event Action<AnnotationWindow>? Changed;
    public event Action? ClearRequested;

    public int StrokeCount => windows.Sum(w => w.Strokes.Count);

    bool Allowed(AnnotationWindow w) => allowed == null || allowed.Contains(w.Display.Name);

    /// 画面に出しておくのは、描ける状態か、線が残っている画面のウィンドウだけ
    bool Wants(AnnotationWindow w) => shown && Allowed(w) && (drawing || w.Strokes.Count > 0);

    public AnnotationWindow? WindowFor(string name) => windows.FirstOrDefault(w => w.Display.Name == name);

    /// 画面の構成に合わせて、画面ごとのウィンドウを作り直す (描いた線は消える)
    public void Cover(IEnumerable<DisplayInfo> displays)
    {
        var list = displays.ToList();
        if (list.SequenceEqual(windows.Select(w => w.Display))) return;
        foreach (var w in windows) w.Close();
        windows.Clear();
        foreach (var d in list)
        {
            var w = new AnnotationWindow(d) { PenColor = color, PenWidth = width };
            w.Changed += win => Changed?.Invoke(win);
            w.ClearRequested += () => ClearRequested?.Invoke();
            windows.Add(w);
        }
        Update();
    }

    public void SetStyle(Color c, double w, double fade)
    {
        color = c; width = w; fadeAfter = fade;
        foreach (var win in windows) { win.PenColor = c; win.PenWidth = w; win.UpdateFrameColor(); }
    }

    public void SetShown(bool on) { shown = on; if (!on) SetDrawing(false); Update(); }

    public void SetAllowed(IEnumerable<string>? names)
    {
        allowed = names?.ToHashSet();
        foreach (var w in windows) w.SetDrawing(drawing && Allowed(w));
        Update();
    }

    public void SetDrawing(bool on)
    {
        if (on == drawing) return;
        drawing = on;
        if (on) Update();   // 描く前に出す
        foreach (var w in windows) w.SetDrawing(on && Allowed(w));
        if (!on) Update();  // 線がなければ隠す
    }

    public void Clear()
    {
        foreach (var w in windows) w.Clear();
        Update();
    }

    public void Tick(DateTime now)
    {
        bool any = false;
        foreach (var w in windows) any |= w.Tick(now, fadeAfter);
        if (any) Update();
    }

    void Update()
    {
        foreach (var w in windows)
        {
            if (Wants(w)) w.ShowNoActivate();
            else if (w.IsVisible) w.Hide();
        }
    }

    public void Close()
    {
        foreach (var w in windows) w.Close();
        windows.Clear();
    }

    /// 全画面出力の画面に描いた線を、合成した映像 (canvasW × canvasH) の座標に直して画像にする。
    /// 全画面出力は映像を画面に収まるように拡大して真ん中に出しているので、その逆をたどる
    /// 返すのは線のある範囲だけの画像と、その範囲 (キャンバスの座標)。キャンバス全体を描くと、
    /// 描いている間 30 回/秒、キャンバスの大きさの画像を作り直すことになり重いため
    public static (byte[] Pixels, Int32Rect Rect)? RenderForCanvas(AnnotationWindow w, int canvasW, int canvasH, double fadeAfter)
    {
        if (w.Strokes.Count == 0 || canvasW <= 0 || canvasH <= 0) return null;
        double ppd = w.PixelsPerDip;
        double s = Math.Min((double)w.Display.Width / canvasW, (double)w.Display.Height / canvasH);
        double tx = (w.Display.Width - canvasW * s) / 2, ty = (w.Display.Height - canvasH * s) / 2;
        var now = DateTime.Now;
        var group = new DrawingGroup();
        using (var dc = group.Open())
        {
            // 画面の画素 = 論理的な単位 × ppd。映像の座標 = (画面の画素 − t) / s
            dc.PushTransform(new MatrixTransform(ppd / s, 0, 0, ppd / s, -tx / s, -ty / s));
            foreach (var st in w.Strokes)
            {
                double a = st.Alpha(now, fadeAfter);
                if (a <= 0 || st.Points.Count == 0) continue;
                dc.DrawGeometry(null, st.Pen(a), st.Geometry());
            }
            dc.Pop();
        }
        // 線のある範囲 (線の太さ込み) をキャンバスの中に切り詰め、画素の境目にそろえる
        var bounds = group.Bounds;
        bounds.Intersect(new Rect(0, 0, canvasW, canvasH));
        if (bounds.IsEmpty) return null;
        int x0 = (int)Math.Floor(bounds.Left), y0 = (int)Math.Floor(bounds.Top);
        int x1 = (int)Math.Ceiling(bounds.Right), y1 = (int)Math.Ceiling(bounds.Bottom);
        int bw = Math.Max(1, x1 - x0), bh = Math.Max(1, y1 - y0);

        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.PushTransform(new TranslateTransform(-x0, -y0));
            dc.DrawDrawing(group);
            dc.Pop();
        }
        var bmp = new RenderTargetBitmap(bw, bh, 96, 96, PixelFormats.Pbgra32);
        bmp.Render(visual);
        var pixels = new byte[bw * bh * 4];
        bmp.CopyPixels(pixels, bw * 4, 0);
        return (pixels, new Int32Rect(x0, y0, bw, bh));
    }
}
