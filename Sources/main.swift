// NoGreenBack — Webカメラから人物だけをリアルタイムで切り抜き、Syphon で送出する macOS アプリ
//
// パイプライン:
//   AVCaptureSession (BGRA) → Vision 人物セグメンテーション (マスク)
//   → Core Image で元映像にマスクを適用 (背景は透明)
//   → MTLTexture に描画 → SyphonMetalServer で送出 + プレビュー表示

import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import MetalKit
import Syphon
import Vision

// MARK: - 設定 (メインスレッドから変更、処理スレッドから読み取り)

final class Settings: @unchecked Sendable {
    private let lock = NSLock()
    private var _quality: VNGeneratePersonSegmentationRequest.QualityLevel = .balanced
    private var _feather: Double = 1.5
    private var _mirror = false
    private var _flipVertical = true   // 既定で上下反転オン
    private var _straightAlpha = false
    private var _smoothing: Double = 0.6
    private var _tighten: Double = 0.3
    private var _hold: Double = 0.6
    private var _deflicker: Double = 0.7

    private func get<T>(_ v: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return v() }
    private func set(_ f: () -> Void) { lock.lock(); f(); lock.unlock() }

    var quality: VNGeneratePersonSegmentationRequest.QualityLevel {
        get { get { _quality } } set { set { _quality = newValue } }
    }
    /// マスク境界のぼかし半径 (マスク解像度上のピクセル)
    var feather: Double { get { get { _feather } } set { set { _feather = newValue } } }
    var mirror: Bool { get { get { _mirror } } set { set { _mirror = newValue } } }
    var flipVertical: Bool { get { get { _flipVertical } } set { set { _flipVertical = newValue } } }
    /// true: ストレートアルファで送出 / false: プリマルチプライド
    var straightAlpha: Bool { get { get { _straightAlpha } } set { set { _straightAlpha = newValue } } }
    /// ちらつき抑制 0...1 (0 = なし)。動きの小さい画素ほど前フレームのマスクを残す
    var smoothing: Double { get { get { _smoothing } } set { set { _smoothing = newValue } } }
    /// 境界の締まり 0...1 (0 = なし)。半透明の縁を減らしてマスクをくっきりさせる
    var tighten: Double { get { get { _tighten } } set { set { _tighten = newValue } } }
    /// 消失の保持 0...1 (0 = なし)。人物と判定された部分が急に消えたとき、すぐ消さずにゆっくりフェードさせる
    /// (手を顔の前にかざしたときなど、判定が一瞬外れても頭が消えないように)
    var hold: Double { get { get { _hold } } set { set { _hold = newValue } } }
    /// 明るさ安定化 0...1 (0 = なし)。照明のフリッカーによる画面全体の明滅をならす
    var deflicker: Double { get { get { _deflicker } } set { set { _deflicker = newValue } } }
}

// MARK: - 映像処理

