// 画面録画: ScreenCaptureKit で画面を受け取り、AVAssetWriter で H.264 / HEVC に圧縮して保存する
// OBS の「Hybrid MP4」と同じ考え方で、落ちても消えず、止めたら普通の MP4 になるようにする:
//   録画中 … 2 秒ごとに区切って .mov に書き込む (アプリが落ちても、それまでの分は再生できる)
//   停止時 … 再圧縮せずに .mp4 へ詰め替えて、.mov を消す
// (AVAssetWriter は .mp4 だと区切りの書き込みが途中で止まるため、録画中は .mov を使う)
// 圧縮は Apple Silicon のメディアエンジン (専用回路) が行うので、CPU の負担は小さい。
// 画面に重ねた人物と手書きの注釈もそのまま録画される (NoGreenBack の操作ウィンドウだけは除く)

import AppKit
import AVFoundation
import ScreenCaptureKit

/// 録画の設定 (メイン画面の「録画の設定」の段で選ぶ)
struct RecordSettings {
    /// 映像の平均ビットレート (Mbps)
    var videoMbps = 8
    /// 長辺の最大ピクセル数 (0 なら縮めずに画面の画素数のまま)
    var maxLongSide = 1920
    /// 最大フレームレート
    var fps = 30
    /// true なら HEVC (H.265)、false なら H.264
    var hevc = false
    /// 音声のビットレート (kbps)
    var audioKbps = 128

    static let videoMbpsChoices = [4, 6, 8, 10, 12, 16, 20, 30, 40]
    static let maxLongSideChoices = [1280, 1920, 2560, 3840, 0]
    static let fpsChoices = [24, 25, 30, 50, 60]
    static let audioKbpsChoices = [64, 96, 128, 192, 256]
}

