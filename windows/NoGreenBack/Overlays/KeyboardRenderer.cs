// キーの操作を説明するための、キーボードの絵 (SPEC.md 8 章「キーボードの絵」。Mac 版の Sources/Keyboard.swift と同じ並び)
// JIS 配列か US 配列。Mac と Windows で名前が違うキーは両方書く (白が Mac、水色が Windows)。テンキーは Windows の並び。
// 位置と大きさは 1 キー分を 1 とした単位 (y は上から)。

using System.Globalization;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace NoGreenBack.Overlays;

public static class KeyboardRenderer
{
    /// キー 1 つ。Win は Windows での名前 (null なら Mac と同じ)。Big は文字や数字 1 つのキー (大きな文字で出す)
    sealed record Key(string Mac, string? Win, double X, double Y, double W = 1, double H = 1, bool Big = false, string? Shift = null);

    /// US 配列で shift を押して出る文字 (テンキー以外)
    static readonly Dictionary<string, string> ShiftedUS = new()
    {
        ["`"] = "~", ["1"] = "!", ["2"] = "@", ["3"] = "#", ["4"] = "$", ["5"] = "%", ["6"] = "^", ["7"] = "&", ["8"] = "*", ["9"] = "(", ["0"] = ")",
        ["-"] = "_", ["="] = "+", ["["] = "{", ["]"] = "}", ["\\"] = "|", [";"] = ":", ["'"] = "\"", [","] = "<", ["."] = ">", ["/"] = "?",
    };

    /// JIS 配列で shift を押して出る文字 (テンキー以外)
    static readonly Dictionary<string, string> ShiftedJIS = new()
    {
        ["1"] = "!", ["2"] = "\"", ["3"] = "#", ["4"] = "$", ["5"] = "%", ["6"] = "&", ["7"] = "'", ["8"] = "(", ["9"] = ")",
        ["-"] = "=", ["^"] = "~", ["¥"] = "|", ["@"] = "`", ["["] = "{", [";"] = "+", [":"] = "*", ["]"] = "}",
        [","] = "<", ["."] = ">", ["/"] = "?",
    };

    const double FnRow = 0.55, MainWidth = 15, NumGap = 0.4, NumWidth = 4;
    const double Width = MainWidth + NumGap + NumWidth, Height = FnRow + 5;

    /// Mac のキーの記号
    static readonly Dictionary<string, string> Symbols = new()
    {
        ["shift"] = "⇧", ["control"] = "⌃", ["option"] = "⌥", ["command"] = "⌘",
        ["tab"] = "⇥", ["delete"] = "⌫", ["return"] = "↩", ["caps"] = "⇪",
    };

    static readonly List<Key> JisKeys = MakeKeys(jis: true);
    static readonly List<Key> UsKeys = MakeKeys(jis: false);

