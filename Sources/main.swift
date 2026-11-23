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
    private var _canvasAspect: Double = 0

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
    /// 背景映像があるときに人物を入れるか (「人物」・⌃⌥⌘P と連動)
    var showPerson: Bool { get { get { _showPerson } } set { set { _showPerson = newValue } } }
    /// 合成した映像の横縦比 (0 = カメラの比率のまま)。全画面で出す画面の比率に合わせるときに使う
    var canvasAspect: Double { get { get { _canvasAspect } } set { set { _canvasAspect = newValue } } }
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
    private let frameLock = NSLock()
    private var _lastFrameTime: CFAbsoluteTime = 0
    /// 最後にカメラのフレームが届いた時刻 (映像が止まったのを見つけるため)
    var lastFrameTime: CFAbsoluteTime { frameLock.withLock { _lastFrameTime } }

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
    /// 新しいフレームができたときに描き直す表示 (プレビュー・全画面出力・画面に重ねる表示)。
    /// 60 回/秒で描き続けるのをやめ、カメラのコマに合わせて描く (高解像度の画面でカクつかないように)
    private let views = NSHashTable<MTKView>.weakObjects()
    private var redrawPending = false
    /// 映像の下に重ねる字幕の文字 (空なら出さない)
    private var _subtitle = ""
    private var subtitleCache: (text: String, images: [String: CIImage])?

    /// 字幕の画像 (文字と大きさ・置く場所が同じあいだは作り直さない)
    private func subtitleImage(_ text: String, extent: CGRect, person: ClosedRange<CGFloat>? = nil,
                               bottom: CGFloat? = nil) -> CIImage? {
        if subtitleCache?.text != text { subtitleCache = (text, [:]) }
        let key = "\(Int(extent.width))x\(Int(extent.height)) \(person.map { "\(Int($0.lowerBound))-\(Int($0.upperBound))" } ?? "") \(bottom.map { Int($0) } ?? -1)"
        if let img = subtitleCache?.images[key] { return img }
        let img = SubtitleRenderer.image(text: text, extent: extent, person: person, bottom: bottom)
        subtitleCache?.images[key] = img
        return img
    }
    var subtitle: String {
        get { previewLock.lock(); defer { previewLock.unlock() }; return _subtitle }
        set { previewLock.lock(); _subtitle = newValue; previewLock.unlock() }
    }
    private var _annotationImage: CIImage?
    /// 全画面出力の上に描いた手書きの線 (合成した映像と同じ座標)。プレビューと Syphon にも重ねる
    var annotationImage: CIImage? {
        get { previewLock.lock(); defer { previewLock.unlock() }; return _annotationImage }
        set { previewLock.lock(); _annotationImage = newValue; previewLock.unlock() }
    }
    private var _pointer: (tip: CGPoint, angle: CGFloat)?
    /// 指し棒の画像 (先と傾きが同じあいだは作り直さない)
    private var pointerCache: (key: String, image: CIImage?)?
    /// 指し棒の先 (合成した映像の座標) と傾き (度)。nil なら出さない
    var pointer: (tip: CGPoint, angle: CGFloat)? {
        get { previewLock.lock(); defer { previewLock.unlock() }; return _pointer }
        set { previewLock.lock(); _pointer = newValue; previewLock.unlock() }
    }
    private var _board: Double?
    /// ホワイトボードの濃さ 0...1 (nil なら出さない)。背景の上・人物の後ろに半透明の白い板を敷く
    var board: Double? {
        get { previewLock.lock(); defer { previewLock.unlock() }; return _board }
        set { previewLock.lock(); _board = newValue; previewLock.unlock() }
    }
    /// 映像に重ねるキーボード (nil なら出さない)。大きさは映像の横幅に対する割合
    private var _keyboard:(scale: Double, position: KeyboardRenderer.Position)?
    private var keyboardCache: (key: String, image: CIImage?)?
    var keyboard: (scale: Double, position: KeyboardRenderer.Position)? {
        get { previewLock.lock(); defer { previewLock.unlock() }; return _keyboard }
        set { previewLock.lock(); _keyboard = newValue; previewLock.unlock() }
    }
    /// キーボードの画像 (映像の大きさと設定が同じあいだは作り直さない)
    /// person は人物の左右の範囲 (「人物の反対側」のとき、すき間の真ん中に置くため)
    private func keyboardImage(extent: CGRect, person: ClosedRange<CGFloat>) -> CIImage? {
        guard let k = keyboard else { return nil }
        let key = "\(Int(extent.width))x\(Int(extent.height)) \(k.scale) \(k.position.rawValue) \(Int(person.lowerBound))-\(Int(person.upperBound)) \(KeyboardRenderer.layout.rawValue)"
        if keyboardCache?.key != key {
            keyboardCache = (key, KeyboardRenderer.ciImage(extent: extent, scale: k.scale, position: k.position,
                                                           person: person))
        }
        return keyboardCache?.image
    }
    func addView(_ v: MTKView) {
        v.isPaused = true
        v.enableSetNeedsDisplay = false
        views.add(v)
    }
    private func requestRedraw() {
        previewLock.lock()
        let busy = redrawPending
        redrawPending = true
        previewLock.unlock()
        if busy { return }   // 前の描画がまだなら、まとめて 1 回にする
        DispatchQueue.main.async { [self] in
            previewLock.lock(); redrawPending = false; previewLock.unlock()
            for v in views.allObjects {
                // 隠れている・閉じているウィンドウは描かない (全画面出力の裏のプレビューなど)
                guard let w = v.window, w.isVisible, w.occlusionState.contains(.visible) else { continue }
                v.draw()
            }
        }
    }
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
    private func deflickered(_ image: CIImage, pixelBuffer: CVPixelBuffer) -> CIImage {
        let strength = settings.deflicker
        guard strength > 0.01 else { lumaAverage = nil; return image }
        let e = image.extent
        // 平均の明るさは、カメラの画素を CPU で間引いて読む (64×36 点)。
        // GPU で求めて読み戻すと、毎フレーム GPU の処理が終わるのを待つことになるため
        guard let luma = Self.averageLuma(pixelBuffer) else { return image }
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

    /// BGRA の画素を間引いて読んだ平均の明るさ (0〜1)
    private static func averageLuma(_ pb: CVPixelBuffer) -> Double? {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        let nx = 64, ny = 36
        var sum = 0
        for j in 0..<ny {
            let line = base + (j * h / ny + h / ny / 2) * row
            for i in 0..<nx {
                let p = line + (i * w / nx + w / nx / 2) * 4
                // BGRA。0.114B + 0.587G + 0.299R を整数で
                sum += 29 * Int(p[0]) + 150 * Int(p[1]) + 77 * Int(p[2])
            }
        }
        // 画素の値は sRGB (ガンマ付き)。補正は Core Image の作業空間 (リニア) でかけるので、リニアに直す
        return pow(Double(sum) / Double(nx * ny * 256 * 255), 2.2)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameLock.withLock { _lastFrameTime = CFAbsoluteTimeGetCurrent() }

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
        let source = deflickered(CIImage(cvPixelBuffer: pixelBuffer), pixelBuffer: pixelBuffer)
        let extent = source.extent
        lastExtent = extent
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
        compose(cutout: cutout, extent: extent, commandBuffer: cb)

        frameCount += 1
        let now = CACurrentMediaTime()
        if now - fpsStart >= 1 {
            let fps = Double(frameCount) / (now - fpsStart)
            frameCount = 0; fpsStart = now
            onFPS?(fps)
        }
    }

    /// カメラがないとき (つないでいない・止まっている) にも、背景・字幕・手書きなどを出し続けるためのタイマー
    private var idleTimer: DispatchSourceTimer?
    /// 最後に受け取ったカメラの映像の大きさ (カメラがないときは、この大きさで合成する)
    private var lastExtent = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    /// カメラの映像が 0.5 秒以上届いていない間は、人物なしで合成して出す
    /// (カメラがないと何も描かれず、全画面出力が黒いままになるため)。
    /// queue はカメラの映像を受け取るのと同じキューにする (合成の処理が同時に走らないように)
    func startIdleRendering(on q: DispatchQueue) {
        guard idleTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 1, repeating: 1.0 / 25)
        t.setEventHandler { [weak self] in self?.renderWithoutCamera() }
        t.resume()
        idleTimer = t
    }

    private func renderWithoutCamera() {
        guard CFAbsoluteTimeGetCurrent() - lastFrameTime > 0.5, let cb = queue.makeCommandBuffer() else { return }
        compose(cutout: CIImage(color: .clear).cropped(to: lastExtent), extent: lastExtent, commandBuffer: cb)
    }

    /// 切り抜いた人物 (cutout) に背景・キーボード・手書き・指し棒・字幕を重ねて、
    /// プレビュー・全画面出力・Syphon に出す
    private func compose(cutout: CIImage, extent: CGRect, commandBuffer cb: MTLCommandBuffer) {
        var source = cutout

        // 合成する映像の大きさ。高さはカメラのまま、横幅を出す画面の比率に合わせる
        let aspect = settings.canvasAspect
        let canvas = aspect > 0
            ? CGRect(x: 0, y: 0, width: (extent.height * CGFloat(aspect) / 2).rounded() * 2, height: extent.height)
            : extent
        // 人物は「位置」「大きさ」に合わせて小さくして隅に置く (大きさは画面の高さに対する割合)
        let corner = OverlayWindow.Corner(rawValue: settings.pipCorner) ?? .bottomRight
        let ps = CGFloat(settings.pipScale)
        let pw = extent.width * ps, ph = extent.height * ps
        let px = (corner == .bottomRight || corner == .topRight) ? canvas.width - pw : 0
        let py = (corner == .bottomRight || corner == .bottomLeft) ? 0 : canvas.height - ph   // 左下原点
        let person = cutout.transformed(by: CGAffineTransform(scaleX: ps, y: ps)
            .concatenating(CGAffineTransform(translationX: px, y: py)))
        // ホワイトボード: 背景の上・人物の後ろに敷く半透明の白い板 (手書きの線を見やすくする)
        let plate = board.map { CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat($0))).cropped(to: canvas) }
        // プレビューと全画面出力に出す映像
        var display: CIImage
        if let bg = background.latestImage {
            // 背景映像は切らずに全部入るように縮めて真ん中に置く (比率が違うときの余りは黒)
            let be = bg.extent
            let s = min(canvas.width / be.width, canvas.height / be.height)
            let tx = (canvas.width - be.width * s) / 2 - be.minX * s
            let ty = (canvas.height - be.height * s) / 2 - be.minY * s
            let fitted = bg.transformed(by: CGAffineTransform(scaleX: s, y: s)
                .concatenating(CGAffineTransform(translationX: tx, y: ty)))
            let black = CIImage(color: .black).cropped(to: canvas)
            var under = fitted.composited(over: black)
            if let plate { under = plate.composited(over: under) }
            display = person.composited(over: under).cropped(to: canvas)
            source = display
        } else {
            // 背景なし: Syphon には人物を元の大きさで送り (OBS 側で配置する)、
            // プレビューと全画面出力では、背景ありのときと同じ位置・大きさにする
            // (透明な下地を敷いて、映像の大きさを元のままにする。ホワイトボードは Syphon には入れない)
            display = person.composited(over: plate ?? CIImage(color: .clear).cropped(to: canvas)).cropped(to: canvas)
        }

        // キーの説明用のキーボードを重ねる (手書きの線より下。背景があるときは Syphon にも)
        // 字幕はキーボードより上に出す (キーボードが下にあるとき)
        var keyboardTop: CGFloat?
        if let kb = keyboardImage(extent: canvas, person: px...(px + pw)) {
            if kb.extent.midY < canvas.midY { keyboardTop = kb.extent.maxY }
            display = kb.composited(over: display).cropped(to: canvas)
            if background.latestImage != nil { source = display }
        }

        // 全画面出力の上に描いた手書きを重ねる (背景があるときは Syphon にも)
        if let lines = annotationImage, lines.extent.size == canvas.size {
            display = lines.composited(over: display).cropped(to: canvas)
            if background.latestImage != nil { source = display }
        }

        // 指し棒 (全画面出力の上のマウスの位置を、人物のいる側から差し出した棒の矢印で指す)
        if let p = pointer {
            let key = "\(Int(canvas.width))x\(Int(canvas.height)) \(Int(p.tip.x)),\(Int(p.tip.y)) \(Int(p.angle * 10))"
            if pointerCache?.key != key {
                let start = PointerRenderer.base(tip: p.tip, angle: p.angle, in: canvas)
                pointerCache = (key, PointerRenderer.ciImage(extent: canvas, from: start, to: p.tip))
            }
            if let stick = pointerCache?.image {
                display = stick.composited(over: display).cropped(to: canvas)
                if background.latestImage != nil { source = display }
            }
        }

        // 字幕を下に重ねる (プレビュー・全画面出力・Syphon のすべて)。
        // 人物を出しているときは、人物にかからないよう反対側のすき間の真ん中に出す
        let text = subtitle
        if !text.isEmpty {
            let personRange: ClosedRange<CGFloat>? = settings.showPerson ? px...(px + pw) : nil
            let se = source.extent, de = display.extent
            // 背景がないときの Syphon は人物だけの映像なので、下の中央に出す
            let sourceIsCanvas = background.latestImage != nil
            if let sub = sourceIsCanvas
                ? subtitleImage(text, extent: se, person: personRange, bottom: keyboardTop)
                : subtitleImage(text, extent: se) {
                source = sub.composited(over: source).cropped(to: se)
            }
            if let sub = subtitleImage(text, extent: de, person: personRange, bottom: keyboardTop) {
                display = sub.composited(over: display).cropped(to: de)
            }
        }

        // 3) テクスチャに描画して Syphon 送出
        let w = Int(source.extent.width), h = Int(source.extent.height)
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
        requestRedraw()
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
        delegate = self
        processor.addView(self)
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
        layer?.isOpaque = false
        delegate = self
        processor.addView(self)
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
        var title: String { [L("右下"), L("左下"), L("右上"), L("左上")][rawValue] }
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
    /// 線が変わって描き直したときの知らせ (全画面出力の映像にも線を入れるため)
    var onChange: ((AnnotationView) -> Void)?

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

    /// 時間がたった線を消す (タイマーから呼ぶ)。
    /// 描き直すのは、線が消えかけている (最後の 0.5 秒) か、消えたときだけ
    /// (線が残っている間ずっと画面全体を 60 回/秒描き直さないように)
    func tick() {
        guard fadeAfter > 0, !strokes.isEmpty else { return }
        let now = Date()
        let before = strokes.count
        strokes.removeAll { s in s.finished.map { now.timeIntervalSince($0) > fadeAfter } ?? false }
        let fading = strokes.contains { s in s.finished.map { now.timeIntervalSince($0) > fadeAfter - 0.5 } ?? false }
        if fading || strokes.count != before { needsDisplay = true }
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
        onChange?(self)
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
        // 人物の表示 (OverlayWindow) より 2 つ上 (間に字幕とキーボードが入る)
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 2)
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
    /// 描ける画面の範囲 (nil ならすべての画面)。全画面出力を出している間は、
    /// 全画面出力と録画している画面だけにして、ほかの画面はマウスでふつうに操作できるようにする
    private var allowedFrames: [CGRect]?

    private func allowed(_ w: AnnotationWindow) -> Bool { allowedFrames?.contains(w.frame) ?? true }

    /// 描ける画面を決める (nil ならすべて)
    func setAllowedScreens(_ screens: [NSScreen]?) {
        allowedFrames = screens?.map(\.frame)
        windows.forEach { $0.setDrawing(drawing && allowed($0)) }
        updateVisibility(bringFront: false)
    }

    var color: NSColor = .systemRed { didSet { windows.forEach { $0.view.color = color } } }
    var lineWidth: CGFloat = 5 { didSet { windows.forEach { $0.view.lineWidth = lineWidth } } }
    var fadeAfter: TimeInterval = 0 { didSet { windows.forEach { $0.view.fadeAfter = fadeAfter } } }
    var onChange: ((AnnotationView) -> Void)? { didSet { windows.forEach { $0.view.onChange = onChange } } }
    var isShown: Bool { shown }

    /// その画面を覆っている手書きのウィンドウ
    func window(for screen: NSScreen) -> AnnotationWindow? {
        windows.first { $0.frame == screen.frame }
    }

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
            w.view.onChange = onChange
            w.cover(screen)
            w.setDrawing(drawing && allowed(w))
            return w
        }
        updateVisibility(bringFront: true)
    }

    /// 画面に出しておくのは、描ける状態 (描くキーを押している・ペン固定) か、線が残っている画面のウィンドウだけ。
    /// 何も描いていないのに画面と同じ大きさの透明なウィンドウを出しっぱなしにすると、
    /// 画面 1 枚につき数十 MB の描画用メモリを使い続けるため
    private func wants(_ w: AnnotationWindow) -> Bool { shown && allowed(w) && (drawing || !w.view.strokes.isEmpty) }

    private func updateVisibility(bringFront: Bool) {
        for w in windows {
            if wants(w) {
                if bringFront || !w.isVisible { w.orderFrontRegardless() }
            } else if w.isVisible {
                w.orderOut(nil)
                // 隠すと描き直されないので、全画面出力の映像に入れていた線もここで消す
                w.view.onChange?(w.view)
            }
        }
    }

    func clear() { windows.forEach { $0.view.clear() }; updateVisibility(bringFront: false) }
    func tick() { windows.forEach { $0.view.tick() }; updateVisibility(bringFront: false) }
    func setDrawing(_ on: Bool) {
        let changed = on != drawing
        drawing = on
        if changed && on { updateVisibility(bringFront: false) }   // 描く前に出す
        windows.forEach { $0.setDrawing(on && allowed($0)) }
        if changed && !on { updateVisibility(bringFront: false) }  // 線がなければ隠す
    }
    func orderFront() { shown = true; updateVisibility(bringFront: true) }
    func orderOut() { shown = false; windows.forEach { $0.orderOut(nil) } }
}

