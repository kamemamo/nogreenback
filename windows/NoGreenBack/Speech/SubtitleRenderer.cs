// 字幕の絵 (SPEC.md 10 章「出し方」。Mac 版の SubtitleRenderer と同じ見た目)
// - 太字・白・影 (ぼかしは文字の大きさの 15%)・行間 15%。黒 55% の帯の上に描き、帯の余白は文字の大きさの 40%
// - 映像の中: 文字の大きさは映像の高さの 5%。帯が映像の幅 (左右の余白 3% を除く) に入りきらなければ、文字を小さくする
// - デスクトップ: 文字の大きさは画面の高さの 4%、角の丸い帯
// - 位置: 人物を出しているときは、キーボードと同じ「広い方のすき間の真ん中」、そうでなければ中央。入りきらなければ画面の端に寄せる。
//   高さは下から 6%、キーボードが下半分にあればその上 (余白 3%)

using System.Globalization;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using NoGreenBack.Overlays;

namespace NoGreenBack.Speech;

public static class SubtitleRenderer
{
    static readonly Typeface Face = new(new FontFamily("Segoe UI, Yu Gothic UI"), FontStyles.Normal, FontWeights.Bold, FontStretches.Normal);
    static readonly Brush Band = Frozen(new SolidColorBrush(Color.FromArgb(140, 0, 0, 0)));
    static T Frozen<T>(T f) where T : Freezable { f.Freeze(); return f; }

    static FormattedText Format(IReadOnlyList<string> lines, double fontSize)
    {
        var ft = new FormattedText(string.Join("\n", lines), CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
            Face, fontSize, Brushes.White, 1.0) { TextAlignment = TextAlignment.Center };
        ft.LineHeight = fontSize * (Face.FontFamily.LineSpacing + 0.15);
        return ft;
    }

    /// 字幕の帯の画像 (Pbgra32)。maxWidth を超えるときは文字を小さくする。rounded なら帯の角を丸める
    public static BitmapSource? Render(IReadOnlyList<string> lines, double fontSize, double maxWidth, bool rounded)
    {
        if (lines.Count == 0 || fontSize < 4) return null;
        var ft = Format(lines, fontSize);
        if (ft.Width + fontSize * 0.8 > maxWidth && ft.Width > 0)
        {
            fontSize *= maxWidth / (ft.Width + fontSize * 0.8);
            ft = Format(lines, fontSize);
        }
        double pad = Math.Round(fontSize * 0.4);
        int w = (int)Math.Ceiling(ft.Width + pad * 2), h = (int)Math.Ceiling(ft.Height + pad * 2);
        if (w <= 0 || h <= 0) return null;

        var root = new ContainerVisual();
        var band = new DrawingVisual();
        using (var dc = band.RenderOpen())
        {
            double r = rounded ? fontSize * 0.25 : 0;
            dc.DrawRoundedRectangle(Band, null, new Rect(0, 0, w, h), r, r);
        }
        var text = new DrawingVisual
        {
            Effect = new DropShadowEffect { ShadowDepth = 0, BlurRadius = Math.Max(1, fontSize * 0.15 * 2), Color = Colors.Black, Opacity = 1 },
        };
        // 文字の幅を決めて、その中で行ごとに中央にそろえる
        double tw = Math.Ceiling(ft.Width) + 1;
        ft.MaxTextWidth = tw;
        using (var dc = text.RenderOpen()) dc.DrawText(ft, new Point((w - tw) / 2, pad));
        root.Children.Add(band);
        root.Children.Add(text);
        var bmp = new RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
        bmp.Render(root);
        bmp.Freeze();
        return bmp;
    }

    /// 帯を置く左上の位置 (area の座標、左上原点)。person は人物の左右の範囲 (なければ中央)、
    /// keyboardTop はキーボードが下半分にあるときのその上端 (area の座標)
    public static Point Position(Size size, Rect area, (double Left, double Right)? person, double? keyboardTop)
    {
        double margin = area.Height * 0.03;
        double center = person is { } p ? KeyboardRenderer.GapCenter(area, p.Left, p.Right) : area.Left + area.Width / 2;
        double x = Math.Min(Math.Max(center - size.Width / 2, area.Left + margin), area.Right - size.Width - margin);
        // 下端: 下から 6%、キーボードがあればその上 (余白 3%)
        double bottom = Math.Min(area.Bottom - area.Height * 0.06, keyboardTop is { } k ? k - margin : double.MaxValue);
        return new Point(Math.Round(x), Math.Round(bottom - size.Height));
    }
}
