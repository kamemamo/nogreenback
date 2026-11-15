// 外部の音声: キャプチャーボードやオーディオインターフェースの音を取り込み、
//   ・選んだスピーカー (外部スピーカーなど) にそのまま出す (LadioCast のような「聞きながら」)
//   ・録画のときはマイクの音と混ぜて 1 本の音声にする
// 取り込みは録画とは別に、選んでいる間ずっと開いておく (スピーカーに出し続けるため)

import AVFoundation
import CoreAudio

final class ExternalAudio: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "external-audio", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var preview: AVCaptureAudioPreviewOutput?
    private(set) var device: AVCaptureDevice?

    private let lock = NSLock()
    private var _level: Float = -160
    private var _tap: ((CMSampleBuffer) -> Void)?

    /// 直近の平均レベル (dBFS、無音で -160)
    var level: Float { lock.lock(); defer { lock.unlock() }; return _level }

    /// 録画中に、届いた音 (48kHz・モノラル・Float32) を受け取る
    var tap: ((CMSampleBuffer) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _tap }
        set { lock.lock(); _tap = newValue; lock.unlock() }
    }

    /// 取り込む機器を切り替える (nil なら止める)
    /// - Parameters:
    ///   - outputUID: スピーカーに出すときの出力先 (nil ならスピーカーに出さない、"" ならシステムの出力)
    func start(_ device: AVCaptureDevice?, outputUID: String?, volume: Float) {
        stop()
        self.device = device
        guard let device else { return }
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            guard ok else { return }
            DispatchQueue.main.async {
                guard self.device?.uniqueID == device.uniqueID, self.session == nil,
                      let input = try? AVCaptureDeviceInput(device: device) else { return }
                let session = AVCaptureSession()
                if session.canAddInput(input) { session.addInput(input) }
                let output = AVCaptureAudioDataOutput()
                // 録画のマイクと同じ 48kHz・モノラルにそろえる (そのまま足し合わせられるように)
                output.audioSettings = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                    AVLinearPCMIsBigEndianKey: false,
                ]
                output.setSampleBufferDelegate(self, queue: self.queue)
                if session.canAddOutput(output) { session.addOutput(output) }
                self.session = session
                self.setMonitor(outputUID: outputUID, volume: volume)
                self.queue.async { session.startRunning() }
            }
        }
    }

    /// スピーカーへの出力を切り替える (nil なら出さない、"" ならシステムの出力)
    func setMonitor(outputUID: String?, volume: Float) {
        guard let session else { return }
        if let preview, let uid = outputUID, (preview.outputDeviceUniqueID ?? "") == uid {
            preview.volume = volume
            return
        }
        session.beginConfiguration()
        if let preview { session.removeOutput(preview) }
        preview = nil
        if let uid = outputUID {
            let p = AVCaptureAudioPreviewOutput()
            p.outputDeviceUniqueID = uid.isEmpty ? nil : uid
            p.volume = volume
            if session.canAddOutput(p) {
                session.addOutput(p)
                preview = p
            }
        }
        session.commitConfiguration()
    }

    func stop() {
        if let session { queue.async { session.stopRunning() } }
        session = nil
        preview = nil
        device = nil
        lock.lock(); _level = -160; lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        let db = connection.audioChannels.map(\.averagePowerLevel).max() ?? -160
        lock.lock(); _level = db; let tap = _tap; lock.unlock()
        tap?(sb)
    }
}

/// 音を出せる機器 (スピーカー、ヘッドホン、オーディオインターフェースなど) の一覧
enum AudioOutputs {
    struct Device { let uid: String; let name: String }

    static func list() -> [Device] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            // 出力のストリームがあるものだけ
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var s: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &s) == noErr, s > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(uid: uid, name: name)
        }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// 声で外部の音を下げる (ダッキング) ときの決まり
enum VoiceDuck {
    /// マイクの音がこれより大きい (dBFS) と「話している」とみなす
    static let threshold: Float = -36
}
