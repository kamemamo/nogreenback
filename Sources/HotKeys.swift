// 全体で効くキーボードショートカット (他のアプリが前面でも反応する)
// Stream Deck の「ホットキー」アクションから送れば、ボタンひとつで操作できる。
// Carbon の RegisterEventHotKey を使うので、アクセシビリティの許可は不要

import Carbon

final class HotKeys {
    /// すべて ⌃⌥⌘ との組み合わせにする (他のアプリのショートカットと重なりにくい)
    static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    static let modifierSymbols = "⌃⌥⌘"

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, user in
            guard let event, let user else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let me = Unmanaged<HotKeys>.fromOpaque(user).takeUnretainedValue()
            DispatchQueue.main.async { me.actions[id.id]?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    deinit {
        refs.forEach { UnregisterEventHotKey($0) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// ⌃⌥⌘ + keyCode に動作を割り当てる。他のアプリが使っていて登録できなければ false
    @discardableResult
    func register(keyCode: Int, _ action: @escaping () -> Void) -> Bool {
        let id = UInt32(actions.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), Self.modifiers,
                                         EventHotKeyID(signature: OSType(0x4E47_4248), id: id), // 'NGBH'
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        actions[id] = action
        return true
    }
}
