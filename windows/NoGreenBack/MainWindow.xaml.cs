using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;

namespace NoGreenBack;

public partial class MainWindow : Window
{
    readonly AppModel model;
    HotKeys? hotKeys;
    Popup? shortcutPopup;

    public MainWindow(AppModel model)
    {
        this.model = model;
        DataContext = model;
        InitializeComponent();
        SetUpLongSideCombo();
        model.State.FpsText = "— fps";

        PreviewHost.PixelSizeChanged += (hwnd, w, h) => model.Video.AttachPreview(hwnd, w, h);
        StateChanged += (_, _) => model.Video.SetPreviewVisible(WindowState != WindowState.Minimized);

        SourceInitialized += (_, _) =>
        {
            hotKeys = new HotKeys((HwndSource)PresentationSource.FromVisual(this), model);
            // 登録できなかったものは、起動時にまとめて知らせる (SPEC.md 14 章)
            Dispatcher.BeginInvoke(() => ReportUnavailableShortcuts(changed: false));
        };
        Closed += (_, _) => hotKeys?.Dispose();

        // ショートカットの修飾キーを替えたら、登録し直して、登録できなかったものを知らせる
        model.Settings.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName != nameof(Settings.HotKeyModifiers) || hotKeys == null) return;
            hotKeys.Register(model.Settings.HotKeyModifiers);
            if (shortcutPopup is { IsOpen: true }) shortcutPopup.Child = BuildShortcutList();
            ReportUnavailableShortcuts(changed: true);
        };

        // Ctrl+/ でショートカットの一覧
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Oem2 && Keyboard.Modifiers == ModifierKeys.Control)
            {
                ToggleShortcutList();
                e.Handled = true;
            }
        };
    }

    /// 長辺の選択肢 (0 は「縮めない」)
    void SetUpLongSideCombo()
    {
        foreach (var v in Choices.RecLongSides)
            LongSideCombo.Items.Add(new ComboBoxItem { Content = v == 0 ? Loc.L("縮めない") : v.ToString(), Tag = v });
        LongSideCombo.SelectedIndex = Math.Max(0, Array.IndexOf(Choices.RecLongSides, model.Settings.RecLongSide));
        LongSideCombo.SelectionChanged += (_, _) =>
        {
            if (LongSideCombo.SelectedItem is ComboBoxItem { Tag: int v }) model.Settings.RecLongSide = v;
        };
    }

    void ClearButton_Click(object sender, RoutedEventArgs e) => model.ClearDrawing();

    /// 押した時点ではボタンの色を変えず、録画が実際に始まった・止まったときに変える (SPEC.md 9 章)
    void RecordButton_Click(object sender, RoutedEventArgs e)
    {
        RecordButton.SetCurrentValue(System.Windows.Controls.Primitives.ToggleButton.IsCheckedProperty, model.State.Recording);
        model.Recording.Toggle();
    }

    void HelpButton_Click(object sender, RoutedEventArgs e) => ToggleShortcutList();

    /// 登録できなかったショートカットを知らせる (起動したとき・修飾キーを替えたとき)
    void ReportUnavailableShortcuts(bool changed)
    {
        var failed = hotKeys?.Entries.Where(e => e.Unavailable).ToList() ?? [];
        if (failed.Count == 0) return;
        string text = Loc.L("次のショートカットは他のアプリが使っているため登録できませんでした:\n")
            + string.Join("\n", failed.Select(e => $"{e.KeyText}  {Loc.L(e.Description)}"));
        if (!changed) text += "\n\n" + Loc.L("ショートカットの一覧 (Ctrl+/) の「組み合わせ」で、ほかの組み合わせに替えられます。");
        MessageBox.Show(this, text, "NoGreenBack", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    /// ショートカットの一覧を吹き出しで出す
    void ToggleShortcutList()
    {
        if (shortcutPopup is { IsOpen: true }) { shortcutPopup.IsOpen = false; return; }
        shortcutPopup = new Popup
        {
            PlacementTarget = HelpButton,
            Placement = PlacementMode.Bottom,
            HorizontalOffset = -420,
            StaysOpen = false,
            AllowsTransparency = true,
            Child = BuildShortcutList(),
        };
        shortcutPopup.IsOpen = true;
    }

    UIElement BuildShortcutList()
    {
        var grid = new Grid { Margin = new Thickness(16) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        void AddRow(string key, string text, bool bold = false, bool gray = false)
        {
            int row = grid.RowDefinitions.Count;
            grid.RowDefinitions.Add(new RowDefinition());
            var brush = gray ? Brushes.Gray : Brushes.Black;
            var k = new TextBlock { Text = key, Margin = new Thickness(0, 2, 16, 2), FontWeight = bold ? FontWeights.Bold : FontWeights.Normal, Foreground = brush };
            var t = new TextBlock { Text = text, Margin = new Thickness(0, 2, 0, 2), Foreground = brush, TextWrapping = TextWrapping.Wrap };
            Grid.SetRow(k, row); Grid.SetRow(t, row); Grid.SetColumn(t, 1);
            grid.Children.Add(k); grid.Children.Add(t);
        }
        void AddHeader(string text)
        {
            int row = grid.RowDefinitions.Count;
            grid.RowDefinitions.Add(new RowDefinition());
            var h = new TextBlock { Text = text, FontWeight = FontWeights.Bold, Margin = new Thickness(0, row == 0 ? 0 : 10, 0, 4) };
            Grid.SetRow(h, row); Grid.SetColumnSpan(h, 2);
            grid.Children.Add(h);
        }

        AddHeader(Loc.L("どこからでも使えるショートカット"));

        // 修飾キーの組み合わせ (ほかのアプリとぶつかるときに替える)
        {
            int row = grid.RowDefinitions.Count;
            grid.RowDefinitions.Add(new RowDefinition());
            var label = new TextBlock { Text = Loc.L("組み合わせ"), Margin = new Thickness(0, 2, 16, 6), VerticalAlignment = VerticalAlignment.Center };
            var combo = new ComboBox
            {
                ItemsSource = HotKeys.ModifierChoices.Select(c => c.Text + Loc.L("＋キー")).ToList(),
                SelectedIndex = model.Settings.HotKeyModifiers,
                HorizontalAlignment = HorizontalAlignment.Left, MinWidth = 180, Margin = new Thickness(0, 2, 0, 6),
                ToolTip = Loc.L("ほかのアプリが同じ組み合わせを使っていて効かないときに替えます。Stream Deck などに設定した組み合わせも替えてください"),
            };
            combo.SelectionChanged += (_, _) => { if (combo.SelectedIndex >= 0) model.Settings.HotKeyModifiers = combo.SelectedIndex; };
            Grid.SetRow(label, row); Grid.SetRow(combo, row); Grid.SetColumn(combo, 1);
            grid.Children.Add(label); grid.Children.Add(combo);
        }

        foreach (var e in hotKeys?.Entries ?? [])
            AddRow(e.KeyText, Loc.L(e.Description) + (e.Unavailable ? Loc.L("（他のアプリが使用中のため使えません）") : ""), gray: e.Unavailable);

        string drawKey = new[] { "Ctrl", "Alt", "Ctrl+Alt" }[Math.Clamp(model.Settings.DrawKey, 0, 2)];
        AddHeader(Loc.L("手書き"));
        AddRow(Loc.L("%@ を押しながら", drawKey), Loc.L("ドラッグで描く（手書きがオンのとき）"));
        AddRow(Loc.L("%@ を 2 回", drawKey), Loc.L("手書きを全部消す"));
        AddRow(Loc.L("%@ ＋ 右クリック", drawKey), Loc.L("手書きを全部消す"));
        AddHeader(Loc.L("NoGreenBack の操作"));
        AddRow("Esc", Loc.L("全画面出力を閉じる（全画面出力を操作中のとき）"));
        AddRow("Ctrl+/", Loc.L("ショートカットの一覧"));

        int last = grid.RowDefinitions.Count;
        grid.RowDefinitions.Add(new RowDefinition());
        var note = new TextBlock
        {
            Text = Loc.L("上のショートカットは、他のアプリを操作中でも効きます。Stream Deck では「ホットキー」アクションにこの組み合わせを設定します。"),
            TextWrapping = TextWrapping.Wrap, Foreground = Brushes.DimGray, Margin = new Thickness(0, 12, 0, 0),
        };
        Grid.SetRow(note, last); Grid.SetColumnSpan(note, 2);
        grid.Children.Add(note);

        return new Border
        {
            Width = 460,
            Background = Brushes.White,
            BorderBrush = new SolidColorBrush(Color.FromRgb(0xC8, 0xC8, 0xCE)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Child = grid,
        };
    }
}
