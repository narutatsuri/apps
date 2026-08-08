import Foundation
import Observation

/// UserDefaults keys are unchanged from the original build, and the bundle identifier
/// still resolves to com.pomodoro.app, so existing preferences carry over untouched.
@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    var workMinutes: Int { didSet { write(Key.work, workMinutes) } }
    var shortBreakMinutes: Int { didSet { write(Key.short, shortBreakMinutes) } }
    var longBreakMinutes: Int { didSet { write(Key.long, longBreakMinutes) } }
    var cycleCount: Int { didSet { write(Key.cycles, cycleCount) } }
    /// Whether focusing an editor should offer to start a session.
    var workDetection: WorkDetectionMode {
        didSet { UserDefaults.standard.set(workDetection.rawValue, forKey: Key.detect) }
    }

    private enum Key {
        static let work = "workMinutes"
        static let short = "shortBreakMinutes"
        static let long = "longBreakMinutes"
        static let cycles = "cycleCount"
        static let detect = "workDetection"
    }

    private init() {
        let d = UserDefaults.standard
        func read(_ key: String, _ fallback: Int) -> Int {
            d.object(forKey: key) == nil ? fallback : d.integer(forKey: key)
        }
        workMinutes = read(Key.work, 25)
        shortBreakMinutes = read(Key.short, 5)
        longBreakMinutes = read(Key.long, 15)
        cycleCount = read(Key.cycles, 4)
        workDetection = WorkDetectionMode(rawValue: d.string(forKey: Key.detect) ?? "") ?? .ask
    }

    private func write(_ key: String, _ value: Int) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
