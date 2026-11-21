// 指し棒 (SPEC.md 8 章「指し棒」。Mac 版の Sources/Pointer.swift と同じ形)
// マウスカーソルの位置を矢印で指す、長さの決まった棒。画面に重ねるウィンドウと、合成した映像の両方で同じ絵を描く。
// 座標は左上原点 (y は下向き)。

using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace NoGreenBack.Overlays;

public static class PointerRenderer
{
    /// 棒の長さ (画面の高さに対する割合)
    const double LengthRatio = 0.45;

    /// 棒の傾き (度。縦から、正なら根元が右)。棒はいつも矢印の右側に出して、左上を指す形にする。
    /// 左の方を指すほど少し寝かせる。画面の端で棒がはみ出すときは、右側のまま収まる向きに回す
    public static double Angle(Point tip, Rect area)
    {
        double f = Math.Clamp((tip.X - area.Left) / Math.Max(area.Width, 1), 0, 1);
        double preferred = 40 - 15 * f;   // 左端で 40 度、右端で 25 度
        var inner = area;
        inner.Inflate(-area.Height * 0.01, -area.Height * 0.01);
        // 根元を右側 (0〜120 度) に保ったまま、近い向きから探す。
        // 右下の隅のように、どの向きでも収まらないときも、左側には回さない。
        // はみ出しがいちばん小さい向きにして、棒の一部は画面の外に出す (指す先は変わらない)
        double best = preferred, bestOver = double.PositiveInfinity;
        for (int step = 0; step <= 90; step++)
            foreach (int sign in step == 0 ? new[] { 1 } : new[] { 1, -1 })
            {
                double deg = preferred + sign * step * 2;
                if (deg < 0 || deg > 120) continue;
                var b = Base(tip, deg, area);
                double over = Math.Max(Math.Max(inner.Left - b.X, b.X - inner.Right), 0)
                            + Math.Max(Math.Max(inner.Top - b.Y, b.Y - inner.Bottom), 0);
                if (over == 0) return deg;
                if (over < bestOver) { bestOver = over; best = deg; }
            }
        return best;
    }

    /// 傾き angle (度) のときの棒の根元 (手で持つ端)
    public static Point Base(Point tip, double angle, Rect area)
    {
        double length = area.Height * LengthRatio, r = angle * Math.PI / 180;
        return new Point(tip.X + Math.Sin(r) * length, tip.Y + Math.Cos(r) * length);
    }

    // 棒は半透明の白い縁の上に黒い棒、矢印は白く塗って黒い縁 (Mac 版と同じ色)
    static readonly Brush StickBrush = Frozen(new SolidColorBrush(Color.FromRgb(41, 41, 41)));
    static readonly Brush StickEdgeBrush = Frozen(new SolidColorBrush(Color.FromArgb(153, 255, 255, 255)));
    static readonly Brush HeadBrush = Frozen(new SolidColorBrush(Colors.White));
    static readonly Brush HeadEdgeBrush = Frozen(new SolidColorBrush(Color.FromRgb(26, 26, 26)));
    static T Frozen<T>(T f) where T : Freezable { f.Freeze(); return f; }

    /// 棒を描く (白い縁の付いた黒い細い棒と、先の白い矢印 (黒い縁))。size は画面 (映像) の高さ。
    /// 明るい画面では黒い棒と矢印の縁が、暗い画面では白い縁と白い矢印が見えるので、影は付けない
    public static void Draw(DrawingContext dc, Point start, Point tip, double size)
    {
        double dx = tip.X - start.X, dy = tip.Y - start.Y, length = Math.Sqrt(dx * dx + dy * dy);
        if (length <= 1) return;
        double ux = dx / length, uy = dy / length, nx = -uy, ny = ux;
        // 先は矢印 (先端がちょうどマウスの位置)。棒は矢印の付け根まで
        double headLength = size * 0.055, headHalf = size * 0.022;
        var hb = new Point(tip.X - ux * headLength, tip.Y - uy * headLength);
        var end = new Point(hb.X + ux * headLength * 0.2, hb.Y + uy * headLength * 0.2);
        foreach (var (brush, width) in new[] { (StickEdgeBrush, size * 0.0225), (StickBrush, size * 0.0125) })
        {
            var pen = new Pen(brush, width) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
            dc.DrawLine(pen, start, end);
        }
        var head = new StreamGeometry();
        using (var g = head.Open())
        {
            g.BeginFigure(tip, true, true);
            g.PolyLineTo([new Point(hb.X + nx * headHalf, hb.Y + ny * headHalf), new Point(hb.X - nx * headHalf, hb.Y - ny * headHalf)], true, true);
        }
        var edge = new Pen(HeadEdgeBrush, Math.Max(1, size * 0.003)) { LineJoin = PenLineJoin.Round };
        dc.DrawGeometry(HeadBrush, edge, head);
    }

