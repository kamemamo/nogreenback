// 背景映像: USB キャプチャーなどの映像や、この Mac の画面を受け取り、切り抜いた人物の後ろに敷く
// 全画面出力: 合成した映像をプロジェクターなどの画面いっぱいに出す (OBS を使わずに済ませる)

import AppKit
import AVFoundation
import CoreImage
import CoreMediaIO
import ScreenCaptureKit

/// 背景にする映像の入力。最新の 1 フレームだけを持っておき、人物の処理のたびに使う
final class BackgroundSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "background", qos: .userInteractive)
    private var session: AVCaptureSession?
    private let lock = NSLock()
    private var _image: CIImage?
    private(set) var device: AVCaptureDevice?
    /// 背景にしている画面の名前 (画面を背景にしていなければ nil)
    private(set) var screenName: String?
    private var screenFeed: AnyObject?   // ScreenFeed (macOS 12.3 以降)
    /// 止めたり切り替えたりするたびに増やす (遅れて届いた古いフレームや開始処理を捨てるため)
    private var generation = 0

    /// USB でつないだ iPhone・iPad の画面を、取り込み機器として出してもらう (QuickTime と同じ仕組み)。
    /// 頼んだあと少しして機器がつながった知らせが来るので、そこで背景の選択肢に加わる
    static func allowIOSScreens() {
        var prop = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        let status = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &prop, 0, nil,
                                               UInt32(MemoryLayout<UInt32>.size), &allow)
        if status != 0 { NSLog("background: can't allow iOS screen devices (\(status))") }
    }

    /// iPhone・iPad の画面か (映像と音が一緒になった機器として出てくる)
    static func isIOSScreen(_ device: AVCaptureDevice) -> Bool {
        device.hasMediaType(.muxed) && !device.hasMediaType(.video)
    }

    /// 最新の背景フレーム (背景なしなら nil)
    var latestImage: CIImage? { lock.lock(); defer { lock.unlock() }; return _image }

    /// 最後にフレームが届いた時刻と、取り込みを開始した時刻 (映像が止まったのを見つけるため)
    private var lastFrameTime: CFAbsoluteTime = 0
    private var startedTime: CFAbsoluteTime = 0
    private var watchdog: Timer?
    private var runtimeObserver: NSObjectProtocol?

    /// 背景にする映像を切り替える (nil なら背景なし = 透明)
    /// - Parameter force: 同じ機器でも開き直す (つなぎ直したときなど)
    func start(_ device: AVCaptureDevice?, force: Bool = false) throws {
        guard force || device?.uniqueID != self.device?.uniqueID || screenFeed != nil else { return }
        stop()
        guard let device else { return }
        try open(device)
        // iPhone・iPad の画面は、画面が動かない間はコマが来ないことがあるので見張らない
        // (外したときは、機器が外れた知らせで止まる)
        if Self.isIOSScreen(device) { return }
        // スイッチャー (ATEM など) は映像形式を変えたときや、つないだ直後に
        // USB の機器として一度消えて出直すことがある。古いつながりのまま映像が止まるので、
        // しばらくフレームが来なければ同じ機器を探して開き直す
        let id = device.uniqueID
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.reopenIfStalled(id)
        }
    }

    private func reopenIfStalled(_ id: String) {
        guard session != nil, self.device?.uniqueID == id else { return }
        lock.lock(); let last = max(lastFrameTime, startedTime); lock.unlock()
        guard CFAbsoluteTimeGetCurrent() - last > 3 else { return }
        // 今つながっている同じ機器 (つなぎ直すと別のオブジェクトになる) で開き直す
        guard let fresh = AVCaptureDevice(uniqueID: id), fresh.isConnected else { return }
        NSLog("background: no frames from \(fresh.localizedName), reopening")
        try? reopen(fresh)
    }

    /// 監視を続けたまま、セッションだけ作り直す
    private func reopen(_ device: AVCaptureDevice) throws {
        if let session { queue.async { session.stopRunning() } }
        if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) }
        runtimeObserver = nil
        session = nil
        try open(device)
    }

    private func open(_ device: AVCaptureDevice) throws {
        let input = try AVCaptureDeviceInput(device: device)
        let session = AVCaptureSession()
        session.beginConfiguration()
        // iPhone・iPad の画面は縦長で大きさが機種ごとに違うので、そのままの大きさで受け取る
        session.sessionPreset = !Self.isIOSScreen(device) && session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                kCVPixelBufferMetalCompatibilityKey as String: true]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        self.session = session
        self.device = device
        lock.lock(); startedTime = CFAbsoluteTimeGetCurrent(); lock.unlock()
        // 取り込み中のエラー (機器が外れた、ほかのアプリに取られたなど) は、少し待ってから開き直す
        runtimeObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            NSLog("background: session error \(String(describing: note.userInfo?[AVCaptureSessionErrorKey]))")
            self?.lock.lock(); self?.startedTime = 0; self?.lastFrameTime = 0; self?.lock.unlock()
        }
        queue.async { session.startRunning() }
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) }
        runtimeObserver = nil
        if let session { queue.async { session.stopRunning() } }
        session = nil
        device = nil
        if #available(macOS 12.3, *) { (screenFeed as? ScreenFeed)?.stop() }
        screenFeed = nil
        screenName = nil
        lock.lock(); _image = nil; generation += 1; lock.unlock()
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }; return generation == gen
    }

    /// この Mac の画面を背景にする。
    /// NoGreenBack 自身のウィンドウ (人物の表示や全画面出力) は映さない。手書きのウィンドウだけは映す
    func startScreen(_ screen: NSScreen, keepWindows: [Int], onError: @escaping (String) -> Void) {
        stop()
        guard #available(macOS 12.3, *) else { return }
        screenName = screen.localizedName
        lock.lock(); let gen = generation; lock.unlock()
        let feed = ScreenFeed()
        feed.onFrame = { [weak self] image in
            guard let self else { return }
            self.lock.lock()
            if self.generation == gen { self._image = image }
            self.lock.unlock()
        }
        screenFeed = feed
        Task { @MainActor in
            do {
                try await feed.start(screen: screen, keepWindows: keepWindows)
                // 開始を待つ間に切り替わっていたら止める
                if !self.isCurrent(gen) { feed.stop() }
            } catch {
                if self.isCurrent(gen) { onError(error.localizedDescription) }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let image = CIImage(cvPixelBuffer: pb)
        lock.lock()
        let first = lastFrameTime < startedTime
        _image = image; lastFrameTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()
        if first { NSLog("background: first frame \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))") }
    }
}

/// 画面をそのまま映像として受け取る (背景用)
@available(macOS 12.3, *)
final class ScreenFeed: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "screen-background", qos: .userInteractive)
    var onFrame: ((CIImage) -> Void)?

    func start(screen: NSScreen, keepWindows: [Int]) async throws {
        // 画面収録の許可がない場合、ここで macOS が許可を求める (または失敗する)。
        // 画面に出ていないウィンドウも含めて取る (起動直後などで、自分のアプリが一覧から漏れないように)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "NoGreenBack", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L("背景にする画面が見つかりません")])
        }
        // 自分のウィンドウを映すと、合わせ鏡のように映像が繰り返されるので外す
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let keep = content.windows.filter { keepWindows.contains(Int($0.windowID)) }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: keep)

        // 長辺 1920 まで (背景は全画面出力の大きさに合わせて拡大・縮小されるため)
        let scale = screen.backingScaleFactor
        let w = Double(display.width) * scale, h = Double(display.height) * scale
        let s = min(1, 1920 / max(w, h))
        let config = SCStreamConfiguration()
        config.width = Int(w * s) / 2 * 2
        config.height = Int(h * s) / 2 * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        // 取り込んだコマをためておく数。最新の 1 枚しか使わないので少なめ (1 枚約 9 MB)
        config.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        // 画面に変化がない間は中身のないフレームが来るので、前のフレームのままにする
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        onFrame?(CIImage(cvPixelBuffer: pb))
    }
}

/// 合成した映像を画面いっぱいに出すウィンドウ (縦横比を保ち、余白は黒)
final class OutputWindow: NSWindow {
    let view: PreviewView
    /// Esc で閉じたときの通知
    var onClose: (() -> Void)?
    /// 出している画面の名前 (その画面が外れたかどうかの判定に使う)
    private(set) var screenName: String?

    /// 最初から画面の大きさで作る (後から大きさを変えると、描画が隅に寄ることがある)
    init(processor: Processor, screen: NSScreen) {
        view = PreviewView(frame: CGRect(origin: .zero, size: screen.frame.size), device: processor.device)
        view.setup(processor: processor)
        view.checkered = false
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        contentView = view
        backgroundColor = .black
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        level = .normal
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// 画面いっぱいに表示する (メニューバーと Dock の上も覆う)
    func show(on screen: NSScreen) {
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        screenName = screen.localizedName
        setFrame(screen.frame, display: true)
        orderFrontRegardless()
        // このアプリを操作中なら、すぐ Esc で閉じられるようにキー入力を受け取る
        if NSApp.isActive { makeKey() }
    }

    override func cancelOperation(_ sender: Any?) { onClose?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) }  // Esc
    }
}
