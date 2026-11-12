// 背景映像: USB キャプチャーなどの映像を受け取り、切り抜いた人物の後ろに敷く
// 全画面出力: 合成した映像をプロジェクターなどの画面いっぱいに出す (OBS を使わずに済ませる)

import AppKit
import AVFoundation
import CoreImage

/// 背景にする映像の入力。最新の 1 フレームだけを持っておき、人物の処理のたびに使う
final class BackgroundSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "background", qos: .userInteractive)
    private var session: AVCaptureSession?
    private let lock = NSLock()
    private var _image: CIImage?
    private(set) var device: AVCaptureDevice?

    /// 最新の背景フレーム (背景なしなら nil)
    var latestImage: CIImage? { lock.lock(); defer { lock.unlock() }; return _image }

    /// 背景にする映像を切り替える (nil なら背景なし = 透明)
    func start(_ device: AVCaptureDevice?) throws {
        guard device?.uniqueID != self.device?.uniqueID else { return }
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
        lock.lock(); _image = nil; lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let image = CIImage(cvPixelBuffer: pb)
        lock.lock(); _image = image; lock.unlock()
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
