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
            var failed = hotKeys.Entries.Where(e => e.Unavailable).ToList();
            if (failed.Count > 0)
            {
                // 登録できなかったものは、起動時にまとめて知らせる (SPEC.md 14 章)
                Dispatcher.BeginInvoke(() => MessageBox.Show(this,
                    Loc.L("次のショートカットは他のアプリが使っているため登録できませんでした:\n")
                        + string.Join("\n", failed.Select(e => $"{e.KeyText}  {Loc.L(e.Description)}")),
                    "NoGreenBack", MessageBoxButton.OK, MessageBoxImage.Information));
            }
        };
        Closed += (_, _) => hotKeys?.Dispose();

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

    void HelpButton_Click(object sender, RoutedEventArgs e) => ToggleShortcutList();

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
