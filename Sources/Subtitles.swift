// 字幕 (試作): マイクの声を Mac の中で文字にして、映像の下に重ねる
// Apple の音声認識 (Speech) を使う。対応している言語なら端末内だけで認識し、音声はネットに送らない

import AVFoundation
import AppKit
import CoreImage
import Speech

/// マイクの声を文字にする。話している途中の文字も次々に知らせる
final class SubtitleEngine: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "subtitles")
    private var session: AVCaptureSession?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var running = false
    /// 続けて失敗した回数 (すぐ失敗し続けるときは止めて知らせる)
    private var failures = 0

    /// 認識した文字 (話している途中のものも含む)。メインスレッドで呼ぶ
    var onText: ((String) -> Void)?
    /// 使えないときの知らせ。メインスレッドで呼ぶ
    var onError: ((String) -> Void)?

    /// macOS 26 以降の新しい認識 (ModernTranscriber)。「音声入力」の設定がオフでも使える
    private var modern: AnyObject?

    /// 聞き取りやすくしたい専門用語や固有名詞 (認識のヒントにする)
    var terms: [String] = [] {
        didSet {
            if #available(macOS 26.0, *) { (modern as? ModernTranscriber)?.setTerms(terms) }
        }
    }

    func start(microphone: AVCaptureDevice?) {
        stop()
        if #available(macOS 26.0, *) {
            let m = ModernTranscriber()
            m.terms = terms
            m.onText = { [weak self] in self?.onText?($0) }
            m.onError = { [weak self] in self?.onError?($0) }
            modern = m
            m.start(microphone: microphone)
            return
        }
        // 古い macOS: 従来の認識 (システム設定の「音声入力」がオンである必要がある)
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self.onError?("音声認識が許可されていません。\n「システム設定 > プライバシーとセキュリティ > 音声認識」で NoGreenBack を許可してください。")
                    return
                }
                guard let recognizer = self.recognizer, recognizer.isAvailable else {
                    self.onError?("日本語の音声認識が使えません。")
                    return
                }
                guard let mic = microphone ?? AVCaptureDevice.default(for: .audio),
                      let input = try? AVCaptureDeviceInput(device: mic) else {
                    self.onError?("字幕に使うマイクを開けません。")
                    return
                }
                let session = AVCaptureSession()
                let output = AVCaptureAudioDataOutput()
                output.setSampleBufferDelegate(self, queue: self.queue)
                if session.canAddInput(input) { session.addInput(input) }
                if session.canAddOutput(output) { session.addOutput(output) }
                self.session = session
                self.lock.lock(); self.running = true; self.lock.unlock()
                self.queue.async {
                    self.beginTask()
                    session.startRunning()
                }
            }
        }
    }

    func stop() {
        if #available(macOS 26.0, *) { (modern as? ModernTranscriber)?.stop() }
        modern = nil
        lock.lock(); running = false; lock.unlock()
        if let session { queue.async { session.stopRunning() } }
        session = nil
        queue.async {
            self.request?.endAudio()
            self.task?.cancel()
            self.request = nil
            self.task = nil
        }
    }

    /// 認識をひと区切り始める (話の区切りや、認識が終わるたびに作り直す)
    private func beginTask() {
        lock.lock(); let ok = running; lock.unlock()
        guard ok, let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        if #available(macOS 13.0, *) { request.addsPunctuation = true }
        request.contextualStrings = terms
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.queue.async { self.failures = 0 }
                DispatchQueue.main.async { self.onText?(text) }
            }
            if let error {
                NSLog("NoGreenBack subtitles error: \(error as NSError)")
            }
            if error != nil || result?.isFinal == true {
                // 区切りがついたら次の認識を始める (長く話し続けても止まらないように)
                self.queue.async {
                    guard self.task != nil else { return }
                    self.request?.endAudio()
                    self.task = nil
                    if error != nil && result == nil {
                        self.failures += 1
                        if self.failures >= 5 {
                            let msg = (error as NSError?)?.localizedDescription ?? ""
                            DispatchQueue.main.async { self.onError?("音声認識を始められません: \(msg)") }
                            return
                        }
                    }
                    // 少し間をあけてから次を始める
                    self.queue.asyncAfter(deadline: .now() + 0.3) { self.beginTask() }
                }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        request?.appendAudioSampleBuffer(sb)
    }
}

