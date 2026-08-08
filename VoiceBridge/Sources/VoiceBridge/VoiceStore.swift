import AppKit
import SwiftUI

@MainActor
final class VoiceStore {
    static let shared = VoiceStore()

    private let recorder = Recorder()
    private let monitor = DoubleTapMonitor(flag: .control)
    private var meterTimer: Timer?
    private var busy = false

    // MARK: - Lifecycle

    func bootstrap() {
        Config.bootstrap()
        monitor.onTrigger = { [weak self] in self?.toggle() }

        guard DoubleTapMonitor.isTrusted else {
            Runtime.record(monitorRunning: false)
            DoubleTapMonitor.requestTrust()
            HUD.shared.show(.init(
                symbol: "hand.raised.fill",
                text: "Enable VoiceBridge under Privacy & Security › Accessibility.",
                tint: .orange, level: nil), hideAfter: 12)
            waitForTrust()
            return
        }
        monitor.start()
        Runtime.record(monitorRunning: true)
        HUD.shared.show(.init(symbol: "mic", text: "Ready — double-tap Control",
                              tint: .secondary, level: nil), hideAfter: 2.5)
    }

    /// Poll rather than demand a relaunch: the grant usually takes effect live.
    private func waitForTrust() {
        Task { [weak self] in
            for _ in 0..<600 {
                try? await Task.sleep(for: .seconds(1))
                guard DoubleTapMonitor.isTrusted else { continue }
                self?.monitor.start()
                Runtime.record(monitorRunning: true)
                HUD.shared.show(.init(symbol: "checkmark.circle.fill",
                                      text: "Ready — double-tap Control",
                                      tint: .green, level: nil), hideAfter: 3)
                return
            }
        }
    }

    // MARK: - Recording

    func toggle() {
        guard !busy else { return }
        recorder.isRecording ? finish() : begin()
    }

    private func begin() {
        Task {
            guard await Recorder.requestPermission() else {
                return fail("Microphone access denied — enable it in Privacy & Security › Microphone.",
                            symbol: "mic.slash.fill")
            }
            do {
                try recorder.start()
                startMetering()
            } catch let e as VBError {
                fail(e.text)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func finish() {
        stopMetering()
        guard let wav = recorder.stop() else {
            HUD.shared.hide()               // too short to be speech
            return
        }
        busy = true
        HUD.shared.show(.init(symbol: "waveform", text: "Transcribing…",
                              tint: .yellow, level: nil))

        Task {
            defer {
                busy = false
                try? FileManager.default.removeItem(at: wav)
            }
            do {
                let text = try await Task.detached { try Transcriber.transcribe(wav) }.value
                guard !text.isEmpty else { return HUD.shared.hide() }
                deliver(text)
            } catch let e as VBError {
                fail(e.text)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func deliver(_ text: String) {
        // Read before posting, so the confirmation names where it actually went —
        // the fastest way to notice it landed somewhere unexpected.
        let destination = Prefs.target == .iterm ? "iTerm2" : Delivery.frontmostAppName
        do {
            try Delivery.send(text, submit: Prefs.autoSubmit)
            HUD.shared.show(.init(symbol: "checkmark.circle.fill",
                                  text: "→ \(destination)  ·  \(text)",
                                  tint: .green, level: nil), hideAfter: 1.8)
        } catch let e as VBError {
            // Never lose the words — park them somewhere recoverable.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            HUD.shared.show(.init(symbol: "doc.on.clipboard.fill",
                                  text: "\(e.text) Transcript copied to clipboard.",
                                  tint: .orange, level: nil), hideAfter: 7)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String, symbol: String = "exclamationmark.triangle.fill") {
        HUD.shared.show(.init(symbol: symbol, text: message, tint: .orange, level: nil),
                        hideAfter: 6)
    }

    // MARK: - Meter

    private func startMetering() {
        stopMetering()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.recorder.isRecording else { return }
                HUD.shared.show(.init(
                    symbol: "mic.fill",
                    text: String(format: "Listening… %.0fs", self.recorder.elapsed),
                    tint: .red,
                    level: self.recorder.level))
            }
        }
        RunLoop.main.add(t, forMode: .common)
        meterTimer = t
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }
}
