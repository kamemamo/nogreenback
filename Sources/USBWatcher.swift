// ATEM スイッチャーが USB でつながったか・外れたかを見張る
// Blackmagic Design の USB 機器 (メーカー番号 0x1EDB) のうち、名前に「ATEM」が入っているものだけを数える
// (同じメーカーのキャプチャー機器などには反応しない)

import Foundation
import IOKit
import IOKit.usb

final class ATEMUSBWatcher {
    /// つながっている ATEM の数が 0 ↔ 1 以上に変わったときの知らせ (メインスレッド)
    var onChange: ((Bool) -> Void)?
    private(set) var isPresent = false

    private var port: IONotificationPortRef?
    private var addedIter: io_iterator_t = 0
    private var removedIter: io_iterator_t = 0

    static let blackmagicVendorID = 0x1EDB

    func start() {
        guard port == nil, let p = IONotificationPortCreate(kIOMainPortDefault) else { return }
        port = p
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(p).takeUnretainedValue(), .defaultMode)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<ATEMUSBWatcher>.fromOpaque(refcon).takeUnretainedValue()
            // 知らせを受け取り続けるには、届いた機器を読み切る必要がある
            var obj = IOIteratorNext(iterator)
            while obj != 0 { IOObjectRelease(obj); obj = IOIteratorNext(iterator) }
            // 外したときは一覧からすぐには消えないことがあるので、少し待ってから数え直す
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { watcher.refresh() }
        }
        for (type, iter) in [(kIOFirstMatchNotification, \ATEMUSBWatcher.addedIter),
                             (kIOTerminatedNotification, \ATEMUSBWatcher.removedIter)] {
            let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
            matching["idVendor"] = Self.blackmagicVendorID
            var it: io_iterator_t = 0
            IOServiceAddMatchingNotification(p, type, matching, callback, me, &it)
            self[keyPath: iter] = it
            // 最初の一覧を読み切ると、以後の知らせが届くようになる
            var obj = IOIteratorNext(it)
            while obj != 0 { IOObjectRelease(obj); obj = IOIteratorNext(it) }
        }
        refresh()
    }

    /// いまつながっている Blackmagic の USB 機器から、ATEM を探す
    private func refresh() {
        let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        matching["idVendor"] = Self.blackmagicVendorID
        var it: io_iterator_t = 0
        var found = false
        if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it) == KERN_SUCCESS {
            var obj = IOIteratorNext(it)
            while obj != 0 {
                let name = IORegistryEntryCreateCFProperty(obj, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String ?? ""
                // 名前が読めないときも ATEM とみなす (読めないと項目が出ず、つなげなくなるため)
                if name.isEmpty || name.localizedCaseInsensitiveContains("ATEM") { found = true }
                IOObjectRelease(obj)
                obj = IOIteratorNext(it)
            }
            IOObjectRelease(it)
        }
        guard found != isPresent else { return }
        isPresent = found
        onChange?(found)
    }
}
