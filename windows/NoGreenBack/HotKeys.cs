// ほかのアプリが前面にあっても効くショートカット (SPEC.md 14 章)
// Windows では Ctrl+Alt+Shift＋キー (SPEC.md 17 章)。RegisterHotKey で登録し、操作ウィンドウのメッセージで受け取る。

using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace NoGreenBack;

public sealed partial class HotKeys : IDisposable
{
    public const string Prefix = "Ctrl+Alt+Shift+";

    public sealed record Entry(char Key, string Description, Action Action)
    {
        /// ほかのアプリが同じ組み合わせを使っていて登録できなかった
        public bool Unavailable { get; set; }
        public string KeyText => Prefix + Key;
    }

    public IReadOnlyList<Entry> Entries { get; }

    const int WM_HOTKEY = 0x0312;
    const uint MOD_ALT = 0x1, MOD_CONTROL = 0x2, MOD_SHIFT = 0x4, MOD_NOREPEAT = 0x4000;
    const int BaseId = 0x4E47; // 'NG'

    readonly HwndSource source;

    public HotKeys(HwndSource source, AppModel model)
    {
        this.source = source;
        var s = model.Settings;
        var st = model.State;
        Entries =
        [
            new('R', "録画の開始・停止", model.Recording.Toggle),
            new('P', "人物の表示・非表示", () => s.PersonOn = !s.PersonOn),
            new('C', "手書きを全部消す", model.ClearDrawing),
            new('D', "ペン (描画モード) のオン・オフ", () => st.PenLock = !st.PenLock),
            new('K', "ペンの色を次の色へ", model.NextPenColor),
            new('F', "全画面出力の表示・非表示", () => st.FullScreen = !st.FullScreen),
            new('S', "字幕のオン・オフ", () => st.SubtitlesOn = !st.SubtitlesOn),
            new('B', "キーボードの表示・非表示", () => s.KeyboardOn = !s.KeyboardOn),
            new('L', "指し棒のオン・オフ", () => st.PointerOn = !st.PointerOn),
            new('W', "ホワイトボードの表示・非表示", () => st.WhiteboardOn = !st.WhiteboardOn),
        ];

        for (int i = 0; i < Entries.Count; i++)
        {
            var e = Entries[i];
            e.Unavailable = !RegisterHotKey(source.Handle, BaseId + i, MOD_CONTROL | MOD_ALT | MOD_SHIFT | MOD_NOREPEAT, e.Key);
        }
        source.AddHook(Hook);
    }

    IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_HOTKEY)
        {
            int i = wParam.ToInt32() - BaseId;
            if (i >= 0 && i < Entries.Count) { Entries[i].Action(); handled = true; }
        }
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        source.RemoveHook(Hook);
        for (int i = 0; i < Entries.Count; i++)
            if (!Entries[i].Unavailable) UnregisterHotKey(source.Handle, BaseId + i);
    }

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool UnregisterHotKey(IntPtr hWnd, int id);
}
