import AVFoundation

@MainActor
final class Recorder {
    private var recorder: AVAudioRecorder?
    private var url: URL?

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicebridge-\(UUID().uuidString).wav")
        // 16 kHz mono signed 16-bit is exactly what whisper.cpp wants; letting
        // AVAudioRecorder convert here avoids a resampling step later.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let r = try AVAudioRecorder(url: out, settings: settings)
        r.isMeteringEnabled = true
        guard r.record() else {
            throw VBError.message("Microphone unavailable — check System Settings › Privacy & Security › Microphone.")
        }
        recorder = r
        url = out
    }

    /// Returns the finished file, or nil if it was too short to be speech.
    func stop() -> URL? {
        guard let r = recorder, let out = url else { return nil }
        let duration = r.currentTime
        r.stop()
        recorder = nil
        url = nil
        guard duration > 0.3 else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return out
    }

    var isRecording: Bool { recorder?.isRecording ?? false }
    var elapsed: TimeInterval { recorder?.currentTime ?? 0 }

    /// 0...1, mapped from dBFS so quiet speech still moves the bars.
    var level: Double {
        guard let r = recorder else { return 0 }
        r.updateMeters()
        let db = Double(r.averagePower(forChannel: 0))
        guard db.isFinite else { return 0 }
        return min(1, max(0, (db + 50) / 50))
    }
}
