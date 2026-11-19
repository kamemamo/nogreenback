// 手書き・ホワイトボード・キーボード・指し棒をまとめて動かす (SPEC.md 7・8 章)
// UI のスレッドで動く。60 回/秒のタイマーで、描くキーとマウスの位置を調べる。
//
// 重なり順 (奥から手前): ホワイトボード → ワイプ → キーボード → 全画面出力 → 手書き → 指し棒。1 秒ごとに並べ直す。
// 手書きは全画面出力より手前に置く (全画面出力の画面の上でも描けるように。その画面の線は映像の中にも入れる)。

using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using NoGreenBack.Video;

namespace NoGreenBack.Overlays;

public sealed partial class OverlayController : IDisposable
{
    readonly AppModel model;
    readonly Annotations annotations = new();
    readonly DispatcherTimer timer;        // 60 回/秒 (描くキーと指し棒)
    readonly DispatcherTimer arrangeTimer; // 1 秒ごと (重なり順)
    readonly OverlayWindow boardWindow = new() { Title = "NoGreenBack Board" };
    readonly OverlayWindow keyboardWindow = new() { Title = "NoGreenBack Keyboard" };
    readonly Image keyboardImage = new() { Stretch = Stretch.Fill };
    readonly OverlayWindow pointerWindow = new() { Title = "NoGreenBack Pointer" };
    readonly Image pointerImage = new() { Stretch = Stretch.Fill };
    bool disposed;

    // 描くキー: 押し始め・押し始めの線の数・前に素早く押して離した時刻 (2 回で全部消す)
    bool keyWasDown;
    DateTime pressStart = DateTime.MinValue, lastTap = DateTime.MinValue;
    int strokesAtPress;

    // 全画面出力の画面の線を映像に入れる (描き直しは 30 回/秒まで)
    bool annotationDirty;
    long lastAnnotationRender;

    // キーボードの画像 (大きさや設定が同じあいだは作り直さない)
    string keyboardCanvasKey = "", keyboardWindowKey = "";

    // 指し棒
    DisplayInfo? pointerDisplay;
    double? pointerAngle;
    Point? lastPointer;

    /// ペンの色 (0 赤, 1 黄, 2 青, 3 緑, 4 白, 5 黒。Mac のシステムの色に合わせる)
    static readonly Color[] PenColors =
    [
        Color.FromRgb(255, 59, 48), Color.FromRgb(255, 204, 0), Color.FromRgb(0, 122, 255),
        Color.FromRgb(52, 199, 89), Colors.White, Colors.Black,
    ];
    static readonly double[] FadeTimes = [0, 3, 10];

    public OverlayController(AppModel model)
    {
        this.model = model;
        keyboardWindow.Content = keyboardImage;
        pointerWindow.Content = pointerImage;

        annotations.Changed += w => { if (w.Display.Name == model.Outputs.FullDisplay?.Name) annotationDirty = true; };
        annotations.ClearRequested += model.ClearDrawing;
        model.ClearDrawingRequested += () => annotations.Clear();

        model.Settings.PropertyChanged += OnChanged;
        model.State.PropertyChanged += OnChanged;
        model.Displays.Changed += _ => { Cover(); UpdateAll(); };
        model.Outputs.Changed += UpdateAll;
        model.Video.CanvasChanged += _ => { annotationDirty = true; UpdateKeyboard(); };

        timer = new DispatcherTimer(TimeSpan.FromMilliseconds(1000.0 / 60), DispatcherPriority.Input, (_, _) => Tick(), Dispatcher.CurrentDispatcher);
        // 1 秒ごとに重なり順を並べ直す (スライドショーなど、あとから最前面に出たウィンドウに隠されないように)
        arrangeTimer = new DispatcherTimer(TimeSpan.FromSeconds(1), DispatcherPriority.Background, (_, _) => Arrange(), Dispatcher.CurrentDispatcher);
        arrangeTimer.Start();
        ApplyPenStyle();
        Cover();
        UpdateAll();
    }

