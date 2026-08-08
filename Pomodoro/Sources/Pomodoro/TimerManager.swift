import AppKit
import Observation

enum Phase: String {
    case idle, work, shortBreak, longBreak

    var isBreak: Bool { self == .shortBreak || self == .longBreak }

    var title: String {
        switch self {
        case .idle: return "Ready"
        case .work: return "Focus"
        case .shortBreak: return "Short Break"
        case .longBreak: return "Long Break"
        }
    }
}

/// The whole timer derives from a wall-clock `deadline`, never from a decremented
/// counter. That is the fix for the original's three timing faults: ticks missed
/// during sleep, ticks missed while a menu is open, and accumulated drift from
/// best-effort timer delivery. A tick that never arrives can no longer lose time —
/// it only delays a redraw, and the next tick self-corrects.
@MainActor
@Observable
final class TimerManager {
    static let shared = TimerManager()

    private(set) var phase: Phase = .idle
    private(set) var isPaused = false
    private(set) var completedSessions = 0
    /// Mirrors `remaining` so SwiftUI has something observable to react to each tick.
    private(set) var displayRemaining: TimeInterval = 0

    /// Absolute end of the running phase — the single source of truth.
    private var deadline: Date?
    /// Set only while paused; holds the remaining interval so it survives the pause.
    private var frozenRemaining: TimeInterval?
    private var ticker: Timer?
    /// Start of the interval currently being logged. Separate from `deadline`: this
    /// tracks what actually happened, while `deadline` drives what should happen.
    private var intervalStart: Date?
    private var intervalPlanned: Int = 0

    var onBreakStarted: (() -> Void)?
    var onWorkPrompt: (() -> Void)?

    private init() {
        // A tick lost to sleep can't corrupt the count any more, but the display
        // would still be stale until the next tick — re-sync the moment we wake.
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    var remaining: TimeInterval {
        if let frozen = frozenRemaining { return frozen }
        guard let deadline else { return 0 }
        return max(0, deadline.timeIntervalSinceNow)
    }

    var timeString: String {
        let total = Int(ceil(displayRemaining))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var isRunning: Bool { phase != .idle }

    // MARK: - Controls

    func startWork() {
        // Also covers skipping a break: whatever was running gets cut short.
        if isRunning { closeInterval(.early) }
        begin(.work, minutes: Settings.shared.workMinutes)
    }

    func skipBreakAndStartWork() {
        startWork()
    }

    /// Take the break early, mid-focus. The focus session counts toward the cycle —
    /// you chose to end it — and the log records however long it actually ran.
    func takeBreakNow() {
        guard phase == .work else { return }
        closeInterval(.early)
        startBreakAfterWork()
    }

    var canTakeBreakNow: Bool { phase == .work }

    func pause() {
        guard isRunning, !isPaused else { return }
        // Close the interval here so paused time is never counted as work.
        closeInterval(.paused)
        frozenRemaining = remaining
        deadline = nil
        isPaused = true
    }

    func resume() {
        guard isPaused, let frozen = frozenRemaining else { return }
        // Re-anchor to now, so a pause of any length is honoured exactly.
        deadline = Date().addingTimeInterval(frozen)
        frozenRemaining = nil
        isPaused = false
        intervalStart = Date()
        tick()
    }

    func stop() {
        closeInterval(.stopped)
        // Stopping by hand must actually stop things: without this, sitting in the
        // editor would have auto-detection start a new session moments later.
        WorkDetector.shared.suppress()
        stopTicking()
        phase = .idle
        deadline = nil
        frozenRemaining = nil
        isPaused = false
        displayRemaining = 0
    }

    func resetCycles() {
        completedSessions = 0
    }

    /// Called on app termination so an in-flight interval is not silently lost.
    func flushOpenInterval() {
        closeInterval(.stopped)
    }

    // MARK: - Logging

    private func closeInterval(_ reason: EndReason) {
        defer { intervalStart = nil }
        guard let start = intervalStart, phase != .idle else { return }
        SessionLog.append(SessionRecord(kind: phase.rawValue, start: start, end: Date(),
                                        endedBy: reason, plannedMinutes: intervalPlanned))
    }

    private func startBreakAfterWork() {
        completedSessions += 1
        let s = Settings.shared
        let isLong = s.cycleCount > 0 && completedSessions % s.cycleCount == 0
        begin(isLong ? .longBreak : .shortBreak,
              minutes: isLong ? s.longBreakMinutes : s.shortBreakMinutes)
    }

    // MARK: - Engine

    private func begin(_ newPhase: Phase, minutes: Int) {
        phase = newPhase
        isPaused = false
        frozenRemaining = nil
        deadline = Date().addingTimeInterval(Double(max(1, minutes)) * 60)
        displayRemaining = remaining
        intervalStart = Date()
        intervalPlanned = minutes
        startTicking()
        if newPhase.isBreak { onBreakStarted?() }
    }

    private func startTicking() {
        stopTicking()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common, not the .default that `scheduledTimer` installs into: otherwise an
        // open menu or a live resize puts the run loop in .eventTracking and the timer
        // stops firing.
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard isRunning else { return }
        displayRemaining = remaining
        guard !isPaused, displayRemaining <= 0 else { return }
        advance()
    }

    private func advance() {
        switch phase {
        case .work:
            closeInterval(.completed)
            startBreakAfterWork()
        case .shortBreak, .longBreak:
            // Break is over; wait for an explicit start so a finished break can't
            // silently roll into a focus session the user never agreed to.
            closeInterval(.completed)
            stopTicking()
            phase = .idle
            deadline = nil
            displayRemaining = 0
            onWorkPrompt?()
        case .idle:
            break
        }
    }
}
