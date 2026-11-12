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
    private var _hold: Double = 0.2
    private var _deflicker: Double = 0.7
    private var _pipCorner = 0
    private var _pipScale: Double = 0.35
    private var _showPerson = true

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
    /// 背景映像があるときの人物の位置 (OverlayWindow.Corner の rawValue) と、画面幅に対する大きさ
    var pipCorner: Int { get { get { _pipCorner } } set { set { _pipCorner = newValue } } }
    var pipScale: Double { get { get { _pipScale } } set { set { _pipScale = newValue } } }
    /// 背景映像があるときに人物を入れるか (「画面に表示」・⌃⌥⌘P と連動)
    var showPerson: Bool { get { get { _showPerson } } set { set { _showPerson = newValue } } }
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
    private var _latestCutout: CIImage?
    /// 画面に重ねる表示用の最新フレーム (背景なしの人物だけ)
    var latestCutout: CIImage? {
        previewLock.lock(); defer { previewLock.unlock() }; return _latestCutout
    }
    /// プレビュー用の最新フレーム (切り抜き済み)
    var latestImage: CIImage? {
        previewLock.lock(); defer { previewLock.unlock() }; return _latestImage
    }

    private var frameCount = 0
    private var fpsStart = CACurrentMediaTime()
    var onFPS: ((Double) -> Void)?
    /// 人物の後ろに敷く映像 (USB キャプチャーなど)
    let background = BackgroundSource()

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
            let d = CGFloat(pow(0.02, hold))   // hold 0.6 → 約 0.1/フレーム (30fps で約 0.3 秒)、既定の 0.2 → 約 0.46/フレーム (約 0.07 秒)
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
        // 「人物」がオフなら、人物を出さない (背景映像がないときは透明になる)
        if !settings.showPerson { cutout = CIImage(color: .clear).cropped(to: extent) }
        source = cutout

        // 人物は「位置」「大きさ」に合わせて小さくして隅に置く
        let corner = OverlayWindow.Corner(rawValue: settings.pipCorner) ?? .bottomRight
        let ps = CGFloat(settings.pipScale)
        let pw = extent.width * ps, ph = extent.height * ps
        let px = (corner == .bottomRight || corner == .topRight) ? extent.width - pw : 0
        let py = (corner == .bottomRight || corner == .bottomLeft) ? 0 : extent.height - ph   // 左下原点
        let person = cutout.transformed(by: CGAffineTransform(scaleX: ps, y: ps)
            .concatenating(CGAffineTransform(translationX: px, y: py)))
        // プレビューと全画面出力に出す映像
        var display: CIImage
        if let bg = background.latestImage {
            // 背景映像は画面を埋めるように拡大して敷く (はみ出した分は切る)
            let be = bg.extent
            let s = max(extent.width / be.width, extent.height / be.height)
            let tx = (extent.width - be.width * s) / 2 - be.minX * s
            let ty = (extent.height - be.height * s) / 2 - be.minY * s
            let fitted = bg.transformed(by: CGAffineTransform(scaleX: s, y: s)
                .concatenating(CGAffineTransform(translationX: tx, y: ty)))
            display = person.composited(over: fitted).cropped(to: extent)
            source = display
        } else {
            // 背景なし: Syphon には人物を元の大きさで送り (OBS 側で配置する)、
            // プレビューと全画面出力では、背景ありのときと同じ位置・大きさにする
            // (透明な下地を敷いて、映像の大きさを元のままにする)
            display = person.composited(over: CIImage(color: .clear).cropped(to: extent)).cropped(to: extent)
        }

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

        previewLock.lock(); _latestImage = display; _latestCutout = cutout; previewLock.unlock()

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
    /// false なら市松模様の代わりに黒を敷く (全画面出力用)
    var checkered = true
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
        // drawableSize ではなく実際のテクスチャの大きさに合わせる (画面を移ったときに食い違うことがある)
        let size = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let bounds = CGRect(origin: .zero, size: size)
        // 映像の外の余白は黒。映像の中の透明な部分だけ市松模様にする
        var img = CIImage(color: .black).cropped(to: bounds)
        if let frame = processor.latestImage {
            // アスペクト比を保ってフィット
            let e = frame.extent
            let s = min(size.width / e.width, size.height / e.height)
            let tx = (size.width - e.width * s) / 2, ty = (size.height - e.height * s) / 2
            let fitted = frame.transformed(by: CGAffineTransform(scaleX: s, y: s)
                .concatenating(CGAffineTransform(translationX: tx, y: ty)))
            if checkered { img = checker.cropped(to: fitted.extent).composited(over: img) }
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
        if let frame = processor.latestCutout {
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

/// 手書きの注釈を、つながっているすべての画面に用意する
/// (液晶タブレットのように別の画面として認識される機器の上でも描けるように)
final class Annotations {
    private(set) var windows: [AnnotationWindow] = []
    private var shown = false
    private var drawing = false

    var color: NSColor = .systemRed { didSet { windows.forEach { $0.view.color = color } } }
    var lineWidth: CGFloat = 5 { didSet { windows.forEach { $0.view.lineWidth = lineWidth } } }
    var fadeAfter: TimeInterval = 0 { didSet { windows.forEach { $0.view.fadeAfter = fadeAfter } } }

    var strokeCount: Int { windows.reduce(0) { $0 + $1.view.strokes.count } }

    /// 画面の構成に合わせて、画面ごとのウィンドウを作り直す (描いた線は消える)
    func coverAllScreens() {
        let screens = NSScreen.screens
        if windows.count == screens.count {
            zip(windows, screens).forEach { $0.cover($1) }
            return
        }
        windows.forEach { $0.orderOut(nil) }
        windows = screens.map { screen in
            let w = AnnotationWindow()
            w.view.color = color
            w.view.lineWidth = lineWidth
            w.view.fadeAfter = fadeAfter
            w.cover(screen)
            w.setDrawing(drawing)
            if shown { w.orderFrontRegardless() }
            return w
        }
    }

    func clear() { windows.forEach { $0.view.clear() } }
    func tick() { windows.forEach { $0.view.tick() } }
    func setDrawing(_ on: Bool) { drawing = on; windows.forEach { $0.setDrawing(on) } }
    func orderFront() { shown = true; windows.forEach { $0.orderFrontRegardless() } }
    func orderOut() { shown = false; windows.forEach { $0.orderOut(nil) } }
}

// MARK: - アプリ本体

/// 上部のオン・オフボタン。背景を自分で塗る
/// (標準のボタンは、全画面出力などが前に出てウィンドウが非アクティブになると、オンの色が消えてしまう)
final class ToggleButton: NSButton {
    /// オンのときの色
    var onColor: NSColor = .controlAccentColor { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        wantsLayer = true
        font = .systemFont(ofSize: 13)
        setButtonType(.pushOnPushOff)
    }
    required init?(coder: NSCoder) { fatalError() }

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
    }

    override var title: String { didSet { needsDisplay = true } }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize {
        let w = (title as NSString).size(withAttributes: [.font: font ?? .systemFont(ofSize: 13)]).width
        return NSSize(width: ceil(w) + 28, height: 30)
    }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let on = state == .on
        var fill = on ? onColor : NSColor.labelColor.withAlphaComponent(0.08)
        if isHighlighted { fill = on ? onColor.blended(withFraction: 0.2, of: .black) ?? onColor
                                     : NSColor.labelColor.withAlphaComponent(0.18) }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
        }
        layer?.cornerRadius = bounds.height / 2
        let color: NSColor = !isEnabled ? .tertiaryLabelColor : on ? .white : .labelColor
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font ?? .systemFont(ofSize: 13), .foregroundColor: color, .paragraphStyle: style,
        ])
    }
}