    static List<Key> MakeKeys(bool jis)
    {
        var keys = new List<Key>();
        var shiftTable = jis ? ShiftedJIS : ShiftedUS;
        // 左から順に並べる。items は (Mac の名前, Windows の名前, 幅)
        void Row(double y, IEnumerable<(string Mac, string? Win, double W)> items, double h = 1, double x0 = 0)
        {
            double x = x0;
            foreach (var (mac, win, w) in items)
            {
                bool big = win == null && mac.Length == 1;
                string? shift = x < MainWidth && shiftTable.TryGetValue(mac, out var sh) ? sh : null;   // テンキーには付けない
                keys.Add(new Key(mac, win, x, y, w, h, big, shift));
                x += w;
            }
        }
        static IEnumerable<(string, string?, double)> Chars(string s) => s.Select(c => (c.ToString(), (string?)null, 1.0));
        static (string, string?, double) K(string mac, string? win, double w) => (mac, win, w);

        // ファンクションキー
        double fw = (MainWidth - 1.5) / 12;
        Row(0, new[] { K("esc", null, 1.5) }.Concat(Enumerable.Range(1, 12).Select(i => K($"F{i}", null, fw))), h: FnRow);
        double y1 = FnRow;
        if (jis)
        {
            // 数字の行 (左端は Windows だけの 半角/全角)
            Row(y1, new[] { K("", "半/全", 1) }.Concat(Chars("1234567890-^¥")).Append(K("delete", "BS", 1)));
            Row(y1 + 1, new[] { K("tab", null, 1.5) }.Concat(Chars("QWERTYUIOP@[")));   // 右端は return (別に描く)
            Row(y1 + 2, new[] { K("control", "Caps", 1.75) }.Concat(Chars("ASDFGHJKL;:]")));
            Row(y1 + 3, new[] { K("shift", null, 2.25) }.Concat(Chars("ZXCVBNM,./")).Append(K("_", "\\", 1)).Append(K("shift", null, 1.75)));
            Row(y1 + 4, [K("caps", "Ctrl", 1), K("option", "Win", 1), K("command", "Alt", 1.25), K("英数", "無変換", 1.25),
                         K("", null, 3.75), K("かな", "変換", 1.25), K("command", "Alt", 1.25), K("option", "Ctrl", 1.25)]);
        }
        else
        {
            Row(y1, Chars("`1234567890-=").Append(K("delete", "Backspace", 2)));
            Row(y1 + 1, new[] { K("tab", null, 1.5) }.Concat(Chars("QWERTYUIOP[]")).Append(K("\\", null, 1.5)));
            Row(y1 + 2, new[] { K("caps", "Caps", 1.75) }.Concat(Chars("ASDFGHJKL;'")).Append(K("return", "Enter", 2.25)));
            Row(y1 + 3, new[] { K("shift", null, 2.25) }.Concat(Chars("ZXCVBNM,./")).Append(K("shift", null, 2.75)));
            Row(y1 + 4, [K("fn", "Ctrl", 1), K("control", "Win", 1), K("option", "Alt", 1), K("command", null, 1.25),
                         K("", null, 5.5), K("command", "Alt", 1.25), K("option", "Ctrl", 1)]);
        }
        // 矢印 (上下は半分の高さ)
        keys.Add(new Key("←", null, MainWidth - 3, y1 + 4.5, H: 0.5));
        keys.Add(new Key("↑", null, MainWidth - 2, y1 + 4, H: 0.5));
        keys.Add(new Key("↓", null, MainWidth - 2, y1 + 4.5, H: 0.5));
        keys.Add(new Key("→", null, MainWidth - 1, y1 + 4.5, H: 0.5));

        // テンキー (Windows の並び。+ と enter は 2 段分)
        double nx = MainWidth + NumGap;
        Row(y1, [K("clear", "NumLk", 1), K("/", null, 1), K("*", null, 1), K("-", null, 1)], x0: nx);
        Row(y1 + 1, Chars("789"), x0: nx);
        Row(y1 + 2, Chars("456"), x0: nx);
        Row(y1 + 3, Chars("123"), x0: nx);
        Row(y1 + 4, [K("0", null, 2), K(".", null, 1)], x0: nx);
        keys.Add(new Key("+", null, nx + 3, y1 + 1, H: 2, Big: true));
        keys.Add(new Key("enter", "Enter", nx + 3, y1 + 3, H: 2));
        return keys;
    }

    static readonly FontFamily Font = new("Segoe UI, Yu Gothic UI, Segoe UI Symbol");
    static readonly Brush WinBrush = Frozen(new SolidColorBrush(Color.FromRgb(140, 204, 255)));
    static readonly Brush ShiftBrush = Frozen(new SolidColorBrush(Color.FromRgb(204, 204, 204)));
    static readonly Brush KeyBrush = Frozen(new SolidColorBrush(Color.FromArgb(242, 56, 56, 56)));
    static readonly Brush BaseBrush = Frozen(new SolidColorBrush(Color.FromArgb(199, 20, 20, 20)));
    static T Frozen<T>(T f) where T : Freezable { f.Freeze(); return f; }

