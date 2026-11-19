// 字幕の文字の扱い (SPEC.md 10 章「置き換え」「出し方」「録画したときの字幕」。Mac 版の Sources/Subtitles.swift と main.swift と同じ決まり)

using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace NoGreenBack.Speech;

/// 確定した文と、話し始めた時刻・確定した時刻 (録画の始まりからの秒)
public sealed record SubtitleCue(double Start, double End, string Text);

public static partial class SubtitleText
{
    static readonly string[] Separators = ["→", "->", "=", "＝"];

    static IEnumerable<string> Lines(string terms) =>
        terms.Split('\n').Select(l => l.Trim().TrimEnd('\r')).Where(l => l.Length > 0);

    /// 「間違い → 正しい」の組 (区切りは → -> = ＝ のどれでもよい)。長い「間違い」から先に置き換える
    public static List<(string From, string To)> Replacements(string terms)
    {
        var list = new List<(string, string)>();
        foreach (var line in Lines(terms))
            foreach (var sep in Separators)
            {
                int i = line.IndexOf(sep, StringComparison.Ordinal);
                if (i < 0) continue;
                string from = line[..i].Trim(), to = line[(i + sep.Length)..].Trim();
                if (from.Length > 0) list.Add((from, to));
                break;
            }
        return [.. list.OrderByDescending(r => r.Item1.Length)];
    }

    /// 認識のヒントに渡す語 (置き換え後の正しい表記と、区切りのない行)
    public static List<string> HintTerms(string terms)
    {
        var list = new List<string>();
        foreach (var line in Lines(terms))
        {
            string term = line;
            foreach (var sep in Separators)
            {
                int i = line.IndexOf(sep, StringComparison.Ordinal);
                if (i >= 0) { term = line[(i + sep.Length)..].Trim(); break; }
            }
            if (term.Length > 0 && !list.Contains(term)) list.Add(term);
        }
        return list;
    }

    /// 置き換えの表を当てる (長い方から順に)
    public static string Apply(string text, List<(string From, string To)> replacements)
    {
        foreach (var (from, to) in replacements) text = text.Replace(from, to, StringComparison.Ordinal);
        return text;
    }

    const int LineLength = 26, LatinLineLength = 42, MaxLines = 2;

    /// 文を行に分ける (全部の行)。かな・漢字を含む文は 26 文字で区切り、ほかは単語の切れ目で折り返して 42 文字まで
    public static List<string> Wrap(string text)
    {
        string t = text.Trim();
        if (t.Length == 0) return [];
        bool cjk = t.Any(c => c is >= '぀' and <= 'ヿ' or >= '一' and <= '鿿');
        var result = new List<string>();
        if (cjk)
        {
            var chars = StringInfo.GetTextElementEnumerator(t);
            var elems = new List<string>();
            while (chars.MoveNext()) elems.Add((string)chars.Current);
            for (int i = 0; i < elems.Count; i += LineLength) result.Add(string.Concat(elems.Skip(i).Take(LineLength)));
            return result;
        }
        string line = "";
        foreach (var word in t.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            if (line.Length == 0) line = word;
            else if (line.Length + 1 + word.Length <= LatinLineLength) line += " " + word;
            else { result.Add(line); line = word; }
        }
        if (line.Length > 0) result.Add(line);
        return result;
    }

    /// 画面に出す行 (最後の 2 行)
    public static List<string> ShownLines(string text) => [.. Wrap(text).TakeLast(MaxLines)];

    /// 画面の字幕と同じ形に分ける: 2 行を超える文は 2 行ずつに区切り、文字数に応じて時間を分けて順に出す。
    /// 1 つの文の長さは最低 0.5 秒とみなす
    public static List<SubtitleCue> Split(IEnumerable<SubtitleCue> cues)
    {
        var result = new List<SubtitleCue>();
        foreach (var c in cues)
        {
            var lines = Wrap(c.Text);
            if (lines.Count == 0) continue;
            double span = Math.Max(c.End - c.Start, 0.5);
            double total = lines.Sum(l => l.Length), done = 0;
            for (int k = 0; k < lines.Count; k += MaxLines)
            {
                var piece = lines.Skip(k).Take(MaxLines).ToList();
                double n = piece.Sum(l => l.Length);
                result.Add(new SubtitleCue(c.Start + span * done / total, c.Start + span * (done + n) / total, string.Join("\n", piece)));
                done += n;
            }
        }
        return result;
    }

    /// .srt の中身。表示時間は最低 0.3 秒。時刻は HH:MM:SS,mmm
    public static string Srt(IEnumerable<SubtitleCue> cues)
    {
        static string Stamp(double t)
        {
            long ms = (long)Math.Round(Math.Max(0, t) * 1000);
            return $"{ms / 3_600_000:00}:{ms / 60_000 % 60:00}:{ms / 1000 % 60:00},{ms % 1000:000}";
        }
        var sb = new StringBuilder();
        int i = 1;
        foreach (var c in Split(cues))
        {
            if (i > 1) sb.Append('\n');
            sb.Append(i++).Append('\n')
              .Append(Stamp(c.Start)).Append(" --> ").Append(Stamp(Math.Max(c.End, c.Start + 0.3))).Append('\n')
              .Append(c.Text).Append('\n');
        }
        return sb.ToString();
    }

    /// 無音や雑音のときに Whisper が出しがちな決まり文句・音の説明 (字幕にしない)
    static readonly string[] Hallucinations =
    [
        "ご視聴ありがとうございました", "ご清聴ありがとうございました", "チャンネル登録", "最後までご視聴", "おやすみなさい",
        "thank you for watching", "thanks for watching", "please subscribe", "subtitles by",
    ];

    /// 認識した文字をきれいにする (音の説明の [音楽] (拍手) ♪ などを外す)。決まり文句だけなら空にする
    public static string Clean(string text)
    {
        string t = Bracketed().Replace(text, "").Replace("♪", "").Trim();
        string lower = t.ToLowerInvariant();
        if (Hallucinations.Any(h => lower.Contains(h, StringComparison.Ordinal)) && t.Length < 40) return "";
        if (t.Trim('。', '、', '.', ',', '!', '?', '！', '？', ' ', '…').Length == 0) return "";
        return t;
    }

    [GeneratedRegex(@"[\[\(（【][^\]\)）】]{0,20}[\]\)）】]")]
    private static partial Regex Bracketed();
}
