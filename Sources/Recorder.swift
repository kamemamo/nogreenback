// 画面録画: ScreenCaptureKit で画面を受け取り、AVAssetWriter で H.264 の .mov に書き出す
// 圧縮は Apple Silicon のメディアエンジン (専用回路) が行うので、CPU の負担は小さい。
// 画面に重ねた人物と手書きの注釈もそのまま録画される (NoGreenBack の操作ウィンドウだけは除く)

import AppKit
import AVFoundation
import ScreenCaptureKit

@available(macOS 12.3, *)
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate,
                            AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// 録画の長辺のピクセル数 (Retina をそのまま録ると重くファイルも大きいので 1080p 相当に縮める)
    static let maxWidth = 1920

    private let queue = DispatchQueue(label: "recorder", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var audioSession: AVCaptureSession?
    private var started = false
    private(set) var url: URL?

    /// 失敗したときの通知 (メインスレッドで呼ぶ)
    var onError: ((String) -> Void)?

    /// - Parameters:
    ///   - screen: 録画する画面
    ///   - excluding: 録画に映さないウィンドウ (操作ウィンドウ) の番号
    ///   - microphone: 音声を録るマイク (nil なら音声なし)
    func start(screen: NSScreen, excluding windowNumbers: [Int], microphone: AVCaptureDevice?) async throws -> URL {
        // 画面収録の許可がない場合、ここで macOS が許可を求める (または失敗する)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw RecorderError.message("録画する画面が見つかりません")
        }
        let excluded = content.windows.filter { windowNumbers.contains(Int($0.windowID)) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        // 縦横比を保って長辺を maxWidth 以下に (エンコーダのため偶数にそろえる)
        // display.width はポイント単位なので、Retina や HiDPI の画面では実際の画素数に直す
        let pixelScale = screen.backingScaleFactor
        let pixelWidth = Double(display.width) * pixelScale, pixelHeight = Double(display.height) * pixelScale
        let scale = min(1, Double(Self.maxWidth) / pixelWidth)
        let width = Int(pixelWidth * scale) / 2 * 2
        let height = Int(pixelHeight * scale) / 2 * 2

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.queueDepth = 6

        // 書き出し先: ムービーフォルダ
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = movies.appendingPathComponent("NoGreenBack \(stamp.string(from: Date())).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)

        var audioSession: AVCaptureSession?
        if let mic = microphone {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw RecorderError.message("マイクへのアクセスが許可されていません。\nシステム設定 > プライバシーとセキュリティ > マイク で許可してください。")
            }
            do {
                let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 1,
                    AVSampleRateKey: 48_000,
                    AVEncoderBitRateKey: 128_000,
                ])
                audio.expectsMediaDataInRealTime = true
                writer.add(audio)
                audioInput = audio

                let session = AVCaptureSession()
                let input = try AVCaptureDeviceInput(device: mic)
                if session.canAddInput(input) { session.addInput(input) }
                let output = AVCaptureAudioDataOutput()
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
        return url
    }

    /// 録画を止めてファイルを閉じる。書き出したファイルの場所を返す
    func stop() async -> URL? {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        audioSession?.stopRunning()
        audioSession = nil
        let writer: AVAssetWriter? = queue.sync {
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            return self.writer
        }
        guard let writer else { return nil }
        if started {
            await writer.finishWriting()
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

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        // 映像が始まる前の音は捨てる (始点を映像にそろえる)
        guard started, let audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sb)
    }
}

enum RecorderError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}