final class Processor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let ciContext: CIContext
    let syphon: SyphonMetalServer
    let settings: Settings
    private let seqHandler = VNSequenceRequestHandler()
    private let request = VNGeneratePersonSegmentationRequest()

    private var outTexture: MTLTexture?
    /// 平滑化したマスクの履歴 (ピンポンバッファ)
    private var maskTextures: [MTLTexture] = []
    private var maskIndex = 0
    private var hasMaskHistory = false
    private var lastQuality: VNGeneratePersonSegmentationRequest.QualityLevel?
    /// 明るさ安定化用: 平均輝度の移動平均
    private var lumaAverage: Double?
    private let previewLock = NSLock()
    private var _latestImage: CIImage?
    /// プレビュー用の最新フレーム (切り抜き済み)
    var latestImage: CIImage? {
        previewLock.lock(); defer { previewLock.unlock() }; return _latestImage
    }

    private var frameCount = 0
    private var fpsStart = CACurrentMediaTime()
    var onFPS: ((Double) -> Void)?

    init(device: MTLDevice, settings: Settings) {
        self.device = device
        self.queue = device.makeCommandQueue()!
        self.settings = settings
        self.ciContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .cacheIntermediates: false,
        ])
        self.syphon = SyphonMetalServer(name: "NoGreenBack", device: device, options: nil)
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        super.init()
    }

    private func texture(width: Int, height: Int) -> MTLTexture {
        if let t = outTexture, t.width == width, t.height == height { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = .private
        let t = device.makeTexture(descriptor: d)!
        outTexture = t
        return t
    }

    private func ensureMaskTextures(width: Int, height: Int) {
        if let t = maskTextures.first, t.width == width, t.height == height { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = .private
        maskTextures = [device.makeTexture(descriptor: d)!, device.makeTexture(descriptor: d)!]
        hasMaskHistory = false
    }

    /// 動き適応の時間平滑化:
    ///   w = clamp(base + |cur - prev| * k)   (動いた画素ほど w → 1 で即座に追従)
    ///   out = prev + (cur - prev) * w
    /// 結果をテクスチャに書き出して次フレームの prev にする
    private func temporallySmoothed(_ cur: CIImage, commandBuffer cb: MTLCommandBuffer) -> CIImage {
        let w = Int(cur.extent.width), h = Int(cur.extent.height)
        ensureMaskTextures(width: w, height: h)
        let smoothing = settings.smoothing
        let raw = [CIImageOption.colorSpace: NSNull()] as [CIImageOption: Any]
        let writeTex = maskTextures[maskIndex]
        let readTex = maskTextures[1 - maskIndex]

        var result = cur
        if hasMaskHistory, smoothing > 0.01, let prev = CIImage(mtlTexture: readTex, options: raw) {
            let base = 1 - smoothing * 0.92   // 静止部分で新マスクを採用する割合
            let k: CGFloat = 5                // 差がこの逆数 (0.2) を超えたら完全に追従
            let diff = cur.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: prev])
            let weight = diff.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: base, y: base, z: base, w: 1),
            ]).applyingFilter("CIColorClamp")
            let blend = CIFilter.blendWithMask()
            blend.inputImage = cur
            blend.backgroundImage = prev
            blend.maskImage = weight
            result = blend.outputImage!.cropped(to: cur.extent)
        }

        // 消失の保持: 1 フレームで減ってよい量を d に制限する
        //   out = max(result, prev - d)
        // 増える方向 (人物が現れる) は即座に反映し、減る方向だけゆっくりにする
        let hold = settings.hold
        if hasMaskHistory, hold > 0.01, let prev = CIImage(mtlTexture: readTex, options: raw) {
            let d = CGFloat(pow(0.02, hold))   // hold 0.6 → 約 0.1/フレーム (30fps で約 0.3 秒)
            let decayed = prev.applyingFilter("CIColorMatrix", parameters: [
                "inputBiasVector": CIVector(x: -d, y: -d, z: -d, w: 0),
            ]).applyingFilter("CIColorClamp")
            result = result.applyingFilter("CIMaximumCompositing",
                                           parameters: [kCIInputBackgroundImageKey: decayed])
                .cropped(to: cur.extent)
        }

        let dest = CIRenderDestination(mtlTexture: writeTex, commandBuffer: cb)
        dest.colorSpace = nil
        _ = try? ciContext.startTask(toRender: result, to: dest)
        hasMaskHistory = true
        maskIndex = 1 - maskIndex
        return CIImage(mtlTexture: writeTex, options: raw) ?? result
    }

    /// 明るさ安定化: フレーム全体の平均輝度を求め、ゆっくり追従する移動平均に合わせてゲインをかける。
    /// 照明の明滅 (例: 50Hz 地域を 30fps で撮ると約 10Hz で脈打つ) を打ち消す。
    /// ゆっくりした明るさの変化 (自動露出や照明の点灯) にはそのまま追従する。
    private func deflickered(_ image: CIImage) -> CIImage {
        let strength = settings.deflicker
        guard strength > 0.01 else { lumaAverage = nil; return image }
        let e = image.extent
        let small = image.transformed(by: CGAffineTransform(scaleX: 0.125, y: 0.125))
        let avg = small.applyingFilter("CIAreaAverage",
                                       parameters: [kCIInputExtentKey: CIVector(cgRect: small.extent)])
        var px = [Float](repeating: 0, count: 4)
        ciContext.render(avg, toBitmap: &px, rowBytes: 16,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        let luma = Double(0.299 * px[0] + 0.587 * px[1] + 0.114 * px[2])
        guard luma > 0.01 else { return image }
        let ref = (lumaAverage ?? luma) * 0.9 + luma * 0.1   // 約 10 フレームで追従
        lumaAverage = ref
        let gain = min(max(ref / luma, 0.8), 1.25)
        let g = CGFloat(1 + (gain - 1) * strength)
        guard abs(g - 1) > 0.001 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: g, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: g, w: 0),
        ]).cropped(to: e)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // 1) 人物マスク生成
        let quality = settings.quality
        request.qualityLevel = quality
        if quality != lastQuality { hasMaskHistory = false; lastQuality = quality }
        do {
            try seqHandler.perform([request], on: pixelBuffer)
        } catch {
            NSLog("Vision error: \(error)")
            return
        }
        guard let maskBuffer = request.results?.first?.pixelBuffer else { return }

        // 2) マスクを映像サイズに拡大して合成
        var source = deflickered(CIImage(cvPixelBuffer: pixelBuffer))
        let extent = source.extent
        guard let cb = queue.makeCommandBuffer() else { return }
        var mask = CIImage(cvPixelBuffer: maskBuffer, options: [.colorSpace: NSNull()])
        // ちらつき抑制 (時間方向の平滑化)
        mask = temporallySmoothed(mask, commandBuffer: cb)
        // 境界の締まり: 0.5 を中心にコントラストを上げて半透明の縁を減らす
        let tighten = settings.tighten
        if tighten > 0.01 {
            let g = CGFloat(1 + tighten * 3), b = 0.5 * (1 - g)
            mask = mask.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: g, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: g, w: 0),
                "inputBiasVector": CIVector(x: b, y: b, z: b, w: 0),
            ]).applyingFilter("CIColorClamp")
        }
        let feather = settings.feather
        if feather > 0.05 {
            mask = mask.clampedToExtent()
                .applyingGaussianBlur(sigma: feather)
                .cropped(to: mask.extent)
        }
        mask = mask.transformed(by: CGAffineTransform(
            scaleX: extent.width / mask.extent.width,
            y: extent.height / mask.extent.height))
            .samplingLinear()

        let blend = CIFilter.blendWithMask()
        blend.inputImage = source
        blend.backgroundImage = CIImage(color: .clear).cropped(to: extent)
        blend.maskImage = mask
        guard var cutout = blend.outputImage?.cropped(to: extent) else { return }

        if settings.mirror {
            cutout = cutout.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
                .translatedBy(x: -extent.width, y: 0))
        }
        source = cutout

        // 3) テクスチャに描画して Syphon 送出
        let w = Int(extent.width), h = Int(extent.height)
        let tex = texture(width: w, height: h)
        let dest = CIRenderDestination(mtlTexture: tex, commandBuffer: cb)
        // Core Image は左下原点。Metal (左上原点) の向きで書き込む
        dest.isFlipped = !settings.flipVertical
        dest.alphaMode = settings.straightAlpha ? .unpremultiplied : .premultiplied
        dest.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        do {
            _ = try ciContext.startTask(toRender: source, to: dest)
        } catch {
            NSLog("Render error: \(error)")
            return
        }
        syphon.publishFrameTexture(tex, on: cb,
                                   imageRegion: NSRect(x: 0, y: 0, width: w, height: h),
                                   flipped: false)
        cb.commit()

        previewLock.lock(); _latestImage = source; previewLock.unlock()

        frameCount += 1
        let now = CACurrentMediaTime()
        if now - fpsStart >= 1 {
            let fps = Double(frameCount) / (now - fpsStart)
            frameCount = 0; fpsStart = now
            onFPS?(fps)
        }
    }
}