    /// 傾き angle (度)、画面 (映像) の高さ size のときの、棒のまわり (縁の分の余白つき) だけの画像と、
    /// 画像の中での矢印の先の位置。絵は先の位置によらず傾きと大きさだけで決まるので、同じ傾きの間は使い回せる
    /// (画像が画面からはみ出しても、ウィンドウや映像の外が切れるだけ)
    public static Rendered? Render(double angle, double size)
    {
        double length = size * LengthRatio, pad = size * 0.03, r = angle * Math.PI / 180;
        double dx = Math.Sin(r) * length, dy = Math.Cos(r) * length;   // 先から根元へ
        double left = Math.Min(0, dx) - pad, top = Math.Min(0, dy) - pad;
        int w = (int)Math.Ceiling(Math.Abs(dx) + pad * 2), h = (int)Math.Ceiling(Math.Abs(dy) + pad * 2);
        if (w < 1 || h < 1) return null;
        var tip = new Point(-left, -top);

        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen()) Draw(dc, new Point(tip.X + dx, tip.Y + dy), tip, size);
        var bmp = new RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
        bmp.Render(visual);
        bmp.Freeze();
        var pixels = new byte[w * h * 4];
        bmp.CopyPixels(pixels, w * 4, 0);
        return new Rendered(bmp, pixels, (int)Math.Round(tip.X), (int)Math.Round(tip.Y));
    }

    /// 指し棒の画像 (Pixels は Bitmap と同じ中身の BGRA)。TipX, TipY は画像の中での矢印の先
    public sealed record Rendered(BitmapSource Bitmap, byte[] Pixels, int TipX, int TipY);
}

/// 指し棒を出している間、マウスカーソルを隠す (矢印の先がカーソルの代わり)。
/// ほかのアプリが前面でも隠れるよう、システムのカーソルを一時的に透明なものに差し替え、戻すときは設定から読み直す。
/// 落ちたときにも戻るよう、App の終了・クラッシュの処理からも Show を呼ぶ。
/// 強制終了などでそれも動かなかったときのために、隠している間は目印のファイルを置き、次に起動したときに目印があれば戻す
public static partial class CursorHider
{
    static bool hidden;

    static string MarkerPath => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NoGreenBack", "cursor-hidden");

    /// 前に隠したまま終わっていたら (強制終了など)、カーソルを戻す。起動したときに呼ぶ
    public static void RestoreIfLeftHidden()
    {
        try
        {
            if (!System.IO.File.Exists(MarkerPath)) return;
            SystemParametersInfoW(0x57 /* SPI_SETCURSORS */, 0, IntPtr.Zero, 0);
            System.IO.File.Delete(MarkerPath);
            Log.Write("前の起動で隠したままだったカーソルを戻しました");
        }
        catch (Exception e) when (e is System.IO.IOException or UnauthorizedAccessException) { }
    }

    // 差し替えるカーソル (矢印・I ビーム・待ち・十字・上矢印・大きさ変更 4 種・移動・禁止・手・バックグラウンド作業中・ヘルプ)
    static readonly uint[] Ids = [32512, 32513, 32514, 32515, 32516, 32642, 32643, 32644, 32645, 32646, 32648, 32649, 32650, 32651];

    public static void Hide()
    {
        if (hidden) return;
        hidden = true;
        try
        {
            System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(MarkerPath)!);
            System.IO.File.WriteAllText(MarkerPath, DateTime.Now.ToString("O"));
        }
        catch (Exception e) when (e is System.IO.IOException or UnauthorizedAccessException) { }
        var and =Enumerable.Repeat((byte)0xFF, 32 * 32 / 8).ToArray();   // AND が 1・XOR が 0 で、画面がそのまま見える (透明)
        var xor = new byte[32 * 32 / 8];
        foreach (var id in Ids)
        {
            var c = CreateCursor(IntPtr.Zero, 0, 0, 32, 32, and, xor);
            if (c != IntPtr.Zero) SetSystemCursor(c, id);   // c はシステムのものになる (自分で消さない)
        }
    }

    public static void Show()
    {
        if (!hidden) return;
        hidden = false;
        SystemParametersInfoW(0x57 /* SPI_SETCURSORS */, 0, IntPtr.Zero, 0);
        try { System.IO.File.Delete(MarkerPath); } catch (Exception e) when (e is System.IO.IOException or UnauthorizedAccessException) { }
    }

    [LibraryImport("user32.dll")]
    private static partial IntPtr CreateCursor(IntPtr instance, int hotX, int hotY, int width, int height, byte[] andPlane, byte[] xorPlane);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetSystemCursor(IntPtr cursor, uint id);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SystemParametersInfoW(uint action, uint param, IntPtr pvParam, uint winIni);
}
