// 字幕 (SPEC.md 10 章) をまとめて動かす。UI のスレッドで動く
// - 「字幕」(と Ctrl+Alt+Shift+S) でオン・オフ。初めてオンにしたときにモデルを取ってくる (確かめてから)
// - 画面に出す文字は、確定した文をつないだもの (最後の 200 文字) に、話している途中の文字を足したもの。4 秒以上話さなかったら前の文は消す
// - 置き換えは、画面の字幕・字幕トラック・字幕ファイルのすべてに当てる
// - 映像の中 (合成・全画面出力・背景があれば Spout)、背景がないときの Spout の下の中央、「表示する画面」の下のウィンドウに出す。4 秒話さないと消す
// - 録画中に確定した文は、話し始めた時刻と確定した時刻と一緒に残す (字幕ファイルと字幕トラックにする)

using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using NoGreenBack.Overlays;
using NoGreenBack.Video;

namespace NoGreenBack.Speech;

public sealed class SubtitleController : Observable, IDisposable
{
    readonly AppModel model;
    readonly Dispatcher dispatcher;
    readonly DispatcherTimer clearTimer;
    readonly OverlayWindow window = new() { Title = "NoGreenBack Subtitle" };
    readonly Image windowImage = new() { Stretch = Stretch.Fill };
    SpeechRecognizer? recognizer;
    CancellationTokenSource? download;

    List<(string From, string To)> replacements = [];
    string committed = "";        // 確定した文をつないだもの (最後の 200 文字)
    string partial = "";          // 話している途中の文字
    DateTime lastResult = DateTime.MinValue;
    string shown = "";            // いま出している文字 (置き換えた後)
    string renderKey = "", windowKey = "";
    readonly List<(string Text, long Start, long End)> recorded = [];

    string message = "";
    /// 操作ウィンドウに出すお知らせ (モデルのダウンロード中など。空なら出さない)
    public string Message { get => message; private set => Set(ref message, value); }

    /// 字幕のウィンドウ (録画や背景の画面の取り込みから外すため)。
    /// 隠れている間も同じウィンドウを返す (録画を止めたときに隠れていても、取り込みから外す指定を戻せるように)
    public IntPtr WindowHwnd => window.Hwnd;

    public SubtitleController(AppModel model)
    {
        this.model = model;
        dispatcher = Dispatcher.CurrentDispatcher;
        window.Content = windowImage;
        clearTimer = new DispatcherTimer(TimeSpan.FromSeconds(4), DispatcherPriority.Background, (_, _) =>
        {
            // 4 秒話さないと消す
            clearTimer!.Stop();
            committed = ""; partial = "";
            Show("");
        }, dispatcher);
        clearTimer.Stop();

        replacements = SubtitleText.Replacements(model.Settings.SubtitleTerms);
        model.State.PropertyChanged += OnChanged;
        model.Settings.PropertyChanged += OnChanged;
        model.Video.CanvasChanged += _ => Render();
        model.Outputs.Changed += Render;
        model.Displays.Changed += _ => Render();
    }

