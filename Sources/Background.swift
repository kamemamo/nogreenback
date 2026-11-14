// 背景映像: USB キャプチャーなどの映像や、この Mac の画面を受け取り、切り抜いた人物の後ろに敷く
// 全画面出力: 合成した映像をプロジェクターなどの画面いっぱいに出す (OBS を使わずに済ませる)

import AppKit
import AVFoundation
import CoreImage
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

    /// 最新の背景フレーム (背景なしなら nil)
    var latestImage: CIImage? { lock.lock(); defer { lock.unlock() }; return _image }

    /// 背景にする映像を切り替える (nil なら背景なし = 透明)
    func start(_ device: AVCaptureDevice?) throws {
        guard device?.uniqueID != self.device?.uniqueID || screenFeed != nil else { return }
        stop()
        guard let device else { return }
        let input = try AVCaptureDeviceInput(device: device)
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
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
        queue.async { session.startRunning() }
    }

    func stop() {
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
        lock.lock(); _image = image; lock.unlock()
    }
}

/// 画面をそのまま映像として受け取る (背景用)
@available(macOS 12.3, *)
final class ScreenFeed: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "screen-background", qos: .userInteractive)
    var onFrame: ((CIImage) -> Void)?

    func start(screen: NSScreen, keepWindows: [Int]) async throws {
        // 画面収録の許可がない場合、ここで macOS が許可を求める (または失敗する)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "NoGreenBack", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "背景にする画面が見つかりません"])
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
        config.queueDepth = 5

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
