// 実際に押したキーを知る (キーボードの絵で光らせ、「⌘ command + C」のような組み合わせを出すため)
// ほかのアプリを使っている間のキーも見るので、「入力監視」の許可が要る。
// パスワードの欄に打っている間は、Mac がキーを渡さないので映らない

import AppKit
import Carbon

final class KeyPressWatcher {
    /// 押しているキーや出す文字が変わったとき (メインスレッド)
    var onChange: ((KeyboardRenderer.Pressed) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// 押しているキー (キーコード)
    private var down: Set<Int> = []
    /// 離したキーと、離した時刻 (少しの間光らせたままにして、見ている人が追いつけるように)
    private var released: [Int: CFAbsoluteTime] = [:]
    private var text: String?
    private var textTime: CFAbsoluteTime = 0
    private var timer: Timer?
    private var last = KeyboardRenderer.Pressed()

    /// 離したあと光らせておく秒数と、最後にキーを離してから文字を出しておく秒数
    static let linger = 1.0
    static let textLinger = 3.0

    var isRunning: Bool { tap != nil }
    /// 「入力監視」が許可されているか
    static var hasAccess: Bool { CGPreflightListenEventAccess() }
    /// 許可を求める (初回だけ Mac が許可を求める画面を出す)
    static func requestAccess() { _ = CGRequestListenEventAccess() }

    /// 見始める。許可がないなどで見られなければ false
    func start() -> Bool {
        if tap != nil { return true }
        guard Self.hasAccess else { return false }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, user in
                if let user { Unmanaged<KeyPressWatcher>.fromOpaque(user).takeUnretainedValue().handle(type, event) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        timer?.invalidate()
        timer = nil
        down = []
        released = [:]
        text = nil
        publish()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        // 時間がかかりすぎたときなどに Mac が止めるので、つけ直す
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let now = CFAbsoluteTimeGetCurrent()
        switch type {
        case .keyDown:
            // 押しっぱなしで繰り返し来る分は、同じ表示のまま
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
            down.insert(code)
            released[code] = nil
            if let name = KeyboardRenderer.displayName(for: code) {
                text = (Self.modifierNames(event.flags) + [name]).joined(separator: " + ")
                textTime = now
            }
        case .keyUp:
            if down.remove(code) != nil { released[code] = now }
        case .flagsChanged:
            if code == kVK_CapsLock {
                // caps lock は押すたびに切り替わる。押した瞬間だけ光らせる
                released[code] = now
                text = KeyboardRenderer.displayName(for: code)
                textTime = now
            } else if Self.isDown(code, event.flags) {
                down.insert(code)
                released[code] = nil
                // ほかのキーを押していなければ、いま押している修飾キーを出す (「⌘ command」など)
                if down.allSatisfy({ Self.modifierCodes.contains($0) }) {
                    text = Self.modifierNames(event.flags).joined(separator: " + ")
                    textTime = now
                }
            } else if down.remove(code) != nil {
                released[code] = now
            }
        default:
            return
        }
        if down.isEmpty { textTime = now }
        publish()
        // 離したキーを消したり、文字を消したりするために、しばらく見張る
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    private func tick() {
        publish()
        if down.isEmpty && released.isEmpty && text == nil {
            timer?.invalidate()
            timer = nil
        }
    }

    /// 今の状態を作って、変わっていれば知らせる
    private func publish() {
        let now = CFAbsoluteTimeGetCurrent()
        released = released.filter { now - $0.value < Self.linger }
        if down.isEmpty && now - textTime >= Self.textLinger { text = nil }
        let pressed = KeyboardRenderer.Pressed(codes: down.union(released.keys), text: text)
        guard pressed != last else { return }
        last = pressed
        onChange?(pressed)
    }

    // MARK: 修飾キー

    static let modifierCodes: Set<Int> = [kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift,
                                          kVK_Option, kVK_RightOption, kVK_Control, kVK_RightControl, kVK_Function]

    /// 修飾キー (左右それぞれ) が押されているか。左右を見分ける値は IOKit の NX_DEVICE…KEYMASK
    private static func isDown(_ code: Int, _ flags: CGEventFlags) -> Bool {
        let raw = flags.rawValue
        switch code {
        case kVK_Control: return raw & 0x0001 != 0
        case kVK_Shift: return raw & 0x0002 != 0
        case kVK_RightShift: return raw & 0x0004 != 0
        case kVK_Command: return raw & 0x0008 != 0
        case kVK_RightCommand: return raw & 0x0010 != 0
        case kVK_Option: return raw & 0x0020 != 0
        case kVK_RightOption: return raw & 0x0040 != 0
        case kVK_RightControl: return raw & 0x2000 != 0
        case kVK_Function: return flags.contains(.maskSecondaryFn)
        default: return false
        }
    }

    /// 押している修飾キーの名前 (Mac のメニューと同じ ⌃ ⌥ ⇧ ⌘ の順)。
    /// fn は矢印キーなどを押すと自動で付くので出さない
    static func modifierNames(_ flags: CGEventFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.maskControl) { names.append("⌃ control") }
        if flags.contains(.maskAlternate) { names.append("⌥ option") }
        if flags.contains(.maskShift) { names.append("⇧ shift") }
        if flags.contains(.maskCommand) { names.append("⌘ command") }
        return names
    }
}

extension KeyboardRenderer {
    /// 押しているキー (キーコード) と、キーボードの上に出す組み合わせの文字
    struct Pressed: Equatable {
        var codes: Set<Int> = []
        var text: String?
        /// 画像を作り直すかどうかを決めるための文字列
        var signature: String { codes.sorted().map(String.init).joined(separator: ",") + "|" + (text ?? "") }
    }

    /// JIS 配列の return (L 字なので、キーの並びとは別に描く)
    static let jisReturn = -1

    /// キーコード (kVK_…) が、絵のどのキーか。名前と、テンキーか、右側のキーか
    private static func spot(for code: Int) -> (label: String, numpad: Bool, right: Bool)? {
        let jis = layout == .jis
        let main: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
            kVK_ANSI_Semicolon: ";",
            // 同じ場所でも、JIS と US で書いてある文字が違うキー
            kVK_ANSI_Equal: jis ? "^" : "=", kVK_ANSI_LeftBracket: jis ? "@" : "[",
            kVK_ANSI_RightBracket: jis ? "[" : "]", kVK_ANSI_Backslash: jis ? "]" : "\\",
            kVK_ANSI_Quote: jis ? ":" : "'", kVK_ANSI_Grave: "`",
            kVK_JIS_Yen: "¥", kVK_JIS_Underscore: "_", kVK_JIS_Eisu: "英数", kVK_JIS_Kana: "かな",
            kVK_Return: "return", kVK_Tab: "tab", kVK_Space: "space", kVK_Delete: "delete", kVK_Escape: "esc",
            kVK_CapsLock: "caps", kVK_Function: "fn",
            kVK_Command: "command", kVK_Shift: "shift", kVK_Option: "option", kVK_Control: "control",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
        let right: [Int: String] = [kVK_RightCommand: "command", kVK_RightShift: "shift",
                                    kVK_RightOption: "option", kVK_RightControl: "control"]
        let numpad: [Int: String] = [
            kVK_ANSI_Keypad0: "0", kVK_ANSI_Keypad1: "1", kVK_ANSI_Keypad2: "2", kVK_ANSI_Keypad3: "3",
            kVK_ANSI_Keypad4: "4", kVK_ANSI_Keypad5: "5", kVK_ANSI_Keypad6: "6", kVK_ANSI_Keypad7: "7",
            kVK_ANSI_Keypad8: "8", kVK_ANSI_Keypad9: "9", kVK_ANSI_KeypadClear: "clear",
            kVK_ANSI_KeypadDivide: "/", kVK_ANSI_KeypadMultiply: "*", kVK_ANSI_KeypadMinus: "-",
            kVK_ANSI_KeypadPlus: "+", kVK_ANSI_KeypadEnter: "enter", kVK_ANSI_KeypadDecimal: ".",
        ]
        if let s = main[code] { return (s, false, false) }
        if let s = right[code] { return (s, false, true) }
        if let s = numpad[code] { return (s, true, false) }
        return nil
    }

    /// キーコードが、いまの配列の絵の何番目のキーか (絵にないキーは nil。JIS の return は jisReturn)
    static func index(of code: Int) -> Int? {
        guard let s = spot(for: code) else { return nil }
        if s.label == "return" && layout == .jis { return jisReturn }
        let ks = keys
        let found = ks.indices.filter { i in
            let k = ks[i]
            if s.label == "space" { return k.mac.isEmpty && k.w > 3 }
            return k.mac == s.label && (k.x >= mainWidth) == s.numpad
        }
        return s.right ? found.last : found.first
    }

    /// 組み合わせの文字に出すキーの名前 (「C」「↩ return」など。出さないキーは nil)
    static func displayName(for code: Int) -> String? {
        let extra: [Int: String] = [
            kVK_ForwardDelete: "⌦ delete", kVK_Home: "home", kVK_End: "end",
            kVK_PageUp: "page up", kVK_PageDown: "page down", kVK_Help: "help",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
            kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
            kVK_ANSI_KeypadEquals: "=", kVK_JIS_KeypadComma: ",",
        ]
        if let name = extra[code] { return name }
        guard let s = spot(for: code) else { return nil }
        switch s.label {
        case "return": return "↩ return"
        case "enter": return "⌅ enter"
        case "fn": return nil
        default: return symbols[s.label].map { "\($0) \(s.label)" } ?? s.label
        }
    }
}
