// ほかのアプリが前面にあっても効くショートカット (SPEC.md 14 章)
// Windows では修飾キー＋キー。修飾キーは Ctrl+Alt+Shift (既定) か Ctrl+Alt+Win から選ぶ (SPEC.md 17 章)。
// RegisterHotKey で登録し、操作ウィンドウのメッセージで受け取る。修飾キーを替えたら登録し直す。

using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace NoGreenBack;

public sealed partial class HotKeys : IDisposable
{
    /// 選べる修飾キー (Settings.HotKeyModifiers の番号の順)
    public static readonly (string Text, uint Mods)[] ModifierChoices =
    [
        ("Ctrl+Alt+Shift", MOD_CONTROL | MOD_ALT | MOD_SHIFT),
        ("Ctrl+Alt+Win", MOD_CONTROL | MOD_ALT | MOD_WIN),
    ];

    /// いまの修飾キーの表示 (末尾に + を付けたもの。例: Ctrl+Alt+Shift+)。画面の文字はこれに追従する
    public static string Prefix => PrefixSource.Instance.Prefix;

    public sealed record Entry(char Key, string Description, Action Action)
    {
        /// ほかのアプリが同じ組み合わせを使っていて登録できなかった
        public bool Unavailable { get; set; }
        public string KeyText => Prefix + Key;
    }

    public IReadOnlyList<Entry> Entries { get; }

    const int WM_HOTKEY = 0x0312;
    const uint MOD_ALT = 0x1, MOD_CONTROL = 0x2, MOD_SHIFT = 0x4, MOD_WIN = 0x8, MOD_NOREPEAT = 0x4000;
    const int BaseId = 0x4E47; // 'NG'

    readonly HwndSource source;
    bool registered;

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
        source.AddHook(Hook);
        Register(s.HotKeyModifiers);
    }

    /// 修飾キー (ModifierChoices の番号) で登録し直す。登録できなかったものは Unavailable になる
    public void Register(int modifiers)
    {
        Unregister();
        var (text, mods) = ModifierChoices[Math.Clamp(modifiers, 0, ModifierChoices.Length - 1)];
        PrefixSource.Instance.Prefix = text + "+";
        for (int i = 0; i < Entries.Count; i++)
        {
            var e = Entries[i];
            e.Unavailable = !RegisterHotKey(source.Handle, BaseId + i, mods | MOD_NOREPEAT, e.Key);
        }
        registered = true;
        var failed = Entries.Where(e => e.Unavailable).Select(e => e.Key);
        Log.Write($"ショートカット: {text}+キー" + (failed.Any() ? $" (登録できない: {string.Join(" ", failed)})" : ""));
    }

    void Unregister()
    {
        if (!registered) return;
        for (int i = 0; i < Entries.Count; i++)
            if (!Entries[i].Unavailable) UnregisterHotKey(source.Handle, BaseId + i);
        registered = false;
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
        Unregister();
    }

    /// 画面の文字 (ツールチップなど) が、修飾キーを替えたときに追従するための元
    public sealed class PrefixSource : INotifyPropertyChanged
    {
        public static PrefixSource Instance { get; } = new();
        string prefix = ModifierChoices[0].Text + "+";
        public string Prefix
        {
            get => prefix;
            set { if (prefix != value) { prefix = value; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Prefix))); } }
        }
        public event PropertyChangedEventHandler? PropertyChanged;
    }

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool UnregisterHotKey(IntPtr hWnd, int id);
}