    void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppState.SubtitlesOn):
                if (model.State.SubtitlesOn) _ = StartAsync(); else Stop();
                break;
            case nameof(AppState.Recording):
                if (model.State.Recording) recorded.Clear();
                break;
            case nameof(Settings.SubtitleTerms) or nameof(Settings.SubtitleLanguage):
                replacements = SubtitleText.Replacements(model.Settings.SubtitleTerms);
                recognizer?.Configure(Language, Prompt);
                break;
            case nameof(Settings.PersonOn) or nameof(Settings.KeyboardOn) or nameof(Settings.KeyboardSize) or nameof(Settings.KeyboardPlace)
                or nameof(AppState.KeyTextShown) or nameof(Settings.OverlayOn) or nameof(Settings.OverlayCorner) or nameof(Settings.OverlayScale) or nameof(Settings.OverlayScreen):
                Render();
                break;
        }
    }

    /// Whisper に渡す言語 (ja / en)
    string Language => model.Settings.EffectiveSubtitleLanguage.StartsWith("en") ? "en" : "ja";

    /// 認識のヒント (置き換え後の正しい表記)
    string Prompt => string.Join(Language == "ja" ? "、" : ", ", SubtitleText.HintTerms(model.Settings.SubtitleTerms));

    async Task StartAsync()
    {
        if (recognizer != null || download != null) return;
        if (!model.Mic.Enabled)
        {
            MessageBox.Show(Loc.L("字幕に使うマイクがありません"), "NoGreenBack", MessageBoxButton.OK, MessageBoxImage.Information);
            model.State.SubtitlesOn = false;
            return;
        }
        var m = WhisperModels.ForThisPC;
        if (!m.IsDownloaded)
        {
            // モデルは同梱しないので、初めてオンにしたときに取ってくる (確かめてから)
            var answer = MessageBox.Show(
                Loc.L("字幕の認識に使うモデル「%@」(約 %d MB) を Hugging Face からダウンロードします。認識はこの PC の中だけで行い、音声はネットに送りません。", m.Name, (int)Math.Round(m.Megabytes)),
                "NoGreenBack", MessageBoxButton.OKCancel, MessageBoxImage.Information);
            if (answer != MessageBoxResult.OK) { model.State.SubtitlesOn = false; return; }
            download = new CancellationTokenSource();
            try
            {
                var progress = new Progress<double>(p => Message = Loc.L("字幕のモデルをダウンロードしています… %d%%", (int)(p * 100)));
                Message = Loc.L("字幕のモデルをダウンロードしています… %d%%", 0);
                await WhisperModels.DownloadAsync(m, progress, download.Token);
                Log.Write($"字幕: {m.File} を取ってきました");
            }
            catch (Exception e)
            {
                bool canceled = download.IsCancellationRequested;
                download = null;
                Message = "";
                if (!canceled)
                {
                    Log.Write($"字幕のモデルをダウンロードできません: {e.Message}");
                    MessageBox.Show(Loc.L("字幕のモデルをダウンロードできません: %@", e.Message), "NoGreenBack", MessageBoxButton.OK, MessageBoxImage.Warning);
                }
                model.State.SubtitlesOn = false;
                return;
            }
            download = null;
            if (!model.State.SubtitlesOn) { Message = ""; return; }   // 取ってくる間にオフにした
        }

        Message = Loc.L("字幕のモデルを読み込んでいます…");
        var r = new SpeechRecognizer(m, Language, Prompt);
        r.Status += s => dispatcher.BeginInvoke(() =>
        {
            Message = s;
            if (s.Length > 0) model.State.SubtitlesOn = false;
        });
        r.Partial += text => dispatcher.BeginInvoke(() => Received(text, isFinal: false, 0, 0));
        r.Final += (text, start, end) => dispatcher.BeginInvoke(() => Received(text, isFinal: true, start, end));
        model.Mic.SamplesArrived += r.Feed;
        recognizer = r;
    }

    void Stop()
    {
        download?.Cancel();
        var r = recognizer;
        recognizer = null;
        if (r != null)
        {
            model.Mic.SamplesArrived -= r.Feed;
            Task.Run(r.Dispose);
        }
        Message = "";
        committed = ""; partial = "";
        clearTimer.Stop();
        Show("");
    }

    /// 認識した文字を、画面に出す文字にまとめる
    void Received(string text, bool isFinal, long start, long end)
    {
        if (recognizer == null) return;
        // しばらく話していなかったら、前の文は消して新しく始める
        if ((DateTime.Now - lastResult).TotalSeconds > 4) committed = "";
        if (text.Length > 0) lastResult = DateTime.Now;
        string sep = Language == "en" && committed.Length > 0 ? " " : "";
        if (isFinal)
        {
            string c = committed + sep + text;
            committed = c.Length > 200 ? c[^200..] : c;
            partial = "";
            if (model.State.Recording)
            {
                // 話し始めの時刻がわからないときは、確定の 2 秒前
                long s = start > 0 ? start : end - 2 * Stopwatch.Frequency;
                recorded.Add((SubtitleText.Apply(text, replacements), s, end));
            }
        }
        else partial = text.Length > 0 ? sep + text : "";
        Show(SubtitleText.Apply(committed + partial, replacements));
        if (text.Length > 0) { clearTimer.Stop(); clearTimer.Start(); }
    }

    void Show(string text)
    {
        if (text == shown) return;
        shown = text;
        Render();
    }

    /// 字幕を、映像 (合成・Spout) とデスクトップの両方に出す
    void Render()
    {
        var s = model.Settings;
        var lines = SubtitleText.ShownLines(shown);
        var canvas = model.Video.Canvas;

        // 映像の中: 人物を出しているときは人物の反対側のすき間の真ん中、キーボードが下半分にあればその上
        bool keyText = model.State.KeyTextShown;
        string key = $"{string.Join("|", lines)} {canvas} {s.PersonOn} {s.KeyboardOn} {s.KeyboardSize} {s.KeyboardPlace} {keyText}";
        if (key != renderKey)
        {
            renderKey = key;
            if (lines.Count == 0 || canvas == null)
            {
                model.Video.SetLayer(LayerKind.Subtitle, null);
                model.Video.SetLayer(LayerKind.SpoutSubtitle, null);
            }
            else
            {
                var area = new Rect(0, 0, canvas.Width, canvas.Height);
                (double, double)? person = s.PersonOn ? (canvas.PersonX, canvas.PersonX + canvas.PersonWidth) : null;
                double? kbTop = null;
                if (s.KeyboardOn && KeyboardRenderer.PixelSize(canvas.Width * s.KeyboardSize, keyText) is { } kb)
                {
                    var f = KeyboardRenderer.Frame(kb, area, s.KeyboardPlace, canvas.PersonX, canvas.PersonX + canvas.PersonWidth);
                    if (f.Top + f.Height / 2 > canvas.Height / 2.0) kbTop = f.Top;
                }
                model.Video.SetLayer(LayerKind.Subtitle, Layer(lines, area, person, kbTop, canvas.Width, canvas.Height));

                // 背景がないときの Spout は人物だけの映像 (カメラの大きさ) なので、下の中央に出す
                var camArea = new Rect(0, 0, canvas.CameraWidth, canvas.CameraHeight);
                model.Video.SetLayer(LayerKind.SpoutSubtitle, Layer(lines, camArea, null, null, canvas.CameraWidth, canvas.CameraHeight));
            }
        }
        RenderWindow(lines);
    }

    static LayerImage? Layer(List<string> lines, Rect area, (double, double)? person, double? keyboardTop, int canvasW, int canvasH)
    {
        double margin = area.Height * 0.03;
        var bmp = SubtitleRenderer.Render(lines, area.Height * 0.05, area.Width - margin * 2, rounded: false);
        if (bmp == null) return null;
        var p = SubtitleRenderer.Position(new Size(bmp.PixelWidth, bmp.PixelHeight), area, person, keyboardTop);
        var px = new byte[bmp.PixelWidth * bmp.PixelHeight * 4];
        bmp.CopyPixels(px, bmp.PixelWidth * 4, 0);
        return new LayerImage(px, bmp.PixelWidth, bmp.PixelHeight, (int)p.X, (int)p.Y, canvasW, canvasH);
    }

    /// デスクトップの字幕: 「表示する画面」の下。全画面出力がその画面を覆っているときは出さない (録画には映さない)
    void RenderWindow(List<string> lines)
    {
        var s = model.Settings;
        var d = model.Displays.OverlayDisplay;
        bool covered = d != null && model.Outputs.FullDisplay?.Name == d.Name;
        if (lines.Count == 0 || d == null || covered)
        {
            windowKey = "";
            if (window.IsVisible) window.Hide();
            return;
        }
        string key = $"{string.Join("|", lines)} {d} {s.OverlayOn} {s.PersonOn} {s.OverlayCorner} {s.OverlayScale} {s.KeyboardOn} {s.KeyboardSize} {s.KeyboardPlace} {model.State.KeyTextShown}";
        if (key == windowKey && window.IsVisible) return;
        windowKey = key;

        var area = new Rect(d.Left, d.Top, d.Width, d.Height);
        bool right = s.OverlayCorner is 0 or 2;
        double pw = d.Width * s.OverlayScale, pl = right ? d.Left + d.Width - pw : d.Left;
        // 画面に人物 (ワイプ) を出しているときは、人物の反対側に出す
        (double, double)? person = s.OverlayOn && s.PersonOn ? (pl, pl + pw) : null;
        double? kbTop = null;
        if (s.KeyboardOn && KeyboardRenderer.PixelSize(d.Width * s.KeyboardSize, model.State.KeyTextShown) is { } kb)
        {
            var f = KeyboardRenderer.Frame(kb, area, s.KeyboardPlace, pl, pl + pw);
            if (f.Top + f.Height / 2 > d.Top + d.Height / 2.0) kbTop = f.Top;
        }
        var bmp = SubtitleRenderer.Render(lines, Math.Round(d.Height * 0.04), d.Width * 0.9, rounded: true);
        if (bmp == null) { window.Hide(); return; }
        var p = SubtitleRenderer.Position(new Size(bmp.PixelWidth, bmp.PixelHeight), area, person, kbTop);
        windowImage.Source = bmp;
        window.Place((int)p.X, (int)p.Y, bmp.PixelWidth, bmp.PixelHeight);
        bool first = !window.IsVisible;
        window.ShowNoActivate();
        if (first) model.Overlays.UpdateCaptureExclusion();   // 録画と背景の画面の取り込みから外す
    }

    /// 録画中に確定した文 (録画の最初のコマを 0 とした秒)。recordingStartTicks は最初のコマが届いた時刻 (Stopwatch)
    public List<SubtitleCue> RecordedCues(long recordingStartTicks)
    {
        double Sec(long ticks) => (ticks - recordingStartTicks) / (double)Stopwatch.Frequency;
        return [.. recorded.Select(r => new SubtitleCue(Math.Max(0, Sec(r.Start)), Math.Max(0, Sec(r.End)), r.Text))
                           .Where(c => c.End > 0)];
    }

    /// 字幕トラックの言語 (ISO 639-2)
    public string TrackLanguage => Language == "en" ? "eng" : "jpn";

    public void Dispose()
    {
        Stop();
        window.Close();
    }
}
