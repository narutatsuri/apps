import AppKit
import CoreGraphics
import Observation

enum WorkDetectionMode: String, CaseIterable {
    case off
    /// Offer to start, and wait for an answer. The default — the point is to
    /// remind you, not to decide for you.
    case ask
    /// Start without asking.
    case auto

    var label: String {
        switch self {
        case .off: return "Off"
        case .ask: return "Ask me"
        case .auto: return "Start automatically"
        }
    }
}

/// Watches which app is frontmost and how long since the last keypress, and turns
/// that into one signal: "you have started working".
///
/// It used to produce a second signal — "you have stopped" — and pause the session
/// on it. That is gone. Idle time cannot tell reading from absence, so every
/// threshold was wrong in one direction or the other, and a session that pauses
/// itself while you think is worse than one that overcounts by a few minutes. The
/// timer now only ever stops because you stopped it.
///
/// Both primitives are permission-free — `NSWorkspace.frontmostApplication` and
/// `CGEventSource.secondsSinceLastEventType`. Nothing here reads window contents or
/// keystrokes; it only knows *which* app is in front and *whether* input happened.
@MainActor
@Observable
final class WorkDetector {
    static let shared = WorkDetector()

    // nonisolated so the pure `decide` can read them without actor hops — and so
    // this keeps compiling under the Swift 6 language mode.
    /// Focus a work app for this long before a session starts. Long enough that
    /// alt-tabbing past Cursor doesn't trigger one.
    nonisolated static let dwell: TimeInterval = 30
    /// After a manual Stop, don't immediately restart just because you're still
    /// sitting in the editor.
    nonisolated static let cooldown: TimeInterval = 600

    private(set) var currentAppIsWork = false
    private(set) var currentAppName = ""
    private(set) var suppressedUntil = Date.distantPast

    private var workAppFocusedSince: Date?
    private var poller: Timer?

    /// Fires when a work app has held focus long enough and the timer is idle.
    var onShouldStartWork: (() -> Void)?

    var mode: WorkDetectionMode {
        get { Settings.shared.workDetection }
        set { Settings.shared.workDetection = newValue; if newValue == .off { reset() } }
    }

    private var isEnabled: Bool { mode != .off }

    /// Declining a nudge should quiet it for a while rather than re-asking a minute
    /// later; that is what makes it a reminder instead of nagging.
    func snooze(_ seconds: TimeInterval = 900) {
        suppressedUntil = Date().addingTimeInterval(seconds)
        workAppFocusedSince = nil
    }

    private init() {}

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.appChanged(to: app)
            }
        }
        appChanged(to: NSWorkspace.shared.frontmostApplication)

        // No screen-lock or display-sleep observers any more. They existed to pause a
        // running session on unambiguous absence; nothing pauses a session now.

        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        RunLoop.main.add(t, forMode: .common)
        poller = t
    }

    /// Called when the user stops a session by hand, so auto-start doesn't undo it.
    func suppress() {
        suppressedUntil = Date().addingTimeInterval(Self.cooldown)
        workAppFocusedSince = nil
    }

    var suppressionRemaining: TimeInterval {
        max(0, suppressedUntil.timeIntervalSinceNow)
    }

    private func reset() {
        workAppFocusedSince = nil
    }

    // MARK: - Signals

    private func appChanged(to app: NSRunningApplication?) {
        currentAppName = app?.localizedName ?? ""
        currentAppIsWork = WorkApps.matches(app)
        // Restart the dwell clock on every switch, so it measures *sustained* focus.
        workAppFocusedSince = currentAppIsWork ? Date() : nil
        evaluate()
    }

    /// Seconds since the last keyboard or mouse event, system-wide.
    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .null)
    }

    /// Everything the decision depends on, gathered so the rule itself can be a
    /// pure function and therefore actually testable.
    struct Input {
        var mode: WorkDetectionMode
        var phase: Phase
        var appIsWork: Bool
        /// How long the current work app has held focus, nil if it isn't one.
        var focusedFor: TimeInterval?
        var idleSeconds: TimeInterval
        var isSuppressed: Bool
    }

    enum Decision: Equatable { case none, startWork }

    /// nonisolated because it touches no state — which is the whole point of
    /// having pulled the rule out of `evaluate()`.
    nonisolated static func decide(_ i: Input) -> Decision {
        guard i.mode != .off else { return .none }
        // A running session is left entirely alone: nothing here can pause, resume
        // or stop one. `phase == .idle` below is what enforces that.
        guard i.phase == .idle, !i.isSuppressed, i.appIsWork else { return .none }
        // Sitting in the editor without touching anything is not starting work.
        guard i.idleSeconds < dwell else { return .none }
        guard let held = i.focusedFor, held >= dwell else { return .none }
        return .startWork
    }

    private func evaluate() {
        guard isEnabled else { return }
        let decision = Self.decide(.init(
            mode: mode,
            phase: TimerManager.shared.phase,
            appIsWork: currentAppIsWork,
            focusedFor: workAppFocusedSince.map { Date().timeIntervalSince($0) },
            idleSeconds: Self.idleSeconds,
            isSuppressed: Date() < suppressedUntil))

        if decision == .startWork {
            workAppFocusedSince = nil
            onShouldStartWork?()
        }
    }
}

/// The set of apps that count as working. Plain text so it can be edited without a
/// rebuild; matched on bundle identifier or on the app's display name.
enum WorkApps {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/pomodoro/work-apps.txt")

    private static let defaults = """
    # Apps that count as "working". When one of these holds focus for 30 seconds
    # and the timer is idle, a focus session starts by itself.
    #
    # One per line. Either a bundle identifier or the app's display name — the name
    # is easier to read, the bundle id is unambiguous. Case-insensitive.
    # Re-read on every check, so edits take effect immediately.
    #
    # Find an app's bundle id with:
    #   osascript -e 'id of app "Cursor"'

    Cursor
    com.todesktop.230313mzl4w4u92
    iTerm2
    com.googlecode.iterm2
    Code
    com.microsoft.VSCode
    Terminal
    Ghostty

    # Deliberately absent: browsers, Slack, Notion. Reading documentation in Chrome
    # is work, but *starting* a session because Chrome came forward would fire
    # constantly. Focus starts on a clear signal and stops on inactivity, not on
    # every app switch.
    """

    static func bootstrap() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? defaults.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    static func entries() -> [String] {
        let raw = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? defaults
        return raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func matches(_ app: NSRunningApplication?) -> Bool {
        guard let app else { return false }
        let bundle = (app.bundleIdentifier ?? "").lowercased()
        let name = (app.localizedName ?? "").lowercased()
        guard !bundle.isEmpty || !name.isEmpty else { return false }
        return entries().contains { entry in
            let e = entry.lowercased()
            return e == bundle || e == name
        }
    }
}