/// 上から下へ並べるための、座標が上から始まるビュー (サイドバーのスクロール用)
final class FlippedView: NSView { override var isFlipped: Bool { true } }

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
    /// 人物を出すか (全画面出力・プレビュー・Syphon・画面に重ねる表示のすべて)
    var personOn: Bool {
        get { UserDefaults.standard.object(forKey: "personOn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "personOn") }
    }
    var personButton = NSButton()
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
    var recordButton = ToggleButton()
    var recordLabel = NSTextField(labelWithString: "")
    var recordStart = Date()
    var recordTimer: Timer?
    var recordMic: Bool {
        get { UserDefaults.standard.object(forKey: "recordMic") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "recordMic") }
    }
    /// 録画に使うマイクの uniqueID (nil ならシステムの既定のマイク)
    var recordMicID: String? {
        get { UserDefaults.standard.string(forKey: "recordMicID") }
        set { UserDefaults.standard.set(newValue, forKey: "recordMicID") }
    }
    var micPopup = NSPopUpButton()

    // 背景映像と全画面出力
    var bgPopup = NSPopUpButton()
    var bgDevices: [AVCaptureDevice] = []
    var outputCheck = NSButton()
    var outputScreenPopup = NSPopUpButton()
    var outputWindow: OutputWindow?
    /// 背景にする映像の uniqueID (nil なら背景なし)
    var backgroundID: String? {
        get { UserDefaults.standard.string(forKey: "backgroundID") }
        set { UserDefaults.standard.set(newValue, forKey: "backgroundID") }
    }
    var recordScreenPopup = NSPopUpButton()
    var recordSizeLabel = NSTextField(labelWithString: "")

    /// 録画の設定 (UserDefaults に保存)
    var recordSettings: RecordSettings {
        get {
            let d = UserDefaults.standard
            var r = RecordSettings()
            if d.object(forKey: "recMbps") != nil { r.videoMbps = d.integer(forKey: "recMbps") }
            if d.object(forKey: "recLongSide") != nil { r.maxLongSide = d.integer(forKey: "recLongSide") }
            if d.object(forKey: "recFPS") != nil { r.fps = d.integer(forKey: "recFPS") }
            r.hevc = d.bool(forKey: "recHEVC")
            if d.object(forKey: "recAudioKbps") != nil { r.audioKbps = d.integer(forKey: "recAudioKbps") }
            return r
        }
        set {
            let d = UserDefaults.standard
            d.set(newValue.videoMbps, forKey: "recMbps")
            d.set(newValue.maxLongSide, forKey: "recLongSide")
            d.set(newValue.fps, forKey: "recFPS")
            d.set(newValue.hevc, forKey: "recHEVC")
            d.set(newValue.audioKbps, forKey: "recAudioKbps")
            updateRecordSizeLabel()
        }
    }

    /// 1 時間あたりのファイルの大きさの目安 (動きが多いときの上限に近い値)
    func updateRecordSizeLabel() {
        let r = recordSettings
        let gb = Double(r.videoMbps * 1000 + r.audioKbps) * 3600 / 8 / 1_000_000
        recordSizeLabel.stringValue = String(format: "1 時間で最大 約 %.1f GB", gb)
    }

    @objc func recordMbpsChanged(_ sender: NSPopUpButton) {
        recordSettings.videoMbps = RecordSettings.videoMbpsChoices[sender.indexOfSelectedItem]
    }
    @objc func recordSizeChanged(_ sender: NSPopUpButton) {
        recordSettings.maxLongSide = RecordSettings.maxLongSideChoices[sender.indexOfSelectedItem]
    }
    @objc func recordFPSChanged(_ sender: NSPopUpButton) {
        recordSettings.fps = RecordSettings.fpsChoices[sender.indexOfSelectedItem]
    }
    @objc func recordCodecChanged(_ sender: NSPopUpButton) {
        recordSettings.hevc = sender.indexOfSelectedItem == 1
    }
    @objc func recordAudioChanged(_ sender: NSPopUpButton) {
        recordSettings.audioKbps = RecordSettings.audioKbpsChoices[sender.indexOfSelectedItem]
    }
    /// 録画する画面の名前 (nil なら「表示する画面」と同じ)
    var recordScreenName: String? {
        get { UserDefaults.standard.string(forKey: "recordScreen") }
        set { UserDefaults.standard.set(newValue, forKey: "recordScreen") }
    }
    var outputScreenName: String? {
        get { UserDefaults.standard.string(forKey: "outputScreen") }
        set { UserDefaults.standard.set(newValue, forKey: "outputScreen") }
    }
    let micMeter = MicMeter()
    var micCheckTick = 0
    let micLevel = NSLevelIndicator()
    var micLevelTimer: Timer?
    var micDevices: [AVCaptureDevice] = []

    // 手書きの注釈の設定
    var annotation: Annotations!
    var annotationTimer: Timer?
    var annotationCheck = NSButton()
    var colorPopup = NSPopUpButton()
    /// Stream Deck などから切り替える「ペン」状態 (キーを押していなくても描ける)
    var penLatched = false {
        didSet { penButton.state = penLatched ? .on : .off }
    }
    var penButton = NSButton()
    /// 「切り抜きの調整」を開いておくか
    var tuningOpen: Bool {
        get { UserDefaults.standard.bool(forKey: "tuningOpen") }
        set { UserDefaults.standard.set(newValue, forKey: "tuningOpen") }
    }
    var lastScreenCount = NSScreen.screens.count
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
                if ok { self.refreshCameras(); self.startSession(); self.refreshBackgrounds() }
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 760),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "NoGreenBack"
        window.subtitle = "Syphon: NoGreenBack"
        window.contentMinSize = NSSize(width: 900, height: 560)
        // メニューバーのある画面 (主ディスプレイ) の中央に出す。
        // center() だと、液晶タブレットなど別の画面に出ることがある
        let home = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? .zero
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: home.midX - size.width / 2, y: home.midY - size.height / 2))

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
        deflicker.toolTip = "照明のフリッカーによる画面全体の明滅をならします (横じまは消せません)"

        let feather = NSSlider(value: settings.feather, minValue: 0, maxValue: 6,
                               target: self, action: #selector(featherChanged(_:)))

        let mirror = NSButton(checkboxWithTitle: "左右反転", target: self, action: #selector(mirrorChanged(_:)))
        let flip = NSButton(checkboxWithTitle: "上下反転", target: self, action: #selector(flipChanged(_:)))
        flip.state = settings.flipVertical ? .on : .off
        let straight = NSButton(checkboxWithTitle: "ストレートα", target: self, action: #selector(alphaChanged(_:)))
        straight.toolTip = "オフ: プリマルチプライドα (既定) / オン: ストレートα。受信側で縁が黒くなる・白くなる場合に切り替え"

        let smoothing = NSSlider(value: settings.smoothing, minValue: 0, maxValue: 1,
                                 target: self, action: #selector(smoothingChanged(_:)))
        smoothing.toolTip = "上げるほど輪郭のちらつきが減ります。上げすぎると動いたときに残像が出ます"
        let tighten = NSSlider(value: settings.tighten, minValue: 0, maxValue: 1,
                               target: self, action: #selector(tightenChanged(_:)))
        tighten.toolTip = "上げるほど半透明の縁 (背景のにじみ) が減り、輪郭がくっきりします"

        let hold = NSSlider(value: settings.hold, minValue: 0, maxValue: 1,
                            target: self, action: #selector(holdChanged(_:)))
        hold.toolTip = "上げるほど、手をかざしたときなどに体の一部が一瞬消える現象を抑えます。上げすぎると、移動した後に元の位置がうっすら残ります"

        fpsLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        // 3 段目: 画面に重ねる表示
        overlay = OverlayWindow(processor: processor)
        overlayCheck = toolbarToggle("画面に表示", #selector(overlayToggled(_:)))
        overlayCheck.state = overlayOn ? .on : .off
        overlayCheck.toolTip = "切り抜いた人物を、デスクトップの隅に常に手前で重ねます (クリックは後ろのアプリに届きます)"
        personButton = toolbarToggle("人物", #selector(personToggled(_:)))
        personButton.state = personOn ? .on : .off
        personButton.toolTip = "人物を出し入れします (全画面出力・プレビュー・Syphon・画面に重ねる表示のすべて)。オフにすると背景だけになります。\(HotKeys.modifierSymbols)P"
        let cornerPopup = NSPopUpButton()
        cornerPopup.addItems(withTitles: OverlayWindow.Corner.allCases.map(\.title))
        cornerPopup.selectItem(at: overlayCorner.rawValue)
        cornerPopup.target = self
        cornerPopup.action = #selector(cornerChanged(_:))
        let sizeSlider = NSSlider(value: overlayScale, minValue: 0.15, maxValue: 0.8,
                                  target: self, action: #selector(overlaySizeChanged(_:)))
        sizeSlider.toolTip = "画面の幅に対する大きさ"
        screenPopup.target = self
        screenPopup.action = #selector(screenChanged(_:))
        refreshScreens()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        }
        recordButton = ToggleButton(title: "● 録画開始", target: self, action: #selector(recordToggled))
        recordButton.onColor = .systemRed
        recordButton.toolTip = "「録画する画面」を録画して、ムービーフォルダに保存します (このウィンドウは映りません)。\(HotKeys.modifierSymbols)R でも開始・停止できます"
        // 「録画開始」と「録画停止」で幅が変わらないよう、広いほうに合わせる
        var recordWidth: CGFloat = 0
        for t in ["■ 録画停止", "● 録画開始"] {
            recordButton.title = t
            recordWidth = max(recordWidth, recordButton.intrinsicContentSize.width)
        }
        recordButton.widthAnchor.constraint(equalToConstant: recordWidth).isActive = true
        micPopup.target = self
        micPopup.action = #selector(micChanged(_:))
        micPopup.toolTip = "録画に入れるマイクの音声"
        // マイクの入力レベル (緑 → 黄 → 赤)。-60dB〜0dB を 0〜30 目盛りで表示
        micLevel.levelIndicatorStyle = .continuousCapacity
        micLevel.minValue = 0
        micLevel.maxValue = 30
        micLevel.warningValue = 24     // -12dB
        micLevel.criticalValue = 28    // -4dB
        micLevel.widthAnchor.constraint(equalToConstant: 70).isActive = true
        micLevel.toolTip = "マイクの入力レベル。話したときに緑〜黄色まで振れればちょうどよい音量です"
        let lt = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            // 録画中は録画側のマイクの音で、それ以外はメーター用に開いたマイクで測る
            var db = Double(self.micMeter.level)
            if #available(macOS 12.3, *), let rec = self.recorder as? ScreenRecorder { db = Double(rec.level) }
            // 減るときはゆっくり落とす (針がちらつかないように)
            let v = max(0, min(30, (db + 60) / 2))
            self.micLevel.doubleValue = v >= self.micLevel.doubleValue ? v : max(v, self.micLevel.doubleValue - 1.5)
            // 約 2 秒ごとに、システムの入力が切り替わっていないか見る
            self.micCheckTick += 1
            if self.micCheckTick % 30 == 0 { self.followSystemMic() }
        }
        RunLoop.main.add(lt, forMode: .common)
        micLevelTimer = lt
        refreshMics()
        // メーター用のマイクは、このアプリを操作している間だけ開く。
        // Bluetooth のイヤホンはマイクを開いている間「通話用」の低音質になるため、
        // 開きっぱなしだと QuickTime などで再生した音がノイズまじりに聞こえる
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.micMeter.stop()
            self?.micLevel.doubleValue = 0
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.startMeter()
        }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshMics()
                self?.refreshBackgrounds()
            }
        }
        recordLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        recordLabel.textColor = .systemRed
        // 経過時間の欄は幅を固定する (数字が変わるたびに右のボタンが動かないように)
        recordLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true
        recordLabel.lineBreakMode = .byClipping
        if #unavailable(macOS 12.3) {
            recordButton.isEnabled = false
            recordButton.toolTip = "画面録画には macOS 12.3 以降が必要です"
        }
        placeOverlay()
        updateOverlayVisibility()

        // 4 段目: 手書きの注釈
        annotation = Annotations()
        annotation.color = penColors[penColorIndex].color
        annotation.lineWidth = CGFloat(penWidth)
        annotation.fadeAfter = fadeTimes[fadeIndex].seconds
        annotation.coverAllScreens()
        annotationCheck = toolbarToggle("手書き", #selector(annotationToggled(_:)))
        annotationCheck.state = annotationOn ? .on : .off
        annotationCheck.toolTip = "選んだキーを押している間だけ、画面にペンで書けます。離すと後ろのアプリを操作できます"
        penButton = toolbarToggle("ペン固定", #selector(penButtonClicked(_:)))
        penButton.toolTip = "キーを押さなくても描ける状態にします。オンの間は後ろのアプリをクリックできません。\(HotKeys.modifierSymbols)D"
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
        let fadePopup = NSPopUpButton()
        fadePopup.addItems(withTitles: fadeTimes.map(\.title))
        fadePopup.selectItem(at: fadeIndex)
        fadePopup.target = self
        fadePopup.action = #selector(fadeChanged(_:))
        let clearButton = NSButton(title: "消去", target: self, action: #selector(clearAnnotation))
        clearButton.controlSize = .large
        clearButton.toolTip = "手書きを全部消します。\(HotKeys.modifierSymbols)C でも消せます"
        setAnnotationVisible(annotationOn)

        // 5 段目: 背景映像と全画面出力
        bgPopup.target = self
        bgPopup.action = #selector(backgroundChanged(_:))
        bgPopup.toolTip = "USB キャプチャーなどの映像を人物の後ろに敷きます"
        outputCheck = toolbarToggle("全画面で出す", #selector(outputToggled(_:)))
        outputCheck.toolTip = "合成した映像を、選んだ画面いっぱいに表示します。Esc か \(HotKeys.modifierSymbols)F で閉じます"
        outputScreenPopup.target = self
        outputScreenPopup.action = #selector(outputScreenChanged(_:))
        recordScreenPopup.target = self
        recordScreenPopup.action = #selector(recordScreenChanged(_:))
        recordScreenPopup.toolTip = "「● 録画開始」で録画する画面"
        refreshScreens()

        // 6 段目: 録画の設定 (数値で選ぶ)
        func popup(_ titles: [String], _ index: Int, _ action: Selector, _ tip: String) -> NSPopUpButton {
            let p = NSPopUpButton()
            p.addItems(withTitles: titles)
            p.selectItem(at: max(0, index))
            p.target = self
            p.action = action
            p.toolTip = tip
            return p
        }
        let rs = recordSettings
        let mbpsPopup = popup(RecordSettings.videoMbpsChoices.map { "\($0) Mbps" },
                              RecordSettings.videoMbpsChoices.firstIndex(of: rs.videoMbps) ?? 2,
                              #selector(recordMbpsChanged(_:)), "映像の平均ビットレート。上げるほど文字や動きがきれいになり、ファイルが大きくなります")
        let sizePopup = popup(RecordSettings.maxLongSideChoices.map { $0 > 0 ? "\($0)" : "縮めない" },
                              RecordSettings.maxLongSideChoices.firstIndex(of: rs.maxLongSide) ?? 1,
                              #selector(recordSizeChanged(_:)), "録画の長辺のピクセル数 (画面のほうが小さいときは画面のまま)。1920 で 1080p 相当")
        let recFPSPopup = popup(RecordSettings.fpsChoices.map { "\($0) fps" },
                             RecordSettings.fpsChoices.firstIndex(of: rs.fps) ?? 2,
                             #selector(recordFPSChanged(_:)), "最大フレームレート (画面が動かない間はコマ数が減ります)")
        let codecPopup = popup(["H.264", "HEVC (H.265)"], rs.hevc ? 1 : 0,
                               #selector(recordCodecChanged(_:)), "同じ Mbps なら HEVC のほうが高画質 (ファイルの大きさは Mbps で決まります)。古い Mac や一部の編集ソフトでは開けないことがあります")
        let audioPopup = popup(RecordSettings.audioKbpsChoices.map { "\($0) kbps" },
                               RecordSettings.audioKbpsChoices.firstIndex(of: rs.audioKbps) ?? 2,
                               #selector(recordAudioChanged(_:)), "音声 (AAC・48kHz・モノラル) のビットレート")
        recordSizeLabel.textColor = .secondaryLabelColor
        recordSizeLabel.font = .systemFont(ofSize: 11)
        updateRecordSizeLabel()
        helpButton = NSButton(title: "", target: self, action: #selector(showShortcuts(_:)))
        helpButton.bezelStyle = .helpButton
        helpButton.toolTip = "ショートカットの一覧 (⌘/)"

        // 上部: 本番中に触るボタンだけを並べる (オンのときは色が付く)
        let toolbar = NSStackView(views: [
            personButton, outputCheck, overlayCheck, toolbarSeparator(),
            annotationCheck, penButton, clearButton, NSView(),
            recordButton, recordLabel, fpsLabel, helpButton,
        ])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        fpsLabel.textColor = .secondaryLabelColor
        // フレームレートも幅を固定して右端にそろえる (数字が変わってもボタンが動かないように)
        fpsLabel.alignment = .right
        fpsLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true

        // 右側: 設定を見出しごとに縦に並べる
        // 反転とストレートα は 1 行に並べ、右端をポップアップにそろえる
        let mirrors = NSStackView()
        for v in [mirror, flip, straight] { mirrors.addView(v, in: .trailing) }
        mirrors.spacing = 14
        // 映像と音声のビットレートは 1 行に並べる
        let rateRow = NSStackView(views: [mbpsPopup, NSTextField(labelWithString: "音声"), audioPopup])
        rateRow.spacing = 6
        mbpsPopup.widthAnchor.constraint(equalToConstant: 92).isActive = true
        audioPopup.widthAnchor.constraint(equalToConstant: 104).isActive = true
        let micRow = NSStackView(views: [micPopup, micLevel])
        micRow.spacing = 6
        micPopup.widthAnchor.constraint(equalToConstant: sideControlWidth - 76).isActive = true
        let tuning = sideGrid([
            ("ちらつき抑制", smoothing), ("消失の保持", hold), ("境界の締まり", tighten),
            ("境界ぼかし", feather), ("明るさ安定化", deflicker),
        ])
        tuning.isHidden = !tuningOpen
        let sections: [NSView] = [
            sectionHeader("カメラ"),
            sideGrid([("カメラ", cameraPopup), ("品質", quality), ("フレームレート", fpsPopup)]),
            mirrors,
            collapsibleSection("切り抜きの調整", content: tuning),
            sectionHeader("人物の位置と大きさ"),
            sideGrid([("位置", cornerPopup), ("大きさ", sizeSlider), ("表示する画面", screenPopup)]),
            sectionHeader("背景と全画面出力"),
            sideGrid([("背景映像", bgPopup), ("出す画面", outputScreenPopup)]),
            sectionHeader("手書き"),
            sideGrid([("描くキー", keyPopup), ("色", colorPopup), ("太さ", widthSlider),
                      ("線を消す", fadePopup)]),
            sectionHeader("録画"),
            sideGrid([("録画する画面", recordScreenPopup), ("マイク", micRow), ("映像", rateRow),
                      ("長辺", sizePopup), ("フレームレート", recFPSPopup), ("形式", codecPopup)]),
            recordSizeLabel,
        ]
        let side = NSStackView(views: sections)
        side.orientation = .vertical
        side.alignment = .leading
        side.spacing = 6
        side.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 16, right: 14)
        mirrors.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -6).isActive = true
        for v in [mirror, flip, straight] { v.font = .systemFont(ofSize: NSFont.systemFontSize) }
        // 見出しの上は少し空ける
        for (k, v) in sections.enumerated() where k > 0 && v.identifier?.rawValue == "header" {
            side.setCustomSpacing(16, after: sections[k - 1])
        }
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        side.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(side)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            side.topAnchor.constraint(equalTo: doc.topAnchor),
            side.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            side.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            side.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scroll.widthAnchor.constraint(equalToConstant: sideControlWidth + 140),
        ])
        let sideBack = NSVisualEffectView()
        sideBack.material = .sidebar
        sideBack.blendingMode = .behindWindow
        sideBack.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: sideBack.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: sideBack.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: sideBack.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sideBack.trailingAnchor),
        ])

        let separator = NSBox()
        separator.boxType = .separator
        let main = NSStackView(views: [preview, sideBack])
        main.orientation = .horizontal
        main.spacing = 0
        main.alignment = .top
        main.distribution = .fill
        preview.setContentHuggingPriority(.defaultLow, for: .horizontal)
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sideBack.setContentHuggingPriority(.required, for: .horizontal)
        preview.heightAnchor.constraint(equalTo: main.heightAnchor).isActive = true
        sideBack.heightAnchor.constraint(equalTo: main.heightAnchor).isActive = true

        let root = NSStackView(views: [toolbar, separator, main])
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .leading
        for v in [toolbar, separator, main] as [NSView] {
            v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        main.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = root
        // 画面に重ねた表示が残っていても、メインウィンドウを閉じたら終了する
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window, queue: .main) { _ in NSApp.terminate(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        registerHotKeys()
    }

    // MARK: 画面の部品

    /// サイドバーのポップアップやスライダーの幅
    let sideControlWidth: CGFloat = 232

    /// 上部に並べる、押すとオン・オフが切り替わるボタン
    func toolbarToggle(_ title: String, _ action: Selector) -> NSButton {
        ToggleButton(title: title, target: self, action: action)
    }

    func toolbarSeparator() -> NSView {
        let b = NSBox()
        b.boxType = .separator
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return b
    }

    func sectionHeader(_ title: String) -> NSTextField {
        let t = NSTextField(labelWithString: title)
        t.font = .boldSystemFont(ofSize: 13)
        t.identifier = NSUserInterfaceItemIdentifier("header")
        return t
    }

    /// 開け閉めできる見出しと中身 (あまり触らない設定をしまっておく)
    func collapsibleSection(_ title: String, content: NSView) -> NSView {
        let tri = NSButton(title: "", target: self, action: #selector(disclosureClicked(_:)))
        tri.bezelStyle = .disclosure
        tri.setButtonType(.pushOnPushOff)
        tri.state = content.isHidden ? .off : .on
        disclosureTargets[ObjectIdentifier(tri)] = content
        let label = NSButton(title: title, target: tri, action: #selector(NSButton.performClick(_:)))
        label.isBordered = false
        label.font = .boldSystemFont(ofSize: 13)
        label.contentTintColor = .labelColor
        let row = NSStackView(views: [tri, label])
        row.spacing = 2
        let section = NSStackView(views: [row, content])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6
        section.identifier = NSUserInterfaceItemIdentifier("header")
        return section
    }
    var disclosureTargets: [ObjectIdentifier: NSView] = [:]
    @objc func disclosureClicked(_ sender: NSButton) {
        disclosureTargets[ObjectIdentifier(sender)]?.isHidden = sender.state == .off
        tuningOpen = sender.state == .on
    }

    /// 左に名前、右に部品を揃えて並べる
    func sideGrid(_ rows: [(String, NSView)]) -> NSGridView {
        let g = NSGridView(views: rows.map { title, view -> [NSView] in
            if view is NSPopUpButton || view is NSSlider {
                view.widthAnchor.constraint(equalToConstant: sideControlWidth).isActive = true
            }
            return [NSTextField(labelWithString: title), view]
        })
        g.column(at: 0).xPlacement = .trailing
        g.column(at: 0).width = 96
        g.rowAlignment = .firstBaseline
        g.rowSpacing = 6
        g.columnSpacing = 8
        return g
    }

    @objc func penButtonClicked(_ sender: NSButton) {
        // togglePen が penLatched を反転させるので、押す前の状態に戻してから呼ぶ
        sender.state = penLatched ? .on : .off
        togglePen()
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
        // 未設定なら主ディスプレイ (NSScreen.main は操作中の画面で変わるので使わない)
        NSScreen.screens.first { $0.localizedName == overlayScreenName } ?? NSScreen.screens[0]
    }

    /// 録画する画面 (未設定、またはその画面が外れていたら「表示する画面」)
    var recordScreen: NSScreen {
        NSScreen.screens.first { $0.localizedName == recordScreenName } ?? overlayScreen
    }

    @objc func recordScreenChanged(_ sender: NSPopUpButton) {
        recordScreenName = sender.indexOfSelectedItem > 0 ? sender.titleOfSelectedItem : nil
    }

    func refreshScreens() {
        screenPopup.removeAllItems()
        screenPopup.addItems(withTitles: NSScreen.screens.map(\.localizedName))
        screenPopup.selectItem(withTitle: overlayScreen.localizedName)
        outputScreenPopup.removeAllItems()
        outputScreenPopup.addItems(withTitles: NSScreen.screens.map(\.localizedName))
        outputScreenPopup.selectItem(withTitle: outputScreen.localizedName)
        recordScreenPopup.removeAllItems()
        recordScreenPopup.addItem(withTitle: "表示する画面と同じ")
        recordScreenPopup.addItems(withTitles: NSScreen.screens.map(\.localizedName))
        if let name = recordScreenName, NSScreen.screens.contains(where: { $0.localizedName == name }) {
            recordScreenPopup.selectItem(withTitle: name)
        } else {
            recordScreenPopup.selectItem(at: 0)
        }
    }

    // MARK: 背景映像と全画面出力

    /// 全画面出力の画面 (未設定なら、メイン以外の画面があればそちら = プロジェクターなど)
    var outputScreen: NSScreen {
        NSScreen.screens.first { $0.localizedName == outputScreenName }
            ?? NSScreen.screens.dropFirst().first ?? NSScreen.screens[0]
    }

    func refreshBackgrounds() {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) { types += [.external, .continuityCamera] }
        else { types.append(.externalUnknown) }
        bgDevices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video,
                                                     position: .unspecified).devices
        bgPopup.removeAllItems()
        bgPopup.addItem(withTitle: "なし（透明）")
        bgPopup.addItems(withTitles: bgDevices.map(\.localizedName))
        let i = bgDevices.firstIndex { $0.uniqueID == backgroundID }
        bgPopup.selectItem(at: i.map { $0 + 1 } ?? 0)
        applyBackground()
    }

    func applyBackground() {
        let i = bgPopup.indexOfSelectedItem
        let device = i > 0 && i - 1 < bgDevices.count ? bgDevices[i - 1] : nil
        do {
            try processor.background.start(device)
        } catch {
            showAlert("背景映像を開けません: \(error.localizedDescription)")
            bgPopup.selectItem(at: 0)
            try? processor.background.start(nil)
        }
    }

    @objc func backgroundChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        backgroundID = i > 0 ? bgDevices[i - 1].uniqueID : nil
        applyBackground()
    }

    @objc func outputToggled(_ sender: NSButton) { setOutputVisible(sender.state == .on) }

    func toggleOutput() { setOutputVisible(outputWindow == nil) }

    func setOutputVisible(_ on: Bool) {
        outputCheck.state = on ? .on : .off
        if on {
            outputWindow?.orderOut(nil)
            let w = OutputWindow(processor: processor, screen: outputScreen)
            w.onClose = { [weak self] in self?.setOutputVisible(false) }
            outputWindow = w
            w.show(on: outputScreen)
        } else {
            outputWindow?.orderOut(nil)
            outputWindow = nil
        }
        updateOverlayVisibility()
    }

    func placeOutput() {
        guard let w = outputWindow else { return }
        if let name = w.screenName, !NSScreen.screens.contains(where: { $0.localizedName == name }) {
            // 出していた画面 (液晶タブレットやプロジェクター) が外れたら閉じる。
            // 残った画面に出し直すと、メニューバーごと画面を覆って操作できなくなるため
            setOutputVisible(false)
        } else {
            setOutputVisible(true)   // 画面を替えたら作り直す
        }
    }

    /// 画面をつないだり外したりしたとき
    func screensChanged() {
        if NSScreen.screens.count < lastScreenCount, penLatched {
            // 画面が外れたらペンモードを解除する (手書きがクリックを受け止めたままにならないように)
            penLatched = false
            annotation?.setDrawing(false)
        }
        lastScreenCount = NSScreen.screens.count
        refreshScreens()
        placeOverlay()
        placeOutput()
    }

    @objc func outputScreenChanged(_ sender: NSPopUpButton) {
        outputScreenName = sender.titleOfSelectedItem
        placeOutput()
    }

    /// 全画面出力が同じ画面に出ている間は、重ねる表示を隠す (出力の中にもう人物が入っているので)
    func updateOverlayVisibility() {
        let covered = outputWindow != nil && outputScreen == overlayScreen
        overlay?.setVisible(overlayOn && personOn && !covered)
        settings.showPerson = personOn
    }

    func placeOverlay() {
        settings.pipCorner = overlayCorner.rawValue
        settings.pipScale = overlayScale
        overlay?.place(on: overlayScreen, corner: overlayCorner, scale: overlayScale)
        annotation?.coverAllScreens()
    }

    // MARK: 全体で効くショートカット (Stream Deck の「ホットキー」から使う)

    /// (キー, キーコード, 内容, 動作)
    var hotKeyList: [(key: String, code: Int, title: String, action: () -> Void)] {
        [
            ("R", kVK_ANSI_R, "録画の開始・停止", { [weak self] in self?.recordToggled() }),
            ("P", kVK_ANSI_P, "人物の表示・非表示", { [weak self] in self?.togglePerson() }),
            ("C", kVK_ANSI_C, "手書きを全部消す", { [weak self] in self?.annotation.clear() }),
            ("D", kVK_ANSI_D, "ペン (描画モード) のオン・オフ", { [weak self] in self?.togglePen() }),
            ("K", kVK_ANSI_K, "ペンの色を次の色へ", { [weak self] in self?.nextPenColor() }),
            ("F", kVK_ANSI_F, "全画面出力の表示・非表示", { [weak self] in self?.toggleOutput() }),
        ]
    }

    func registerHotKeys() {
        let keys = HotKeys()
        var failed: [String] = []
        for k in hotKeyList where !keys.register(keyCode: k.code, k.action) {
            failed.append("\(HotKeys.modifierSymbols)\(k.key)（\(k.title)）")
            failedHotKeys.insert(k.key)
        }
        hotKeys = keys
        if !failed.isEmpty {
            showAlert("次のショートカットは他のアプリが使っているため登録できませんでした:\n" + failed.joined(separator: "\n"))
        }
    }

    // MARK: ショートカット一覧

    /// 他のアプリが使っていて登録できなかったキー
    var failedHotKeys: Set<String> = []
    var helpButton = NSButton()
    var shortcutPopover: NSPopover?

    @objc func showShortcuts(_ sender: Any?) {
        if let p = shortcutPopover, p.isShown { p.close(); return }
        func cell(_ text: String, bold: Bool = false, dim: Bool = false) -> NSTextField {
            let t = NSTextField(labelWithString: text)
            t.font = bold ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 13)
            if dim { t.textColor = .secondaryLabelColor }
            return t
        }
        func header(_ text: String) -> NSTextField {
            let t = NSTextField(labelWithString: text)
            t.font = .boldSystemFont(ofSize: 13)
            return t
        }
        var rows: [[NSView]] = []
        for k in hotKeyList {
            let used = failedHotKeys.contains(k.key)
            rows.append([cell("\(HotKeys.modifierSymbols) \(k.key)", bold: true, dim: used),
                         cell(k.title + (used ? "（他のアプリが使用中のため使えません）" : ""), dim: used)])
        }
        let drawKey = drawKeys[drawKeyIndex].title.components(separatedBy: " ").first ?? ""
        let note = NSTextField(wrappingLabelWithString: "上の 6 つは、他のアプリを操作中でも効きます。Stream Deck では「ホットキー」アクションにこの組み合わせを設定します。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 400
        // 見出しも説明も 1 つの表に入れて、左右の位置をそろえる
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        func addMerged(_ v: NSView, space: CGFloat) {
            let r = grid.addRow(with: [v, NSGridCell.emptyContentView])
            r.mergeCells(in: NSRange(location: 0, length: 2))
            r.topPadding = space
        }
        addMerged(header("どこからでも使えるショートカット"), space: 0)
        rows.forEach { grid.addRow(with: $0) }
        addMerged(header("NoGreenBack の操作"), space: 12)
        for r in [[cell("\(drawKey) を押しながら", bold: true), cell("ドラッグで描く（手書きがオンのとき）")],
                  [cell("\(drawKey) を 2 回", bold: true), cell("手書きを全部消す")],
                  [cell("\(drawKey) ＋ 右クリック", bold: true), cell("手書きを全部消す")],
                  [cell("Esc", bold: true), cell("全画面出力を閉じる（全画面出力を操作中のとき）")],
                  [cell("⌘ Q", bold: true), cell("終了")]] { grid.addRow(with: r) }
        addMerged(note, space: 12)
        grid.rowSpacing = 6
        grid.columnSpacing = 20
        grid.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: box.topAnchor, constant: 16),
            grid.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -16),
            grid.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -18),
        ])
        let vc = NSViewController()
        vc.view = box
        vc.preferredContentSize = box.fittingSize
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = vc
        shortcutPopover = p
        window.makeKeyAndOrderFront(nil)
        p.show(relativeTo: helpButton.bounds, of: helpButton, preferredEdge: .maxY)
    }

    func togglePerson() {
        personButton.state = personOn ? .off : .on
        personToggled(personButton)
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

    func refreshMics() {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) { types = [.microphone, .external] }
        else { types = [.builtInMicrophone, .externalUnknown] }
        micDevices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified).devices
        micPopup.removeAllItems()
        micPopup.addItem(withTitle: "なし")
        micPopup.addItem(withTitle: systemMicTitle)
        micPopup.addItems(withTitles: micDevices.map(\.localizedName))
        if !recordMic {
            micPopup.selectItem(at: 0)
        } else if let i = micDevices.firstIndex(where: { $0.uniqueID == recordMicID }) {
            micPopup.selectItem(at: i + 2)
        } else {
            // 「システムの設定に合わせる」、または選んでいたマイクが外れているとき
            micPopup.selectItem(at: 1)
        }
        startMeter()
    }

    /// メーター用にマイクを開く (録画中は録画側の音を使うので開かない)
    func startMeter() {
        if recorder != nil || !NSApp.isActive { return }
        micMeter.start(selectedMic)
    }

    /// 「システムの設定に合わせる」の表示 (今使われるマイクの名前を添える)
    var systemMicTitle: String {
        "システムの設定（\(AVCaptureDevice.default(for: .audio)?.localizedName ?? "なし")）"
    }

    /// システムの入力 (サウンド設定) が変わっていたら、表示とメーターを合わせる
    func followSystemMic() {
        guard micPopup.indexOfSelectedItem == 1, micPopup.numberOfItems > 1 else { return }
        let title = systemMicTitle
        if micPopup.item(at: 1)?.title != title { micPopup.item(at: 1)?.title = title }
        if micMeter.device?.uniqueID != selectedMic?.uniqueID { startMeter() }
    }

    @objc func micChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        recordMic = i > 0
        recordMicID = i >= 2 ? micDevices[i - 2].uniqueID : nil   // nil = システムの設定に合わせる
        startMeter()
    }

    /// 録画に使うマイク (なしなら nil)
    var selectedMic: AVCaptureDevice? {
        let i = micPopup.indexOfSelectedItem
        if i == 1 { return AVCaptureDevice.default(for: .audio) }
        return i >= 2 && i - 2 < micDevices.count ? micDevices[i - 2] : nil
    }

    @objc func recordToggled() {
        guard #available(macOS 12.3, *) else { return }
        // 押した時点では色を変えず、録画が始まった・止まったときに合わせる
        recordButton.state = recorder != nil ? .on : .off
        recordButton.isEnabled = false
        if let rec = recorder as? ScreenRecorder {
            // 停止 (MP4 への詰め替えが終わるまで「保存中」と出す)
            recordTimer?.invalidate()
            recordLabel.stringValue = "保存中…"
            Task { @MainActor in
                let url = await rec.stop()
                self.recorder = nil
                self.startMeter()
                self.recordTimer?.invalidate()
                self.recordLabel.stringValue = ""
                self.recordButton.title = "● 録画開始"
                self.recordButton.state = .off
                self.recordButton.isEnabled = true
                if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                else { self.showAlert("画面に変化がなかったため、録画は保存されませんでした。") }
                if url != nil, rec.recordsAudio, rec.audioSamplesWritten == 0 {
                    self.showAlert("マイクの音が届いていなかったため、録画には音が入っていません。\n「マイク」の選択と、右のメーターが動くかを確かめてください。")
                }
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
                    _ = try await rec.start(screen: self.recordScreen,
                                            excluding: [self.window.windowNumber],
                                            microphone: self.selectedMic,
                                            settings: self.recordSettings)
                    self.recorder = rec
                    // 録画中はメーター用にマイクを開かない (Bluetooth マイクは 2 か所から開くと途切れる)
                    self.micMeter.stop()
                    self.recordButton.title = "■ 録画停止"
                    self.recordButton.state = .on
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
        guard on else { annotation.orderOut(); return }
        annotation.coverAllScreens()
        annotation.orderFront()
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
                strokesAtPress = self.annotation.strokeCount
            } else if !down && wasDown {
                let isTap = now.timeIntervalSince(pressStart) < 0.3
                    && self.annotation.strokeCount == strokesAtPress
                if isTap && pressStart.timeIntervalSince(lastTap) < 0.4 {
                    self.annotation.clear()
                    lastTap = .distantPast
                } else {
                    lastTap = isTap ? now : .distantPast
                }
            }
            wasDown = down
            self.annotation.setDrawing(down || self.penLatched)
            self.annotation.tick()
            // 定期的に最前面へ戻す (1 秒ごと)
            frontCount += 1
            if frontCount >= 60 { frontCount = 0; self.annotation.orderFront() }
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
        annotation.color = penColors[penColorIndex].color
    }
    @objc func penWidthChanged(_ sender: NSSlider) {
        penWidth = sender.doubleValue
        annotation.lineWidth = CGFloat(penWidth)
    }
    @objc func fadeChanged(_ sender: NSPopUpButton) {
        fadeIndex = sender.indexOfSelectedItem
        annotation.fadeAfter = fadeTimes[fadeIndex].seconds
    }
    @objc func clearAnnotation() { annotation.clear() }

    @objc func personToggled(_ sender: NSButton) {
        personOn = sender.state == .on
        updateOverlayVisibility()
    }
    @objc func overlayToggled(_ sender: NSButton) {
        overlayOn = sender.state == .on
        placeOverlay()
        updateOverlayVisibility()
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
        defer { updateOverlayVisibility() }
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
let helpItem = NSMenuItem()
mainMenu.addItem(helpItem)
let helpMenu = NSMenu(title: "ヘルプ")
let shortcutItem = helpMenu.addItem(withTitle: "ショートカットの一覧", action: #selector(AppDelegate.showShortcuts(_:)), keyEquivalent: "/")
shortcutItem.target = delegate
helpItem.submenu = helpMenu
app.mainMenu = mainMenu
app.helpMenu = helpMenu

app.run()