/// macOS 26 以降の認識 (SpeechAnalyzer + SpeechTranscriber)。
/// 端末内で長い話を続けて認識でき、システム設定の「音声入力」に左右されない
@available(macOS 26.0, *)
final class ModernTranscriber: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "subtitles-modern")
    private var session: AVCaptureSession?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    /// マイクから受け取る形 (48kHz・モノラル・32bit 浮動小数)
    private let captureFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                              channels: 1, interleaved: false)!
    private var analyzerFormat: AVAudioFormat?
    // 字幕に出す文字: 確定した文 + 認識中の文
    private var committed = ""
    private var lastResult = Date.distantPast
    /// 聞き取りやすくしたい用語
    var terms: [String] = []

    /// 認識中に用語が変わったら、すぐ使う
    func setTerms(_ terms: [String]) {
        self.terms = terms
        guard let analyzer else { return }
        Task { try? await analyzer.setContext(Self.context(terms)) }
    }

    private static func context(_ terms: [String]) -> AnalysisContext {
        let context = AnalysisContext()
        context.contextualStrings[.general] = terms
        return context
    }

    func start(microphone: AVCaptureDevice?) {
        Task { @MainActor in
            do {
                try await self.run(microphone: microphone)
            } catch {
                self.onError?("音声認識を始められません: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func run(microphone: AVCaptureDevice?) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ja-JP")) else {
            throw NSError(domain: "NoGreenBack", code: 1, userInfo: [NSLocalizedDescriptionKey: "日本語の認識に対応していません"])
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        // 日本語の認識データがなければダウンロードする (初回だけ)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onText?("（日本語の認識データを準備しています…）")
            try await request.downloadAndInstall()
            onText?("")
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "NoGreenBack", code: 2, userInfo: [NSLocalizedDescriptionKey: "音声の形式を決められません"])
        }
        analyzerFormat = format
        converter = AVAudioConverter(from: captureFormat, to: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        if !terms.isEmpty { try await analyzer.setContext(Self.context(terms)) }

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    self.queue.async { self.received(text, isFinal: result.isFinal) }
                }
            } catch {
                let msg = error.localizedDescription
                DispatchQueue.main.async { self?.onError?("音声認識が止まりました: \(msg)") }
            }
        }
        try await analyzer.start(inputSequence: stream)

        // マイクを開く
        guard let mic = microphone ?? AVCaptureDevice.default(for: .audio) else {
            throw NSError(domain: "NoGreenBack", code: 3, userInfo: [NSLocalizedDescriptionKey: "字幕に使うマイクがありません"])
        }
        let input = try AVCaptureDeviceInput(device: mic)
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        self.session = session
        queue.async { session.startRunning() }
    }

    /// 認識した文字を、字幕に出す文字にまとめる
    private func received(_ text: String, isFinal: Bool) {
        // しばらく話していなかったら、前の文は消して新しく始める
        if Date().timeIntervalSince(lastResult) > 4 { committed = "" }
        lastResult = Date()
        let shown: String
        if isFinal {
            committed = String((committed + text).suffix(200))
            shown = committed
        } else {
            shown = committed + text
        }
        DispatchQueue.main.async { self.onText?(shown) }
    }

    func stop() {
        if let session { queue.async { session.stopRunning() } }
        session = nil
        continuation?.finish()
        continuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let continuation, let converter, let analyzerFormat else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames),
                                                           into: pcm.mutableAudioBufferList) == noErr else { return }
        // 認識に合う形 (多くは 16kHz) に変換する
        let ratio = analyzerFormat.sampleRate / captureFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return pcm
        }
        if err == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
    }
}

