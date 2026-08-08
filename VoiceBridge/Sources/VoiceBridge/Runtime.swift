import Foundation
import ApplicationServices

/// The running app writes what it can actually see; `--status` reads it back.
///
/// Needed because `AXIsProcessTrusted()` called from a shell reports the *responsible
/// process* — the terminal — not this app, so `--status` said `false` no matter what
/// was granted. Only the GUI process knows the truth, so only it may answer.
enum Runtime {
    static let fileURL = Config.support.appendingPathComponent("runtime.json")

    static func record(monitorRunning: Bool) {
        let payload: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "accessibilityTrusted": AXIsProcessTrusted(),
            "monitorRunning": monitorRunning,
            "updatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        try? FileManager.default.createDirectory(at: Config.support,
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: .prettyPrinted) else { return }
        try? data.write(to: fileURL)
    }

    /// What the GUI app last reported, and how stale it is.
    static func lastReport() -> (trusted: Bool, monitor: Bool, age: TimeInterval, pid: Int)? {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stamp = json["updatedAt"] as? String,
              let when = ISO8601DateFormatter().date(from: stamp) else { return nil }
        return (json["accessibilityTrusted"] as? Bool ?? false,
                json["monitorRunning"] as? Bool ?? false,
                -when.timeIntervalSinceNow,
                json["pid"] as? Int ?? 0)
    }

    static var isProcessAlive: Bool {
        !(try? Process.run(URL(fileURLWithPath: "/usr/bin/pgrep"),
                           arguments: ["-x", "VoiceBridge"])).isNil
    }
}

private extension Optional {
    var isNil: Bool { self == nil }
}
