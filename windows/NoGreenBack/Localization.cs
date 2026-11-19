// 画面に出す文字の英語対応 (Mac 版の Sources/Localization.swift と同じ考え方)
// 日本語の文をそのままキーにして、英語の訳は Mac 版と共有の Resources/en.lproj/Localizable.strings と、
// Windows だけの文を書いた windows/NoGreenBack/Resources/en.strings から読む。
// Windows の表示言語が日本語なら日本語、それ以外は英語 (訳がない文は日本語のまま) で出す。

using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Markup;

namespace NoGreenBack;

public static partial class Loc
{
    /// アプリを英語で表示しているか (字幕の言語やキーボードの配列の既定に使う)
    /// 確かめるときは環境変数 NOGREENBACK_LANG=en / ja で言語を決められる
    public static bool IsEnglish { get; } =
        (Environment.GetEnvironmentVariable("NOGREENBACK_LANG") ?? CultureInfo.CurrentUICulture.TwoLetterISOLanguageName) != "ja";

    static readonly Dictionary<string, string> english = LoadEnglish();

    /// 日本語の文 key を、表示の言語に合わせた文にする
    public static string L(string key) =>
        IsEnglish && english.TryGetValue(key, out var en) ? en : key;

    /// 書式付き (%@ や %d を含む) の文を、言語に合わせてから値を埋め込む
    public static string L(string key, params object[] args) => Printf(L(key), args);

    static Dictionary<string, string> LoadEnglish()
    {
        var dict = new Dictionary<string, string>();
        var asm = Assembly.GetExecutingAssembly();
        // 後から読む Windows の訳が、共有の訳より優先される
        foreach (var name in new[] { "Shared.en.strings", "Windows.en.strings" })
        {
            using var stream = asm.GetManifestResourceStream(name);
            if (stream == null) continue;
            using var reader = new StreamReader(stream, Encoding.UTF8);
            foreach (Match m in StringsLine().Matches(reader.ReadToEnd()))
                dict[Unescape(m.Groups[1].Value)] = Unescape(m.Groups[2].Value);
        }
        return dict;
    }

    // "キー" = "訳"; の 1 組 (コメントの行は合わないので読み飛ばされる)
    [GeneratedRegex(@"^""((?:[^""\\]|\\.)*)""\s*=\s*""((?:[^""\\]|\\.)*)""\s*;", RegexOptions.Multiline)]
    private static partial Regex StringsLine();

    static string Unescape(string s)
    {
        var sb = new StringBuilder(s.Length);
        for (int i = 0; i < s.Length; i++)
        {
            if (s[i] != '\\' || i + 1 >= s.Length) { sb.Append(s[i]); continue; }
            char c = s[++i];
            sb.Append(c switch { 'n' => '\n', 't' => '\t', 'r' => '\r', _ => c });
        }
        return sb.ToString();
    }

    /// Mac の書式 (%@、%d、%.1f、%1$@、%%) に値を埋め込む
    public static string Printf(string format, object[] args)
    {
        var sb = new StringBuilder();
        int next = 0;
        for (int i = 0; i < format.Length; i++)
        {
            if (format[i] != '%' || i + 1 >= format.Length) { sb.Append(format[i]); continue; }
            var m = Spec().Match(format, i + 1);
            if (!m.Success || m.Index != i + 1) { sb.Append('%'); continue; }
            i = m.Index + m.Length - 1;
            string conv = m.Groups["conv"].Value;
            if (conv == "%") { sb.Append('%'); continue; }
            int index = m.Groups["pos"].Success ? int.Parse(m.Groups["pos"].Value) - 1 : next++;
            object? value = index < args.Length ? args[index] : null;
            if (conv == "f" && value is IConvertible num)
            {
                int digits = m.Groups["prec"].Success ? int.Parse(m.Groups["prec"].Value) : 6;
                sb.Append(Convert.ToDouble(num, CultureInfo.InvariantCulture).ToString("F" + digits, CultureInfo.CurrentCulture));
            }
            else sb.Append(value);
        }
        return sb.ToString();
    }

    [GeneratedRegex(@"(?:(?<pos>\d+)\$)?(?:\.(?<prec>\d+))?(?<conv>[@dfs%]|ld|lu)")]
    private static partial Regex Spec();
}

/// XAML から {l:L 日本語の文} で訳を引く。
/// 文の中の %@ にショートカットの修飾キー (Ctrl+Alt+Shift+ など) を入れるときは {l:L '…%@P', Shortcut=True}。
/// 修飾キーを替えたら文字も変わるよう、そのときは修飾キーへのバインディングにする
public sealed class LExtension(string key) : MarkupExtension
{
    public string Key { get; set; } = key;
    public bool Shortcut { get; set; }
    public override object ProvideValue(IServiceProvider serviceProvider)
    {
        if (!Shortcut) return Loc.L(Key);
        var binding = new System.Windows.Data.Binding(nameof(HotKeys.PrefixSource.Prefix))
        {
            Source = HotKeys.PrefixSource.Instance,
            Mode = System.Windows.Data.BindingMode.OneWay,
            Converter = new ShortcutTextConverter(Key),
        };
        return binding.ProvideValue(serviceProvider);
    }

    sealed class ShortcutTextConverter(string key) : System.Windows.Data.IValueConverter
    {
        public object Convert(object value, Type targetType, object parameter, System.Globalization.CultureInfo culture) => Loc.L(key, (string)value);
        public object ConvertBack(object value, Type targetType, object parameter, System.Globalization.CultureInfo culture) => throw new NotSupportedException();
    }
}
