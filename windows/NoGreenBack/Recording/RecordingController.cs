// 画面録画の操作 (SPEC.md 9 章)
// - 「録画する画面」を録画し、もう一度押すと止めて、「ビデオ」フォルダに NoGreenBack yyyy-MM-dd HH.mm.ss.mp4 で保存し、エクスプローラーで選んで見せる
// - 押した時点ではボタンの色を変えず、録画が実際に始まった・止まったときに変える。処理中はボタンを押せなくする。止めたあとは「保存中…」と出す
// - 録画停止ボタン: 録画している画面の右上 (右から 16・上から 12) に「■ 録画停止」と経過時間の小さなパネルを出す。録画に映さず、ドラッグで動かせる
// - 操作ウィンドウと同じ画面を録画するときは、録画を始めたら操作ウィンドウを最小化し、止めたら元に戻して前面にする
// - 画面に変化がなく 1 コマも書けなかったときは保存しない。マイクを選んでいたのに音が届かなかったときは知らせる

using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using NoGreenBack.Overlays;
using NoGreenBack.Video;

namespace NoGreenBack.Recording;

public sealed record RecordDisplayChoice(string Id, string Label)
{
    public override string ToString() => Label;
}

public sealed partial class RecordingController : Observable, IDisposable
{
    readonly AppModel model;
    readonly DispatcherTimer elapsedTimer;
    ScreenRecorder? recorder;
    DisplayInfo? recordingDisplay;
    string finalPath = "";
    DateTime startedAt;
    bool minimizedMain;
    StopPanel? panel;

    public ObservableCollection<RecordDisplayChoice> DisplayChoices { get; } = [];

    bool busy;
    /// 始めている・止めている途中 (ボタンを押せなくする)
    public bool Busy { get => busy; private set { if (Set(ref busy, value)) Raise(nameof(CanToggle)); } }
    public bool CanToggle => !busy;

    /// 録画停止のパネルのウィンドウ (録画から外すため)
    public IntPtr PanelHwnd => panel?.Hwnd ?? IntPtr.Zero;

    /// 録画している画面 (録画していなければ null)
    public DisplayInfo? RecordingDisplay => recorder != null ? recordingDisplay : null;

