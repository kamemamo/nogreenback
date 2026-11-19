// 全画面出力とワイプのウィンドウ (SPEC.md 5 章)
// UI のスレッドで、設定と画面の一覧を見てウィンドウを開け閉めし、描く先を Pipeline に渡す。
//
// 全画面出力
// - 枠のないウィンドウで、出す画面全体 (タスクバーの上も) を覆う。最初から画面の大きさで作る
// - Esc (そのウィンドウがキー入力を受けているとき) か Ctrl+Alt+Shift+F で閉じる。開いたとき、このアプリが前面ならキー入力を受ける
// - 出していた画面が外れたら閉じる (残った画面に出し直すと、操作ウィンドウのある画面まで覆うため)。「出す画面」を変えたら作り直す
//
// ワイプ
// - 枠なし・背景透明・クリックは後ろへ通す・アクティブにならない・最前面のウィンドウ。1 秒ごとに最前面を取り直す
// - 大きさは 幅 = 画面の幅 × 大きさ、高さ = 幅 × 9 / 16。選んだ隅にぴったり付ける
// - 出す条件: ワイプ オン かつ 人物 オン かつ 全画面出力が同じ画面を覆っていない

using System.ComponentModel;
using System.Windows.Threading;

namespace NoGreenBack.Video;

public sealed class OutputWindows : IDisposable
{
    readonly AppModel model;
    readonly DispatcherTimer topmostTimer;

    SurfaceWindow? full;
    DisplayInfo? fullDisplay;
    SurfaceWindow? overlay;
    (int X, int Y, int W, int H) overlayRect;
    bool disposed;

    public OutputWindows(AppModel model)
    {
        this.model = model;
        model.State.PropertyChanged += OnChanged;
        model.Settings.PropertyChanged += OnChanged;
        model.Displays.Changed += OnDisplaysChanged;

        topmostTimer = new DispatcherTimer(TimeSpan.FromSeconds(1), DispatcherPriority.Background, (_, _) => overlay?.BringToTop(), Dispatcher.CurrentDispatcher);
        topmostTimer.Start();
        Update();
    }

    void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppState.FullScreen) or nameof(Settings.OverlayOn) or nameof(Settings.PersonOn)
            or nameof(Settings.OverlayScale) or nameof(Settings.OverlayCorner)
            or nameof(Settings.OverlayScreen) or nameof(Settings.OutputScreen))
            Update();
    }

    void OnDisplaysChanged(bool fewer)
    {
        // 出していた画面が外れたら、全画面出力を閉じる (FullScreen を外すと Update が呼ばれる)
        if (fullDisplay != null && model.Displays.Find(fullDisplay.Name) == null)
        {
            Log.Write($"全画面出力の画面が外れたので閉じます: {fullDisplay.Name}");
            CloseFull();
            model.State.FullScreen = false;
        }
        Update();
    }

    void Update()
    {
        if (disposed) return;
        UpdateFull();
        UpdateOverlay();
    }

    void UpdateFull()
    {
        var d = model.State.FullScreen ? model.Displays.OutputDisplay : null;
        if (d == fullDisplay) return;   // 同じ画面・同じ大きさならそのまま
        CloseFull();
        if (d == null) return;

        bool activate = SurfaceWindow.AppIsForeground();
        full = new SurfaceWindow("NoGreenBack", SurfaceWindow.WS_EX_TOPMOST | SurfaceWindow.WS_EX_TOOLWINDOW,
            d.Left, d.Top, d.Width, d.Height);
        full.KeyDown += key =>
        {
            if (key == 0x1B) model.State.FullScreen = false;   // Esc
        };
        fullDisplay = d;
        model.Video.SetFullScreenWindow(full.Hwnd, d.Width, d.Height);
        full.Show(activate);
        Log.Write($"全画面出力: {d.Name} {d.Width}x{d.Height}");
    }

    void CloseFull()
    {
        if (full == null) return;
        model.Video.SetFullScreenWindow(IntPtr.Zero, 0, 0);
        full.Dispose();
        full = null;
        fullDisplay = null;
    }

    void UpdateOverlay()
    {
        var s = model.Settings;
        var d = model.Displays.OverlayDisplay;
        bool show = s.OverlayOn && s.PersonOn && d != null && !(fullDisplay != null && fullDisplay.Name == d.Name);
        if (!show || d == null) { CloseOverlay(); return; }

        int w = Math.Max(2, (int)Math.Round(d.Width * s.OverlayScale));
        int h = Math.Max(2, (int)Math.Round(w * 9.0 / 16));
        bool right = s.OverlayCorner is 0 or 2, bottom = s.OverlayCorner is 0 or 1;
        var rect = (X: right ? d.Left + d.Width - w : d.Left, Y: bottom ? d.Top + d.Height - h : d.Top, W: w, H: h);

        if (overlay == null)
        {
            overlay = new SurfaceWindow("NoGreenBack Wipe",
                SurfaceWindow.WS_EX_LAYERED | SurfaceWindow.WS_EX_TRANSPARENT | SurfaceWindow.WS_EX_TOPMOST
                | SurfaceWindow.WS_EX_NOACTIVATE | SurfaceWindow.WS_EX_TOOLWINDOW | SurfaceWindow.WS_EX_NOREDIRECTIONBITMAP,
                rect.X, rect.Y, rect.W, rect.H);
            overlayRect = rect;
            model.Video.SetOverlayWindow(overlay.Hwnd, w, h);
            overlay.Show(activate: false);
            overlay.BringToTop();
        }
        else if (rect != overlayRect)
        {
            overlayRect = rect;
            overlay.Place(rect.X, rect.Y, rect.W, rect.H);
            model.Video.SetOverlayWindow(overlay.Hwnd, w, h);
        }
    }

    void CloseOverlay()
    {
        if (overlay == null) return;
        model.Video.SetOverlayWindow(IntPtr.Zero, 0, 0);
        overlay.Dispose();
        overlay = null;
    }

    /// 終了する前に、画面を覆うウィンドウを先に消す (SPEC.md 2 章)
    public void Dispose()
    {
        disposed = true;
        topmostTimer.Stop();
        CloseOverlay();
        CloseFull();
    }
}