// MARK: - プレビュー (市松模様の上に透過映像を表示)

final class PreviewView: MTKView, MTKViewDelegate {
    var processor: Processor!
    private var checker: CIImage = {
        let f = CIFilter.checkerboardGenerator()
        f.color0 = CIColor(red: 0.8, green: 0.8, blue: 0.8)
        f.color1 = CIColor(red: 0.55, green: 0.55, blue: 0.55)
        f.width = 16
        return f.outputImage!
    }()

    func setup(processor: Processor) {
        self.processor = processor
        device = processor.device
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        preferredFramesPerSecond = 60
        delegate = self
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let cb = processor.queue.makeCommandBuffer() else { return }
        let size = drawableSize
        let bounds = CGRect(origin: .zero, size: size)
        var img = checker.cropped(to: bounds)
        if let frame = processor.latestImage {
            // アスペクト比を保ってフィット
            let e = frame.extent
            let s = min(size.width / e.width, size.height / e.height)
            let tx = (size.width - e.width * s) / 2, ty = (size.height - e.height * s) / 2
            let fitted = frame.transformed(by: CGAffineTransform(scaleX: s, y: s)
                .concatenating(CGAffineTransform(translationX: tx, y: ty)))
            img = fitted.composited(over: img)
        }
        let dest = CIRenderDestination(width: Int(size.width), height: Int(size.height),
                                       pixelFormat: colorPixelFormat, commandBuffer: cb) {
            drawable.texture
        }
        dest.isFlipped = true
        _ = try? processor.ciContext.startTask(toRender: img, to: dest)
        cb.present(drawable)
        cb.commit()
    }
}

// MARK: - 画面に重ねる表示 (OBS なしで画面の隅に人物を浮かせる)

/// 背景が透明な MTKView。人物以外は透けて後ろの画面が見える
final class OverlayView: MTKView, MTKViewDelegate {
    var processor: Processor!

    func setup(processor: Processor) {
        self.processor = processor
        device = processor.device
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        preferredFramesPerSecond = 60
        layer?.isOpaque = false
        delegate = self
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let cb = processor.queue.makeCommandBuffer() else { return }
        let size = drawableSize
        var img = CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: size))
        if let frame = processor.latestImage {
            // 横はフィット、下端をそろえる (人物の下端が画面の下に付くように)
            let e = frame.extent
            let s = min(size.width / e.width, size.height / e.height)
            let tx = (size.width - e.width * s) / 2 - e.minX * s
            let fitted = frame.transformed(by: CGAffineTransform(scaleX: s, y: s)
                .concatenating(CGAffineTransform(translationX: tx, y: -e.minY * s)))
            img = fitted.composited(over: img)
        }
        let dest = CIRenderDestination(width: Int(size.width), height: Int(size.height),
                                       pixelFormat: colorPixelFormat, commandBuffer: cb) {
            drawable.texture
        }
        dest.isFlipped = true
        dest.alphaMode = .premultiplied
        _ = try? processor.ciContext.startTask(toRender: img, to: dest)
        cb.present(drawable)
        cb.commit()
    }
}

/// 枠なし・透明・常に最前面・クリックは後ろへ通すウィンドウ。
/// 他のアプリの全画面表示 (別スペース) の上にも出せるよう、アクティブにならないパネルにする
final class OverlayWindow: NSPanel {
    let view: OverlayView
    private var keepFrontTimer: Timer?

    init(processor: Processor) {
        view = OverlayView(frame: .zero, device: processor.device)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        view.setup(processor: processor)
        contentView = view
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        // Keynote や PowerPoint のスライドショーより上 (画面を占有する表示と同じ最上位の層)
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    enum Corner: Int, CaseIterable {
        case bottomRight, bottomLeft, topRight, topLeft
        var title: String { ["右下", "左下", "右上", "左上"][rawValue] }
    }

    /// 画面幅に対する割合 (scale) で大きさを決め、指定の隅に置く (映像は 16:9)
    func place(on screen: NSScreen, corner: Corner, scale: Double) {
        let sf = screen.frame
        let w = (sf.width * scale).rounded(), h = (w * 9 / 16).rounded()
        let x = (corner == .bottomRight || corner == .topRight) ? sf.maxX - w : sf.minX
        let y = (corner == .bottomRight || corner == .bottomLeft) ? sf.minY : sf.maxY - h
        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }

    func setVisible(_ on: Bool) {
        view.isPaused = !on
        keepFrontTimer?.invalidate()
        keepFrontTimer = nil
        if on {
            orderFrontRegardless()
            // 同じ層に後から出たウィンドウ (スライドショー開始時など) に隠されないよう、定期的に最前面へ戻す
            keepFrontTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.orderFrontRegardless()
            }
        } else {
            orderOut(nil)
        }
    }
}

// MARK: - 手書きの注釈 (人物の表示よりさらに手前)

