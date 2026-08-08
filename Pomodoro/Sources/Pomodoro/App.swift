import SwiftUI

enum AppAssets {
    /// The original build's tomato glyph, carried over from its Resources folder.
    static let menuBarIcon: NSImage = {
        let image = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "timer", accessibilityDescription: "Pomodoro")!
        image.isTemplate = true
        image.size = NSSize(width: 15, height: 15)
        return image
    }()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["POMO_SELFTEST"] == "1" { Self.selfTest() }
        MainActor.assumeIsolated {
            let timer = TimerManager.shared
            let overlay = OverlayController.shared

            timer.onBreakStarted = { overlay.show(.breakRunning) }
            timer.onWorkPrompt = { overlay.show(.workPrompt) }

            overlay.onStartWork = { overlay.hide(); timer.startWork() }
            overlay.onSkipToWork = { overlay.hide(); timer.skipBreakAndStartWork() }
            overlay.onClose = { overlay.hide() }

            WorkApps.bootstrap()
            let detector = WorkDetector.shared

            detector.onShouldStartWork = { [weak self] in
                guard let self else { return }
                switch detector.mode {
                case .off:
                    return
                case .auto:
                    overlay.hide()
                    timer.startWork()
                case .ask:
                    NudgePanel.shared.ask(
                        "Starting work?",
                        detail: "You've been in \(detector.currentAppName) for a while.",
                        confirmTitle: "Start focus",
                        onConfirm: {
                            overlay.hide()
                            timer.startWork()
                        },
                        onDecline: { detector.snooze() })
                }
                _ = self
            }

            // Nothing pauses a running session any more. The detector only ever
            // offers to *start* one; stopping and pausing are yours alone.
            detector.start()
        }
    }

    static func selfTest() -> Never {
        var fails = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { fails += 1 }
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day = cal.date(from: DateComponents(year: 2026, month: 7, day: 30))!
        func t(_ h: Int, _ m: Int) -> Date { day.addingTimeInterval(Double(h) * 3600 + Double(m) * 60) }
        func rec(_ kind: Phase, _ from: Date, _ to: Date, _ why: EndReason = .completed) -> SessionRecord {
            SessionRecord(kind: kind.rawValue, start: from, end: to, endedBy: why, plannedMinutes: 25)
        }

        // Wholly inside one hour.
        var s = SessionLog.summarize([rec(.work, t(9, 0), t(9, 25))], for: day, calendar: cal)
        check("single hour", abs(s.workMinutes - 25) < 0.01 && s.buckets.count == 1,
              String(format: "%.1f min in %d bucket(s)", s.workMinutes, s.buckets.count))

        // Straddling an hour boundary — the case a naive implementation gets wrong.
        s = SessionLog.summarize([rec(.work, t(9, 50), t(10, 15))], for: day, calendar: cal)
        let h9 = s.buckets.first { $0.hour == 9 }?.workMinutes ?? -1
        let h10 = s.buckets.first { $0.hour == 10 }?.workMinutes ?? -1
        check("splits across the hour", abs(h9 - 10) < 0.01 && abs(h10 - 15) < 0.01,
              String(format: "09:00 got %.0f, 10:00 got %.0f (expect 10 / 15)", h9, h10))

        // Work and break kept apart.
        s = SessionLog.summarize([rec(.work, t(14, 0), t(14, 25)),
                                  rec(.shortBreak, t(14, 25), t(14, 30))], for: day, calendar: cal)
        check("work vs break separated",
              abs(s.workMinutes - 25) < 0.01 && abs(s.breakMinutes - 5) < 0.01,
              String(format: "%.0f work / %.0f break", s.workMinutes, s.breakMinutes))

        // Idle hours between activity are retained, because gaps are signal.
        s = SessionLog.summarize([rec(.work, t(9, 0), t(9, 30)),
                                  rec(.work, t(12, 0), t(12, 30))], for: day, calendar: cal)
        check("idle hours retained in span", s.buckets.count == 4,
              "hours \(s.buckets.map(\.hour)) (expect 9…12)")

        // A session crossing midnight contributes to both days.
        let prev = cal.date(byAdding: .day, value: -1, to: day)!
        let crossing = [rec(.work, day.addingTimeInterval(-600), day.addingTimeInterval(600))]
        let today = SessionLog.summarize(crossing, for: day, calendar: cal)
        let yesterday = SessionLog.summarize(crossing, for: prev, calendar: cal)
        check("midnight split", abs(today.workMinutes - 10) < 0.01 && abs(yesterday.workMinutes - 10) < 0.01,
              String(format: "%.0f today / %.0f yesterday", today.workMinutes, yesterday.workMinutes))

        // Other days are excluded entirely.
        s = SessionLog.summarize([rec(.work, t(9, 0), t(9, 25))], for: prev, calendar: cal)
        check("other days excluded", s.isEmpty, "buckets: \(s.buckets.count)")

        // Early breaks counted separately from completed sessions.
        s = SessionLog.summarize([rec(.work, t(9, 0), t(9, 25), .completed),
                                  rec(.work, t(10, 0), t(10, 8), .early)], for: day, calendar: cal)
        check("early vs completed", s.completedFocusSessions == 1 && s.earlyBreaks == 1,
              "\(s.completedFocusSessions) completed / \(s.earlyBreaks) early")

        // Focus share.
        s = SessionLog.summarize([rec(.work, t(9, 0), t(9, 45)),
                                  rec(.shortBreak, t(9, 45), t(10, 0))], for: day, calendar: cal)
        check("focus share", abs((s.focusShare ?? 0) - 0.75) < 0.001,
              String(format: "%.3f (expect 0.750)", s.focusShare ?? -1))

        // Round-trip through a temp file — never the real log.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomo-selftest-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        SessionLog.append(rec(.work, t(9, 0), t(9, 25)), to: tmp)
        SessionLog.append(rec(.shortBreak, t(9, 25), t(9, 30)), to: tmp)
        SessionLog.append(rec(.work, t(9, 30), t(9, 30).addingTimeInterval(2)), to: tmp)  // too short
        let read = SessionLog.allRecords(from: tmp)
        check("append/read round-trip", read.count == 2, "\(read.count) record(s) (expect 2)")
        check("sub-5s intervals dropped", !read.contains { $0.duration < 5 }, "no mis-clicks logged")
        if let first = read.first {
            check("dates survive encoding", abs(first.start.timeIntervalSince(t(9, 0))) < 0.001
                  && first.endedBy == .completed && first.plannedMinutes == 25,
                  "start, endedBy and plannedMinutes all preserved")
        } else {
            check("dates survive encoding", false, "nothing read back")
        }

        // --- work detection ---
        func input(mode: WorkDetectionMode = .ask, phase: Phase = .idle, appIsWork: Bool = true,
                   focusedFor: TimeInterval? = 60, idle: TimeInterval = 2,
                   suppressed: Bool = false) -> WorkDetector.Input {
            .init(mode: mode, phase: phase, appIsWork: appIsWork, focusedFor: focusedFor,
                  idleSeconds: idle, isSuppressed: suppressed)
        }
        func decide(_ i: WorkDetector.Input) -> WorkDetector.Decision { WorkDetector.decide(i) }

        check("sustained focus starts", decide(input()) == .startWork)
        check("brief focus does not", decide(input(focusedFor: 5)) == .none, "5s of focus")
        check("non-work app ignored", decide(input(appIsWork: false)) == .none)
        check("off means off", decide(input(mode: .off)) == .none)
        check("suppressed after manual stop", decide(input(suppressed: true)) == .none)
        // Sitting in the editor untouched is not starting work.
        check("idle in editor does not start", decide(input(idle: 120)) == .none, "2 min untouched")
        // Never interrupt a break.
        check("no start during a break",
              decide(input(phase: .shortBreak)) == .none && decide(input(phase: .longBreak)) == .none)
        check("no double-start while running", decide(input(phase: .work, idle: 2)) == .none)

        // Nothing the detector observes may touch a running session. These are the
        // cases that used to pause one; every single one of them is now a no-op.
        check("a long absence does not pause",
              decide(input(phase: .work, idle: 700)) == .none, "11½ min untouched")
        check("an hour away does not pause",
              decide(input(phase: .work, idle: 3600)) == .none)
        check("app switch does not stop a session",
              decide(input(phase: .work, appIsWork: false, focusedFor: nil, idle: 5)) == .none,
              "reading docs in a browser is work")
        check("no decision reachable during a session",
              [2.0, 400, 700, 3600].allSatisfy { idle in
                  [true, false].allSatisfy { isWork in
                      decide(input(phase: .work, appIsWork: isWork,
                                   focusedFor: isWork ? 60 : nil, idle: idle)) == .none
                  }
              },
              "the only signal left is startWork, and that requires phase == .idle")

        print(fails == 0 ? "\nALL PASS" : "\n\(fails) FAILURE(S)")
        exit(fails == 0 ? 0 : 1)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Don't lose the interval that was in flight when the app quit.
        MainActor.assumeIsolated { TimerManager.shared.flushOpenInterval() }
    }
}

enum DayReportWindow {
    static let id = "day-report"
}

@main
struct PomodoroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var timer = TimerManager.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView()
        } label: {
            HStack(spacing: 3) {
                Image(nsImage: AppAssets.menuBarIcon)
                if timer.isRunning {
                    Text(timer.timeString)
                        .font(.system(size: 12).monospacedDigit())
                }
            }
        }
        .menuBarExtraStyle(.window)

        Window("Pomodoro — Day", id: DayReportWindow.id) {
            DayReportView()
        }
        .windowResizability(.contentMinSize)
    }
}
