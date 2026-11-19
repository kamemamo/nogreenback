// 字幕の設定の吹き出し (SPEC.md 10 章「置き換え」。上部の辞書のボタン)
// 認識する言語、AI で直す (初版では入れていないので選べない)、置き換えの欄、件数、読み込む… / 保存…
// 置き換えの欄は、書いてから 0.8 秒待って自動で保存し、すぐ認識に使う。

using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Threading;

namespace NoGreenBack;

public partial class MainWindow
{
    Popup? termsPopup;

    void TermsButton_Click(object sender, RoutedEventArgs e)
    {
        if (termsPopup is { IsOpen: true }) { termsPopup.IsOpen = false; return; }
        termsPopup = new Popup
        {
            PlacementTarget = TermsButton,
            Placement = PlacementMode.Bottom,
            StaysOpen = false,
            AllowsTransparency = true,
            Child = BuildTermsPanel(),
        };
        termsPopup.IsOpen = true;
    }

    UIElement BuildTermsPanel()
    {
        var s = model.Settings;
        var stack = new StackPanel { Margin = new Thickness(16, 14, 16, 14), Width = 420 };

        // 認識する言語
        var language = new ComboBox { Width = 160, Margin = new Thickness(8, 0, 0, 0) };
        language.Items.Add("日本語");
        language.Items.Add("English");
        language.SelectedIndex = s.EffectiveSubtitleLanguage.StartsWith("en") ? 1 : 0;
        language.SelectionChanged += (_, _) => s.SubtitleLanguage = language.SelectedIndex == 1 ? "en-US" : "ja-JP";
        var languageRow = new StackPanel { Orientation = Orientation.Horizontal };
        languageRow.Children.Add(new TextBlock { Text = Loc.L("認識する言語"), VerticalAlignment = VerticalAlignment.Center });
        languageRow.Children.Add(language);
        stack.Children.Add(languageRow);

        // AI で直す (初版では入れていない。選べなくして理由を添える。SPEC.md 17 章 4)
        stack.Children.Add(new CheckBox { Content = Loc.L("AI で聞き間違いを直す"), IsEnabled = false, IsChecked = false, Margin = new Thickness(0, 8, 0, 0) });
        stack.Children.Add(new TextBlock
        {
            Text = Loc.L("AI での直しは、Windows 版にはまだ入っていません"),
            FontSize = 11, Foreground = Brushes.Gray, Margin = new Thickness(20, 2, 0, 0), TextWrapping = TextWrapping.Wrap,
        });

        stack.Children.Add(new TextBlock { Text = Loc.L("字幕の置き換え"), FontWeight = FontWeights.Bold, FontSize = 13, Margin = new Thickness(0, 10, 0, 4) });
        var terms = new TextBox
        {
            Text = s.SubtitleTerms, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap, Height = 240,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            FontSize = 13,
        };
        stack.Children.Add(terms);

        var count = new TextBlock { FontSize = 11, FontWeight = FontWeights.Medium, VerticalAlignment = VerticalAlignment.Center };
        void UpdateCount()
        {
            int n = Speech.SubtitleText.Replacements(s.SubtitleTerms).Count;
            count.Text = n == 0 ? Loc.L("置き換えは登録されていません") : Loc.L("✓ %d 件の置き換えを字幕に使っています", n);
            count.Foreground = n == 0 ? Brushes.Gray : new SolidColorBrush(Color.FromRgb(0x2E, 0x9E, 0x4F));
        }
        UpdateCount();

        // 書いた内容は 0.8 秒待ってから保存し、すぐ認識に使う
        var saveTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(0.8) };
        void Apply() { saveTimer.Stop(); s.SubtitleTerms = terms.Text; UpdateCount(); }
        saveTimer.Tick += (_, _) => Apply();
        terms.TextChanged += (_, _) => { saveTimer.Stop(); saveTimer.Start(); };
        termsPopup!.Closed += (_, _) => { if (saveTimer.IsEnabled) Apply(); };

        var load = new Button { Content = Loc.L("読み込む…"), Padding = new Thickness(10, 2, 10, 2), Margin = new Thickness(8, 0, 0, 0), ToolTip = Loc.L("字幕の置き換えのファイルを選びます (今の内容と入れ替わります)") };
        var save = new Button { Content = Loc.L("保存…"), Padding = new Thickness(10, 2, 10, 2), Margin = new Thickness(8, 0, 0, 0), ToolTip = Loc.L("字幕の置き換えをファイルに保存します") };
        load.Click += (_, _) =>
        {
            var dlg = new Microsoft.Win32.OpenFileDialog { Filter = "Text (*.txt)|*.txt|*.*|*.*", Title = Loc.L("字幕の置き換えのファイルを選びます (今の内容と入れ替わります)") };
            if (!WithDialog(() => dlg.ShowDialog(this) == true)) return;
            try { terms.Text = File.ReadAllText(dlg.FileName); Apply(); }
            catch (Exception ex) { MessageBox.Show(this, Loc.L("読み込めません: %@", ex.Message), "NoGreenBack"); }
        };
        save.Click += (_, _) =>
        {
            Apply();
            var dlg = new Microsoft.Win32.SaveFileDialog { Filter = "Text (*.txt)|*.txt", FileName = Loc.L("字幕の置き換え.txt"), Title = Loc.L("字幕の置き換えをファイルに保存します") };
            if (!WithDialog(() => dlg.ShowDialog(this) == true)) return;
            try { File.WriteAllText(dlg.FileName, terms.Text, new System.Text.UTF8Encoding(false)); }
            catch (Exception ex) { MessageBox.Show(this, Loc.L("保存できません: %@", ex.Message), "NoGreenBack"); }
        };
        var buttons = new DockPanel { Margin = new Thickness(0, 8, 0, 0) };
        DockPanel.SetDock(save, Dock.Right);
        DockPanel.SetDock(load, Dock.Right);
        buttons.Children.Add(save);
        buttons.Children.Add(load);
        buttons.Children.Add(count);
        stack.Children.Add(buttons);

        stack.Children.Add(new TextBlock
        {
            Text = Loc.L("よく間違える言葉を「間違い → 正しい」と 1 行ずつ書くと、字幕と字幕ファイルで置き換えます (例: ジオメトリー濃度 → ジオメトリーノード、ブレンダー → Blender)。→ は -> や = でも書けます。書いた内容は自動で残ります。ほかの PC や別の話題用に、ファイルに保存・読み込みもできます"),
            TextWrapping = TextWrapping.Wrap, FontSize = 11, Foreground = Brushes.Gray, Margin = new Thickness(0, 8, 0, 0),
        });

        return new Border
        {
            Background = Brushes.White,
            BorderBrush = new SolidColorBrush(Color.FromRgb(0xC8, 0xC8, 0xCE)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Child = stack,
        };
    }

    /// ファイルの選択画面を開いている間は、吹き出しが閉じないようにする
    bool WithDialog(Func<bool> show)
    {
        if (termsPopup == null) return show();
        termsPopup.StaysOpen = true;
        try { return show(); }
        finally { termsPopup.StaysOpen = false; }
    }
}
