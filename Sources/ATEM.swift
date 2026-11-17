// ATEM スイッチャー (Blackmagic Design) の入力を切り替える
// ・ATEM のソフト (Blackmagic ATEM Switchers) が入っていれば、その SDK で USB でも LAN でもつなぐ
// ・入っていなければ、ATEM Software Control と同じネットワークの通信 (UDP 9910) を自前で行う (LAN のみ)

import Foundation
import Network

final class ATEMControl: @unchecked Sendable {
    enum State { case disconnected, connecting, connected }
    struct Input { let id: Int; let name: String }

    /// SDK を使えるか (使えなければ LAN だけ)
    static let sdkAvailable = atem_sdk_available() != 0

    // 呼ばれるのはメインスレッド。detail は「USB」や機種名など、表示に添える言葉
    var onState: ((State, String?) -> Void)?
    var onProgram: ((Int) -> Void)?
    var onPreview: ((Int) -> Void)?
    var onInputs: (([Input]) -> Void)?

    private let queue = DispatchQueue(label: "atem")
    private var conn: NWConnection?
    private var host: String?
    private var timer: DispatchSourceTimer?

    // 通信の状態 (すべて queue の上で触る)
    private var sessionID: UInt16 = 0
    private var localPacketID: UInt16 = 0
    private var lastRemoteID: UInt16 = 0
    private var established = false
    private var initDone = false
    private var framesPerSecond: Double = 30
    private var lastReceived = Date.distantPast
    private var helloSent = Date.distantPast
    private var pending: [UInt16: (packet: Data, sent: Date, tries: Int)] = [:]
    private var inputs: [Int: String] = [:]
    // SDK でつないでいるとき
    private var sdk: OpaquePointer?
    private var sdkRetryAt = Date.distantPast
    private var sdkProgram = -1

    // MARK: 接続

    func connect(_ host: String) {
        queue.async {
            self.host = host
            if Self.sdkAvailable {
                self.closeSDK()
                self.sdkRetryAt = .distantPast
            } else {
                self.openConnection()
            }
            if self.timer == nil {
                let t = DispatchSource.makeTimerSource(queue: self.queue)
                t.schedule(deadline: .now() + 0.2, repeating: 0.2)
                t.setEventHandler { self.tick() }   // アプリが終わるまで使うので強く持ってよい
                t.resume()
                self.timer = t
            }
        }
    }

    func disconnect() {
        queue.async {
            self.host = nil
            self.timer?.cancel(); self.timer = nil
            self.conn?.cancel(); self.conn = nil
            self.closeSDK()
            self.reset()
            self.notify { $0.onState?(.disconnected, nil) }
        }
    }

    private func reset() {
        established = false
        initDone = false
        pending.removeAll()
        localPacketID = 0
        inputs.removeAll()
    }

