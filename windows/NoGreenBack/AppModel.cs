// 設定と状態をまとめ、ボタンどうしの決まり (SPEC.md 5・8 章) を守らせる

namespace NoGreenBack;

public sealed class AppModel
{
    public Settings Settings { get; }
    public AppState State { get; } = new();

    /// 映像の処理 (カメラ・合成・表示)
    public Video.Pipeline Video { get; }

    public AppModel(Settings settings)
    {
        Settings = settings;
        Video = new Video.Pipeline(this);

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