    void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(Settings.PenColor) or nameof(Settings.PenWidth) or nameof(Settings.PenFade):
                ApplyPenStyle();
                break;
            case nameof(Settings.AnnotationOn) or nameof(AppState.PenLock) or nameof(AppState.WhiteboardOn)
                or nameof(Settings.BoardOpacity) or nameof(Settings.KeyboardOn) or nameof(Settings.KeyboardLayout)
                or nameof(Settings.KeyboardPlace) or nameof(Settings.KeyboardSize) or nameof(AppState.PointerOn)
                or nameof(Settings.OverlayScreen) or nameof(Settings.OverlayCorner) or nameof(Settings.OverlayScale):
                UpdateAll();
                break;
        }
    }

    void ApplyPenStyle()
    {
        var s = model.Settings;
        annotations.SetStyle(PenColors[Math.Clamp(s.PenColor, 0, 5)], s.PenWidth, FadeTimes[Math.Clamp(s.PenFade, 0, 2)]);
    }

    /// 画面ごとの手書きのウィンドウを作り直す
    void Cover()
    {
        if (model.Settings.AnnotationOn) annotations.Cover(model.Displays.All);
    }

    void UpdateAll()
    {
        if (disposed) return;
        var s = model.Settings;
        var st = model.State;
        var full = model.Outputs.FullDisplay;

        // 手書き: 全画面出力を出している間は、全画面出力の画面だけで描ける (録画している画面は、録画を作ったら足す)
        if (s.AnnotationOn) annotations.Cover(model.Displays.All);
        annotations.SetShown(s.AnnotationOn);
        annotations.SetAllowed(full == null ? null : [full.Name]);
        annotationDirty = true;

        // ホワイトボード: 映像には背景の上・人物の後ろに入れる。全画面出力を出していなければ「表示する画面」に板のウィンドウを出す
        bool board = st.WhiteboardOn && s.AnnotationOn;
        model.Video.BoardOpacity = board ? (float)s.BoardOpacity : 0;
        var overlayDisplay = model.Displays.OverlayDisplay;
        if (board && full == null && overlayDisplay is { } od)
        {
            boardWindow.Background = new SolidColorBrush(Color.FromArgb((byte)Math.Round(255 * s.BoardOpacity), 255, 255, 255));
            boardWindow.Place(od.Left, od.Top, od.Width, od.Height);
            boardWindow.ShowNoActivate();
        }
        else if (boardWindow.IsVisible) boardWindow.Hide();

        UpdateKeyboard();

        // 指し棒
        bool pointer = st.PointerOn;
        if (pointer) CursorHider.Hide();
        else
        {
            CursorHider.Show();
            if (pointerWindow.IsVisible) pointerWindow.Hide();
            model.Video.SetLayer(LayerKind.Pointer, null);
            lastPointer = null; pointerAngle = null; pointerDisplay = null;
        }

        bool needTimer = s.AnnotationOn || pointer;
        if (needTimer && !timer.IsEnabled) timer.Start();
        if (!needTimer && timer.IsEnabled) { timer.Stop(); annotations.SetDrawing(false); }
        Arrange();
    }

    /// キーボード: 映像にいつも入れ、全画面出力が「表示する画面」を覆っていなければ、その画面にもウィンドウで出す
    void UpdateKeyboard()
    {
        var s = model.Settings;
        bool jis = s.KeyboardLayoutIndex == 0;
        var canvas = model.Video.Canvas;
        if (s.KeyboardOn && canvas != null)
        {
            string key = $"{canvas} {s.KeyboardSize} {s.KeyboardPlace} {jis}";
            if (key != keyboardCanvasKey)
            {
                keyboardCanvasKey = key;
                var bmp = KeyboardRenderer.Render(canvas.Width * s.KeyboardSize, jis);
                if (bmp == null) model.Video.SetLayer(LayerKind.Keyboard, null);
                else
                {
                    var f = KeyboardRenderer.Frame(new Size(bmp.PixelWidth, bmp.PixelHeight), new Rect(0, 0, canvas.Width, canvas.Height),
                        s.KeyboardPlace, canvas.PersonX, canvas.PersonX + canvas.PersonWidth);
                    model.Video.SetLayer(LayerKind.Keyboard, new LayerImage(Pixels(bmp), bmp.PixelWidth, bmp.PixelHeight,
                        (int)f.X, (int)f.Y, canvas.Width, canvas.Height));
                }
            }
        }
        else if (keyboardCanvasKey != "")
        {
            keyboardCanvasKey = "";
            model.Video.SetLayer(LayerKind.Keyboard, null);
        }

        var d = model.Displays.OverlayDisplay;
        bool covered = model.Outputs.FullDisplay != null && model.Outputs.FullDisplay.Name == d?.Name;
        if (s.KeyboardOn && d != null && !covered)
        {
            string key = $"{d} {s.KeyboardSize} {s.KeyboardPlace} {jis} {s.OverlayCorner} {s.OverlayScale}";
            if (key != keyboardWindowKey || !keyboardWindow.IsVisible)
            {
                keyboardWindowKey = key;
                var bmp = KeyboardRenderer.Render(d.Width * s.KeyboardSize, jis);
                if (bmp == null) { keyboardWindow.Hide(); return; }
                // ワイプは画面の幅に対して「大きさ」の幅で隅に置いている
                bool right = s.OverlayCorner is 0 or 2;
                double pw = d.Width * s.OverlayScale;
                double pl = right ? d.Left + d.Width - pw : d.Left;
                var f = KeyboardRenderer.Frame(new Size(bmp.PixelWidth, bmp.PixelHeight), new Rect(d.Left, d.Top, d.Width, d.Height),
                    s.KeyboardPlace, pl, pl + pw);
                keyboardImage.Source = bmp;
                keyboardWindow.Place((int)f.X, (int)f.Y, bmp.PixelWidth, bmp.PixelHeight);
                keyboardWindow.ShowNoActivate();
            }
        }
        else if (keyboardWindow.IsVisible) keyboardWindow.Hide();
    }

    void Tick()
    {
        var s = model.Settings;
        var now = DateTime.Now;

        // 描くキー: 押している修飾キーの組み合わせがちょうど選んだものと同じときだけ描ける
        if (s.AnnotationOn)
        {
            bool down = DrawKeyDown(s.DrawKey);
            if (down && !keyWasDown)
            {
                pressStart = now;
                strokesAtPress = annotations.StrokeCount;
            }
            else if (!down && keyWasDown)
            {
                // 「押してから 0.3 秒未満で離し、その間に線が増えていない」を 1 回とし、2 回の間が 0.4 秒未満なら全部消す
                bool isTap = (now - pressStart).TotalSeconds < 0.3 && annotations.StrokeCount == strokesAtPress;
                if (isTap && (pressStart - lastTap).TotalSeconds < 0.4) { model.ClearDrawing(); lastTap = DateTime.MinValue; }
                else lastTap = isTap ? now : DateTime.MinValue;
            }
            bool wasDrawing = keyWasDown || model.State.PenLock;
            keyWasDown = down;
            bool drawing = down || model.State.PenLock;
            annotations.SetDrawing(drawing);
            if (drawing && !wasDrawing) Arrange();
            annotations.Tick(now);

            // 全画面出力の画面の線を映像に入れる
            if (annotationDirty && Environment.TickCount64 - lastAnnotationRender >= 33) RenderAnnotationLayer();
        }

        if (model.State.PointerOn) UpdatePointer();
    }

    void RenderAnnotationLayer()
    {
        annotationDirty = false;
        lastAnnotationRender = Environment.TickCount64;
        var full = model.Outputs.FullDisplay;
        var canvas = model.Video.Canvas;
        var w = full == null ? null : annotations.WindowFor(full.Name);
        byte[]? pixels = w == null || canvas == null || !w.IsVisible ? null
            : Annotations.RenderForCanvas(w, canvas.Width, canvas.Height, FadeTimes[Math.Clamp(model.Settings.PenFade, 0, 2)]);
        model.Video.SetLayer(LayerKind.Annotation, pixels == null || canvas == null ? null
            : new LayerImage(pixels, canvas.Width, canvas.Height, 0, 0, canvas.Width, canvas.Height));
    }

    /// マウスのある画面に指し棒を描く。全画面出力の画面なら、合成した映像の中に描く。
    /// 先はマウスにぴったり付いていき、棒の傾きは少し遅れてなめらかに変わる
    void UpdatePointer()
    {
        if (!GetCursorPos(out var m)) return;
        var d = model.Displays.All.FirstOrDefault(x => m.X >= x.Left && m.X < x.Left + x.Width && m.Y >= x.Top && m.Y < x.Top + x.Height);
        if (d == null) return;
        if (d != pointerDisplay) { pointerDisplay = d; pointerAngle = null; }

        // 全画面出力の画面なら、合成した映像の座標で考える (映像は画面に収まるように拡大して真ん中に出しているので、その逆をたどる)
        var tip = new Point(m.X - d.Left, m.Y - d.Top);
        var area = new Rect(0, 0, d.Width, d.Height);
        bool onOutput = model.Outputs.FullDisplay?.Name == d.Name;
        var canvas = model.Video.Canvas;
        if (onOutput)
        {
            if (canvas == null) return;
            double sc = Math.Min((double)d.Width / canvas.Width, (double)d.Height / canvas.Height);
            double tx = (d.Width - canvas.Width * sc) / 2, ty = (d.Height - canvas.Height * sc) / 2;
            tip = new Point((tip.X - tx) / sc, (tip.Y - ty) / sc);
            area = new Rect(0, 0, canvas.Width, canvas.Height);
        }
        double target = PointerRenderer.Angle(tip, area);
        double current = pointerAngle ?? target;
        double angle = Math.Abs(target - current) < 0.1 ? target : current + (target - current) * 0.18;
        // マウスも傾きも変わっていなければ描き直さない
        if (lastPointer == tip && pointerAngle == angle) return;
        lastPointer = tip;
        pointerAngle = angle;

        var start = PointerRenderer.Base(tip, angle, area);
        var bmp = PointerRenderer.Render(start, tip, area, out var r);
        if (onOutput)
        {
            if (pointerWindow.IsVisible) pointerWindow.Hide();
            model.Video.SetLayer(LayerKind.Pointer, bmp == null ? null
                : new LayerImage(Pixels(bmp), bmp.PixelWidth, bmp.PixelHeight, r.X, r.Y, canvas!.Width, canvas.Height));
        }
        else
        {
            model.Video.SetLayer(LayerKind.Pointer, null);
            if (bmp == null) { pointerWindow.Hide(); return; }
            // ウィンドウは棒のまわりだけの大きさにして動かす (画面全体を 60 回/秒描き直さないように)
            pointerImage.Source = bmp;
            pointerWindow.Place(d.Left + r.X, d.Top + r.Y, bmp.PixelWidth, bmp.PixelHeight);
            pointerWindow.ShowNoActivate();
        }
    }

    /// 重なり順を並べ直す (奥から手前へ)
    void Arrange()
    {
        var order = new List<IntPtr> { boardWindow.Hwnd, model.Outputs.WipeHwnd, keyboardWindow.Hwnd, model.Outputs.FullHwnd };
        order.AddRange(annotations.Windows.Select(w => w.Hwnd));
        order.Add(pointerWindow.Hwnd);
        OverlayWindow.Arrange(order);
    }

    static byte[] Pixels(BitmapSource bmp)
    {
        var px = new byte[bmp.PixelWidth * bmp.PixelHeight * 4];
        bmp.CopyPixels(px, bmp.PixelWidth * 4, 0);
        return px;
    }

    /// 描くキーの組み合わせ (0 Ctrl, 1 Alt, 2 Ctrl+Alt) をちょうど押しているか (Shift・Win を押していれば違う)
    static bool DrawKeyDown(int drawKey)
    {
        static bool Down(int vk) => (GetAsyncKeyState(vk) & 0x8000) != 0;
        bool ctrl = Down(0x11), alt = Down(0x12), shift = Down(0x10), win = Down(0x5B) || Down(0x5C);
        if (shift || win) return false;
        return drawKey switch { 1 => alt && !ctrl, 2 => ctrl && alt, _ => ctrl && !alt };
    }

    /// 終了する前に、画面を覆うウィンドウを消し、ペン固定を外し、カーソルを戻す (SPEC.md 2 章)
    public void Dispose()
    {
        disposed = true;
        timer.Stop();
        arrangeTimer.Stop();
        CursorHider.Show();
        annotations.Close();
        boardWindow.Close();
        keyboardWindow.Close();
        pointerWindow.Close();
    }

    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int X, Y; }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetCursorPos(out POINT point);

    [LibraryImport("user32.dll")]
    private static partial short GetAsyncKeyState(int vk);
}