    /// 横幅およそ pixelWidth 画素のキーボードの画像 (Pbgra32)。小さすぎれば null
    public static BitmapSource? Render(double pixelWidth, bool jis)
    {
        const double pad = 0.2;
        double unit = Math.Floor(pixelWidth / (Width + pad * 2));
        if (unit < 4) return null;
        int w = (int)Math.Round((Width + pad * 2) * unit), h = (int)Math.Round((Height + pad * 2) * unit);

        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            // 下地
            dc.DrawRoundedRectangle(BaseBrush, null, new Rect(0, 0, w, h), unit * 0.3, unit * 0.3);

            double gap = unit * 0.1, radius = unit * 0.14;
            var keyPen = new Pen(new SolidColorBrush(Color.FromRgb(115, 115, 115)), Math.Max(1, unit * 0.025));
            keyPen.Freeze();

            static (string S, double Size, Brush Brush, bool Bold) Text(string s, double size, Brush? brush = null, bool bold = false) =>
                (s, size, brush ?? Brushes.White, bold);
            static FormattedText Format((string S, double Size, Brush Brush, bool Bold) t, double size) =>
                new(t.S, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                    new Typeface(Font, FontStyles.Normal, t.Bold ? FontWeights.SemiBold : FontWeights.Medium, FontStretches.Normal),
                    size, t.Brush, 1.0);

            // 文字を縦に並べて、キーの真ん中に置く (はみ出す文字は小さくする)
            void DrawLines(List<(string S, double Size, Brush Brush, bool Bold)> specs, Rect r)
            {
                double maxW = r.Width - unit * 0.12;
                var lines = specs.Select(t =>
                {
                    var f = Format(t, t.Size);
                    return f.Width > maxW ? Format(t, t.Size * maxW / f.Width) : f;
                }).ToList();
                double total = lines.Sum(t => t.Height);
                double y = r.Top + (r.Height - total) / 2;
                foreach (var t in lines)
                {
                    dc.DrawText(t, new Point(r.Left + (r.Width - t.Width) / 2, y));
                    y += t.Height;
                }
            }

            void DrawLabel(Key key, Rect r)
            {
                if (key.Big && key.Shift != null)
                {
                    // shift の文字を上に、ふだんの文字を下に
                    DrawLines([Text(key.Shift, unit * 0.26, ShiftBrush), Text(key.Mac, unit * 0.34, bold: true)], r);
                    return;
                }
                if (key.Big) { DrawLines([Text(key.Mac, unit * 0.4, bold: true)], r); return; }
                var lines = new List<(string, double, Brush, bool)>();
                if (key.Mac.Length > 0)
                    lines.Add(Text(Symbols.TryGetValue(key.Mac, out var sym) ? $"{sym} {key.Mac}" : key.Mac, unit * 0.21));
                if (key.Win != null) lines.Add(Text(key.Win, unit * 0.21, WinBrush));
                DrawLines(lines, r);
            }

            foreach (var key in jis ? JisKeys : UsKeys)
            {
                var r = new Rect((pad + key.X) * unit + gap / 2, (pad + key.Y) * unit + gap / 2, key.W * unit - gap, key.H * unit - gap);
                dc.DrawRoundedRectangle(KeyBrush, keyPen, r, radius, radius);
                DrawLabel(key, r);
            }

            // return (JIS は 2 行にまたがる L 字。US はふつうのキーとして並べてある)
            if (jis)
            {
                double top = (pad + FnRow + 1) * unit + gap / 2;
                double right = (pad + MainWidth) * unit - gap / 2;
                double upperLeft = (pad + 13.5) * unit + gap / 2;
                double lowerLeft = (pad + 13.75) * unit + gap / 2;
                double mid = top + unit - gap, bottom = top + 2 * unit - gap;
                var ret = new StreamGeometry();
                using (var g = ret.Open())
                {
                    g.BeginFigure(new Point(upperLeft, top), true, true);
                    g.PolyLineTo([new Point(right, top), new Point(right, bottom), new Point(lowerLeft, bottom),
                                  new Point(lowerLeft, mid), new Point(upperLeft, mid)], true, true);
                }
                ret.Freeze();
                dc.DrawGeometry(KeyBrush, keyPen, ret);
                DrawLabel(new Key("return", "Enter", 0, 0), new Rect(lowerLeft, top, right - lowerLeft, bottom - top));
            }
        }
        var bmp = new RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
        bmp.Render(visual);
        bmp.Freeze();
        return bmp;
    }

    /// 人物 (personLeft〜personRight) と画面の端の、広い方のすき間の真ん中の x。
    /// 人物の体は枠の真ん中寄りにあるので、枠を左右 20% ずつ狭めて体の端とみなす (字幕も同じ場所に出す)
    public static double GapCenter(Rect area, double personLeft, double personRight)
    {
        double inset = (personRight - personLeft) * 0.2;
        double lo = personLeft + inset, hi = personRight - inset;
        double left = lo - area.Left, right = area.Right - hi;
        return left >= right ? area.Left + left / 2 : hi + right / 2;
    }

    /// キーボードを置く枠 (左上原点)。place は 0 人物の反対側, 1 下の中央, 2 左下, 3 右下, 4 上の中央。余白は高さの 3%
    public static Rect Frame(Size size, Rect area, int place, double personLeft, double personRight)
    {
        double margin = area.Height * 0.03;
        double x = place switch
        {
            2 => area.Left + margin,
            3 => area.Right - size.Width - margin,
            1 or 4 => area.Left + (area.Width - size.Width) / 2,
            // 人物の反対側。入りきらなければ画面の端に寄せる
            _ => Math.Min(Math.Max(GapCenter(area, personLeft, personRight) - size.Width / 2, area.Left + margin),
                          area.Right - size.Width - margin),
        };
        double y = place == 4 ? area.Top + margin : area.Bottom - size.Height - margin;
        return new Rect(Math.Round(x), Math.Round(y), size.Width, size.Height);
    }
}
