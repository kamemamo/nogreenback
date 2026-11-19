// 設定と状態をまとめ、ボタンどうしの決まり (SPEC.md 5・8 章) を守らせる

namespace NoGreenBack;

public sealed class AppModel
{
    public Settings Settings { get; }
    public AppState State { get; } = new();

    /// 画面の一覧
    public Displays Displays { get; }

    /// 映像の処理 (カメラ・合成・表示)
    public Video.Pipeline Video { get; }

    /// 全画面出力とワイプのウィンドウ
    public Video.OutputWindows Outputs { get; }

    /// 手書き・ホワイトボード・キーボード・指し棒
    public Overlays.OverlayController Overlays { get; }

    /// マイク (録画と、メーター)
    public Audio.MicInput Mic { get; }

    /// 外部の音声 (スピーカーに出し、録画ではマイクと混ぜる)
    public Audio.ExternalAudio External { get; }

    /// ATEM スイッチャー
    public Atem.AtemController Atem { get; }

    /// 画面録画
    public Recording.RecordingController Recording { get; }

    /// 字幕
    public Speech.SubtitleController Subtitles { get; }

    public AppModel(Settings settings)
    {
        Settings = settings;
        Displays = new Displays(settings);
        Video = new Video.Pipeline(this);
        Outputs = new Video.OutputWindows(this);
        Overlays = new Overlays.OverlayController(this);
        Mic = new Audio.MicInput(settings);
        External = new Audio.ExternalAudio(settings);
        Atem = new Atem.AtemController(settings);
        Recording = new Recording.RecordingController(this);
        Subtitles = new Speech.SubtitleController(this);

        // 画面の数が減ったら、ペン固定を外す (SPEC.md 5 章)
        Displays.Changed += fewer => { if (fewer) State.PenLock = false; };

        State.PropertyChanged += (_, e) =>
        {
            switch (e.PropertyName)
            {
                // ペン固定・ホワイトボードをオンにしたとき、手書きがオフなら手書きもオンにする
                case nameof(AppState.PenLock) when State.PenLock:
                case nameof(AppState.WhiteboardOn) when State.WhiteboardOn:
                    Settings.AnnotationOn = true;
                    break;
                // 全画面を外したら、ペン固定も外す (操作ウィンドウのある画面まで手書きがクリックを受け止めないように)
                case nameof(AppState.FullScreen) when !State.FullScreen:
                    State.PenLock = false;
                    break;
            }
        };
        Settings.PropertyChanged += (_, e) =>
        {
            // 手書きをオフにしたら、ペン固定とホワイトボードもオフにする
            if (e.PropertyName == nameof(Settings.AnnotationOn) && !Settings.AnnotationOn)
            {
                State.PenLock = false;
                State.WhiteboardOn = false;
            }
        };
    }

    /// ⌃⌥⌘ K と同じ: ペンの色を次の色へ
    public void NextPenColor() => Settings.PenColor = (Settings.PenColor + 1) % 6;

    /// 手書きを全部消す (手書きのウィンドウを作ったらつなぐ)
    public event Action? ClearDrawingRequested;
    public void ClearDrawing() => ClearDrawingRequested?.Invoke();
}
