// NoGreenBack — Webカメラから人物だけをリアルタイムで切り抜き、Syphon で送出する macOS アプリ
//
// パイプライン:
//   AVCaptureSession (BGRA) → Vision 人物セグメンテーション (マスク)
//   → Core Image で元映像にマスクを適用 (背景は透明)
//   → MTLTexture に描画 → SyphonMetalServer で送出 + プレビュー表示

import AppKit
import AVFoundation
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
    private var _flipVertical = false
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

        let root = NSStackView(views: [bar, bar2, preview])
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .leading
        bar.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        bar2.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        preview.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
            if !session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .high }
        } catch {
            showAlert("カメラを開けません: \(error.localizedDescription)")
        }
        session.commitConfiguration()
        applyFrameRate()
    }

    /// 選んだフレームレートをカメラに設定する (カメラが対応していなければ範囲内に丸める)
    func applyFrameRate() {
        guard let device = currentDevice else { return }
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        guard !ranges.isEmpty else { return }
        let want = Double(targetFPS)
        let lo = ranges.map(\.minFrameRate).min()!, hi = ranges.map(\.maxFrameRate).max()!
        let fps = min(max(want, lo), hi)
        let duration = CMTime(value: 1000, timescale: CMTimeScale(fps * 1000))
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            NSLog("frame rate error: \(error)")
        }
    }

    @objc func fpsChanged(_ sender: NSPopUpButton) {
        targetFPS = frameRates[sender.indexOfSelectedItem].fps
        applyFrameRate()
    }
    @objc func deflickerChanged(_ sender: NSSlider) { settings.deflicker = sender.doubleValue }

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