/// 字幕の文字を、映像に重ねる画像にする
enum SubtitleRenderer {
    /// 1 行の文字数と、出す行数 (長い話は最後の部分だけ出す)
    static let lineLength = 26
    static let maxLines = 2

    /// 長い文を行に分けて、最後の数行だけにする
    static func lines(_ text: String) -> [String] {
        let chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !chars.isEmpty else { return [] }
        var result: [String] = []
        var i = 0
        while i < chars.count {
            result.append(String(chars[i..<min(i + lineLength, chars.count)]))
            i += lineLength
        }
        return Array(result.suffix(maxLines))
    }

    /// 映像の大きさ (extent) に合わせて、下の中央に置いた字幕の画像を作る
    static func image(text: String, extent: CGRect) -> CIImage? {
        let lines = lines(text)
        guard !lines.isEmpty else { return nil }
        let fontSize = extent.height * 0.05
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineSpacing = fontSize * 0.15
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = fontSize * 0.15
        let attributed = NSAttributedString(string: lines.joined(separator: "\n"), attributes: [
            .font: font, .foregroundColor: NSColor.white, .paragraphStyle: style, .shadow: shadow,
        ])
        let gen = CIFilter(name: "CIAttributedTextImageGenerator")!
        gen.setValue(attributed, forKey: "inputText")
        gen.setValue(1.0, forKey: "inputScaleFactor")
        guard let textImage = gen.outputImage else { return nil }
        // 半透明の黒い帯を敷く
        let pad = fontSize * 0.4
        let box = CGRect(x: 0, y: 0, width: textImage.extent.width + pad * 2,
                         height: textImage.extent.height + pad * 2)
        let back = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.55)).cropped(to: box)
        let label = textImage.transformed(by: CGAffineTransform(translationX: pad - textImage.extent.minX,
                                                                y: pad - textImage.extent.minY))
            .composited(over: back)
        // 下の中央 (下から映像の高さの 6%)
        let x = extent.midX - box.width / 2
        let y = extent.minY + extent.height * 0.06
        return label.transformed(by: CGAffineTransform(translationX: x, y: y))
    }
}

/// デスクトップの下の中央に出す字幕 (画面に重ねる表示や録画に字幕を入れるため)。
/// クリックは後ろのアプリに届く
final class SubtitleWindow: NSPanel {
    private let box = NSView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // 人物の表示と同じ、最上位の層
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        label.maximumNumberOfLines = 0
        label.alignment = .center
        label.lineBreakMode = .byClipping
        box.addSubview(label)
        contentView = box
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 字幕を出す (空なら隠す)。映像に重ねる字幕と同じ見た目にする
    func show(_ text: String, on screen: NSScreen) {
        let lines = SubtitleRenderer.lines(text)
        guard !lines.isEmpty else { orderOut(nil); return }
        let sf = screen.frame
        let fontSize = (sf.height * 0.04).rounded()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineSpacing = fontSize * 0.15
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = fontSize * 0.15
        let attributed = NSAttributedString(string: lines.joined(separator: "\n"), attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white, .paragraphStyle: style, .shadow: shadow,
        ])
        label.attributedStringValue = attributed
        // 実際に表示するラベルで大きさを測る (計算だけだと少し小さく出て、文字が切れるため)
        let text = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: sf.width * 0.9,
                                                          height: .greatestFiniteMagnitude)) ?? .zero
        let pad = (fontSize * 0.4).rounded()
        let w = ceil(text.width) + pad * 2, h = ceil(text.height) + pad * 2
        setFrame(NSRect(x: sf.midX - w / 2, y: sf.minY + sf.height * 0.06, width: w, height: h), display: true)
        label.frame = NSRect(x: pad, y: pad, width: w - pad * 2, height: h - pad * 2)
        box.layer?.cornerRadius = fontSize * 0.25
        orderFrontRegardless()
    }
}
