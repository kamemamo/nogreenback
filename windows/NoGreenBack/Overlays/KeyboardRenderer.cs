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
    /// 押しているキー (オレンジ。Mac 版の 1, 0.58, 0.1) と、組み合わせの文字の下地
    static readonly Brush LitBrush = Frozen(new SolidColorBrush(Color.FromRgb(255, 148, 26)));
    static readonly Brush PillBrush = Frozen(new SolidColorBrush(Color.FromArgb(217, 20, 20, 20)));
    static T Frozen<T>(T f) where T : Freezable { f.Freeze(); return f; }

    const double Pad = 0.2;

    /// 押しているキー (Code で作った番号) と、キーボードの上に出す組み合わせの文字
    public sealed class Pressed(IReadOnlySet<int> codes, string? text)
    {
        public static readonly Pressed None = new(new HashSet<int>(), null);
        public IReadOnlySet<int> Codes { get; } = codes;
        public string? Text { get; } = text;
        /// 画像を作り直すかどうかを決めるための文字列
        public string Signature => string.Join(",", Codes.Order()) + "|" + Text;
    }

    /// 組み合わせの文字を出す帯の高さ (unit は 1 キーの画素数)
    static double Band(double unit) => Math.Round(unit * 1.25);

    /// 横幅およそ pixelWidth 画素のキーボードの画像の大きさ (Render と同じ計算。字幕をキーボードの上に置くため)。
    /// withText なら組み合わせの文字の帯も含める
    public static Size? PixelSize(double pixelWidth, bool withText = false)
    {
        double unit = Math.Floor(pixelWidth / (Width + Pad * 2));
        if (unit < 4) return null;
        return new Size(Math.Round((Width + Pad * 2) * unit), Math.Round((Height + Pad * 2) * unit) + (withText ? Band(unit) : 0));
    }

    /// 横幅およそ pixelWidth 画素のキーボードの画像 (Pbgra32)。小さすぎれば null。
    /// pressed のキーを光らせ、組み合わせの文字があればキーボードの上 (textBelow なら下) に出す。
    /// キーボード全体は大きさと配列ごとに一度だけ描いて取っておき、キーを押したときは光るキーと文字だけを重ねる
    public static BitmapSource? Render(double pixelWidth, bool jis, Pressed? pressed = null, bool textBelow = false)
    {
        double unit = Math.Floor(pixelWidth / (Width + Pad * 2));
        if (unit < 4) return null;
        int w = (int)Math.Round((Width + Pad * 2) * unit), kbH = (int)Math.Round((Height + Pad * 2) * unit);
        var baseImage = BaseImage(w, kbH, unit, jis);
        var lit = (pressed?.Codes ?? Pressed.None.Codes).Select(c => IndexOf(c, jis)).OfType<int>().ToHashSet();
        string? text = pressed?.Text;
        if (lit.Count == 0 && text == null) return baseImage;

        int band = text == null ? 0 : (int)Band(unit);
        int h = kbH + band;
        double top = textBelow ? 0 : band;   // キーボードの上端
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.DrawImage(baseImage, new Rect(0, top, w, kbH));
            // 組み合わせの文字 (「Ctrl + C」など)
            if (text != null)
            {
                double pillH = unit * 0.95, maxW = w - unit * 0.8;
                var f = TextLine(text, unit * 0.55);
                if (f.Width > maxW) f = TextLine(text, unit * 0.55 * maxW / f.Width);
                double pillW = f.Width + unit * 0.8;
                double y = textBelow ? kbH + unit * 0.15 : band - pillH - unit * 0.15;
                var pill = new Rect((w - pillW) / 2, y, pillW, pillH);
                dc.DrawRoundedRectangle(PillBrush, null, pill, unit * 0.25, unit * 0.25);
                dc.DrawText(f, new Point(pill.Left + (pill.Width - f.Width) / 2, pill.Top + (pill.Height - f.Height) / 2));
            }
            // 光るキーだけを上から描く
            dc.PushTransform(new TranslateTransform(0, top));
            DrawKeys(dc, unit, jis, lit);
            dc.Pop();
        }
        var bmp = new RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
        bmp.Render(visual);
        bmp.Freeze();
        return bmp;

        static FormattedText TextLine(string s, double size) =>
            new(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                new Typeface(Font, FontStyles.Normal, FontWeights.Bold, FontStretches.Normal), size, Brushes.White, 1.0);
    }

    /// 取っておいたキーボード全体の画像 (大きさと配列ごと)
    static readonly Dictionary<string, BitmapSource> Bases = [];
    static readonly object BasesLock = new();

    static BitmapSource BaseImage(int w, int h, double unit, bool jis)
    {
        string key = $"{w}x{h} {unit} {jis}";
        lock (BasesLock) { if (Bases.TryGetValue(key, out var cached)) return cached; }
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            // 下地
            dc.DrawRoundedRectangle(BaseBrush, null, new Rect(0, 0, w, h), unit * 0.3, unit * 0.3);
            DrawKeys(dc, unit, jis, null);
        }
        var bmp = new RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
        bmp.Render(visual);
        bmp.Freeze();
        lock (BasesLock)
        {
            // 画面や大きさを何度も変えても増え続けないように
            if (Bases.Count >= 8) Bases.Clear();
            Bases[key] = bmp;
        }
        return bmp;
    }

    /// キーを描く。only が null ならすべてのキーをふだんの色で、そうでなければ only のキーだけを光らせて描く
    static void DrawKeys(DrawingContext dc, double unit, bool jis, IReadOnlySet<int>? only)
    {
        bool lit = only != null;
        double gap = unit * 0.1, radius = unit * 0.14;
        var keyPen = new Pen(lit ? Brushes.White : new SolidColorBrush(Color.FromRgb(115, 115, 115)),
                             Math.Max(1, unit * (lit ? 0.06 : 0.025)));
        keyPen.Freeze();
        var keyBrush = lit ? LitBrush : KeyBrush;
        var winBrush = lit ? Brushes.White : WinBrush;
        var shiftBrush = lit ? Brushes.White : ShiftBrush;

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
                DrawLines([Text(key.Shift, unit * 0.26, shiftBrush), Text(key.Mac, unit * 0.34, bold: true)], r);
                return;
            }
            if (key.Big) { DrawLines([Text(key.Mac, unit * 0.4, bold: true)], r); return; }
            var lines = new List<(string, double, Brush, bool)>();
            if (key.Mac.Length > 0)
                lines.Add(Text(Symbols.TryGetValue(key.Mac, out var sym) ? $"{sym} {key.Mac}" : key.Mac, unit * 0.21));
            if (key.Win != null) lines.Add(Text(key.Win, unit * 0.21, winBrush));
            DrawLines(lines, r);
        }

        var keys = jis ? JisKeys : UsKeys;
        for (int i = 0; i < keys.Count; i++)
        {
            if (only != null && !only.Contains(i)) continue;
            var key = keys[i];
            var r = new Rect((Pad + key.X) * unit + gap / 2, (Pad + key.Y) * unit + gap / 2, key.W * unit - gap, key.H * unit - gap);
            dc.DrawRoundedRectangle(keyBrush, keyPen, r, radius, radius);
            DrawLabel(key, r);
        }

        // return (JIS は 2 行にまたがる L 字。US はふつうのキーとして並べてある)
        if (jis && (only == null || only.Contains(JisReturn)))
        {
            double top = (Pad + FnRow + 1) * unit + gap / 2;
            double right = (Pad + MainWidth) * unit - gap / 2;
            double upperLeft = (Pad + 13.5) * unit + gap / 2;
            double lowerLeft = (Pad + 13.75) * unit + gap / 2;
            double mid = top + unit - gap, bottom = top + 2 * unit - gap;
            var ret = new StreamGeometry();
            using (var g = ret.Open())
            {
                g.BeginFigure(new Point(upperLeft, top), true, true);
                g.PolyLineTo([new Point(right, top), new Point(right, bottom), new Point(lowerLeft, bottom),
                              new Point(lowerLeft, mid), new Point(upperLeft, mid)], true, true);
            }
            ret.Freeze();
            dc.DrawGeometry(keyBrush, keyPen, ret);
            DrawLabel(new Key("return", "Enter", 0, 0), new Rect(lowerLeft, top, right - lowerLeft, bottom - top));
        }
    }

    // MARK: 押したキーと絵のキーの対応

    /// JIS 配列の return (L 字なので、キーの並びとは別に描く)
    const int JisReturn = -1;

    /// フックで受け取った仮想キーコードを、キーの番号にする。
    /// テンキーの Enter (拡張キー) はふつうの Enter と分け、NumLock がオフのテンキー (拡張でない Home・矢印など) は 0x200 を足して分ける
    public static int Code(uint vk, bool extended)
    {
        int v = (int)vk;
        if (v == 0x0D && extended) return 0x100 | v;
        if (!extended && v is 0x0C or (>= 0x21 and <= 0x28) or 0x2D or 0x2E) return 0x200 | v;
        return v;
    }

    /// 修飾キー (左右の Shift・Ctrl・Alt と Win)
    public static bool IsModifier(int code) => code is (>= 0xA0 and <= 0xA5) or 0x5B or 0x5C;

    /// キーの番号が、絵のどのキーか (Windows での名前、テンキーか、右側のキーか)
    static (string Label, bool Numpad, bool Right)? Spot(int code, bool jis)
    {
        if (code is >= 0x41 and <= 0x5A or >= 0x30 and <= 0x39) return (((char)code).ToString(), false, false);
        if (code is >= 0x70 and <= 0x7B) return ($"F{code - 0x6F}", false, false);
        if (code is >= 0x60 and <= 0x69) return (((char)('0' + code - 0x60)).ToString(), true, false);
        // NumLock がオフのテンキー
        string? nav = code switch
        {
            0x200 | 0x2D => "0", 0x200 | 0x23 => "1", 0x200 | 0x28 => "2", 0x200 | 0x22 => "3", 0x200 | 0x25 => "4",
            0x200 | 0x0C => "5", 0x200 | 0x27 => "6", 0x200 | 0x24 => "7", 0x200 | 0x26 => "8", 0x200 | 0x21 => "9",
            0x200 | 0x2E => ".", _ => null,
        };
        if (nav != null) return (nav, true, false);
        string? label = code switch
        {
            0xBD => "-", 0xBC => ",", 0xBE => ".", 0xBF => "/",
            // 同じ仮想キーでも、JIS と US で書いてある文字が違うキー
            0xDE => jis ? "^" : "'", 0xDC => jis ? "¥" : "\\", 0xC0 => jis ? "@" : "`", 0xDB => "[", 0xDD => "]",
            0xBB => jis ? ";" : "=", 0xBA => jis ? ":" : ";", 0xE2 => "\\",
            0x1D => "無変換", 0x1C => "変換", 0xF3 or 0xF4 or 0x19 => "半/全",
            0x08 => jis ? "BS" : "Backspace", 0x0D => "Enter", 0x09 => "tab", 0x1B => "esc", 0x20 => "space", 0x14 => "Caps",
            0x25 => "←", 0x26 => "↑", 0x27 => "→", 0x28 => "↓",
            _ => null,
        };
        if (label != null) return (label, false, false);
        return code switch
        {
            0xA0 => ("shift", false, false), 0xA1 => ("shift", false, true),
            0xA2 => ("Ctrl", false, false), 0xA3 => ("Ctrl", false, true),
            0xA4 => ("Alt", false, false), 0xA5 => ("Alt", false, true),
            0x5B => ("Win", false, false), 0x5C => ("Win", false, true),
            0x90 => ("NumLk", true, false), 0x6F => ("/", true, false), 0x6A => ("*", true, false),
            0x6D => ("-", true, false), 0x6B => ("+", true, false), 0x6E => (".", true, false),
            0x100 | 0x0D => ("Enter", true, false),
            _ => null,
        };
    }

    /// キーの番号が、絵の何番目のキーか (絵にないキーは null。JIS の return は JisReturn)
    static int? IndexOf(int code, bool jis)
    {
        if (Spot(code, jis) is not { } s) return null;
        if (jis && s.Label == "Enter" && !s.Numpad) return JisReturn;
        var keys = jis ? JisKeys : UsKeys;
        var found = Enumerable.Range(0, keys.Count).Where(i =>
        {
            var k = keys[i];
            if (s.Label == "space") return k.Mac.Length == 0 && k.W > 3;
            return (k.Win ?? k.Mac) == s.Label && (k.X >= MainWidth) == s.Numpad;
        }).ToList();
        return found.Count == 0 ? null : s.Right ? found[^1] : found[0];
    }

    /// 組み合わせの文字に出すキーの名前 (Windows の呼び方。「C」「Enter」など。出さないキーは null)
    public static string? DisplayName(int code, bool jis)
    {
        string? name = code switch
        {
            0x08 => "Backspace", 0x09 => "Tab", 0x0D => "Enter", 0x100 | 0x0D => "Enter", 0x1B => "Esc", 0x20 => "Space",
            0x14 => "Caps Lock", 0x2E => "Delete", 0x2D => "Insert", 0x24 => "Home", 0x23 => "End",
            0x21 => "Page Up", 0x22 => "Page Down", 0x2C => "PrtSc", 0x13 => "Pause", 0x91 => "Scroll Lock",
            0x90 => "Num Lock", 0x5D => "Menu", 0xF3 or 0xF4 or 0x19 => "半角/全角",
            >= 0x7C and <= 0x87 => $"F{code - 0x6F}",
            _ => null,
        };
        return name ?? Spot(code, jis)?.Label;
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
