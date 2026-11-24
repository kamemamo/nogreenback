// 実際に押したキーを知る (SPEC.md 8 章「押したキーを光らせる」。Mac 版の Sources/KeyPress.swift と同じ動き)
// キーボードの絵で押したキーを光らせ、「Ctrl + C」のような組み合わせを出すために使う。
// 低レベルのキーボードフック (WH_KEYBOARD_LL) で、ほかのアプリを使っている間のキーも見る。許可は要らない。
//
// Windows は、フックが返るまですべてのキー入力を待たせるので、フックの中では押したキーを書き留めるだけにして、
// すぐ次へ渡す (キーを止めたり書き換えたりはしない)。絵の描き直しは、返したあとに UI のスレッドで行う。

using System.Runtime.InteropServices;
using System.Windows.Threading;

namespace NoGreenBack.Overlays;

public sealed class KeyPressWatcher : IDisposable
{
    /// 押しているキーや出す文字が変わったとき (UI のスレッド)
    public event Action<KeyboardRenderer.Pressed>? Changed;
    /// 絵の配列が JIS か (キーの名前を決めるため)
    public Func<bool> IsJis { get; set; } = () => true;

    /// 離したあと光らせておく秒数と、すべて離してから文字を出しておく秒数
    public const double Linger = 1.0, TextLinger = 3.0;

    readonly Dispatcher dispatcher = Dispatcher.CurrentDispatcher;
    readonly DispatcherTimer timer;
    readonly LowLevelKeyboardProc proc;   // ガベージコレクションで消えないよう持っておく
    IntPtr hook;
    readonly HashSet<int> down = [];
    readonly Dictionary<int, DateTime> released = [];
    string? text;
    DateTime textTime;
    bool pending;
    KeyboardRenderer.Pressed last = KeyboardRenderer.Pressed.None;

    public KeyPressWatcher()
    {
        proc = HookProc;
        // 離したキーや文字を消すために、何かを出している間だけ見張る
        timer = new DispatcherTimer(TimeSpan.FromMilliseconds(100), DispatcherPriority.Background, (_, _) => Tick(), dispatcher);
    }

    public bool IsRunning => hook != IntPtr.Zero;

    /// 見始める (UI のスレッドから呼ぶ。フックはこのスレッドのメッセージループで受け取る)
    public void Start()
    {
        if (hook != IntPtr.Zero) return;
        hook = SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(null), 0);
        if (hook == IntPtr.Zero) Log.Write($"keys: SetWindowsHookEx failed ({Marshal.GetLastWin32Error()})");
    }

    public void Stop()
    {
        if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook);
        hook = IntPtr.Zero;
        down.Clear();
        released.Clear();
        text = null;
        Publish();
    }

    public void Dispose() { Stop(); timer.Stop(); }

    IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var k = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
            int msg = (int)wParam;
            bool isDown = msg is WM_KEYDOWN or WM_SYSKEYDOWN, isUp = msg is WM_KEYUP or WM_SYSKEYUP;
            if (isDown || isUp) Record(KeyboardRenderer.Code(k.vkCode, (k.flags & LLKHF_EXTENDED) != 0), isDown);
        }
        return CallNextHookEx(hook, nCode, wParam, lParam);
    }

    /// 押した・離したを書き留める (フックの中。重いことはしない)
    void Record(int code, bool isDown)
    {
        var now = DateTime.Now;
        if (isDown)
        {
            // 押しっぱなしで繰り返し来る分は、同じ表示のまま
            if (!down.Add(code)) return;
            released.Remove(code);
            if (KeyboardRenderer.IsModifier(code))
            {
                // ほかのキーを押していなければ、いま押している修飾キーを出す (「Ctrl」など)
                if (down.All(KeyboardRenderer.IsModifier)) { text = string.Join(" + ", ModifierNames()); textTime = now; }
            }
            else if (KeyboardRenderer.DisplayName(code, IsJis()) is { } name)
            {
                text = string.Join(" + ", ModifierNames().Append(name));
                textTime = now;
            }
        }
        else if (down.Remove(code)) released[code] = now;
        if (down.Count == 0) textTime = now;
        if (!pending)
        {
            pending = true;
            dispatcher.BeginInvoke(DispatcherPriority.Input, Publish);
        }
    }

    /// 押している修飾キーの名前 (Windows の説明書きと同じ Win・Ctrl・Alt・Shift の順)
    IEnumerable<string> ModifierNames()
    {
        if (down.Contains(VK_LWIN) || down.Contains(VK_RWIN)) yield return "Win";
        if (down.Contains(VK_LCONTROL) || down.Contains(VK_RCONTROL)) yield return "Ctrl";
        if (down.Contains(VK_LMENU) || down.Contains(VK_RMENU)) yield return "Alt";
        if (down.Contains(VK_LSHIFT) || down.Contains(VK_RSHIFT)) yield return "Shift";
    }

    void Tick()
    {
        // 離したことを受け取れなかったキー (Win + L で画面をロックしたときなど) を、押したままにしない
        foreach (int code in down.Where(c => (GetAsyncKeyState(c & 0xFF) & 0x8000) == 0).ToList())
        {
            down.Remove(code);
            released[code] = DateTime.Now;
        }
        Publish();
    }

    /// 今の状態を作って、変わっていれば知らせる
    void Publish()
    {
        pending = false;
        var now = DateTime.Now;
        foreach (int c in released.Where(kv => (now - kv.Value).TotalSeconds >= Linger).Select(kv => kv.Key).ToList())
            released.Remove(c);
        if (down.Count == 0 && (now - textTime).TotalSeconds >= TextLinger) text = null;
        var p = new KeyboardRenderer.Pressed(down.Union(released.Keys).ToHashSet(), text);
        if (p.Signature != last.Signature)
        {
            last = p;
            Changed?.Invoke(p);
        }
        bool busy = down.Count > 0 || released.Count > 0 || text != null;
        if (busy && !timer.IsEnabled) timer.Start();
        else if (!busy && timer.IsEnabled) timer.Stop();
    }

    const int WH_KEYBOARD_LL = 13;
    const int WM_KEYDOWN = 0x100, WM_KEYUP = 0x101, WM_SYSKEYDOWN = 0x104, WM_SYSKEYUP = 0x105;
    const uint LLKHF_EXTENDED = 0x01;
    const int VK_LWIN = 0x5B, VK_RWIN = 0x5C, VK_LSHIFT = 0xA0, VK_RSHIFT = 0xA1,
              VK_LCONTROL = 0xA2, VK_RCONTROL = 0xA3, VK_LMENU = 0xA4, VK_RMENU = 0xA5;

    [StructLayout(LayoutKind.Sequential)]
    struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public IntPtr dwExtraInfo; }

    delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll")]
    static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")]
    static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr GetModuleHandle(string? lpModuleName);
    [DllImport("user32.dll")]
    static extern short GetAsyncKeyState(int vKey);
}