/// 線を描くビュー。描いた線は残し、設定すれば一定時間後に消える
final class AnnotationView: NSView {
    struct Stroke {
        var points: [CGPoint]
        var color: NSColor
        var width: CGFloat
        var finished: Date?
    }
    var strokes: [Stroke] = []
    var color = NSColor.systemRed
    var lineWidth: CGFloat = 5
    /// 描き終わってから消えるまでの秒数 (0 なら消えない)
    var fadeAfter: TimeInterval = 0
    /// 描画できる状態 (キーを押している間) なら画面の縁に枠を出して知らせる
    var drawingMode = false { didSet { if drawingMode != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        strokes.append(Stroke(points: [p], color: color, width: lineWidth, finished: nil))
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard !strokes.isEmpty, strokes[strokes.count - 1].finished == nil else { return }
        strokes[strokes.count - 1].points.append(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { finishStroke() }
    /// キーを押しながら右クリックで全部消す
    override func rightMouseDown(with event: NSEvent) { clear() }

    func finishStroke() {
        if let i = strokes.indices.last, strokes[i].finished == nil { strokes[i].finished = Date() }
    }
    func clear() { strokes.removeAll(); needsDisplay = true }

    /// 時間がたった線を消す (タイマーから呼ぶ)
    func tick() {
        guard fadeAfter > 0, !strokes.isEmpty else { return }
        let now = Date()
        strokes.removeAll { s in s.finished.map { now.timeIntervalSince($0) > fadeAfter } ?? false }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()
        let now = Date()
        for s in strokes {
            // 消える直前の 0.5 秒でフェードアウト
            var alpha: CGFloat = 1
            if fadeAfter > 0, let f = s.finished {
                alpha = CGFloat(min(1, max(0, (fadeAfter - now.timeIntervalSince(f)) / 0.5)))
            }
            let path = NSBezierPath()
            path.lineWidth = s.width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: s.points[0])
            if s.points.count == 1 { path.line(to: s.points[0]) }
            for p in s.points.dropFirst() { path.line(to: p) }
            s.color.withAlphaComponent(alpha).setStroke()
            path.stroke()
        }
        if drawingMode {
            let frame = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
            frame.lineWidth = 4
            color.withAlphaComponent(0.5).setStroke()
            frame.stroke()
        }
    }
}

/// 画面全体を覆う透明なパネル。普段はクリックを後ろへ通し、キーを押している間だけ描ける
final class AnnotationWindow: NSPanel {
    let view = AnnotationView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = view
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        // 人物の表示 (OverlayWindow) より 1 つ上
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func cover(_ screen: NSScreen) { setFrame(screen.frame, display: true) }

    /// 描画モードの切り替え。オフに戻したら描きかけの線を確定する
    func setDrawing(_ on: Bool) {
        guard ignoresMouseEvents == on else { return }
        ignoresMouseEvents = !on
        view.drawingMode = on
        if !on { view.finishStroke() }
    }
}

// MARK: - アプリ本体

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = Settings()
    var processor: Processor!
    let session = AVCaptureSession()
    let videoQueue = DispatchQueue(label: "video", qos: .userInteractive)
    var window: NSWindow!
    var cameraPopup = NSPopUpButton()
    var fpsLabel = NSTextField(labelWithString: "-- fps")
    var devices: [AVCaptureDevice] = []
    var currentDevice: AVCaptureDevice?
    /// 選べるフレームレート。50Hz 地域 (東日本) は 25/20fps、60Hz 地域 (西日本) は 30fps でフリッカーが出にくい
    let frameRates: [(fps: Int32, title: String)] = [
        (30, "30fps (60Hz・西日本)"),
        (25, "25fps (50Hz・東日本)"),
        (20, "20fps (50Hz・より安定)"),
    ]
    var targetFPS: Int32 {
        get { let v = UserDefaults.standard.integer(forKey: "frameRate"); return v > 0 ? Int32(v) : 25 }
        set { UserDefaults.standard.set(Int(newValue), forKey: "frameRate") }
    }

    // 画面に重ねる表示の設定 (次回起動時も使う)
    var overlay: OverlayWindow!
    var overlayCheck = NSButton()
    var screenPopup = NSPopUpButton()
    var overlayOn: Bool {
        get { UserDefaults.standard.bool(forKey: "overlayOn") }
        set { UserDefaults.standard.set(newValue, forKey: "overlayOn") }
    }
    var overlayCorner: OverlayWindow.Corner {
        get { .init(rawValue: UserDefaults.standard.integer(forKey: "overlayCorner")) ?? .bottomRight }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "overlayCorner") }
    }
    var overlayScale: Double {
        get { let v = UserDefaults.standard.double(forKey: "overlayScale"); return v > 0 ? v : 0.35 }
        set { UserDefaults.standard.set(newValue, forKey: "overlayScale") }
    }
    // 画面録画
    var recorder: AnyObject?   // ScreenRecorder (macOS 12.3 以降)
    var recordButton = NSButton()
    var recordLabel = NSTextField(labelWithString: "")
    var recordStart = Date()
    var recordTimer: Timer?
    var recordMic: Bool {
        get { UserDefaults.standard.object(forKey: "recordMic") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "recordMic") }
    }

    // 手書きの注釈の設定
    var annotation: AnnotationWindow!
    var annotationTimer: Timer?
    var annotationCheck = NSButton()
    var colorPopup = NSPopUpButton()
    /// Stream Deck などから切り替える「ペン」状態 (キーを押していなくても描ける)
    var penLatched = false
    var hotKeys: HotKeys?
    let drawKeys: [(title: String, flags: NSEvent.ModifierFlags)] = [
        ("⌥ Option", .option), ("⌃ Control", .control), ("⌥⌘ Option+Command", [.option, .command]),
    ]
    let penColors: [(title: String, color: NSColor)] = [
        ("赤", .systemRed), ("黄", .systemYellow), ("青", .systemBlue), ("緑", .systemGreen), ("白", .white), ("黒", .black),
    ]
    let fadeTimes: [(title: String, seconds: TimeInterval)] = [
        ("消さない", 0), ("3秒で消す", 3), ("10秒で消す", 10),
    ]
    var annotationOn: Bool {
        get { UserDefaults.standard.bool(forKey: "annotationOn") }
        set { UserDefaults.standard.set(newValue, forKey: "annotationOn") }
    }
    var drawKeyIndex: Int {
        get { min(UserDefaults.standard.integer(forKey: "drawKey"), drawKeys.count - 1) }
        set { UserDefaults.standard.set(newValue, forKey: "drawKey") }
    }
    var penColorIndex: Int {
        get { min(UserDefaults.standard.integer(forKey: "penColor"), penColors.count - 1) }
        set { UserDefaults.standard.set(newValue, forKey: "penColor") }
    }
    var penWidth: Double {
        get { let v = UserDefaults.standard.double(forKey: "penWidth"); return v > 0 ? v : 5 }
        set { UserDefaults.standard.set(newValue, forKey: "penWidth") }
    }
    var fadeIndex: Int {
        get { min(UserDefaults.standard.integer(forKey: "penFade"), fadeTimes.count - 1) }
        set { UserDefaults.standard.set(newValue, forKey: "penFade") }
    }

    var overlayScreenName: String? {
        get { UserDefaults.standard.string(forKey: "overlayScreen") }
        set { UserDefaults.standard.set(newValue, forKey: "overlayScreen") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let mtl = MTLCreateSystemDefaultDevice() else { fatalError("Metal 非対応") }
        processor = Processor(device: mtl, settings: settings)
        processor.onFPS = { [weak self] fps in
            DispatchQueue.main.async { self?.fpsLabel.stringValue = String(format: "%.1f fps", fps) }
        }
        buildUI()
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async {
                if ok { self.refreshCameras(); self.startSession() }
                else { self.showAlert("カメラへのアクセスが許可されていません。\nシステム設定 > プライバシーとセキュリティ > カメラ で許可してください。") }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 録画中に終了するときは、ファイルを閉じてから終了する (閉じないと再生できないファイルになる)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard #available(macOS 12.3, *), let rec = recorder as? ScreenRecorder else { return .terminateNow }
        Task { @MainActor in
            _ = await rec.stop()
            self.recorder = nil
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.stopRunning()
        processor.syphon.stop()
    }

    // MARK: UI

    func buildUI() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 680),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "NoGreenBack — Syphon: \"NoGreenBack\""
        window.center()

        let preview = PreviewView(frame: .zero, device: processor.device)
        preview.setup(processor: processor)

        cameraPopup.target = self
        cameraPopup.action = #selector(cameraChanged)

        let quality = NSPopUpButton()
        quality.addItems(withTitles: ["Fast (低負荷)", "Balanced", "Accurate (高品質)"])
        quality.selectItem(at: 1)
        quality.target = self
        quality.action = #selector(qualityChanged(_:))

        let fpsPopup = NSPopUpButton()
        fpsPopup.addItems(withTitles: frameRates.map(\.title))
        fpsPopup.selectItem(at: frameRates.firstIndex { $0.fps == targetFPS } ?? 1)
        fpsPopup.target = self
        fpsPopup.action = #selector(fpsChanged(_:))
        fpsPopup.toolTip = "照明の電源周波数に合わせると、フリッカー (明滅) が出にくくなります"

        let deflicker = NSSlider(value: settings.deflicker, minValue: 0, maxValue: 1,
                                 target: self, action: #selector(deflickerChanged(_:)))
        deflicker.widthAnchor.constraint(equalToConstant: 110).isActive = true
        deflicker.toolTip = "照明のフリッカーによる画面全体の明滅をならします (横じまは消せません)"

        let feather = NSSlider(value: settings.feather, minValue: 0, maxValue: 6,
                               target: self, action: #selector(featherChanged(_:)))
        feather.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let mirror = NSButton(checkboxWithTitle: "左右反転", target: self, action: #selector(mirrorChanged(_:)))
        let flip = NSButton(checkboxWithTitle: "上下反転", target: self, action: #selector(flipChanged(_:)))
        flip.state = settings.flipVertical ? .on : .off
        let straight = NSButton(checkboxWithTitle: "ストレートα", target: self, action: #selector(alphaChanged(_:)))
        straight.toolTip = "オフ: プリマルチプライドα (既定) / オン: ストレートα。受信側で縁が黒くなる・白くなる場合に切り替え"

        let smoothing = NSSlider(value: settings.smoothing, minValue: 0, maxValue: 1,
                                 target: self, action: #selector(smoothingChanged(_:)))
        smoothing.widthAnchor.constraint(equalToConstant: 140).isActive = true
        smoothing.toolTip = "上げるほど輪郭のちらつきが減ります。上げすぎると動いたときに残像が出ます"
        let tighten = NSSlider(value: settings.tighten, minValue: 0, maxValue: 1,
                               target: self, action: #selector(tightenChanged(_:)))
        tighten.widthAnchor.constraint(equalToConstant: 140).isActive = true
        tighten.toolTip = "上げるほど半透明の縁 (背景のにじみ) が減り、輪郭がくっきりします"

        let bar = NSStackView(views: [
            NSTextField(labelWithString: "カメラ"), cameraPopup,
            NSTextField(labelWithString: "品質"), quality,
            NSTextField(labelWithString: "フレームレート"), fpsPopup,
            mirror, flip, straight, NSView(), fpsLabel,
        ])
        let hold = NSSlider(value: settings.hold, minValue: 0, maxValue: 1,
                            target: self, action: #selector(holdChanged(_:)))
        hold.widthAnchor.constraint(equalToConstant: 120).isActive = true
        hold.toolTip = "上げるほど、手をかざしたときなどに体の一部が一瞬消える現象を抑えます。上げすぎると、移動した後に元の位置がうっすら残ります"

        let bar2 = NSStackView(views: [
            NSTextField(labelWithString: "ちらつき抑制"), smoothing,
            NSTextField(labelWithString: "消失の保持"), hold,
            NSTextField(labelWithString: "境界の締まり"), tighten,
            NSTextField(labelWithString: "境界ぼかし"), feather,
            NSTextField(labelWithString: "明るさ安定化"), deflicker, NSView(),
        ])
        for b in [bar, bar2] {
            b.orientation = .horizontal
            b.spacing = 8
            b.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        }
        fpsLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        // 3 段目: 画面に重ねる表示
        overlay = OverlayWindow(processor: processor)
        overlayCheck = NSButton(checkboxWithTitle: "画面に表示", target: self, action: #selector(overlayToggled(_:)))
        overlayCheck.state = overlayOn ? .on : .off
        overlayCheck.toolTip = "OBS を使わずに、人物を画面の隅に常に手前で表示します (クリックは後ろのアプリに届きます)"
        let cornerPopup = NSPopUpButton()
        cornerPopup.addItems(withTitles: OverlayWindow.Corner.allCases.map(\.title))
        cornerPopup.selectItem(at: overlayCorner.rawValue)
        cornerPopup.target = self
        cornerPopup.action = #selector(cornerChanged(_:))
        let sizeSlider = NSSlider(value: overlayScale, minValue: 0.15, maxValue: 0.8,
                                  target: self, action: #selector(overlaySizeChanged(_:)))
        sizeSlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        sizeSlider.toolTip = "画面の幅に対する大きさ"
        screenPopup.target = self
        screenPopup.action = #selector(screenChanged(_:))
        refreshScreens()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.refreshScreens(); self?.placeOverlay()
        }
        recordButton = NSButton(title: "● 録画開始", target: self, action: #selector(recordToggled))
        recordButton.toolTip = "「表示する画面」を録画して、ムービーフォルダに保存します (このウィンドウは映りません)。⌃⌥⌘R でも開始・停止できます"
        let micCheck = NSButton(checkboxWithTitle: "マイク音声", target: self, action: #selector(micToggled(_:)))
        micCheck.state = recordMic ? .on : .off
        recordLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        recordLabel.textColor = .systemRed
        if #unavailable(macOS 12.3) {
            recordButton.isEnabled = false
            recordButton.toolTip = "画面録画には macOS 12.3 以降が必要です"
        }
        let bar3 = NSStackView(views: [
            overlayCheck,
            NSTextField(labelWithString: "位置"), cornerPopup,
            NSTextField(labelWithString: "大きさ"), sizeSlider,
            NSTextField(labelWithString: "表示する画面"), screenPopup, NSView(),
            recordButton, micCheck, recordLabel,
        ])
        bar3.orientation = .horizontal
        bar3.spacing = 8
        bar3.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        placeOverlay()
        overlay.setVisible(overlayOn)

        // 4 段目: 手書きの注釈
        annotation = AnnotationWindow()
        annotation.view.color = penColors[penColorIndex].color
        annotation.view.lineWidth = CGFloat(penWidth)
        annotation.view.fadeAfter = fadeTimes[fadeIndex].seconds
        annotationCheck = NSButton(checkboxWithTitle: "手書き", target: self, action: #selector(annotationToggled(_:)))
        annotationCheck.state = annotationOn ? .on : .off
        annotationCheck.toolTip = "選んだキーを押している間だけ、画面にペンで書けます。離すと後ろのアプリを操作できます。⌃⌥⌘D でペンを押しっぱなし状態にできます"
        let keyPopup = NSPopUpButton()
        keyPopup.addItems(withTitles: drawKeys.map(\.title))
        keyPopup.selectItem(at: drawKeyIndex)
        keyPopup.target = self
        keyPopup.action = #selector(drawKeyChanged(_:))
        colorPopup = NSPopUpButton()
        colorPopup.addItems(withTitles: penColors.map(\.title))
        colorPopup.selectItem(at: penColorIndex)
        colorPopup.target = self
        colorPopup.action = #selector(penColorChanged(_:))
        let widthSlider = NSSlider(value: penWidth, minValue: 2, maxValue: 20,
                                   target: self, action: #selector(penWidthChanged(_:)))
        widthSlider.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let fadePopup = NSPopUpButton()
        fadePopup.addItems(withTitles: fadeTimes.map(\.title))
        fadePopup.selectItem(at: fadeIndex)
        fadePopup.target = self
        fadePopup.action = #selector(fadeChanged(_:))
        let clearButton = NSButton(title: "消去", target: self, action: #selector(clearAnnotation))
        let hint = NSTextField(labelWithString: "キーを押しながらドラッグで描く／キーを2回押すか、押しながら右クリックで全消去")
        hint.textColor = .secondaryLabelColor
        let bar4 = NSStackView(views: [
            annotationCheck,
            NSTextField(labelWithString: "描くキー"), keyPopup,
            NSTextField(labelWithString: "色"), colorPopup,
            NSTextField(labelWithString: "太さ"), widthSlider,
            fadePopup, clearButton, hint, NSView(),
        ])
        bar4.orientation = .horizontal
        bar4.spacing = 8
        bar4.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        setAnnotationVisible(annotationOn)

        let root = NSStackView(views: [bar, bar2, bar3, bar4, preview])
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .leading
        bar.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        bar2.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        bar3.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        bar4.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        preview.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        window.contentView = root
        // 画面に重ねた表示が残っていても、メインウィンドウを閉じたら終了する
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window, queue: .main) { _ in NSApp.terminate(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        registerHotKeys()
    }

    func showAlert(_ text: String) {
        let a = NSAlert(); a.messageText = text; a.runModal()
    }

    // MARK: カメラ

    func refreshCameras() {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types += [.external, .continuityCamera]
        } else {
            types.append(.externalUnknown)
        }
        devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video,
                                                   position: .unspecified).devices
        cameraPopup.removeAllItems()
        cameraPopup.addItems(withTitles: devices.map(\.localizedName))
    }

    func startSession() {
        guard !devices.isEmpty else { showAlert("カメラが見つかりません"); return }
        configure(device: devices[0])
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                kCVPixelBufferMetalCompatibilityKey as String: true]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(processor, queue: videoQueue)
        session.beginConfiguration()
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        videoQueue.async {
            self.session.startRunning()
            // セッション開始時にフレームレートが既定値へ戻ることがあるので、開始後にも設定する
            DispatchQueue.main.async { self.applyFrameRate() }
        }
    }

    func configure(device: AVCaptureDevice) {
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
            currentDevice = device
            watchFrameRate(of: device)
            if !session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .high }
        } catch {
            showAlert("カメラを開けません: \(error.localizedDescription)")
        }
        session.commitConfiguration()
        applyFrameRate()
    }

    /// カメラが対応するフレーム間隔のうち、選んだフレームレートに最も近いものを返す
    /// (Osmo Pocket などは 30/25/24fps のような飛び飛びの値しか受け付けない)
    func frameDuration(for device: AVCaptureDevice) -> CMTime? {
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        let want = Double(targetFPS)
        if let r = ranges.first(where: { $0.minFrameRate <= want && want <= $0.maxFrameRate }) {
            // 飛び飛びの値ならカメラが示す値そのものを使う
            return r.minFrameRate == r.maxFrameRate ? r.minFrameDuration : CMTime(value: 1, timescale: targetFPS)
        }
        // 範囲外なら最も近い端の値に合わせる
        let candidates = ranges.flatMap { [($0.minFrameRate, $0.maxFrameDuration), ($0.maxFrameRate, $0.minFrameDuration)] }
        return candidates.min(by: { abs($0.0 - want) < abs($1.0 - want) })?.1
    }

    /// 使う映像形式: 横長 1920x1080 (なければ 1920 幅以下で最大の横長)。
    /// Osmo Pocket など縦横両方を出せるカメラは、指定しないと縦長の枠に横長の映像を入れて送ってくる
    func preferredFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let landscape = device.formats.filter {
            let d = $0.formatDescription.dimensions
            return d.width > d.height && d.width <= 1920
        }
        func score(_ f: AVCaptureDevice.Format) -> (Int32, Bool) {
            // 解像度が大きいもの優先、同じなら 420v (Vision と相性がよい) を優先
            (f.formatDescription.dimensions.width,
             f.formatDescription.mediaSubType == .init(rawValue: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
        }
        return landscape.max { a, b in
            let (sa, sb) = (score(a), score(b))
            return sa.0 != sb.0 ? sa.0 < sb.0 : (!sa.1 && sb.1)
        }
    }

    /// 映像形式と選んだフレームレートをカメラに設定する
    func applyFrameRate() {
        guard let device = currentDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if let f = preferredFormat(for: device), device.activeFormat != f {
                device.activeFormat = f
            }
            if let duration = frameDuration(for: device),
               device.activeVideoMinFrameDuration != duration || device.activeVideoMaxFrameDuration != duration {
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
        } catch {
            NSLog("camera config error: \(error)")
        }
    }

    /// カメラ側 (UVC カメラなど) が撮影開始時にフレームレートを既定値へ戻すことがあるので、
    /// 変わったら設定し直す
    var frameRateObservers: [NSKeyValueObservation] = []
    func watchFrameRate(of device: AVCaptureDevice) {
        let reapply: (AVCaptureDevice, Any) -> Void = { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyFrameRate() }
        }
        frameRateObservers = [
            device.observe(\.activeVideoMinFrameDuration, changeHandler: reapply),
            device.observe(\.activeVideoMaxFrameDuration, changeHandler: reapply),
            device.observe(\.activeFormat, changeHandler: reapply),
        ]
    }

    @objc func fpsChanged(_ sender: NSPopUpButton) {
        targetFPS = frameRates[sender.indexOfSelectedItem].fps
        applyFrameRate()
    }
    @objc func deflickerChanged(_ sender: NSSlider) { settings.deflicker = sender.doubleValue }

    // MARK: 画面に重ねる表示

    var overlayScreen: NSScreen {
        NSScreen.screens.first { $0.localizedName == overlayScreenName } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func refreshScreens() {
        screenPopup.removeAllItems()
        screenPopup.addItems(withTitles: NSScreen.screens.map(\.localizedName))
        screenPopup.selectItem(withTitle: overlayScreen.localizedName)
    }

    func placeOverlay() {
        overlay?.place(on: overlayScreen, corner: overlayCorner, scale: overlayScale)
        annotation?.cover(overlayScreen)
    }

    // MARK: 全体で効くショートカット (Stream Deck の「ホットキー」から使う)

    /// (キー, キーコード, 内容, 動作)
    var hotKeyList: [(key: String, code: Int, title: String, action: () -> Void)] {
        [
            ("R", kVK_ANSI_R, "録画の開始・停止", { [weak self] in self?.recordToggled() }),
            ("P", kVK_ANSI_P, "人物を画面に表示・非表示", { [weak self] in self?.toggleOverlay() }),
            ("C", kVK_ANSI_C, "手書きを全部消す", { [weak self] in self?.annotation.view.clear() }),
            ("D", kVK_ANSI_D, "ペン (描画モード) のオン・オフ", { [weak self] in self?.togglePen() }),
            ("K", kVK_ANSI_K, "ペンの色を次の色へ", { [weak self] in self?.nextPenColor() }),
        ]
    }

    func registerHotKeys() {
        let keys = HotKeys()
        var failed: [String] = []
        for k in hotKeyList where !keys.register(keyCode: k.code, k.action) {
            failed.append("\(HotKeys.modifierSymbols)\(k.key)（\(k.title)）")
        }
        hotKeys = keys
        if !failed.isEmpty {
            showAlert("次のショートカットは他のアプリが使っているため登録できませんでした:\n" + failed.joined(separator: "\n"))
        }
    }

    func toggleOverlay() {
        overlayCheck.state = overlayCheck.state == .on ? .off : .on
        overlayToggled(overlayCheck)
    }

    func togglePen() {
        if !annotationOn {
            annotationCheck.state = .on
            annotationToggled(annotationCheck)
        }
        penLatched.toggle()
        annotation.setDrawing(penLatched)
    }

    func nextPenColor() {
        let i = (penColorIndex + 1) % penColors.count
        colorPopup.selectItem(at: i)
        penColorChanged(colorPopup)
    }

    // MARK: 画面録画

    @objc func micToggled(_ sender: NSButton) { recordMic = sender.state == .on }

    @objc func recordToggled() {
        guard #available(macOS 12.3, *) else { return }
        recordButton.isEnabled = false
        if let rec = recorder as? ScreenRecorder {
            // 停止
            Task { @MainActor in
                let url = await rec.stop()
                self.recorder = nil
                self.recordTimer?.invalidate()
                self.recordLabel.stringValue = ""
                self.recordButton.title = "● 録画開始"
                self.recordButton.isEnabled = true
                if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                else { self.showAlert("画面に変化がなかったため、録画は保存されませんでした。") }
            }
        } else {
            // 開始
            let rec = ScreenRecorder()
            rec.onError = { [weak self] msg in
                self?.showAlert(msg)
                if self?.recorder != nil { self?.recordToggled() }
            }
            Task { @MainActor in
                do {
                    _ = try await rec.start(screen: self.overlayScreen,
                                            excluding: [self.window.windowNumber],
                                            microphone: self.recordMic)
                    self.recorder = rec
                    self.recordButton.title = "■ 録画停止"
                    self.recordStart = Date()
                    self.recordLabel.stringValue = "0:00"
                    let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                        guard let self else { return }
                        let s = Int(Date().timeIntervalSince(self.recordStart))
                        self.recordLabel.stringValue = s >= 3600
                            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                            : String(format: "%d:%02d", s / 60, s % 60)
                    }
                    RunLoop.main.add(t, forMode: .common)
                    self.recordTimer = t
                } catch {
                    self.showAlert("録画を開始できません: \(error.localizedDescription)\n\n初回は「システム設定 > プライバシーとセキュリティ > 画面収録」で NoGreenBack を許可し、アプリを開き直してください。")
                }
                self.recordButton.isEnabled = true
            }
        }
    }

    // MARK: 手書きの注釈

    func setAnnotationVisible(_ on: Bool) {
        annotationTimer?.invalidate()
        annotationTimer = nil
        annotation.setDrawing(false)
        guard on else { annotation.orderOut(nil); return }
        annotation.cover(overlayScreen)
        annotation.orderFrontRegardless()
        // キーの状態を見て描画モードを切り替える。NSEvent.modifierFlags は
        // 他のアプリが前面でも読めて、アクセシビリティの許可も要らない
        var frontCount = 0
        // 描くキーを素早く 2 回押す (描かずに離す) と全消し
        var wasDown = false, pressStart = Date.distantPast, strokesAtPress = 0, lastTap = Date.distantPast
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let held = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function])
            let down = held == self.drawKeys[self.drawKeyIndex].flags
            let now = Date()
            if down && !wasDown {
                pressStart = now
                strokesAtPress = self.annotation.view.strokes.count
            } else if !down && wasDown {
                let isTap = now.timeIntervalSince(pressStart) < 0.3
                    && self.annotation.view.strokes.count == strokesAtPress
                if isTap && pressStart.timeIntervalSince(lastTap) < 0.4 {
                    self.annotation.view.clear()
                    lastTap = .distantPast
                } else {
                    lastTap = isTap ? now : .distantPast
                }
            }
            wasDown = down
            self.annotation.setDrawing(down || self.penLatched)
            self.annotation.view.tick()
            // 定期的に最前面へ戻す (1 秒ごと)
            frontCount += 1
            if frontCount >= 60 { frontCount = 0; self.annotation.orderFrontRegardless() }
        }
        // ドラッグ中 (イベント追跡中) も止まらないよう common モードで回す
        RunLoop.main.add(timer, forMode: .common)
        annotationTimer = timer
    }

    @objc func annotationToggled(_ sender: NSButton) {
        annotationOn = sender.state == .on
        if !annotationOn { penLatched = false }
        setAnnotationVisible(annotationOn)
    }
    @objc func drawKeyChanged(_ sender: NSPopUpButton) { drawKeyIndex = sender.indexOfSelectedItem }
    @objc func penColorChanged(_ sender: NSPopUpButton) {
        penColorIndex = sender.indexOfSelectedItem
        annotation.view.color = penColors[penColorIndex].color
    }
    @objc func penWidthChanged(_ sender: NSSlider) {
        penWidth = sender.doubleValue
        annotation.view.lineWidth = CGFloat(penWidth)
    }
    @objc func fadeChanged(_ sender: NSPopUpButton) {
        fadeIndex = sender.indexOfSelectedItem
        annotation.view.fadeAfter = fadeTimes[fadeIndex].seconds
    }
    @objc func clearAnnotation() { annotation.view.clear() }

    @objc func overlayToggled(_ sender: NSButton) {
        overlayOn = sender.state == .on
        placeOverlay()
        overlay.setVisible(overlayOn)
    }
    @objc func cornerChanged(_ sender: NSPopUpButton) {
        overlayCorner = .init(rawValue: sender.indexOfSelectedItem) ?? .bottomRight
        placeOverlay()
    }
    @objc func overlaySizeChanged(_ sender: NSSlider) {
        overlayScale = sender.doubleValue
        placeOverlay()
    }
    @objc func screenChanged(_ sender: NSPopUpButton) {
        overlayScreenName = sender.titleOfSelectedItem
        placeOverlay()
    }

    @objc func cameraChanged() {
        let i = cameraPopup.indexOfSelectedItem
        guard devices.indices.contains(i) else { return }
        configure(device: devices[i])
    }

    @objc func qualityChanged(_ sender: NSPopUpButton) {
        settings.quality = [.fast, .balanced, .accurate][sender.indexOfSelectedItem]
    }
    @objc func featherChanged(_ sender: NSSlider) { settings.feather = sender.doubleValue }
    @objc func smoothingChanged(_ sender: NSSlider) { settings.smoothing = sender.doubleValue }
    @objc func tightenChanged(_ sender: NSSlider) { settings.tighten = sender.doubleValue }
    @objc func holdChanged(_ sender: NSSlider) { settings.hold = sender.doubleValue }
    @objc func mirrorChanged(_ sender: NSButton) { settings.mirror = sender.state == .on }
    @objc func flipChanged(_ sender: NSButton) { settings.flipVertical = sender.state == .on }
    @objc func alphaChanged(_ sender: NSButton) { settings.straightAlpha = sender.state == .on }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)

// 最低限のメニュー (Cmd+Q で終了できるように)
let mainMenu = NSMenu()
let appItem = NSMenuItem()
mainMenu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "NoGreenBack を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu
app.mainMenu = mainMenu

app.run()