// MARK: - ホワイトボード (手書きの線を見やすくする半透明の板)

/// 画面全体に敷く半透明の白い板。ほかのアプリ (スライドショーも) より手前、
/// 画面に重ねる人物のすぐ後ろに置く (字幕・キーボード・手書きの線はさらに手前)。クリックは後ろへ通す
final class BoardWindow: NSPanel {
    private var keepFrontTimer: Timer?
    /// この板より手前に出しておくウィンドウ (画面に重ねる人物)
    weak var above: NSWindow?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        // 出すときに縮んだ板が広がるアニメーションをしない (一瞬、画面の縁だけ白くならないことがある)
        animationBehavior = .none
        // 人物の表示と同じ層 (Keynote や PowerPoint のスライドショーより上)
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(on screen: NSScreen, opacity: Double) {
        backgroundColor = NSColor(white: 1, alpha: opacity)
        if frame != screen.frame { setFrame(screen.frame, display: true) }
        bringFront()
        guard keepFrontTimer == nil else { return }
        // 同じ層に後から出たウィンドウ (スライドショーを始めたときなど) に隠されないよう、定期的に前へ戻す
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.bringFront() }
        RunLoop.main.add(t, forMode: .common)
        keepFrontTimer = t
    }

    func hide() {
        keepFrontTimer?.invalidate()
        keepFrontTimer = nil
        orderOut(nil)
    }

    /// 人物を出していれば、そのすぐ後ろに並べる
    private func bringFront() {
        if let above, above.isVisible { order(.below, relativeTo: above.windowNumber) } else { orderFrontRegardless() }
    }
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

/// 録画中に操作ウィンドウを Dock にしまっている間だけ出す、小さな停止ボタン。
/// 録画には映らない (録画の対象から外す)。ドラッグで動かせる
final class RecordingPanel: NSPanel {
    let timeLabel = NSTextField(labelWithString: "0:00")

    /// restoresWindow: 止めたときに操作ウィンドウを戻すか (ヒントの文に使う)
    init(target: AnyObject, action: Selector, restoresWindow: Bool) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 168, height: 44),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let back = NSVisualEffectView()
        back.material = .hudWindow
        back.state = .active
        back.wantsLayer = true
        back.layer?.cornerRadius = 22
        back.layer?.masksToBounds = true
        let button = ToggleButton(title: L("■ 録画停止"), target: target, action: action)
        button.onColor = .systemRed
        button.state = .on
        button.toolTip = restoresWindow
            ? L("録画を止めて、操作ウィンドウを戻します (%@R)", HotKeys.modifierSymbols)
            : L("この画面を録画しています。押すと録画を止めます (%@R)", HotKeys.modifierSymbols)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timeLabel.textColor = .white
        let row = NSStackView(views: [button, timeLabel])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 7, left: 7, bottom: 7, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        back.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: back.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: back.trailingAnchor),
            row.topAnchor.constraint(equalTo: back.topAnchor),
            row.bottomAnchor.constraint(equalTo: back.bottomAnchor),
        ])
        contentView = back
        setContentSize(back.fittingSize)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // 全画面出力 (メニューバーの 1 つ上) よりさらに手前に出す
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    /// 画面の右上 (メニューバーの下) に出す
    func show(on screen: NSScreen) {
        let v = screen.visibleFrame
        setFrameOrigin(NSPoint(x: v.maxX - frame.width - 16, y: v.maxY - frame.height - 12))
        orderFrontRegardless()
    }
}