@available(macOS 12.3, *)
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate,
                            AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "recorder", qos: .userInitiated)
    private var stream: SCStream?
    private var display: SCDisplay?

    /// NoGreenBack のウィンドウは、映すと決めたものだけを残して外す
    /// (後から出したウィンドウも、指定しなければ映らない)
    private static func filter(content: SCShareableContent, display: SCDisplay, keeping numbers: [Int]) -> SCContentFilter {
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let keep = content.windows.filter { numbers.contains(Int($0.windowID)) }
        return SCContentFilter(display: display, excludingApplications: me, exceptingWindows: keep)
    }

    /// 録画中に、映すウィンドウが変わったとき (全画面出力を出したときなど) に呼ぶ
    func updateKeptWindows(_ numbers: [Int]) async {
        guard let stream, let display,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
        try? await stream.updateContentFilter(Self.filter(content: content, display: display, keeping: numbers))
    }
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var audioSession: AVCaptureSession?
    private var started = false
    /// 書き込めた音のかたまりの数 (0 のままなら、マイクの音が届いていない)
    private(set) var audioSamplesWritten = 0
    /// マイクの音を録る設定だったか
    private(set) var recordsAudio = false
    private(set) var url: URL?

    /// 失敗したときの通知 (メインスレッドで呼ぶ)
    var onError: ((String) -> Void)?

    /// - Parameters:
    ///   - screen: 録画する画面
    ///   - keeping: 録画に映す NoGreenBack のウィンドウ (重ねた人物・手書き・全画面出力) の番号。
    ///     NoGreenBack のそれ以外のウィンドウ (操作ウィンドウや停止ボタン) は映さない
    ///   - microphone: 音声を録るマイク (nil なら音声なし)
    ///   - external: 外部の音声。マイクがあればマイクと混ぜ、なければこれだけを録る
    ///   - settings: 画質などの設定
    func start(screen: NSScreen, keeping windowNumbers: [Int], microphone: AVCaptureDevice?,
               external: ExternalAudio? = nil, settings: RecordSettings) async throws -> URL {
        // 画面収録の許可がない場合、ここで macOS が許可を求める (または失敗する)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw RecorderError.message("録画する画面が見つかりません")
        }
        self.display = display
        let filter = Self.filter(content: content, display: display, keeping: windowNumbers)

        // 縦横比を保って長辺を設定の値以下に (エンコーダのため偶数にそろえる)
        // display.width はポイント単位なので、Retina や HiDPI の画面では実際の画素数に直す
        let pixelScale = screen.backingScaleFactor
        let pixelWidth = Double(display.width) * pixelScale, pixelHeight = Double(display.height) * pixelScale
        let longSide = max(pixelWidth, pixelHeight)
        let scale = settings.maxLongSide > 0 ? min(1, Double(settings.maxLongSide) / longSide) : 1
        let width = Int(pixelWidth * scale) / 2 * 2
        let height = Int(pixelHeight * scale) / 2 * 2

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.queueDepth = 6

        // 書き出し先: ムービーフォルダ
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = movies.appendingPathComponent("NoGreenBack \(stamp.string(from: Date())).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // 2 秒ごとにフラグメントを書き出す (途中で止まっても最大 2 秒分しか失わない)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: settings.videoMbps * 1_000_000,
                AVVideoExpectedSourceFrameRateKey: settings.fps,
                AVVideoMaxKeyFrameIntervalKey: settings.fps * 2,   // 2 秒ごとにキーフレーム
            ],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)

        var audioSession: AVCaptureSession?
        if microphone != nil || external != nil {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw RecorderError.message("マイクへのアクセスが許可されていません。\nシステム設定 > プライバシーとセキュリティ > マイク で許可してください。")
            }
            do {
                let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 1,
                    AVSampleRateKey: 48_000,
                    AVEncoderBitRateKey: settings.audioKbps * 1000,
                ])
                audio.expectsMediaDataInRealTime = true
                writer.add(audio)
                audioInput = audio
                recordsAudio = true
            }
        }
        if let mic = microphone {
            do {
                let session = AVCaptureSession()
                let input = try AVCaptureDeviceInput(device: mic)
                if session.canAddInput(input) { session.addInput(input) }
                let output = AVCaptureAudioDataOutput()
                // マイクごとに形式が違う (Bluetooth は 16kHz や 24kHz、仮想デバイスはステレオなど) ので、
                // 48kHz・モノラルにそろえてから書き込む。そろえないと音が入らないことがある
                output.audioSettings = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                    AVLinearPCMIsBigEndianKey: false,
                ]
                output.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(output) { session.addOutput(output) }
                audioSession = session
            }
        }

        guard writer.startWriting() else {
            throw RecorderError.message("録画ファイルを作れません: \(writer.error?.localizedDescription ?? "")")
        }
        self.writer = writer
        self.videoInput = video
        self.url = url
        self.started = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        // 画面とマイクはどちらもホスト時刻で時刻が付くので、同じ時間軸に並べられる
        audioSession?.startRunning()
        self.audioSession = audioSession
        // 外部の音声: マイクがあれば混ぜるためにためておき、なければそのまま録る
        if let external {
            let mixing = microphone != nil
            mixesExternal = mixing
            fifoLock.withLock { fifo.removeAll() }
            external.tap = { [weak self] sb in
                guard let self else { return }
                if mixing { self.pushExternal(sb) } else { self.queue.async { self.appendAudio(sb, mixing: false, scale: true) } }
            }
            self.external = external
        }
        return url
    }

    /// 録画を止めてファイルを閉じる。書き出したファイルの場所を返す
    /// - Parameter subtitles: 録画中に確定した字幕。あれば、動画に字幕トラックとして入れる
    func stop(subtitles: [SubtitleFile.Cue] = []) async -> URL? {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        audioSession?.stopRunning()
        audioSession = nil
        external?.tap = nil
        external = nil
        let writer: AVAssetWriter? = queue.sync {
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            return self.writer
        }
        guard let writer else { return nil }
        if started {
            await writer.finishWriting()
            if writer.status == .completed, let mov = url {
                // 字幕付きで詰め替え、失敗したら字幕なしでもう一度
                var mp4 = await Self.remuxToMP4(mov, subtitles: subtitles)
                if mp4 == nil, !subtitles.isEmpty { mp4 = await Self.remuxToMP4(mov) }
                if let mp4 { self.url = mp4 }
            }
        } else {
            // 1 フレームも届かなかった (画面に変化がなかった等) 場合は空ファイルを消す
            writer.cancelWriting()
            if let url { try? FileManager.default.removeItem(at: url) }
            self.url = nil
        }
        self.writer = nil
        videoInput = nil
        audioInput = nil
        return url
    }

    /// .mov を再圧縮せずに .mp4 へ詰め替える。成功したら .mov を消して .mp4 の場所を返す
    /// (失敗したときは .mov をそのまま残す)
    static func remuxToMP4(_ mov: URL, subtitles: [SubtitleFile.Cue] = []) async -> URL? {
        let mp4 = mov.deletingPathExtension().appendingPathExtension("mp4")
        let asset = AVURLAsset(url: mov)
        // 字幕があれば、映像・音声に字幕トラックを足した組み合わせを書き出す (うまくいかなければ字幕なし)
        var source: AVAsset = asset
        var subFile: URL?
        if !subtitles.isEmpty, let comp = await withSubtitleTrack(asset, subtitles: subtitles, tempNear: mov) {
            source = comp.asset
            subFile = comp.file
        }
        defer { if let subFile { try? FileManager.default.removeItem(at: subFile) } }
        guard let export = AVAssetExportSession(asset: source, presetName: AVAssetExportPresetPassthrough) else { return nil }
        export.outputURL = mp4
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true   // 先頭に目次を置く (読み込みが速い)
        await export.export()
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: mp4)
            return nil
        }
        try? FileManager.default.removeItem(at: mov)
        return mp4
    }

    /// 録画 (.mov) の映像・音声に、字幕トラックを足した組み合わせを作る
    private static func withSubtitleTrack(_ asset: AVURLAsset, subtitles: [SubtitleFile.Cue],
                                          tempNear mov: URL) async -> (asset: AVAsset, file: URL)? {
        let subURL = mov.deletingPathExtension().appendingPathExtension("subtitles.mov")
        do {
            let duration = try await asset.load(.duration).seconds
            try await SubtitleTrack.write(subtitles, duration: duration, to: subURL)
            let comp = AVMutableComposition()
            for t in try await asset.loadTracks(withMediaType: .video) + asset.loadTracks(withMediaType: .audio) {
                guard let ct = comp.addMutableTrack(withMediaType: t.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try ct.insertTimeRange(try await t.load(.timeRange), of: t, at: .zero)
            }
            let subAsset = AVURLAsset(url: subURL)
            guard let st = try await subAsset.loadTracks(withMediaType: .subtitle).first,
                  let ct = comp.addMutableTrack(withMediaType: .subtitle, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                try? FileManager.default.removeItem(at: subURL)
                return nil
            }
            try ct.insertTimeRange(try await st.load(.timeRange), of: st, at: .zero)
            ct.languageCode = "jpn"
            ct.extendedLanguageTag = "ja"
            return (comp, subURL)
        } catch {
            try? FileManager.default.removeItem(at: subURL)
            return nil
        }
    }

    // MARK: 画面のフレーム

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, let writer, let videoInput else { return }
        // 画面に変化がない間は「完了」でないフレーム (中身なし) が来るので捨てる
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete else { return }
        if !started {
            writer.startSession(atSourceTime: sb.presentationTimeStamp)
            started = true
        }
        if videoInput.isReadyForMoreMediaData { videoInput.append(sb) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let msg = error.localizedDescription
        DispatchQueue.main.async { self.onError?("録画が止まりました: \(msg)") }
    }

    // MARK: マイクの音声

    /// 録画中のマイクの入力レベル (dBFS)。録画中はメーターもこの値を使う
    /// (同じ Bluetooth マイクを 2 か所から開くと、音が途切れやすくなるため)
    var level: Float { levelLock.lock(); defer { levelLock.unlock() }; return _level }
    private let levelLock = NSLock()
    private var _level: Float = -160
    /// 音の時刻の基準と、そこから書き込んだサンプル数
    private var audioAnchor: CMTime?
    private var audioFrames: Int64 = 0

    /// 外部の音声 (録画中だけ)
    private var external: ExternalAudio?
    /// true ならマイクの音に外部の音を足して書く
    private var mixesExternal = false
    /// マイクの音に足すまで、外部の音をためておく所
    private let fifoLock = NSLock()
    private var fifo: [Float] = []

    /// 録画に入れる外部の音の大きさ (スピーカー音量と連動)
    var externalGain: Float = 1
    /// 声で外部の音を下げる: 話している間の外部の音の倍率 (1 なら下げない)
    var duckLevel: Float = 1
    /// 今の外部の音の倍率 (下げている間は duckLevel に近づく)
    private(set) var duckGain: Float = 1
    /// 話し終わってから、まだ下げたままにする残りサンプル数
    private var duckHold = 0

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        let db = connection.audioChannels.map(\.averagePowerLevel).max() ?? -160
        levelLock.lock(); _level = db; levelLock.unlock()
        appendAudio(sb, mixing: mixesExternal)
    }

    /// 外部の音をためる。たまりすぎたら (時計のずれなど) 古いほうを捨てて遅れないようにする
    private func pushExternal(_ sb: CMSampleBuffer) {
        guard let samples = Self.floats(sb) else { return }
        fifoLock.lock()
        fifo += samples
        if fifo.count > 9_600 { fifo.removeFirst(fifo.count - 2_400) }   // 0.2 秒を超えたら 0.05 秒まで
        fifoLock.unlock()
    }

    /// 48kHz・モノラル・Float32 の音をサンプルの配列にする
    private static func floats(_ sb: CMSampleBuffer) -> [Float]? {
        guard let asbd = sb.formatDescription?.audioStreamBasicDescription,
              asbd.mChannelsPerFrame == 1, asbd.mBitsPerChannel == 32,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        let frames = CMSampleBufferGetNumSamples(sb)
        let bytes = frames * 4
        guard frames > 0, CMBlockBufferGetDataLength(block) >= bytes else { return nil }
        var samples = [Float](repeating: 0, count: frames)
        let ok = samples.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) == noErr
        }
        return ok ? samples : nil
    }

    /// サンプルの配列から音のバッファを作る
    private static func buffer(_ samples: [Float], format: CMFormatDescription, pts: CMTime) -> CMSampleBuffer? {
        let bytes = samples.count * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let ok = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: bytes) == noErr
        }
        guard ok else { return nil }
        var out: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                             sampleCount: samples.count, presentationTimeStamp: pts,
                                                             packetDescriptions: nil, sampleBufferOut: &out)
        return out
    }

    /// 音を時刻を付け直して書き込む (mixing なら、ためた外部の音を足してから)
    /// - scale: 外部の音だけを録るとき、externalGain を掛けてから書く
    private func appendAudio(_ sb: CMSampleBuffer, mixing: Bool, scale: Bool = false) {
        // 映像が始まる前の音は捨てる (始点を映像にそろえる)
        guard started, let audioInput else { return }
        let frames = Int64(CMSampleBufferGetNumSamples(sb))
        let rate = Int32(sb.formatDescription?.audioStreamBasicDescription?.mSampleRate ?? 48_000)
        guard frames > 0, rate > 0 else { return }

        // Bluetooth のマイクは音の届く時刻が不規則なので、届いた時刻のまま書くと、すき間が無音になって途切れる。
        // 最初の時刻を基準に、サンプル数から時刻を付け直して隙間なく並べる。
        // ただし 0.25 秒以上ずれたとき (本当に音が途切れた、映像とずれてきた) は基準を取り直す
        let pts = sb.presentationTimeStamp
        let offset = CMTime(value: audioFrames, timescale: rate)
        if let anchor = audioAnchor {
            let drift = CMTimeGetSeconds(CMTimeSubtract(pts, CMTimeAdd(anchor, offset)))
            if abs(drift) > 0.25 { audioAnchor = CMTimeSubtract(pts, offset) }
        } else {
            audioAnchor = CMTimeSubtract(pts, offset)
        }
        let newPTS = CMTimeAdd(audioAnchor!, offset)
        var retimed: CMSampleBuffer?
        if mixing, var samples = Self.floats(sb), let format = sb.formatDescription {
            // マイクの声の大きさで、外部の音を下げるか決める
            // (すぐ下げ・0.6 秒待ってからゆっくり戻すので、言葉の切れ目で上がったり下がったりしない)
            let target = duckLevel
            if target < 1 {
                let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
                if 20 * log10(max(rms, 1e-9)) > VoiceDuck.threshold { duckHold = 28_800 }
                else { duckHold = max(0, duckHold - samples.count) }
            } else {
                duckHold = 0
            }
            let goal: Float = duckHold > 0 ? target : 1
            let down = (1 - target) / 2_400 + 1e-6     // 0.05 秒で下げる
            let up = (1 - target) / 24_000 + 1e-6      // 0.5 秒で戻す
            var gain = duckGain
            fifoLock.lock()
            let n = min(samples.count, fifo.count)
            for i in 0..<samples.count {
                gain = gain > goal ? max(goal, gain - down) : min(goal, gain + up)
                if i < n { samples[i] = max(-1, min(1, samples[i] + fifo[i] * gain * externalGain)) }
            }
            duckGain = gain
            fifo.removeFirst(n)
            fifoLock.unlock()
            retimed = Self.buffer(samples, format: format, pts: newPTS)
        }
        if retimed == nil, scale, externalGain != 1, var samples = Self.floats(sb), let format = sb.formatDescription {
            for i in 0..<samples.count { samples[i] = max(-1, min(1, samples[i] * externalGain)) }
            retimed = Self.buffer(samples, format: format, pts: newPTS)
        }
        if retimed == nil {
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: rate),
                                            presentationTimeStamp: newPTS, decodeTimeStamp: .invalid)
            CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1,
                                                  sampleTimingArray: &timing, sampleBufferOut: &retimed)
        }
        audioFrames += frames
        guard let retimed, audioInput.isReadyForMoreMediaData else { return }
        if audioInput.append(retimed) { audioSamplesWritten += 1 }
    }
}

enum RecorderError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}
