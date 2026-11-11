// マイクの入力レベルを測る (録画の前に音が入っているか確かめるため)
// 録画とは別に、選んだマイクを開いて音量だけを読む

import AVFoundation

final class MicMeter: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "micmeter")
    private var session: AVCaptureSession?
    private let lock = NSLock()
    private var _level: Float = -160
    private(set) var device: AVCaptureDevice?

    /// 直近の平均レベル (dBFS、無音で -160)
    var level: Float { lock.lock(); defer { lock.unlock() }; return _level }

    /// 測るマイクを切り替える (nil なら止める)
    func start(_ device: AVCaptureDevice?) {
        guard device?.uniqueID != self.device?.uniqueID || (device != nil && session == nil) else { return }
        stop()
        self.device = device
        guard let device else { return }
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            guard ok else { return }
            DispatchQueue.main.async {
                // 許可を待つ間に別のマイクに替わっていたらやめる
                guard self.device?.uniqueID == device.uniqueID, self.session == nil,
                      let input = try? AVCaptureDeviceInput(device: device) else { return }
                let session = AVCaptureSession()
                let output = AVCaptureAudioDataOutput()
                output.setSampleBufferDelegate(self, queue: self.queue)
                if session.canAddInput(input) { session.addInput(input) }
                if session.canAddOutput(output) { session.addOutput(output) }
                self.session = session
                self.queue.async { session.startRunning() }
            }
        }
    }

    func stop() {
        if let session { queue.async { session.stopRunning() } }
        session = nil
        device = nil
        lock.lock(); _level = -160; lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        // チャンネルの中で一番大きいものをレベルにする
        let db = connection.audioChannels.map(\.averagePowerLevel).max() ?? -160
        lock.lock(); _level = db; lock.unlock()
    }
}