    public RecordingController(AppModel model)
    {
        this.model = model;
        model.Displays.Changed += _ => RefreshChoices();
        model.Settings.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(Settings.RecordScreen)) Raise(nameof(SelectedDisplayId)); };
        elapsedTimer = new DispatcherTimer(TimeSpan.FromSeconds(0.5), DispatcherPriority.Background, (_, _) => UpdateElapsed(), Dispatcher.CurrentDispatcher);
        RefreshChoices();
    }

    /// 選んでいる「録画する画面」(空は「表示する画面と同じ」)
    public string SelectedDisplayId
    {
        get => model.Displays.Find(model.Settings.RecordScreen)?.Name ?? "";
        set { if (value != null) model.Settings.RecordScreen = value.Length == 0 ? null : value; }
    }

    /// 録画する画面 (覚えた名前の画面がなければ「表示する画面」)
    public DisplayInfo? RecordDisplay => model.Displays.Find(model.Settings.RecordScreen) ?? model.Displays.OverlayDisplay;

    void RefreshChoices()
    {
        DisplayChoices.Clear();
        DisplayChoices.Add(new RecordDisplayChoice("", Loc.L("表示する画面と同じ")));
        foreach (var d in model.Displays.All) DisplayChoices.Add(new RecordDisplayChoice(d.Name, d.Label));
        Raise(nameof(SelectedDisplayId));
    }

    /// 録画の開始・停止 (ボタンと Ctrl+Alt+Shift+R)
    public void Toggle()
    {
        if (Busy) return;
        if (recorder == null) _ = StartAsync();
        else _ = StopAsync();
    }

    async Task StartAsync()
    {
        var display = RecordDisplay;
        if (display == null) return;
        var s = model.Settings;
        Busy = true;
        try
        {
            string folder = Environment.GetFolderPath(Environment.SpecialFolder.MyVideos);
            Directory.CreateDirectory(folder);
            string name = $"NoGreenBack {DateTime.Now:yyyy-MM-dd HH.mm.ss}";
            finalPath = Path.Combine(folder, name + ".mp4");
            string temp = Path.Combine(folder, name + ".recording.mp4");
            var options = new RecordOptions(s.RecMbps, s.RecLongSide, s.RecFPS, s.RecHEVC, s.RecAudioKbps);

            // 録画停止のパネルを先に出して、録画の対象から外しておく
            recordingDisplay = display;
            panel = new StopPanel(this);
            panel.ShowAt(display);
            model.State.Recording = true;   // 取り込みから外すウィンドウが決まる (Overlays.OverlayController)
            model.Overlays.UpdateCaptureExclusion();

            var mic = model.Mic.Enabled ? model.Mic : null;
            var external = model.External;
            recorder = await Task.Run(() => new ScreenRecorder(display, options, mic, temp, external));
            startedAt = DateTime.Now;
            elapsedTimer.Start();
            UpdateElapsed();

            // 操作ウィンドウと同じ画面を録画するときは、操作ウィンドウを最小化する
            if (Application.Current.MainWindow is { } mw && IsOnDisplay(mw, display) && mw.WindowState != WindowState.Minimized)
            {
                mw.WindowState = WindowState.Minimized;
                minimizedMain = true;
            }
        }
        catch (Exception e)
        {
            Log.Write($"録画を始められません: {e}");
            recorder?.Dispose();
            recorder = null;
            ClosePanel();
            model.State.Recording = false;
            model.Overlays.UpdateCaptureExclusion();
            MessageBox.Show(Loc.L("録画を始められません: %@", e.Message), "NoGreenBack", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally { Busy = false; }
    }

    async Task StopAsync()
    {
        var rec = recorder;
        if (rec == null) return;
        Busy = true;
        elapsedTimer.Stop();
        model.State.ElapsedText = Loc.L("保存中…");
        ClosePanel();
        string? saved = null;
        bool noFrames = false, noAudio = false, externalOnly = rec.ExternalOnly;
        var subtitles = model.Subtitles;
        string trackLanguage = subtitles.TrackLanguage;
        try
        {
            (saved, noFrames, noAudio) = await Task.Run(() =>
            {
                rec.Stop();
                // 録画中に確定した字幕の文 (録画の最初のコマを 0 とした秒)
                var cues = rec.FrameCount > 0 ? CuesOnUiThread(subtitles, rec.StartTicks) : [];
                if (rec.FrameCount == 0)
                {
                    TryDelete(rec.TempPath);
                    return ((string?)null, true, false);
                }
                bool silent = rec.HasAudio && rec.AudioSamples == 0;
                try
                {
                    ScreenRecorder.Remux(rec.TempPath, finalPath);
                    TryDelete(rec.TempPath);
                    WriteSubtitles(finalPath, cues, trackLanguage);
                    return (finalPath, false, silent);
                }
                catch (Exception e)
                {
                    // 詰め替えに失敗したら、断片化した方を残す (そのままでも再生できる)。
                    // 字幕は .srt だけ作る (断片化した MP4 には字幕トラックを足せないため)
                    Log.Write($"録画を MP4 に詰め替えられません: {e.Message}");
                    TryDelete(finalPath);
                    WriteSrt(rec.TempPath, cues);
                    return (rec.TempPath, false, silent);
                }
            });
            Log.Write($"録画: {rec.FrameCount} コマ、音 {rec.AudioSamples} サンプル → {saved ?? "保存しない"}");
        }
        catch (Exception e)
        {
            Log.Write($"録画を止められません: {e}");
            MessageBox.Show(Loc.L("録画を保存できません: %@", e.Message), "NoGreenBack", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally
        {
            rec.Dispose();
            recorder = null;
            model.State.Recording = false;
            model.State.ElapsedText = "";
            model.Overlays.UpdateCaptureExclusion();
            Busy = false;
        }

        // 最小化していた操作ウィンドウを戻して前面にする
        if (minimizedMain && Application.Current.MainWindow is { } mw)
        {
            mw.WindowState = WindowState.Normal;
            mw.Activate();
        }
        minimizedMain = false;

        if (noFrames)
            MessageBox.Show(Loc.L("画面に変化がなかったため、録画は保存されませんでした。"), "NoGreenBack", MessageBoxButton.OK, MessageBoxImage.Information);
        else if (saved != null)
        {
            if (noAudio)
                MessageBox.Show(externalOnly
                    ? Loc.L("外部の音声が届いていなかったため、録画には音が入っていません。\n「外部の音声」の「入力」の選択と、右のメーターが動くかを確かめてください。")
                    : Loc.L("マイクの音が届いていなかったため、録画には音が入っていません。\n「マイク」の選択と、右のメーターが動くかを確かめてください。"),
                    "NoGreenBack", MessageBoxButton.OK, MessageBoxImage.Information);
            try { Process.Start("explorer.exe", $"/select,\"{saved}\""); } catch { }
        }
    }

    /// 字幕の文を UI のスレッドで受け取る
    static List<Speech.SubtitleCue> CuesOnUiThread(Speech.SubtitleController subtitles, long startTicks) =>
        Application.Current.Dispatcher.Invoke(() => subtitles.RecordedCues(startTicks));

    /// 録画と同じ名前の .srt と、MP4 の中の字幕トラックを作る (SPEC.md 10 章「録画したときの字幕」)
    static void WriteSubtitles(string mp4, List<Speech.SubtitleCue> cues, string language)
    {
        if (cues.Count == 0) return;
        try
        {
            File.WriteAllText(Path.ChangeExtension(mp4, ".srt"), Speech.SubtitleText.Srt(cues), new System.Text.UTF8Encoding(false));
            Speech.Mp4SubtitleTrack.Append(mp4, cues, language);
            Log.Write($"録画: 字幕 {cues.Count} 文を .srt と字幕トラックに書きました");
        }
        catch (Exception e) { Log.Write($"録画の字幕を書けません: {e.Message}"); }
    }

    /// 録画と同じ名前の .srt だけを作る (MP4 に詰め替えられず、断片化した方を残したとき)
    static void WriteSrt(string mp4, List<Speech.SubtitleCue> cues)
    {
        if (cues.Count == 0) return;
        try
        {
            File.WriteAllText(Path.ChangeExtension(mp4, ".srt"), Speech.SubtitleText.Srt(cues), new System.Text.UTF8Encoding(false));
            Log.Write($"録画: 字幕 {cues.Count} 文を .srt に書きました");
        }
        catch (Exception e) { Log.Write($"録画の字幕を書けません: {e.Message}"); }
    }

    void UpdateElapsed()
    {
        if (recorder == null) return;
        var t = DateTime.Now - startedAt;
        string text = t.TotalHours >= 1 ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}" : $"{(int)t.TotalMinutes}:{t.Seconds:00}";
        model.State.ElapsedText = text;
        panel?.SetElapsed(text);
    }

    void ClosePanel()
    {
        panel?.Close();
        panel = null;
    }

    static bool IsOnDisplay(Window w, DisplayInfo d)
    {
        var h = new WindowInteropHelper(w).Handle;
        if (h == IntPtr.Zero || !GetWindowRect(h, out var r)) return false;
        int cx = (r.Left + r.Right) / 2, cy = (r.Top + r.Bottom) / 2;
        return cx >= d.Left && cx < d.Left + d.Width && cy >= d.Top && cy < d.Top + d.Height;
    }

    static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }

    /// 終了するとき: 録画中なら、ファイルを閉じてから終える (詰め替えはせず、断片化した MP4 を録画の名前で残す。3 秒で打ち切る)
    public void Dispose()
    {
        elapsedTimer.Stop();
        ClosePanel();
        var rec = recorder;
        recorder = null;
        if (rec == null) return;
        var done = Task.Run(() =>
        {
            rec.Stop();
            if (rec.FrameCount == 0) TryDelete(rec.TempPath);
            else try { File.Move(rec.TempPath, finalPath); } catch { }
        });
        if (!done.Wait(TimeSpan.FromSeconds(3))) Log.Write("録画の後片付けが 3 秒で終わりませんでした");
        try { rec.Dispose(); } catch { }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetWindowRect(IntPtr hwnd, out RECT rect);

    /// 録画している画面の右上に出す、録画停止ボタンと経過時間の小さなパネル (録画に映さない。ドラッグで動かせる)
    sealed class StopPanel : OverlayWindow
    {
        readonly TextBlock elapsed = new() { Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 4, 0), Text = "0:00" };

        public StopPanel(RecordingController owner)
        {
            Title = "NoGreenBack Recording";
            ClickThrough = false;
            SizeToContent = SizeToContent.WidthAndHeight;
            var button = new Button
            {
                Content = Loc.L("■ 録画停止"),
                Padding = new Thickness(10, 3, 10, 3),
                Foreground = Brushes.White,
                Background = new SolidColorBrush(Color.FromRgb(220, 50, 47)),
                BorderThickness = new Thickness(0),
                Cursor = System.Windows.Input.Cursors.Hand,
            };
            button.Click += (_, _) => owner.Toggle();
            button.ToolTip = Loc.L("この画面を録画しています。押すと録画を止めます (%@R)", HotKeys.Prefix);
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(button);
            row.Children.Add(elapsed);
            var border = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(230, 30, 30, 30)),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(6),
                Child = row,
            };
            // 何もないところをドラッグして動かす
            border.MouseLeftButtonDown += (_, e) => { if (e.OriginalSource == border || e.OriginalSource == elapsed) DragMove(); };
            Content = border;
        }

        public void ShowAt(DisplayInfo d)
        {
            ShowNoActivate();
            UpdateLayout();
            double ppd = PixelsPerDip;
            int w = (int)Math.Ceiling(ActualWidth * ppd), h = (int)Math.Ceiling(ActualHeight * ppd);
            Place(d.Left + d.Width - w - (int)(16 * ppd), d.Top + (int)(12 * ppd), w, h);
        }

        public void SetElapsed(string text) => elapsed.Text = text;
    }
}