/// 上から下へ並べるための、座標が上から始まるビュー (サイドバーのスクロール用)
final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate, NSWindowDelegate {
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
        (30, L("30fps (60Hz・西日本)")),
        (25, L("25fps (50Hz・東日本)")),
        (20, L("20fps (50Hz・より安定)")),
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
    // 指し棒
    var pointerButton = NSButton()
    lazy var pointerWindow = PointerWindow()
    var pointerTimer: Timer?
    var lastPointerLocation: CGPoint?
    /// いまの棒の傾き (度)。向きが変わるときは、すぐ変えずになめらかに回す
    var pointerAngle: CGFloat?
    var pointerScreen: NSScreen?
    // キーの説明用のキーボード
    var keyboardButton = NSButton()
    lazy var keyboardWindow = KeyboardWindow()
    var keyboardOn: Bool {
        get { UserDefaults.standard.bool(forKey: "keyboardOn") }
        set { UserDefaults.standard.set(newValue, forKey: "keyboardOn") }
    }
    var keyboardPosition: KeyboardRenderer.Position {
        get { (UserDefaults.standard.object(forKey: "keyboardPlace") as? Int).flatMap { .init(rawValue: $0) } ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "keyboardPlace") }
    }
    /// キーボードの配列。選んだことがなければ、アプリの表示が英語なら US、それ以外は JIS
    var keyboardLayout: KeyboardRenderer.Layout {
        get {
            (UserDefaults.standard.object(forKey: "keyboardLayout") as? Int).flatMap { .init(rawValue: $0) }
                ?? (appIsEnglish ? .us : .jis)
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "keyboardLayout") }
    }
    /// キーボード (テンキー込み) の横幅の、映像の横幅に対する割合
    var keyboardScale: Double {
        get { UserDefaults.standard.object(forKey: "keyboardSize") as? Double ?? 0.58 }
        set { UserDefaults.standard.set(newValue, forKey: "keyboardSize") }
    }
    // 字幕
    var subtitleButton = NSButton()
    let subtitles = SubtitleEngine()
    /// 字幕で認識する言語 (表示名, 言語の ID)
    static let subtitleLanguages: [(title: String, id: String)] = [("日本語", "ja-JP"), ("English", "en-US")]
    /// 字幕で認識する言語。選んだことがなければ、アプリの表示が英語なら英語、それ以外は日本語
    var subtitleLanguage: String {
        get { UserDefaults.standard.string(forKey: "subtitleLanguage") ?? (appIsEnglish ? "en-US" : "ja-JP") }
        set { UserDefaults.standard.set(newValue, forKey: "subtitleLanguage") }
    }
    /// デスクトップに出す字幕 (録画にも映る)
    lazy var subtitleWindow = SubtitleWindow()
    /// 録画中に確定した字幕 (録画を止めたら .srt に保存する)
    var subtitleCues: [SubtitleFile.Cue] = []
    var recordingSubtitles = false
    /// 今話している文が出始めた時刻
    var utteranceStart: Date?
    var subtitleClearTimer: Timer?
    /// 字幕を AI (Apple Intelligence) で直すか。選んだことがなければオン (使えない Mac では何もしない)
    var subtitleAI: Bool {
        get { UserDefaults.standard.object(forKey: "subtitleAI") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "subtitleAI") }
    }
    /// AI で直した文 (聞き取ったまま → 直したもの)。画面の字幕に出ている文を差し替えるのに使う
    var subtitleCorrections: [(raw: String, fixed: String)] = []
    /// 直前に確定した文 (AI に前後のつながりを伝える)
    var recentFinals: [String] = []
    /// 画面に出している字幕の、聞き取ったままの文字
    var lastRawSubtitle = ""
    var subtitleRefiner: AnyObject?
    let termsView = NSTextView()
    let termsCountLabel = NSTextField(labelWithString: "")
    var termsSaveTimer: Timer?
    /// 字幕の置き換え (1 行に「間違い → 正しい」)
    var subtitleTerms: String {
        get { UserDefaults.standard.string(forKey: "subtitleTerms") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "subtitleTerms") }
    }
    /// 欄の各行 (空行は除く)
    private var subtitleTermLines: [String] {
        subtitleTerms.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    /// 「間違い → 正しい」の行から作る置き換えの表 (長いものから先に置き換える)
    var subtitleReplacements: [(from: String, to: String)] {
        subtitleTermLines.compactMap { line -> (String, String)? in
            for sep in ["→", "->", "=", "＝"] {
                guard let r = line.range(of: sep) else { continue }
                let from = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                let to = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                return from.isEmpty ? nil : (from, to)
            }
            return nil
        }.sorted { $0.0.count > $1.0.count }
    }
    /// 認識のヒントに渡す語 (置き換え後の正しい表記と、矢印のない行)
    var subtitleTermList: [String] {
        subtitleTermLines.map { line in
            for sep in ["→", "->", "=", "＝"] {
                if let r = line.range(of: sep) { return line[r.upperBound...].trimmingCharacters(in: .whitespaces) }
            }
            return line
        }.filter { !$0.isEmpty }
    }
    private var cachedReplacements: [(from: String, to: String)] = []
    /// 認識した文字に置き換えの表を当てる
    func applyReplacements(_ text: String) -> String {
        var t = text
        for r in cachedReplacements { t = t.replacingOccurrences(of: r.from, with: r.to) }
        return t
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
    var recorder: AnyObject? { didSet { updateDrawableScreens() } }   // ScreenRecorder (macOS 12.3 以降)
    var recordButton = ToggleButton()
    var recordLabel = NSTextField(labelWithString: "")
    var recordStart = Date()
    /// 録画のあいだ操作ウィンドウを Dock にしまったか (止めたら戻す)
    var windowHiddenForRecording = false
    var recordingPanel: RecordingPanel?

    /// 録画に映す NoGreenBack のウィンドウ (重ねた人物・手書き・全画面出力)
    var recordedWindowNumbers: [Int] {
        // 全画面出力の上の手書きは、出力の映像の中にも入っているので録画から外す (線が二重にならないように)
        let covered = outputWindow != nil ? annotation?.window(for: outputScreen) : nil
        var n = (annotation?.windows.filter { $0 !== covered }.map(\.windowNumber) ?? [])
        if let overlay { n.append(overlay.windowNumber) }
        if let outputWindow { n.append(outputWindow.windowNumber) }
        if boardWindow.isVisible { n.append(boardWindow.windowNumber) }
        // キーボードも録画に映す (説明に使うため)
        if keyboardWindow.isVisible { n.append(keyboardWindow.windowNumber) }
        if pointerWindow.isVisible { n.append(pointerWindow.windowNumber) }
        // デスクトップの字幕は録画に焼き込まない (字幕は .srt ファイルとして別に残す)
        return n
    }

    /// 録画中に映すウィンドウが変わったら、録画の対象を更新する
    func updateRecordedWindows() {
        guard #available(macOS 12.3, *), let rec = recorder as? ScreenRecorder else { return }
        let numbers = recordedWindowNumbers
        Task { await rec.updateKeptWindows(numbers) }
    }
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
    var aspectPopup = NSPopUpButton()
    /// 合成した映像の比率を「出す画面」に合わせるか (オフならカメラの比率のまま)
    var matchOutputAspect: Bool {
        get { UserDefaults.standard.object(forKey: "matchOutputAspect") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "matchOutputAspect") }
    }
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
        recordSizeLabel.stringValue = String(format: L("1 時間で最大 約 %.1f GB"), gb)
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
    // ATEM スイッチャーの操作
    let atem = ATEMControl()
    let atemUSB = ATEMUSBWatcher()
    /// サイドバーの ATEM の見出しと状態 (USB で ATEM がつながっている間だけ出す)
    var atemSidebarViews: [NSView] = []
    let atemStatus = NSTextField(labelWithString: L("つないでいません"))
    let atemInputs = NSSegmentedControl()
    let atemMixCheck = NSButton(checkboxWithTitle: L("ミックス"), target: nil, action: nil)
    /// 上部に並べる ATEM の入力ボタンとミックスのチェック (つないでいる間だけ出す)
    lazy var atemToolbarGroup: NSStackView = {
        let label = NSTextField(labelWithString: "ATEM")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let g = NSStackView(views: [toolbarSeparator(), label, atemInputs, atemMixCheck])
        g.spacing = 8
        g.isHidden = true
        return g
    }()
    var atemInputIDs: [Int] = [1, 2, 3, 4]
    var atemProgram = 0
    var atemConnected = false
    // 外部の音声: 取り込む機器、出すスピーカー、音量
    let externalAudio = ExternalAudio()
    let extInPopup = NSPopUpButton()
    let extOutPopup = NSPopUpButton()
    let extLevel = NSLevelIndicator()
    var extOutputs: [AudioOutputs.Device] = []
    var extInputID: String? {
        get { UserDefaults.standard.string(forKey: "externalInputID") }
        set { UserDefaults.standard.set(newValue, forKey: "externalInputID") }
    }
    /// nil = スピーカーに出さない、"" = システムの出力、それ以外は出力先の UID
    var extOutputUID: String? {
        get { UserDefaults.standard.string(forKey: "externalOutputUID") }
        set { UserDefaults.standard.set(newValue, forKey: "externalOutputUID") }
    }
    /// 声で外部の音を下げるときの倍率 (1 なら下げない)
    static let duckChoices: [(String, Float)] = [(L("下げない"), 1), (L("少し (-6dB)"), 0.5), (L("半分くらい (-12dB)"), 0.25), (L("大きく (-20dB)"), 0.1)]
    var extDuck: Float {
        get { UserDefaults.standard.object(forKey: "externalDuck") as? Float ?? 0.25 }
        set { UserDefaults.standard.set(newValue, forKey: "externalDuck") }
    }
    var extVolume: Float {
        get { UserDefaults.standard.object(forKey: "externalVolume") as? Float ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "externalVolume") }
    }
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
    /// ホワイトボード (起動するたびにオフから始める)
    var whiteboardOn = false
    var whiteboardButton = NSButton()
    lazy var boardWindow = BoardWindow()
    var boardOpacity: Double {
        get { let v = UserDefaults.standard.double(forKey: "boardOpacity"); return v > 0 ? v : 0.7 }
        set { UserDefaults.standard.set(newValue, forKey: "boardOpacity") }
    }
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
        (L("赤"), .systemRed), (L("黄"), .systemYellow), (L("青"), .systemBlue), (L("緑"), .systemGreen), (L("白"), .white), (L("黒"), .black),
    ]
    let fadeTimes: [(title: String, seconds: TimeInterval)] = [
        (L("消さない"), 0), (L("3秒で消す"), 3), (L("10秒で消す"), 10),
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
        processor.startIdleRendering(on: videoQueue)
        processor.onFPS = { [weak self] fps in
            DispatchQueue.main.async { self?.fpsLabel.stringValue = String(format: "%.1f fps", fps) }
        }
        buildUI()
        BackgroundSource.allowIOSScreens()
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async {
                if ok { self.refreshCameras(); self.startSession(); self.watchCamera(); self.refreshBackgrounds() }
                else { self.showAlert(L("カメラへのアクセスが許可されていません。\nシステム設定 > プライバシーとセキュリティ > カメラ で許可してください。")) }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 録画中に終了するときは、ファイルを閉じてから終了する (閉じないと再生できないファイルになる)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 終わる前に、画面を覆う透明なウィンドウ (手書きなど) を先に消す。
        // 録画の保存などで終了に時間がかかる間も、ほかのアプリをクリックできるように
        hideFloatingWindows()
        guard #available(macOS 12.3, *), let rec = recorder as? ScreenRecorder else { return .terminateNow }
        Task { @MainActor in
            _ = await rec.stop()
            self.recorder = nil
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        hideFloatingWindows()
        // カメラなどの停止が止まったままになっても、プロセスを残さない
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { exit(0) }
        externalAudio.stop()
        atem.disconnect()
        micMeter.stop()
        session.stopRunning()
        processor.syphon.stop()
    }

    /// 操作ウィンドウを閉じたら、ほかのウィンドウが残っていても必ず終了する
    /// (手書きなどの画面を覆うウィンドウだけが残って、クリックを受け取り続けないように)
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        hideFloatingWindows()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// 画面を覆う透明なウィンドウ (手書き・人物・全画面出力・字幕) を消し、描画モードを切る
    func hideFloatingWindows() {
        annotationTimer?.invalidate()
        annotationTimer = nil
        penLatched = false
        annotation?.setDrawing(false)
        annotation?.orderOut()
        overlay?.orderOut(nil)
        outputWindow?.orderOut(nil)
        subtitleWindow.orderOut(nil)
        keyboardWindow.orderOut(nil)
        boardWindow.hide()
        pointerTimer?.invalidate()
        pointerTimer = nil
        pointerWindow.orderOut(nil)
        CursorHider.show()
    }

    // MARK: UI

    func buildUI() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 760),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "NoGreenBack"
        window.delegate = self
        window.isReleasedWhenClosed = false
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
        quality.addItems(withTitles: [L("Fast (低負荷)"), "Balanced", L("Accurate (高品質)")])
        quality.selectItem(at: 1)
        quality.target = self
        quality.action = #selector(qualityChanged(_:))

        let fpsPopup = NSPopUpButton()
        fpsPopup.addItems(withTitles: frameRates.map(\.title))
        fpsPopup.selectItem(at: frameRates.firstIndex { $0.fps == targetFPS } ?? 1)
        fpsPopup.target = self
        fpsPopup.action = #selector(fpsChanged(_:))
        fpsPopup.toolTip = L("照明の電源周波数に合わせると、フリッカー (明滅) が出にくくなります")

        let deflicker = NSSlider(value: settings.deflicker, minValue: 0, maxValue: 1,
                                 target: self, action: #selector(deflickerChanged(_:)))
        deflicker.toolTip = L("照明のフリッカーによる画面全体の明滅をならします (横じまは消せません)")

        let feather = NSSlider(value: settings.feather, minValue: 0, maxValue: 6,
                               target: self, action: #selector(featherChanged(_:)))

        // 反転とαは前回の設定を使う (左右反転は既定でオン)
        let defaults = UserDefaults.standard
        settings.mirror = defaults.object(forKey: "mirror") as? Bool ?? true
        settings.flipVertical = defaults.object(forKey: "flipVertical") as? Bool ?? true
        settings.straightAlpha = defaults.bool(forKey: "straightAlpha")
        let mirror = NSButton(checkboxWithTitle: L("左右反転"), target: self, action: #selector(mirrorChanged(_:)))
        mirror.state = settings.mirror ? .on : .off
        let flip = NSButton(checkboxWithTitle: L("上下反転"), target: self, action: #selector(flipChanged(_:)))
        flip.state = settings.flipVertical ? .on : .off
        let straight = NSButton(checkboxWithTitle: L("ストレートα"), target: self, action: #selector(alphaChanged(_:)))
        straight.state = settings.straightAlpha ? .on : .off
        straight.toolTip = L("オフ: プリマルチプライドα (既定) / オン: ストレートα。受信側で縁が黒くなる・白くなる場合に切り替え")

        let smoothing = NSSlider(value: settings.smoothing, minValue: 0, maxValue: 1,
                                 target: self, action: #selector(smoothingChanged(_:)))
        smoothing.toolTip = L("上げるほど輪郭のちらつきが減ります。上げすぎると動いたときに残像が出ます")
        let tighten = NSSlider(value: settings.tighten, minValue: 0, maxValue: 1,
                               target: self, action: #selector(tightenChanged(_:)))
        tighten.toolTip = L("上げるほど半透明の縁 (背景のにじみ) が減り、輪郭がくっきりします")

        let hold = NSSlider(value: settings.hold, minValue: 0, maxValue: 1,
                            target: self, action: #selector(holdChanged(_:)))
        hold.toolTip = L("上げるほど、手をかざしたときなどに体の一部が一瞬消える現象を抑えます。上げすぎると、移動した後に元の位置がうっすら残ります")

        fpsLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        // 3 段目: 画面に重ねる表示
        overlay = OverlayWindow(processor: processor)
        overlayCheck = toolbarToggle(L("ワイプ"), #selector(overlayToggled(_:)))
        overlayCheck.state = overlayOn ? .on : .off
        overlayCheck.toolTip = L("切り抜いた人物を、テレビのワイプのようにデスクトップの隅に小さく重ねて出します (クリックは後ろのアプリに届きます)。人物をどこにも出したくないときは「人物」をオフにします")
        personButton = toolbarToggle(L("人物"), #selector(personToggled(_:)))
        personButton.state = personOn ? .on : .off
        personButton.toolTip = L("人物を出すかどうかの大もとのスイッチです。オフにすると、ワイプ・全画面・プレビュー・Syphon のすべてから人物が消えて、背景だけになります。%@P", HotKeys.modifierSymbols)
        let cornerPopup = NSPopUpButton()
        cornerPopup.addItems(withTitles: OverlayWindow.Corner.allCases.map(\.title))
        cornerPopup.selectItem(at: overlayCorner.rawValue)
        cornerPopup.target = self
        cornerPopup.action = #selector(cornerChanged(_:))
        let sizeSlider = NSSlider(value: overlayScale, minValue: 0.15, maxValue: 0.8,
                                  target: self, action: #selector(overlaySizeChanged(_:)))
        sizeSlider.toolTip = L("画面の幅に対する大きさ")
        screenPopup.target = self
        screenPopup.action = #selector(screenChanged(_:))
        refreshScreens()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        }
        recordButton = ToggleButton(title: L("● 録画開始"), target: self, action: #selector(recordToggled))
        recordButton.onColor = .systemRed
        recordButton.toolTip = L("「録画する画面」を録画して、ムービーフォルダに保存します (このウィンドウは映りません)。%@R でも開始・停止できます", HotKeys.modifierSymbols)
        // 「録画開始」と「録画停止」で幅が変わらないよう、広いほうに合わせる
        var recordWidth: CGFloat = 0
        for t in [L("■ 録画停止"), L("● 録画開始")] {
            recordButton.title = t
            recordWidth = max(recordWidth, recordButton.intrinsicContentSize.width)
        }
        recordButton.widthAnchor.constraint(equalToConstant: recordWidth).isActive = true
        micPopup.target = self
        micPopup.action = #selector(micChanged(_:))
        micPopup.toolTip = L("録画に入れるマイクの音声")
        // マイクの入力レベル (緑 → 黄 → 赤)。-60dB〜0dB を 0〜30 目盛りで表示
        micLevel.levelIndicatorStyle = .continuousCapacity
        micLevel.minValue = 0
        micLevel.maxValue = 30
        micLevel.warningValue = 24     // -12dB
        micLevel.criticalValue = 28    // -4dB
        micLevel.widthAnchor.constraint(equalToConstant: 70).isActive = true
        micLevel.toolTip = L("マイクの入力レベル。話したときに緑〜黄色まで振れればちょうどよい音量です")
        let lt = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            // 録画中は録画側のマイクの音で、それ以外はメーター用に開いたマイクで測る
            var db = Double(self.micMeter.level)
            if #available(macOS 12.3, *), let rec = self.recorder as? ScreenRecorder { db = Double(rec.level) }
            // 減るときはゆっくり落とす (針がちらつかないように)
            let v = max(0, min(30, (db + 60) / 2))
            self.micLevel.doubleValue = v >= self.micLevel.doubleValue ? v : max(v, self.micLevel.doubleValue - 1.5)
            let ev = max(0, min(30, (Double(self.externalAudio.level) + 60) / 2))
            self.extLevel.doubleValue = ev >= self.extLevel.doubleValue ? ev : max(ev, self.extLevel.doubleValue - 1.5)
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
            self?.refreshExtOutputs()
        }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                self.refreshCameras()
                if name == AVCaptureDevice.wasConnectedNotification,
                   let d = note.object as? AVCaptureDevice, d.hasMediaType(.video) || d.hasMediaType(.muxed) {
                    if d.uniqueID == self.currentDevice?.uniqueID {
                        self.reopenCamera(d)
                    } else if self.currentDevice == nil,
                              d.uniqueID != self.processor.background.device?.uniqueID,
                              let cam = self.devices.first(where: { $0.uniqueID == d.uniqueID }) {
                        // カメラなしで起動していたら、つながったカメラをそのまま使い始める
                        self.reopenCamera(cam)
                        self.refreshCameras()
                    }
                    if d.uniqueID == self.processor.background.device?.uniqueID {
                        self.refreshBackgrounds()
                        self.applyBackground(reopenDevice: true)
                    }
                }
                self.refreshMics()
                self.refreshBackgrounds()
                self.refreshExtInputs()
                self.refreshExtOutputs()
            }
        }
        recordLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        recordLabel.textColor = .systemRed
        // 経過時間の欄は幅を固定する (数字が変わるたびに右のボタンが動かないように)
        recordLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true
        recordLabel.lineBreakMode = .byClipping
        if #unavailable(macOS 12.3) {
            recordButton.isEnabled = false
            recordButton.toolTip = L("画面録画には macOS 12.3 以降が必要です")
        }
        placeOverlay()
        updateOverlayVisibility()

        // 4 段目: 手書きの注釈
        annotation = Annotations()
        annotation.color = penColors[penColorIndex].color
        annotation.lineWidth = CGFloat(penWidth)
        annotation.fadeAfter = fadeTimes[fadeIndex].seconds
        annotation.onChange = { [weak self] view in self?.annotationChanged(view) }
        annotation.coverAllScreens()
        annotationCheck = toolbarToggle(L("手書き"), #selector(annotationToggled(_:)))
        annotationCheck.state = annotationOn ? .on : .off
        annotationCheck.toolTip = L("選んだキーを押している間だけ、画面にペンで書けます。離すと後ろのアプリを操作できます")
        penButton = toolbarToggle(L("ペン固定"), #selector(penButtonClicked(_:)))
        penButton.toolTip = L("キーを押さなくても描ける状態にします。オンの間は後ろのアプリをクリックできません。%@D", HotKeys.modifierSymbols)
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
        let clearButton = NSButton(title: L("消去"), target: self, action: #selector(clearAnnotation))
        clearButton.controlSize = .large
        clearButton.toolTip = L("手書きを全部消します。%@C でも消せます", HotKeys.modifierSymbols)
        whiteboardButton = toolbarToggle(L("ホワイトボード"), #selector(whiteboardToggled(_:)))
        whiteboardButton.toolTip = L("画面に半透明の白い板を敷いて、手書きの線を見やすくします。人物は板の手前に出ます。%@W", HotKeys.modifierSymbols)
        let boardSlider = NSSlider(value: boardOpacity, minValue: 0.3, maxValue: 0.95,
                                   target: self, action: #selector(boardOpacityChanged(_:)))
        boardSlider.toolTip = L("ホワイトボードの白さ。濃くするほど後ろの画面が見えにくくなります")
        setAnnotationVisible(annotationOn)

        // キーの説明用のキーボード
        keyboardButton = toolbarToggle(L("キーボード"), #selector(keyboardToggled(_:)))
        keyboardButton.state = keyboardOn ? .on : .off
        keyboardButton.toolTip = L("キーボード (JIS / US 配列・テンキー付き。Mac と Windows のキーの名前入り) の絵を出します。手書きで「このキー」と示すときに使います。%@B", HotKeys.modifierSymbols)
        pointerButton = toolbarToggle(L("指し棒"), #selector(pointerToggled(_:)))
        pointerButton.toolTip = L("マウスの位置を指し棒の矢印で指します (オンの間はマウスカーソルを隠します)。%@L", HotKeys.modifierSymbols)
        KeyboardRenderer.layout = keyboardLayout
        let keyboardLayoutPopup = NSPopUpButton()
        keyboardLayoutPopup.addItems(withTitles: KeyboardRenderer.Layout.allCases.map(\.title))
        keyboardLayoutPopup.selectItem(at: keyboardLayout.rawValue)
        keyboardLayoutPopup.target = self
        keyboardLayoutPopup.action = #selector(keyboardLayoutChanged(_:))
        let keyboardPositionPopup = NSPopUpButton()
        keyboardPositionPopup.addItems(withTitles: KeyboardRenderer.Position.allCases.map(\.title))
        keyboardPositionPopup.selectItem(at: keyboardPosition.rawValue)
        keyboardPositionPopup.target = self
        keyboardPositionPopup.action = #selector(keyboardPositionChanged(_:))
        let keyboardSizeSlider = NSSlider(value: keyboardScale, minValue: 0.35, maxValue: 0.95,
                                          target: self, action: #selector(keyboardSizeChanged(_:)))
        keyboardSizeSlider.isContinuous = false

        // 5 段目: 背景映像と全画面出力
        bgPopup.target = self
        bgPopup.action = #selector(backgroundChanged(_:))
        bgPopup.toolTip = L("USB キャプチャーなどの映像を人物の後ろに敷きます")
        outputCheck = toolbarToggle(L("全画面"), #selector(outputToggled(_:)))
        outputCheck.toolTip = L("合成した映像を、選んだ画面いっぱいに表示します。Esc か %@F で閉じます", HotKeys.modifierSymbols)
        outputScreenPopup.target = self
        outputScreenPopup.action = #selector(outputScreenChanged(_:))
        aspectPopup.addItems(withTitles: [L("出す画面に合わせる"), L("カメラと同じ")])
        aspectPopup.selectItem(at: matchOutputAspect ? 0 : 1)
        aspectPopup.target = self
        aspectPopup.action = #selector(aspectChanged(_:))
        aspectPopup.toolTip = L("背景と人物を合成した映像の横縦比。「出す画面に合わせる」なら、プロジェクターや外部モニターに全画面で出したときに上下や左右が黒くなりません")
        updateCanvasAspect()
        recordScreenPopup.target = self
        recordScreenPopup.action = #selector(recordScreenChanged(_:))
        recordScreenPopup.toolTip = L("「● 録画開始」で録画する画面")
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
                              #selector(recordMbpsChanged(_:)), L("映像の平均ビットレート。上げるほど文字や動きがきれいになり、ファイルが大きくなります"))
        let sizePopup = popup(RecordSettings.maxLongSideChoices.map { $0 > 0 ? "\($0)" : L("縮めない") },
                              RecordSettings.maxLongSideChoices.firstIndex(of: rs.maxLongSide) ?? 1,
                              #selector(recordSizeChanged(_:)), L("録画の長辺のピクセル数 (画面のほうが小さいときは画面のまま)。1920 で 1080p 相当"))
        let recFPSPopup = popup(RecordSettings.fpsChoices.map { "\($0) fps" },
                             RecordSettings.fpsChoices.firstIndex(of: rs.fps) ?? 2,
                             #selector(recordFPSChanged(_:)), L("最大フレームレート (画面が動かない間はコマ数が減ります)"))
        let codecPopup = popup(["H.264", "HEVC (H.265)"], rs.hevc ? 1 : 0,
                               #selector(recordCodecChanged(_:)), L("同じ Mbps なら HEVC のほうが高画質 (ファイルの大きさは Mbps で決まります)。古い Mac や一部の編集ソフトでは開けないことがあります"))
        let audioPopup = popup(RecordSettings.audioKbpsChoices.map { "\($0) kbps" },
                               RecordSettings.audioKbpsChoices.firstIndex(of: rs.audioKbps) ?? 2,
                               #selector(recordAudioChanged(_:)), L("音声 (AAC・48kHz・モノラル) のビットレート"))
        recordSizeLabel.textColor = .secondaryLabelColor
        recordSizeLabel.font = .systemFont(ofSize: 11)
        updateRecordSizeLabel()
        helpButton = NSButton(title: "", target: self, action: #selector(showShortcuts(_:)))
        helpButton.bezelStyle = .helpButton
        helpButton.toolTip = L("ショートカットと使い方 (⌘/)")

        termsButton = NSButton(image: NSImage(systemSymbolName: "character.book.closed",
                                              accessibilityDescription: L("字幕の置き換え"))!,
                               target: self, action: #selector(showTerms(_:)))
        termsButton.bezelStyle = .rounded
        termsButton.toolTip = L("字幕の言語と置き換え (よく間違える言葉の直し方) を設定します")
        subtitleButton = toolbarToggle(L("字幕"), #selector(subtitleToggled(_:)))
        subtitleButton.toolTip = L("話した言葉を文字にして、映像の下に出します。認識は Mac の中で行います。%@S", HotKeys.modifierSymbols)
        subtitles.terms = subtitleTermList
        cachedReplacements = subtitleReplacements
        subtitles.onText = { [weak self] text in
            guard let self else { return }
            self.showSubtitle(self.applyReplacements(text))
        }
        subtitles.onFinal = { [weak self] text in
            guard let self else { return }
            self.subtitleFinalized(self.applyReplacements(text))
        }
        subtitles.onError = { [weak self] msg in
            self?.subtitleButton.state = .off
            self?.subtitles.stop()
            self?.setSubtitle("")
            self?.showAlert(msg)
        }

        // 上部: 本番中に触るボタンだけを並べる (オンのときは色が付く)
        let toolbar = NSStackView(views: [
            personButton, outputCheck, overlayCheck, subtitleButton, termsButton, toolbarSeparator(),
            annotationCheck, penButton, whiteboardButton, clearButton, keyboardButton, pointerButton, atemToolbarGroup, NSView(),
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
        // ペンの色と線を消すまでの時間は 1 行に並べる
        let penRow = NSStackView(views: [colorPopup, NSTextField(labelWithString: L("線を消す")), fadePopup])
        penRow.spacing = 6
        colorPopup.widthAnchor.constraint(equalToConstant: 62).isActive = true
        fadePopup.widthAnchor.constraint(equalToConstant: 106).isActive = true
        // 録画の長辺とフレームレートは 1 行に並べる (フレームレートは「30 fps」のように単位付きで出る)
        let sizeRow = NSStackView(views: [sizePopup, recFPSPopup])
        sizeRow.spacing = 8
        sizePopup.widthAnchor.constraint(equalToConstant: 112).isActive = true
        recFPSPopup.widthAnchor.constraint(equalToConstant: 112).isActive = true
        // 映像と音声のビットレートは 1 行に並べる
        let rateRow = NSStackView(views: [mbpsPopup, NSTextField(labelWithString: L("音声")), audioPopup])
        rateRow.spacing = 6
        mbpsPopup.widthAnchor.constraint(equalToConstant: 92).isActive = true
        audioPopup.widthAnchor.constraint(equalToConstant: 104).isActive = true
        let micRow = NSStackView(views: [micPopup, micLevel])
        micRow.spacing = 6
        micPopup.widthAnchor.constraint(equalToConstant: sideControlWidth - 76).isActive = true
        // 外部の音声
        for l in [extLevel] {
            l.levelIndicatorStyle = .continuousCapacity
            l.minValue = 0; l.maxValue = 30; l.warningValue = 24; l.criticalValue = 28
            l.widthAnchor.constraint(equalToConstant: 70).isActive = true
        }
        extLevel.toolTip = L("外部の音声の入力レベル")
        extInPopup.target = self
        extInPopup.action = #selector(extInputChanged(_:))
        extInPopup.toolTip = L("キャプチャーボードやオーディオインターフェースなど、取り込む音声の機器。録画のときはマイクの音と混ぜて入ります")
        extOutPopup.target = self
        extOutPopup.action = #selector(extOutputChanged(_:))
        extOutPopup.toolTip = L("取り込んだ音を、そのまま出すスピーカー")
        let extInRow = NSStackView(views: [extInPopup, extLevel])
        extInRow.spacing = 6
        extInPopup.widthAnchor.constraint(equalToConstant: sideControlWidth - 76).isActive = true
        let extVolSlider = NSSlider(value: Double(extVolume), minValue: 0, maxValue: 1,
                                    target: self, action: #selector(extVolumeChanged(_:)))
        extVolSlider.toolTip = L("外部の音の音量。スピーカーに出す音と、録画に入る音の両方が変わります")
        let duckPopup = NSPopUpButton()
        duckPopup.addItems(withTitles: Self.duckChoices.map(\.0))
        duckPopup.selectItem(at: Self.duckChoices.firstIndex { abs($0.1 - extDuck) < 0.001 } ?? 2)
        duckPopup.target = self
        duckPopup.action = #selector(extDuckChanged(_:))
        duckPopup.toolTip = L("マイクで話している間、録画に入る外部の音を自動で下げます (スピーカーに出す音は下げません)")
        refreshExtInputs()
        refreshExtOutputs()
        startExternal()
        atemSidebarViews = [sectionHeader(L("ATEM スイッチャー"))] + buildATEM()
        atemSidebarViews.forEach { $0.isHidden = true }
        atemUSB.start()
        let tuning = sideGrid([
            (L("ちらつき抑制"), smoothing), (L("消失の保持"), hold), (L("境界の締まり"), tighten),
            (L("境界ぼかし"), feather), (L("明るさ安定化"), deflicker),
        ])
        tuning.isHidden = !tuningOpen
        let cameraGrid = sideGrid([(L("カメラ"), cameraPopup), (L("品質"), quality), (L("フレームレート"), fpsPopup)])
        let sections: [NSView] = [
            sectionHeader(L("カメラ")),
            cameraGrid,
            mirrors,
            collapsibleSection(L("切り抜きの調整"), content: tuning),
            sectionHeader(L("人物の位置と大きさ")),
            sideGrid([(L("位置"), cornerPopup), (L("大きさ"), sizeSlider), (L("表示する画面"), screenPopup)]),
            sectionHeader(L("背景と全画面出力")),
            sideGrid([(L("背景映像"), bgPopup), (L("出す画面"), outputScreenPopup), (L("映像の比率"), aspectPopup)]),
            sectionHeader(L("手書き")),
            sideGrid([(L("描くキー"), keyPopup), (L("色"), penRow), (L("太さ"), widthSlider),
                      (L("ボードの濃さ"), boardSlider)]),
            sectionHeader(L("キーボード")),
            sideGrid([(L("配列"), keyboardLayoutPopup), (L("位置"), keyboardPositionPopup), (L("大きさ"), keyboardSizeSlider)]),
            sectionHeader(L("録画")),
            sideGrid([(L("録画する画面"), recordScreenPopup), (L("マイク"), micRow), (L("映像"), rateRow),
                      (L("長辺"), sizeRow), (L("形式"), codecPopup), ("", recordSizeLabel)]),
            sectionHeader(L("外部の音声")),
            sideGrid([(L("入力"), extInRow), (L("スピーカー"), extOutPopup), (L("音量"), extVolSlider),
                      (L("声で下げる"), duckPopup)]),
        ] + atemSidebarViews
        let side = NSStackView(views: sections)
        side.orientation = .vertical
        side.alignment = .leading
        side.spacing = 6
        side.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 16, right: 14)
        mirrors.trailingAnchor.constraint(equalTo: cameraGrid.trailingAnchor, constant: -8).isActive = true
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
        if let id = currentDevice?.uniqueID, let i = devices.firstIndex(where: { $0.uniqueID == id }) {
            cameraPopup.selectItem(at: i)
        }
    }

    /// カメラの映像が止まっていないか見張る。
    /// スイッチャー (ATEM など) は映像形式を変えたときや、つないだ直後に USB の機器として
    /// 一度消えて出直すことがあり、古いつながりのままだと一覧にあるのに映像が出なくなる
    var cameraWatchdog: Timer?
    var cameraStartedTime: CFAbsoluteTime = 0
    func watchCamera() {
        cameraWatchdog?.invalidate()
        cameraWatchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, let id = self.currentDevice?.uniqueID else { return }
            let last = max(self.processor.lastFrameTime, self.cameraStartedTime)
            guard CFAbsoluteTimeGetCurrent() - last > 3,
                  let fresh = AVCaptureDevice(uniqueID: id), fresh.isConnected else { return }
            NSLog("camera: no frames from \(fresh.localizedName), reopening")
            self.reopenCamera(fresh)
        }
        NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                               object: session, queue: .main) { [weak self] note in
            NSLog("camera: session error \(String(describing: note.userInfo?[AVCaptureSessionErrorKey]))")
            self?.cameraStartedTime = 0   // 次の見張りで開き直す
        }
    }

    /// 同じ機器を開き直す (止まっていたセッションも動かし直す)
    func reopenCamera(_ device: AVCaptureDevice) {
        configure(device: device)
        videoQueue.async {
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { self.applyFrameRate() }
        }
    }

    func startSession() {
        // 映像の受け取り口は、カメラがなくても先に用意しておく
        // (あとからカメラをつないだときに、受け取り口がなくて画面が白いままにならないように)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                kCVPixelBufferMetalCompatibilityKey as String: true]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(processor, queue: videoQueue)
        session.beginConfiguration()
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        guard !devices.isEmpty else {
            showAlert(L("カメラが見つかりません。カメラをつなぐと、自動で映ります。"))
            return
        }
        configure(device: devices[0])
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
            cameraStartedTime = CFAbsoluteTimeGetCurrent()
            watchFrameRate(of: device)
            if !session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .high }
        } catch {
            showAlert(L("カメラを開けません: %@", error.localizedDescription))
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
        recordScreenPopup.addItem(withTitle: L("表示する画面と同じ"))
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

    /// 背景の選択肢: なし / この Mac の画面 / カメラやキャプチャー機器 / USB でつないだ iPhone・iPad の画面。
    /// 項目の representedObject に、保存用の ID (画面は "screen:名前"、機器は uniqueID) を入れる
    func refreshBackgrounds() {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) { types += [.external, .continuityCamera] }
        else { types.append(.externalUnknown) }
        bgDevices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video,
                                                     position: .unspecified).devices
        // iPhone・iPad の画面は、映像と音が一緒になった機器 (muxed) として出てくる
        let iosTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) { iosTypes = [.external] } else { iosTypes = [.externalUnknown] }
        bgDevices += AVCaptureDevice.DiscoverySession(deviceTypes: iosTypes, mediaType: .muxed,
                                                      position: .unspecified).devices
            .filter { d in !bgDevices.contains { $0.uniqueID == d.uniqueID } }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L("なし（透明）"), action: nil, keyEquivalent: ""))
        if #available(macOS 12.3, *) {
            menu.addItem(.separator())
            for screen in NSScreen.screens {
                let item = NSMenuItem(title: L("画面: %@", screen.localizedName), action: nil, keyEquivalent: "")
                item.representedObject = "screen:" + screen.localizedName
                menu.addItem(item)
            }
        }
        if !bgDevices.isEmpty { menu.addItem(.separator()) }
        for d in bgDevices {
            // iPhone の画面は、同じ iPhone のカメラ (連係カメラ) と見分けられるように名前を付ける
            let title = BackgroundSource.isIOSScreen(d) ? L("iPhone・iPad の画面: %@", d.localizedName) : d.localizedName
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = d.uniqueID
            menu.addItem(item)
        }
        bgPopup.menu = menu
        let i = backgroundID.flatMap { id in menu.items.firstIndex { $0.representedObject as? String == id } }
        bgPopup.selectItem(at: i ?? 0)
        applyBackground()
    }

    /// 選んでいる背景を使い始める (restartScreen: 画面の構成が変わったときに、画面の取り込みをやり直す)
    func applyBackground(restartScreen: Bool = false, reopenDevice: Bool = false) {
        // 背景にする画面が変わると、ホワイトボードを映像に重ねるかどうかも変わる
        defer { updateWhiteboard() }
        let id = bgPopup.selectedItem?.representedObject as? String
        if let id, id.hasPrefix("screen:") {
            let name = String(id.dropFirst("screen:".count))
            guard let screen = NSScreen.screens.first(where: { $0.localizedName == name }) else { return }
            if !restartScreen, processor.background.screenName == name { return }
            // 手書きの線とホワイトボードは背景にも映す (全画面出力に手書きが入るように)
            let keep = (annotation?.windows.map(\.windowNumber) ?? []) + [boardWindow.windowNumber]
            processor.background.startScreen(screen, keepWindows: keep) { [weak self] msg in
                self?.showAlert(L("画面を背景にできません: %@\n\n初回は「システム設定 > プライバシーとセキュリティ > 画面収録」で NoGreenBack を許可し、アプリを開き直してください。", msg))
                self?.bgPopup.selectItem(at: 0)
                try? self?.processor.background.start(nil)
            }
            return
        }
        let device = bgDevices.first { $0.uniqueID == id }
        do {
            try processor.background.start(device, force: reopenDevice)
        } catch {
            showAlert(L("背景映像を開けません: %@", error.localizedDescription))
            bgPopup.selectItem(at: 0)
            try? processor.background.start(nil)
        }
    }

    @objc func backgroundChanged(_ sender: NSPopUpButton) {
        backgroundID = sender.selectedItem?.representedObject as? String
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
            // 全画面を外したらペン固定も外す (そのままだと、操作ウィンドウのある画面まで
            // 手書きがクリックを受け止めて、マウスで操作できなくなるため)
            if outputWindow != nil, penLatched {
                penLatched = false
                annotation?.setDrawing(false)
            }
            outputWindow?.orderOut(nil)
            outputWindow = nil
        }
        updateOverlayVisibility()
        updateRecordedWindows()
        updateDrawableScreens()
        refreshAnnotationImage()
    }

    /// 全画面出力を出している間は、手書きで描ける画面を全画面出力と録画している画面だけにする
    /// (操作ウィンドウのある画面などは、描くキーを押していてもマウスでふつうに操作できる)
    func updateDrawableScreens() {
        guard let annotation else { return }
        guard outputWindow != nil else { annotation.setAllowedScreens(nil); return }
        var screens = [outputScreen]
        if recorder != nil, recordScreen != outputScreen { screens.append(recordScreen) }
        annotation.setAllowedScreens(screens)
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
        updateCanvasAspect()
        placeOverlay()
        placeOutput()
        // 画面を背景にしているときは、画面の一覧と取り込みを作り直す
        if processor.background.screenName != nil || backgroundID?.hasPrefix("screen:") == true {
            refreshBackgrounds()
            applyBackground(restartScreen: true)
        }
        // 手書きのウィンドウが作り直されることがあるので、録画の対象も更新する
        updateRecordedWindows()
    }

    @objc func outputScreenChanged(_ sender: NSPopUpButton) {
        outputScreenName = sender.titleOfSelectedItem
        updateCanvasAspect()
        placeOutput()
    }

    @objc func aspectChanged(_ sender: NSPopUpButton) {
        matchOutputAspect = sender.indexOfSelectedItem == 0
        updateCanvasAspect()
    }

    /// 合成した映像の比率を、出す画面 (外部モニターなど) の比率にそろえる
    func updateCanvasAspect() {
        let f = outputScreen.frame
        settings.canvasAspect = matchOutputAspect && f.height > 0 ? Double(f.width / f.height) : 0
        // 映像の大きさが変わるので、手書きの線も描き直す (次のフレームで大きさが決まってから)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.refreshAnnotationImage() }
    }

    // MARK: 全画面出力の上の手書きを映像に入れる

    func refreshAnnotationImage() {
        guard let view = annotation?.window(for: outputScreen)?.view else { processor.annotationImage = nil; return }
        annotationChanged(view)
    }

    /// 全画面出力の画面で描いた線を、合成した映像の座標に直して画像にする
    func annotationChanged(_ view: AnnotationView) {
        guard outputWindow != nil, annotation.isShown,
              view.window === annotation.window(for: outputScreen) else {
            if view.window === annotation?.window(for: outputScreen) { processor.annotationImage = nil }
            return
        }
        guard !view.strokes.isEmpty, let canvas = processor.latestImage?.extent, canvas.width > 0 else {
            processor.annotationImage = nil
            return
        }
        // 全画面出力は、映像を画面に収まるように拡大して真ん中に出している。その逆をたどる
        let screen = view.bounds.size
        let s = min(screen.width / canvas.width, screen.height / canvas.height)
        let tx = (screen.width - canvas.width * s) / 2, ty = (screen.height - canvas.height * s) / 2
        let w = Int(canvas.width), h = Int(canvas.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.translateBy(x: 0, y: 0)
        ctx.scaleBy(x: 1 / s, y: 1 / s)
        ctx.translateBy(x: -tx, y: -ty)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let now = Date()
        for stroke in view.strokes {
            var alpha: CGFloat = 1
            if view.fadeAfter > 0, let f = stroke.finished {
                alpha = CGFloat(min(1, max(0, (view.fadeAfter - now.timeIntervalSince(f)) / 0.5)))
            }
            guard alpha > 0, let first = stroke.points.first else { continue }
            ctx.setStrokeColor(stroke.color.withAlphaComponent(alpha).cgColor)
            ctx.setLineWidth(stroke.width)
            ctx.beginPath()
            ctx.move(to: first)
            if stroke.points.count == 1 { ctx.addLine(to: first) }
            for p in stroke.points.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        }
        guard let cg = ctx.makeImage() else { return }
        processor.annotationImage = CIImage(cgImage: cg)
    }

    /// 全画面出力が同じ画面に出ている間は、重ねる表示を隠す (出力の中にもう人物が入っているので)
    func updateOverlayVisibility() {
        let covered = outputWindow != nil && outputScreen == overlayScreen
        overlay?.setVisible(overlayOn && personOn && !covered)
        settings.showPerson = personOn
        updateKeyboard()
        updateWhiteboard()
    }

    // MARK: 指し棒

    @objc func pointerToggled(_ sender: NSButton) { setPointer(sender.state == .on) }
    func togglePointer() { setPointer(pointerTimer == nil) }

    func setPointer(_ on: Bool) {
        pointerButton.state = on ? .on : .off
        pointerTimer?.invalidate()
        pointerTimer = nil
        lastPointerLocation = nil
        pointerAngle = nil
        if on {
            // マウスの位置を 1 秒に 60 回調べる (許可は要らない)
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [unowned self] _ in self.updatePointer() }
            RunLoop.main.add(t, forMode: .common)
            pointerTimer = t
            CursorHider.hide()
            watchCursorReshown()
            updatePointer()
        } else {
            CursorHider.show()
            pointerWindow.orderOut(nil)
            processor.pointer = nil
            updateRecordedWindows()
        }
    }

    /// 指し棒で隠したカーソルを、macOS がまた出したときに隠し直す見張り (最初に指し棒をオンにしたときに 1 回だけ付ける)。
    /// 操作ウィンドウでポップアップのメニューを選んだり、ボタンを押したりすると、カーソルが出てくるため
    var cursorWatchers: [Any] = []
    func watchCursorReshown() {
        guard cursorWatchers.isEmpty else { return }
        // 出されたあとに隠し直すよう、知らせの処理が終わってから隠す
        let rehide = { DispatchQueue.main.async { CursorHider.rehide() } }
        cursorWatchers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in rehide() })
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp], handler: { e in rehide(); return e }) {
            cursorWatchers.append(m)
        }
    }

    /// マウスのある画面に指し棒を描く。全画面出力の画面なら、合成した映像の中に描く。
    /// 先はマウスにぴったり付いていき、棒の傾きは少し遅れてなめらかに変わる
    func updatePointer() {
        let m = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) else { return }
        if screen != pointerScreen { pointerScreen = screen; pointerAngle = nil }
        // 全画面出力の画面なら、合成した映像の座標で考える
        // (映像は画面に収まるように拡大して真ん中に出しているので、その逆をたどる)
        var tip = m, area = screen.frame
        let onOutput = outputWindow != nil && screen == outputScreen
        if onOutput {
            guard let canvas = processor.latestImage?.extent, canvas.width > 0 else { return }
            let sf = screen.frame
            let s = min(sf.width / canvas.width, sf.height / canvas.height)
            let tx = (sf.width - canvas.width * s) / 2, ty = (sf.height - canvas.height * s) / 2
            tip = CGPoint(x: (m.x - sf.minX - tx) / s, y: (m.y - sf.minY - ty) / s)
            area = canvas
        }
        let target = PointerRenderer.angle(tip: tip, in: area)
        let current = pointerAngle ?? target
        let angle = abs(target - current) < 0.1 ? target : current + (target - current) * 0.18
        // マウスも傾きも変わっていなければ描き直さない
        guard m != lastPointerLocation || angle != pointerAngle else { return }
        lastPointerLocation = m
        pointerAngle = angle

        let wasVisible = pointerWindow.isVisible
        if onOutput {
            pointerWindow.orderOut(nil)
            processor.pointer = (tip, angle)
        } else {
            processor.pointer = nil
            pointerWindow.show(on: screen, from: PointerRenderer.base(tip: tip, angle: angle, in: area), to: tip)
        }
        if pointerWindow.isVisible != wasVisible { updateRecordedWindows() }
    }

    // MARK: キーの説明用のキーボード

    /// 映像 (プレビュー・全画面出力・Syphon) と、全画面出力に隠れていなければ画面にも出す
    func updateKeyboard() {
        processor.keyboard = keyboardOn ? (keyboardScale, keyboardPosition) : nil
        let covered = outputWindow != nil && outputScreen == overlayScreen
        if keyboardOn && !covered {
            // 画面に重ねる人物は、画面の幅に対して overlayScale の幅で隅に置いている
            let right = overlayCorner == .bottomRight || overlayCorner == .topRight
            let s = CGFloat(overlayScale)
            keyboardWindow.show(on: overlayScreen, scale: keyboardScale, position: keyboardPosition,
                                person: right ? (1 - s)...1 : 0...s)
        } else {
            keyboardWindow.orderOut(nil)
        }
        updateRecordedWindows()
    }
    @objc func keyboardToggled(_ sender: NSButton) {
        keyboardOn = sender.state == .on
        updateKeyboard()
    }
    func toggleKeyboard() {
        keyboardButton.state = keyboardOn ? .off : .on
        keyboardToggled(keyboardButton)
    }
    @objc func keyboardLayoutChanged(_ sender: NSPopUpButton) {
        keyboardLayout = .init(rawValue: sender.indexOfSelectedItem) ?? .jis
        KeyboardRenderer.layout = keyboardLayout
        updateKeyboard()
    }
    @objc func keyboardPositionChanged(_ sender: NSPopUpButton) {
        keyboardPosition = .init(rawValue: sender.indexOfSelectedItem) ?? .auto
        updateKeyboard()
    }
    @objc func keyboardSizeChanged(_ sender: NSSlider) {
        keyboardScale = sender.doubleValue
        updateKeyboard()
    }

    func placeOverlay() {
        settings.pipCorner = overlayCorner.rawValue
        settings.pipScale = overlayScale
        overlay?.place(on: overlayScreen, corner: overlayCorner, scale: overlayScale)
        annotation?.coverAllScreens()
        updateDrawableScreens()
        // 人物の位置が変わったら、キーボードを反対側へ
        if keyboardButton.state == .on { updateKeyboard() }
        updateWhiteboard()
    }

    // MARK: 全体で効くショートカット (Stream Deck の「ホットキー」から使う)

    /// (キー, キーコード, 内容, 動作)
    var hotKeyList: [(key: String, code: Int, title: String, action: () -> Void)] {
        [
            ("R", kVK_ANSI_R, L("録画の開始・停止"), { [weak self] in self?.recordToggled() }),
            ("P", kVK_ANSI_P, L("人物の表示・非表示"), { [weak self] in self?.togglePerson() }),
            ("C", kVK_ANSI_C, L("手書きを全部消す"), { [weak self] in self?.annotation.clear() }),
            ("D", kVK_ANSI_D, L("ペン (描画モード) のオン・オフ"), { [weak self] in self?.togglePen() }),
            ("K", kVK_ANSI_K, L("ペンの色を次の色へ"), { [weak self] in self?.nextPenColor() }),
            ("F", kVK_ANSI_F, L("全画面出力の表示・非表示"), { [weak self] in self?.toggleOutput() }),
            ("S", kVK_ANSI_S, L("字幕のオン・オフ"), { [weak self] in self?.toggleSubtitles() }),
            ("B", kVK_ANSI_B, L("キーボードの表示・非表示"), { [weak self] in self?.toggleKeyboard() }),
            ("L", kVK_ANSI_L, L("指し棒のオン・オフ"), { [weak self] in self?.togglePointer() }),
            ("W", kVK_ANSI_W, L("ホワイトボードの表示・非表示"), { [weak self] in self?.toggleWhiteboard() }),
        ]
    }

    func registerHotKeys() {
        let keys = HotKeys()
        var failed: [String] = []
        for k in hotKeyList where !keys.register(keyCode: k.code, k.action) {
            failed.append(L("%@（%@）", "\(HotKeys.modifierSymbols)\(k.key)", k.title))
            failedHotKeys.insert(k.key)
        }
        hotKeys = keys
        if !failed.isEmpty {
            showAlert(L("次のショートカットは他のアプリが使っているため登録できませんでした:\n") + failed.joined(separator: "\n"))
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
                         cell(k.title + (used ? L("（他のアプリが使用中のため使えません）") : ""), dim: used)])
        }
        let drawKey = drawKeys[drawKeyIndex].title.components(separatedBy: " ").first ?? ""
        let note = NSTextField(wrappingLabelWithString: L("上のショートカットは、他のアプリを操作中でも効きます。Stream Deck では「ホットキー」アクションにこの組み合わせを設定します。"))
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
        addMerged(header(L("どこからでも使えるショートカット")), space: 0)
        rows.forEach { grid.addRow(with: $0) }
        addMerged(header(L("NoGreenBack の操作")), space: 12)
        for r in [[cell(L("%@ を押しながら", drawKey), bold: true), cell(L("ドラッグで描く（手書きがオンのとき）"))],
                  [cell(L("%@ を 2 回", drawKey), bold: true), cell(L("手書きを全部消す"))],
                  [cell(L("%@ ＋ 右クリック", drawKey), bold: true), cell(L("手書きを全部消す"))],
                  [cell("Esc", bold: true), cell(L("全画面出力を閉じる（全画面出力を操作中のとき）"))],
                  [cell("⌘ Q", bold: true), cell(L("終了"))]] { grid.addRow(with: r) }
        addMerged(note, space: 12)
        func explain(_ text: String) -> NSTextField {
            let t = NSTextField(wrappingLabelWithString: text)
            t.font = .systemFont(ofSize: 13)
            t.preferredMaxLayoutWidth = 400
            return t
        }
        addMerged(header(L("外部の音声")), space: 16)
        addMerged(explain(L("取り込んだ音をスピーカーに出し、録画ではマイクと混ぜて 1 本の音声にします。話している間は録画の外部の音を自動で下げます。「音量」はスピーカーと録画の両方に効きます。")), space: 0)
        addMerged(header(L("ATEM スイッチャー")), space: 16)
        addMerged(explain(L("ATEM を USB でつなぐと自動でつながり、上部に入力のボタンが出ます。押した入力が本番に出ます。外すとボタンも消えます。USB で操作するには、Blackmagic の ATEM Software Control を入れておいてください。")), space: 0)
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

    func toggleSubtitles() {
        subtitleButton.state = subtitleButton.state == .on ? .off : .on
        subtitleToggled(subtitleButton)
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
        micPopup.addItem(withTitle: L("なし"))
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

    // MARK: ATEM スイッチャー

    func buildATEM() -> [NSView] {
        atemStatus.font = .systemFont(ofSize: 11)
        atemStatus.textColor = .secondaryLabelColor
        atemInputs.trackingMode = .selectOne
        atemInputs.target = self
        atemInputs.action = #selector(atemInputClicked(_:))
        atemInputs.toolTip = L("押した入力を本番 (PGM) に出します")
        setATEMInputs(atemInputIDs.map { ATEMControl.Input(id: $0, name: "\($0)") })
        atemInputs.isEnabled = false
        atemMixCheck.state = UserDefaults.standard.bool(forKey: "atemMix") ? .on : .off
        atemMixCheck.target = self
        atemMixCheck.action = #selector(atemMixChanged(_:))
        atemMixCheck.toolTip = L("オンにすると、ATEM で設定している切り替え効果 (ミックスなど) で移ります。ミックスは 0.5 秒。オフならすぐ切り替えます (カット)")

        atem.onState = { [weak self] state, detail in
            guard let self else { return }
            switch state {
            case .connected: self.atemStatus.stringValue = (detail.map { L("つながりました（%@）", $0) } ?? L("つながりました"))
            case .connecting: self.atemStatus.stringValue = detail ?? L("つないでいます…")
            case .disconnected: self.atemStatus.stringValue = L("つないでいません")
            }
            self.atemInputs.isEnabled = state == .connected
        }
        atem.onInputs = { [weak self] list in
            guard let self, !list.isEmpty else { return }
            self.setATEMInputs(list)
        }
        atem.onProgram = { [weak self] src in
            guard let self else { return }
            self.atemProgram = src
            self.showATEMProgram()
        }
        // ATEM を USB で挿したらつなぎ、外したら切る (サイドバーの項目もそのときだけ出す)
        atemUSB.onChange = { [weak self] present in self?.atemPlugged(present) }
        return [sideGrid([("", atemStatus)])]
    }

    func setATEMInputs(_ list: [ATEMControl.Input]) {
        atemInputIDs = list.map(\.id)
        atemInputs.segmentCount = list.count
        // 幅に収まるよう、名前が長いときは番号だけにする
        for (i, input) in list.enumerated() {
            atemInputs.setLabel(input.name.count <= 6 ? input.name : "\(input.id)", forSegment: i)
            atemInputs.setToolTip(input.name, forSegment: i)
            atemInputs.setWidth(0, forSegment: i)   // 0 = 文字に合わせる
        }
        showATEMProgram()
    }

    func showATEMProgram() {
        if let i = atemInputIDs.firstIndex(of: atemProgram) {
            atemInputs.selectedSegment = i
        } else {
            atemInputs.selectedSegment = -1
        }
    }

    /// ATEM が USB で挿された・外された
    func atemPlugged(_ present: Bool) {
        atemSidebarViews.forEach { $0.isHidden = !present }
        if present && !ATEMControl.sdkAvailable {
            // USB で操作するには Blackmagic の ATEM Software Control が必要
            atemStatus.stringValue = L("ATEM Software Control を入れると、USB で操作できます")
            return
        }
        setATEMConnected(present)
    }

    func setATEMConnected(_ on: Bool) {
        atemConnected = on
        atemToolbarGroup.isHidden = !on
        if on { atem.connect("") } else { atem.disconnect() }
    }

    @objc func atemInputClicked(_ sender: NSSegmentedControl) {
        let i = sender.selectedSegment
        guard atemInputIDs.indices.contains(i) else { return }
        let src = atemInputIDs[i]
        if atemMixCheck.state == .on {
            atem.setPreview(src)
            atem.auto()
        } else {
            atem.setProgram(src)
        }
        // 実際に切り替わったかは ATEM からの知らせで表示し直す
        showATEMProgram()
    }

    @objc func atemMixChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "atemMix")
    }

    // MARK: 外部の音声

    func refreshExtInputs() {
        extInPopup.removeAllItems()
        extInPopup.addItem(withTitle: L("使わない"))
        extInPopup.addItems(withTitles: micDevices.map(\.localizedName))
        if let id = extInputID, let i = micDevices.firstIndex(where: { $0.uniqueID == id }) {
            extInPopup.selectItem(at: i + 1)
        } else {
            extInPopup.selectItem(at: 0)
        }
        // 選んでいた機器が抜けた・つながったときは開き直す
        if selectedExternal?.uniqueID != externalAudio.device?.uniqueID { startExternal() }
    }

    func refreshExtOutputs() {
        let list = AudioOutputs.list()
        if list.map(\.uid) == extOutputs.map(\.uid), extOutPopup.numberOfItems > 0 { return }
        extOutputs = list
        extOutPopup.removeAllItems()
        extOutPopup.addItem(withTitle: L("出さない"))
        extOutPopup.addItem(withTitle: L("システムの出力"))
        extOutPopup.addItems(withTitles: list.map(\.name))
        switch extOutputUID {
        case nil: extOutPopup.selectItem(at: 0)
        case "": extOutPopup.selectItem(at: 1)
        case let uid?:
            if let i = list.firstIndex(where: { $0.uid == uid }) { extOutPopup.selectItem(at: i + 2) }
            else { extOutPopup.selectItem(at: 0) }
        }
    }

    var selectedExternal: AVCaptureDevice? {
        let i = extInPopup.indexOfSelectedItem
        return i >= 1 && i - 1 < micDevices.count ? micDevices[i - 1] : nil
    }

    /// スピーカーの出力先 (出さないなら nil、システムの出力なら "")
    var selectedExtOutput: String? {
        let i = extOutPopup.indexOfSelectedItem
        if i == 1 { return "" }
        return i >= 2 && i - 2 < extOutputs.count ? extOutputs[i - 2].uid : nil
    }

    func startExternal() {
        externalAudio.start(selectedExternal, outputUID: selectedExtOutput, volume: extVolume)
    }

    @objc func extInputChanged(_ sender: NSPopUpButton) {
        extInputID = selectedExternal?.uniqueID
        startExternal()
    }

    @objc func extOutputChanged(_ sender: NSPopUpButton) {
        extOutputUID = selectedExtOutput
        externalAudio.setMonitor(outputUID: selectedExtOutput, volume: extVolume)
    }

    @objc func extVolumeChanged(_ sender: NSSlider) {
        extVolume = sender.floatValue
        externalAudio.setMonitor(outputUID: selectedExtOutput, volume: extVolume)
        if #available(macOS 12.3, *), let rec = recorder as? ScreenRecorder { rec.externalGain = extVolume }
    }

    @objc func extDuckChanged(_ sender: NSPopUpButton) {
        extDuck = Self.duckChoices[sender.indexOfSelectedItem].1
        if #available(macOS 12.3, *), let rec = recorder as? ScreenRecorder { rec.duckLevel = extDuck }
    }

    /// メーター用にマイクを開く (録画中は録画側の音を使うので開かない)
    func startMeter() {
        if recorder != nil || !NSApp.isActive { return }
        micMeter.start(selectedMic)
    }

    /// 「システムの設定に合わせる」の表示 (今使われるマイクの名前を添える)
    var systemMicTitle: String {
        L("システムの設定（%@）", AVCaptureDevice.default(for: .audio)?.localizedName ?? L("なし"))
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

    /// 録画に混ぜる外部の音声 (マイクと同じ機器なら二重になるので混ぜない)
    var recordExternal: ExternalAudio? {
        guard let d = externalAudio.device, d.uniqueID != selectedMic?.uniqueID else { return nil }
        return externalAudio
    }

    @objc func recordToggled() {
        guard #available(macOS 12.3, *) else { return }
        // 押した時点では色を変えず、録画が始まった・止まったときに合わせる
        recordButton.state = recorder != nil ? .on : .off
        recordButton.isEnabled = false
        if let rec = recorder as? ScreenRecorder {
            // 停止 (MP4 への詰め替えが終わるまで「保存中」と出す)
            recordTimer?.invalidate()
            recordLabel.stringValue = L("保存中…")
            recordingPanel?.orderOut(nil)
            recordingPanel = nil
            // ここまでに確定した字幕を、録画と同じ名前の .srt にする
            recordingSubtitles = false
            let cues = subtitleCues
            subtitleCues = []
            // しまっていた操作ウィンドウを戻す
            if windowHiddenForRecording {
                windowHiddenForRecording = false
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            Task { @MainActor in
                let url = await rec.stop(subtitles: cues)
                self.recorder = nil
                self.startMeter()
                self.recordTimer?.invalidate()
                self.recordLabel.stringValue = ""
                self.recordButton.title = L("● 録画開始")
                self.recordButton.state = .off
                self.recordButton.isEnabled = true
                if let url, !cues.isEmpty {
                    let srt = url.deletingPathExtension().appendingPathExtension("srt")
                    try? SubtitleFile.srt(cues).write(to: srt, atomically: true, encoding: .utf8)
                }
                if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                else { self.showAlert(L("画面に変化がなかったため、録画は保存されませんでした。")) }
                if url != nil, rec.recordsAudio, rec.audioSamplesWritten == 0 {
                    self.showAlert(L("マイクの音が届いていなかったため、録画には音が入っていません。\n「マイク」の選択と、右のメーターが動くかを確かめてください。"))
                }
            }
        } else {
            // 開始
            let rec = ScreenRecorder()
            rec.onError = { [weak self] msg in
                self?.showAlert(msg)
                if self?.recorder != nil { self?.recordToggled() }
            }
            // 録画している画面の右上に、小さな停止ボタンと経過時間を出す
            // (画面が 2 つ以上あるとき、どの画面を録画しているかひと目でわかるように)。
            // 操作ウィンドウと同じ画面を録画するとき (モニターが 1 台のときなど) は、
            // 録画中はウィンドウを Dock にしまう。
            // 停止ボタンは録画に映らないよう、録画を始める前に出しておいて対象から外す
            let hideWindow = window.screen == recordScreen && !window.isMiniaturized
            let panel = RecordingPanel(target: self, action: #selector(recordToggled), restoresWindow: hideWindow)
            panel.show(on: recordScreen)
            recordingPanel = panel
            Task { @MainActor in
                do {
                    _ = try await rec.start(screen: self.recordScreen,
                                            keeping: self.recordedWindowNumbers,
                                            microphone: self.selectedMic,
                                            external: self.recordExternal,
                                            settings: self.recordSettings)
                    rec.duckLevel = self.extDuck
                    rec.externalGain = self.extVolume
                    self.recorder = rec
                    // 録画中はメーター用にマイクを開かない (Bluetooth マイクは 2 か所から開くと途切れる)
                    self.micMeter.stop()
                    self.recordButton.title = L("■ 録画停止")
                    self.recordButton.state = .on
                    if hideWindow {
                        self.windowHiddenForRecording = true
                        self.window.miniaturize(nil)
                    }
                    self.recordStart = Date()
                    self.subtitleCues = []
                    self.recordingSubtitles = true
                    self.recordLabel.stringValue = "0:00"
                    let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                        guard let self else { return }
                        let s = Int(Date().timeIntervalSince(self.recordStart))
                        let text = s >= 3600
                            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                            : String(format: "%d:%02d", s / 60, s % 60)
                        self.recordLabel.stringValue = text
                        self.recordingPanel?.timeLabel.stringValue = text
                    }
                    RunLoop.main.add(t, forMode: .common)
                    self.recordTimer = t
                } catch {
                    self.recordingPanel?.orderOut(nil)
                    self.recordingPanel = nil
                    self.showAlert(L("録画を開始できません: %@\n\n初回は「システム設定 > プライバシーとセキュリティ > 画面収録」で NoGreenBack を許可し、アプリを開き直してください。", error.localizedDescription))
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
        guard on else { annotation.orderOut(); refreshAnnotationImage(); return }
        annotation.coverAllScreens()
        annotation.orderFront()
        refreshAnnotationImage()
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
        if !annotationOn { penLatched = false; whiteboardOn = false }
        setAnnotationVisible(annotationOn)
        updateWhiteboard()
    }

    // MARK: ホワイトボード

    /// 板は映像 (プレビュー・全画面出力・背景があれば Syphon) に入れる。
    /// 全画面出力を出している間は、全画面出力の画面 (録画する画面) だけにして、操作ウィンドウのある画面などには出さない。
    /// 全画面出力を出していないときは「表示する画面」に板のウィンドウを出す
    func updateWhiteboard() {
        let on = whiteboardOn && annotationOn
        whiteboardButton.state = on ? .on : .off
        if on && outputWindow == nil {
            boardWindow.above = overlay
            boardWindow.show(on: overlayScreen, opacity: boardOpacity)
        } else {
            boardWindow.hide()
        }
        // 板を出している画面を背景にしているときは、取り込んだ背景にもう板が入っているので映像には重ねない
        let inBackground = boardWindow.isVisible && processor.background.screenName == overlayScreen.localizedName
        processor.board = on && !inBackground ? boardOpacity : nil
        updateRecordedWindows()
    }

    @objc func whiteboardToggled(_ sender: NSButton) {
        whiteboardOn = sender.state == .on
        // ホワイトボードは手書きの一部。手書きがオフならオンにする
        if whiteboardOn && !annotationOn {
            annotationCheck.state = .on
            annotationToggled(annotationCheck)
        }
        updateWhiteboard()
    }
    func toggleWhiteboard() {
        whiteboardButton.state = whiteboardOn ? .off : .on
        whiteboardToggled(whiteboardButton)
    }
    @objc func boardOpacityChanged(_ sender: NSSlider) {
        boardOpacity = sender.doubleValue
        updateWhiteboard()
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

    @objc func subtitleToggled(_ sender: NSButton) {
        if sender.state == .on {
            subtitles.localeID = subtitleLanguage
            subtitles.start(microphone: selectedMic)
        } else {
            subtitles.stop()
            subtitleClearTimer?.invalidate()
            setSubtitle("")
        }
    }

    /// 用語の欄を書き換えたら、少し待ってから保存して認識に使う
    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === termsView else { return }
        termsSaveTimer?.invalidate()
        termsSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.subtitleTerms = self.termsView.string
            self.subtitles.terms = self.subtitleTermList
            self.cachedReplacements = self.subtitleReplacements
            self.updateTermsCount()
        }
    }

    // MARK: 字幕の置き換え (上部のボタンから開く)

    var termsButton = NSButton()
    var termsPopover: NSPopover?

    @objc func showTerms(_ sender: Any?) {
        if let p = termsPopover, p.isShown { p.close(); return }
        let p = termsPopover ?? makeTermsPopover()
        termsPopover = p
        termsView.string = subtitleTerms
        updateTermsCount()
        // 件数の文が変わると中身の大きさも変わるので、開くたびに吹き出しの大きさを合わせ直す
        if let vc = p.contentViewController {
            vc.view.layoutSubtreeIfNeeded()
            vc.preferredContentSize = vc.view.fittingSize
        }
        window.makeKeyAndOrderFront(nil)
        p.show(relativeTo: termsButton.bounds, of: termsButton, preferredEdge: .maxY)
        window.makeFirstResponder(nil)
        p.contentViewController?.view.window?.makeFirstResponder(termsView)
    }

    func makeTermsPopover() -> NSPopover {
        // 認識する言語
        let languagePopup = NSPopUpButton()
        languagePopup.addItems(withTitles: Self.subtitleLanguages.map(\.title))
        languagePopup.selectItem(at: Self.subtitleLanguages.firstIndex { $0.id == subtitleLanguage } ?? 0)
        languagePopup.target = self
        languagePopup.action = #selector(subtitleLanguageChanged(_:))
        let languageRow = NSStackView(views: [NSTextField(labelWithString: L("認識する言語")), languagePopup])
        languageRow.spacing = 8
        // AI で字幕を直す (Apple Intelligence。使えない Mac では選べない)
        let aiCheck = NSButton(checkboxWithTitle: L("AI で聞き間違いを直す (Apple Intelligence)"), target: self,
                               action: #selector(subtitleAIChanged(_:)))
        let aiReason = SubtitleRefinerSupport.unavailableReason
        aiCheck.state = subtitleAI && aiReason == nil ? .on : .off
        aiCheck.isEnabled = aiReason == nil
        aiCheck.toolTip = aiReason ?? L("話し終えた文を Mac の中の AI が読み直し、誤変換や専門用語の表記を直します。音声も文字もネットには送りません。キーの名前や英字・数字が変わる直しは使いません")
        var aiViews: [NSView] = [aiCheck]
        if let aiReason {
            let note = NSTextField(labelWithString: aiReason)
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            aiViews.append(note)
        }
        let aiRow = NSStackView(views: aiViews)
        aiRow.orientation = .vertical
        aiRow.alignment = .leading
        aiRow.spacing = 2
        let title = NSTextField(labelWithString: L("字幕の置き換え"))
        title.font = .boldSystemFont(ofSize: 13)
        // よく間違える言葉を「間違い → 正しい」と 1 行ずつ書く
        termsView.font = .systemFont(ofSize: 13)
        termsView.isRichText = false
        termsView.isAutomaticQuoteSubstitutionEnabled = false
        termsView.isAutomaticTextReplacementEnabled = false
        termsView.isAutomaticSpellingCorrectionEnabled = false
        termsView.textContainerInset = NSSize(width: 4, height: 4)
        termsView.delegate = self
        termsView.isVerticallyResizable = true
        termsView.autoresizingMask = [.width]
        let termsBox = NSScrollView()
        termsBox.documentView = termsView
        termsBox.hasVerticalScroller = true
        termsBox.autohidesScrollers = true
        termsBox.borderType = .bezelBorder
        termsBox.widthAnchor.constraint(equalToConstant: 460).isActive = true
        termsBox.heightAnchor.constraint(equalToConstant: 240).isActive = true
        let hint = NSTextField(wrappingLabelWithString: L("よく間違える言葉を「間違い → 正しい」と 1 行ずつ書くと、字幕と字幕ファイルで置き換えます (例: ジオメトリー濃度 → ジオメトリーノード、ブレンダー → Blender)。→ は -> や = でも書けます。書いた内容は自動で残ります。ほかの Mac や別の話題用に、ファイルに保存・読み込みもできます"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 460
        termsCountLabel.font = .systemFont(ofSize: 11, weight: .medium)
        // 件数の文が長いときは、ボタンを押し出さずに文の方を詰める (吹き出しの右端でボタンが切れないように)
        termsCountLabel.lineBreakMode = .byTruncatingTail
        termsCountLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let load = NSButton(title: L("読み込む…"), target: self, action: #selector(loadTerms))
        let save = NSButton(title: L("保存…"), target: self, action: #selector(saveTerms))
        let buttons = NSStackView(views: [termsCountLabel, NSView(), load, save])
        buttons.spacing = 8
        let stack = NSStackView(views: [languageRow, aiRow, title, termsBox, buttons, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        buttons.widthAnchor.constraint(equalTo: termsBox.widthAnchor).isActive = true
        // 左寄せの縦の並びは、右の余白 (edgeInsets.right) を大きさに入れないので、右端をはっきり決める
        // (決めないと「保存…」のボタンが吹き出しの右端にくっつき、説明の文も切れる)
        termsBox.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16).isActive = true
        let vc = NSViewController()
        vc.view = stack
        vc.preferredContentSize = stack.fittingSize
        let p = NSPopover()
        // ファイルの選択画面を開いても閉じないように、外を押したときだけ閉じる
        p.behavior = .transient
        p.contentViewController = vc
        return p
    }

    @objc func subtitleAIChanged(_ sender: NSButton) {
        subtitleAI = sender.state == .on
        if !subtitleAI { subtitleCorrections = [] }
    }

    /// 認識する言語を変えたら、字幕を出している途中ならその言語でやり直す
    @objc func subtitleLanguageChanged(_ sender: NSPopUpButton) {
        guard Self.subtitleLanguages.indices.contains(sender.indexOfSelectedItem) else { return }
        subtitleLanguage = Self.subtitleLanguages[sender.indexOfSelectedItem].id
        if subtitleButton.state == .on {
            subtitles.localeID = subtitleLanguage
            subtitles.start(microphone: selectedMic)
        }
    }

    /// 欄の内容をすぐ保存して、認識と置き換えに使う
    func applyTerms(_ text: String) {
        termsSaveTimer?.invalidate()
        subtitleTerms = text
        subtitles.terms = subtitleTermList
        cachedReplacements = subtitleReplacements
        updateTermsCount()
    }

    @objc func saveTerms() {
        applyTerms(termsView.string)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = L("字幕の置き換え.txt")
        panel.message = L("字幕の置き換えをファイルに保存します")
        termsPopover?.behavior = .applicationDefined
        defer { termsPopover?.behavior = .transient }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try termsView.string.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showAlert(L("保存できません: %@", error.localizedDescription))
        }
    }

    @objc func loadTerms() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        panel.message = L("字幕の置き換えのファイルを選びます (今の内容と入れ替わります)")
        termsPopover?.behavior = .applicationDefined
        defer { termsPopover?.behavior = .transient }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var enc = String.Encoding.utf8
            let text = try String(contentsOf: url, usedEncoding: &enc)
            termsView.string = text
            applyTerms(text)
        } catch {
            showAlert(L("読み込めません: %@", error.localizedDescription))
        }
    }

    /// 字幕に使っている置き換えの数を出す
    func updateTermsCount() {
        let n = subtitleReplacements.count
        termsCountLabel.stringValue = n == 0 ? L("置き換えは登録されていません") : L("✓ %d 件の置き換えを字幕に使っています", n)
        termsCountLabel.textColor = n == 0 ? .secondaryLabelColor : .systemGreen
    }

    /// 文が確定したら、録画中なら字幕ファイル用に時刻と一緒に残し、AI で直す
    func subtitleFinalized(_ text: String) {
        let end = Date()
        let start = utteranceStart ?? end.addingTimeInterval(-2)
        utteranceStart = nil
        var cueIndex: Int?
        if recordingSubtitles {
            subtitleCues.append(.init(start: start.timeIntervalSince(recordStart),
                                      end: end.timeIntervalSince(recordStart), text: text))
            cueIndex = subtitleCues.count - 1
        }
        refineSubtitle(text, cueIndex: cueIndex)
        recentFinals = Array((recentFinals + [text]).suffix(2))
    }

    /// 確定した文を AI で直し、直せたら画面の字幕と字幕ファイルの文を差し替える
    func refineSubtitle(_ text: String, cueIndex: Int?) {
        guard subtitleAI, SubtitleRefinerSupport.unavailableReason == nil else { return }
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return }
        let refiner = (subtitleRefiner as? SubtitleRefiner) ?? SubtitleRefiner()
        subtitleRefiner = refiner
        let context = recentFinals, terms = subtitleTermList, english = subtitleLanguage.hasPrefix("en")
        let recordingAt = recordStart
        Task {
            await refiner.refine(text, context: context, terms: terms, english: english) { fixed in
                DispatchQueue.main.async { [weak self] in
                    guard let self, let fixed, fixed != text else { return }
                    self.subtitleCorrections = Array((self.subtitleCorrections + [(text, fixed)]).suffix(10))
                    // 同じ録画の字幕ファイルの文も直す
                    if let i = cueIndex, self.recordingSubtitles, self.recordStart == recordingAt,
                       self.subtitleCues.indices.contains(i), self.subtitleCues[i].text == text {
                        self.subtitleCues[i].text = fixed
                    }
                    // まだ画面に出ていれば、直した文に差し替える
                    if !self.lastRawSubtitle.isEmpty, self.subtitleButton.state == .on, !self.processor.subtitle.isEmpty {
                        self.setSubtitle(self.corrected(self.lastRawSubtitle))
                    }
                }
            }
        }
        #endif
    }

    /// 聞き取ったままの字幕に、AI で直した文を当てる
    func corrected(_ text: String) -> String {
        var t = text
        for c in subtitleCorrections { t = t.replacingOccurrences(of: c.raw, with: c.fixed) }
        return t
    }

    /// 字幕を出し、しばらく話さなければ消す
    func showSubtitle(_ text: String) {
        guard subtitleButton.state == .on else { return }
        if utteranceStart == nil, !text.isEmpty { utteranceStart = Date() }
        lastRawSubtitle = text
        setSubtitle(corrected(text))
        subtitleClearTimer?.invalidate()
        subtitleClearTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            self?.lastRawSubtitle = ""
            self?.setSubtitle("")
        }
    }

    /// 字幕を、映像 (プレビュー・全画面出力・Syphon) とデスクトップの両方に出す。
    /// 全画面出力が「表示する画面」を覆っているときは、全画面出力の字幕だけにする
    func setSubtitle(_ text: String) {
        processor.subtitle = text
        let covered = outputWindow != nil && outputScreen == overlayScreen
        // 画面に人物を出しているときは、人物の反対側に出す (キーボードが下にあればその上)
        var person: ClosedRange<CGFloat>?
        if overlayOn && personOn {
            let right = overlayCorner == .bottomRight || overlayCorner == .topRight
            let s = CGFloat(overlayScale)
            person = right ? (1 - s)...1 : 0...s
        }
        var bottom: CGFloat?
        if keyboardWindow.isVisible, keyboardWindow.frame.midY < overlayScreen.frame.midY {
            bottom = keyboardWindow.frame.maxY
        }
        subtitleWindow.show(covered ? "" : text, on: overlayScreen, person: person, bottom: bottom)
    }

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
        // カメラなしで起動していたときも映るよう、止まっているセッションは動かし直す
        reopenCamera(devices[i])
    }

    @objc func qualityChanged(_ sender: NSPopUpButton) {
        settings.quality = [.fast, .balanced, .accurate][sender.indexOfSelectedItem]
    }
    @objc func featherChanged(_ sender: NSSlider) { settings.feather = sender.doubleValue }
    @objc func smoothingChanged(_ sender: NSSlider) { settings.smoothing = sender.doubleValue }
    @objc func tightenChanged(_ sender: NSSlider) { settings.tighten = sender.doubleValue }
    @objc func holdChanged(_ sender: NSSlider) { settings.hold = sender.doubleValue }
    @objc func mirrorChanged(_ sender: NSButton) {
        settings.mirror = sender.state == .on
        UserDefaults.standard.set(settings.mirror, forKey: "mirror")
    }
    @objc func flipChanged(_ sender: NSButton) {
        settings.flipVertical = sender.state == .on
        UserDefaults.standard.set(settings.flipVertical, forKey: "flipVertical")
    }
    @objc func alphaChanged(_ sender: NSButton) {
        settings.straightAlpha = sender.state == .on
        UserDefaults.standard.set(settings.straightAlpha, forKey: "straightAlpha")
    }
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
appMenu.addItem(withTitle: L("NoGreenBack を終了"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu
let helpItem = NSMenuItem()
mainMenu.addItem(helpItem)
let helpMenu = NSMenu(title: L("ヘルプ"))
let shortcutItem = helpMenu.addItem(withTitle: L("ショートカットの一覧"), action: #selector(AppDelegate.showShortcuts(_:)), keyEquivalent: "/")
shortcutItem.target = delegate
helpItem.submenu = helpMenu
app.mainMenu = mainMenu
app.helpMenu = helpMenu

app.run()