    private func openConnection() {
        conn?.cancel()
        reset()
        guard let host, !host.isEmpty else { return }
        let c = NWConnection(host: NWEndpoint.Host(host), port: 9910, using: .udp)
        conn = c
        c.start(queue: queue)
        receive(on: c)
        sendHello()
        notify { $0.onState?(.connecting, nil) }
    }

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self, c === self.conn else { return }
            if let data { self.handle(data) }
            if error == nil { self.receive(on: c) }
        }
    }

    /// 0.2 秒ごと: つながるまで呼びかけ直す、返事のない命令を送り直す、途切れたらつなぎ直す
    private func tick() {
        guard host != nil else { return }
        if Self.sdkAvailable { tickSDK(); return }
        let now = Date()
        if !established {
            if now.timeIntervalSince(helloSent) > 2 { openConnection() }
            return
        }
        if now.timeIntervalSince(lastReceived) > 5 {
            NSLog("ATEM: timeout, reconnecting")
            notify { $0.onState?(.connecting, nil) }
            openConnection()
            return
        }
        for (id, p) in pending where now.timeIntervalSince(p.sent) > 0.2 {
            if p.tries >= 5 { pending[id] = nil; continue }
            var packet = p.packet
            packet[0] |= 0x04 << 3   // 送り直しの印
            conn?.send(content: packet, completion: .idempotent)
            pending[id] = (p.packet, now, p.tries + 1)
        }
    }

    // MARK: 受信

    private func handle(_ p: Data) {
        let b = [UInt8](p)
        guard b.count >= 12 else { return }
        let flags = b[0] >> 3
        let length = min(Int(b[0] & 0x07) << 8 | Int(b[1]), b.count)
        sessionID = u16(b, 2)
        let remoteID = u16(b, 10)
        lastReceived = Date()

        if flags & 0x02 != 0 {   // 新しいセッション (呼びかけへの返事)
            let wasConnected = established
            established = true
            lastRemoteID = remoteID
            sendAck(remoteID)
            if !wasConnected { notify { $0.onState?(.connected, "LAN") } }
            return
        }
        guard established else { return }
        if flags & 0x10 != 0 {   // こちらの命令が届いた
            let acked = u16(b, 4)
            pending = pending.filter { id, _ in
                let d = (Int(acked) - Int(id) + 32768) % 32768
                return d >= 16384   // acked より後の番号だけ残す
            }
        }
        if flags & 0x01 != 0 {   // 返事が必要な知らせ
            if remoteID == (lastRemoteID + 1) % 32768 {
                lastRemoteID = remoteID
                sendAck(remoteID)
                parseCommands(b, length)
            } else {
                sendAck(lastRemoteID)
            }
        }
    }

    private func parseCommands(_ b: [UInt8], _ length: Int) {
        var o = 12
        while o + 8 <= length {
            let len = Int(u16(b, o))
            guard len >= 8, o + len <= length else { break }
            let name = String(bytes: b[(o + 4)..<(o + 8)], encoding: .ascii) ?? ""
            let body = Array(b[(o + 8)..<(o + len)])
            command(name, body)
            o += len
        }
    }

    private func command(_ name: String, _ d: [UInt8]) {
        switch name {
        case "PrgI" where d.count >= 4 && d[0] == 0:
            let src = Int(u16(d, 2))
            notify { $0.onProgram?(src) }
        case "PrvI" where d.count >= 4 && d[0] == 0:
            let src = Int(u16(d, 2))
            notify { $0.onPreview?(src) }
        case "InPr" where d.count >= 26:
            let id = Int(u16(d, 0))
            // 外部の入力 (HDMI / SDI) だけ。カラーバーやメディアプレーヤーなどは 1000 以上
            guard (1..<1000).contains(id) else { return }
            let long = cString(d[2..<22]), short = cString(d[22..<26])
            inputs[id] = long.isEmpty ? (short.isEmpty ? "\(id)" : short) : long
            if initDone { publishInputs() }
        case "VidM" where d.count >= 1:
            framesPerSecond = Self.framesPerSecond(videoMode: Int(d[0]))
        case "InCm":   // 最初の状態をひととおり受け取った
            initDone = true
            publishInputs()
        default:
            break
        }
    }

    /// VidM の番号ごとの、ミックスの長さの 1 秒あたりのフレーム数 (50p / 60p でも 25 / 30 で数える)
    private static func framesPerSecond(videoMode m: Int) -> Double {
        let table: [Double] = [30, 25, 30, 25, 25, 30, 25, 30, 24, 24, 25, 30, 25, 30,
                               24, 24, 25, 30, 25, 30, 24, 24, 25, 30, 25, 30, 30, 30, 30, 30]
        return m < table.count ? table[m] : 30
    }

    private func publishInputs() {
        let list = inputs.keys.sorted().map { Input(id: $0, name: inputs[$0]!) }
        notify { $0.onInputs?(list) }
    }

    // MARK: SDK でつなぐ

    /// 0.2 秒ごと: つながっていなければつなぐ (数秒かかる)、つながっていれば本番の入力を見る
    private func tickSDK() {
        if let sdk {
            if atem_sdk_is_connected(sdk) == 0 {
                NSLog("ATEM: disconnected")
                closeSDK()
                sdkRetryAt = Date().addingTimeInterval(1)
                notify { $0.onState?(.connecting, nil) }
                return
            }
            let p = Int(atem_sdk_program(sdk))
            if p != sdkProgram {
                sdkProgram = p
                notify { $0.onProgram?(p) }
            }
            return
        }
        guard Date() >= sdkRetryAt, let host else { return }
        notify { $0.onState?(.connecting, nil) }
        var fail: Int32 = 0
        guard let s = atem_sdk_connect(host, &fail) else {
            NSLog("ATEM: connect failed (\(fail))")
            sdkRetryAt = Date().addingTimeInterval(3)
            let why = fail == 0x63666966 ? L("ATEM のソフトと本体のバージョンが合いません") : L("見つかりません。もう一度試しています…")
            notify { $0.onState?(.connecting, why) }
            return
        }
        guard self.host != nil else { atem_sdk_release(s); return }
        sdk = s
        sdkProgram = -1
        var name = [CChar](repeating: 0, count: 128)
        atem_sdk_product_name(s, &name, 128)
        let product = String(cString: name)
        var list: [Input] = []
        for i in 0..<atem_sdk_input_count(s) {
            var buf = [CChar](repeating: 0, count: 128)
            atem_sdk_input_name(s, i, &buf, 128)
            list.append(Input(id: Int(atem_sdk_input_id(s, i)), name: String(cString: buf)))
        }
        let via = host.isEmpty ? "USB" : host
        notify {
            $0.onState?(.connected, product.isEmpty ? via : "\(product)・\(via)")
            $0.onInputs?(list)
        }
    }

    private func closeSDK() {
        if let sdk { atem_sdk_release(sdk) }
        sdk = nil
        sdkProgram = -1
    }

    // MARK: 送信

    /// 本番 (PGM) の入力を、すぐ切り替える (カット)
    func setProgram(_ source: Int) {
        if Self.sdkAvailable { queue.async { if let s = self.sdk { _ = atem_sdk_set_program(s, Int64(source)) } }; return }
        send("CPgI", [0, 0] + be16(source))
    }
    /// 次に出す (PVW) 入力を選ぶ
    func setPreview(_ source: Int) {
        if Self.sdkAvailable { queue.async { if let s = self.sdk { _ = atem_sdk_set_preview(s, Int64(source)) } }; return }
        send("CPvI", [0, 0] + be16(source))
    }
    /// ミックスの長さ (秒)
    static let mixSeconds = 0.5

    /// 次に出す入力へ、ミックスなどの切り替え効果で移る
    func auto() {
        if Self.sdkAvailable {
            queue.async {
                guard let s = self.sdk else { return }
                _ = atem_sdk_set_mix_seconds(s, Self.mixSeconds)
                _ = atem_sdk_auto(s)
            }
            return
        }
        // ミックスの長さはフレーム数で送る (映像の形式は VidM で受け取っている)
        queue.async {
            let frames = max(1, min(250, Int((Self.mixSeconds * self.framesPerSecond).rounded())))
            self.send("CTMx", [0, UInt8(frames), 0, 0])
            self.send("DAut", [0, 0, 0, 0])
        }
    }

    private func send(_ name: String, _ body: [UInt8]) {
        queue.async {
            guard self.established, let conn = self.conn else { return }
            self.localPacketID = (self.localPacketID + 1) % 32768
            let id = self.localPacketID
            let cmdLen = 8 + body.count
            let payload = be16(cmdLen) + [0, 0] + Array(name.utf8) + body
            let length = 12 + payload.count
            var h = [UInt8](repeating: 0, count: 12)
            h[0] = UInt8(0x01 << 3) | UInt8(length >> 8); h[1] = UInt8(length & 0xff)
            h[2] = UInt8(self.sessionID >> 8); h[3] = UInt8(self.sessionID & 0xff)
            h[10] = UInt8(id >> 8); h[11] = UInt8(id & 0xff)
            let packet = Data(h + payload)
            self.pending[id] = (packet, Date(), 0)
            conn.send(content: packet, completion: .idempotent)
        }
    }

    private func sendHello() {
        sessionID = UInt16.random(in: 0x100..<0x7fff)
        let p: [UInt8] = [0x10, 0x14, UInt8(sessionID >> 8), UInt8(sessionID & 0xff), 0, 0, 0, 0, 0, 0x3a, 0, 0,
                          0x01, 0, 0, 0, 0, 0, 0, 0]
        helloSent = Date()
        conn?.send(content: Data(p), completion: .idempotent)
    }

    private func sendAck(_ id: UInt16) {
        var h = [UInt8](repeating: 0, count: 12)
        h[0] = 0x10 << 3; h[1] = 12
        h[2] = UInt8(sessionID >> 8); h[3] = UInt8(sessionID & 0xff)
        h[4] = UInt8(id >> 8); h[5] = UInt8(id & 0xff)
        conn?.send(content: Data(h), completion: .idempotent)
    }

    // MARK: 小物

    private func notify(_ f: @escaping (ATEMControl) -> Void) {
        DispatchQueue.main.async { f(self) }
    }
    private func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) << 8 | UInt16(b[o + 1]) }
    private func cString(_ s: ArraySlice<UInt8>) -> String {
        String(decoding: s.prefix { $0 != 0 }, as: UTF8.self)
    }
}

private func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
