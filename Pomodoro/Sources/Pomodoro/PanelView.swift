import SwiftUI

struct PanelView: View {
    @Environment(\.openWindow) private var openWindow
    private var timer: TimerManager { TimerManager.shared }
    private var settings: Settings { Settings.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            controls
            Divider()
            detection
            Divider()
            sliders
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 268)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(timer.isPaused ? "Paused" : timer.phase.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                cycleDots
            }
            Text(displayTime)
                .font(.system(size: 44, weight: .thin).monospacedDigit())
        }
    }

    private var cycleDots: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(1, settings.cycleCount), id: \.self) { i in
                Circle()
                    .fill(i < completedInCycle ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                    .frame(width: 5, height: 5)
            }
        }
        .help("Focus sessions completed before the next long break")
    }

    private var completedInCycle: Int {
        let n = max(1, settings.cycleCount)
        guard timer.completedSessions > 0 else { return 0 }
        let r = timer.completedSessions % n
        return r == 0 ? n : r
    }

    private var displayTime: String {
        timer.isRunning ? timer.timeString : String(format: "%d:00", settings.workMinutes)
    }

    private var controls: some View {
        HStack(spacing: 7) {
            if !timer.isRunning {
                PanelButton(title: "Start Focus", prominent: true) { timer.startWork() }
            } else if timer.isPaused {
                PanelButton(title: "Resume", prominent: true) { timer.resume() }
            } else {
                PanelButton(title: "Pause", prominent: true) { timer.pause() }
            }

            // Break on demand, in whichever direction makes sense for the phase.
            if timer.canTakeBreakNow {
                PanelButton(title: "Break now", prominent: false) { timer.takeBreakNow() }
            } else if timer.phase.isBreak {
                PanelButton(title: "Skip break", prominent: false) {
                    OverlayController.shared.hide()
                    timer.skipBreakAndStartWork()
                }
            }

            if timer.isRunning {
                PanelButton(title: "Stop", prominent: false) {
                    timer.stop()
                    OverlayController.shared.hide()
                }
            }
            Spacer()
        }
    }

    private var detection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("When I start working")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { WorkDetector.shared.mode },
                    set: { WorkDetector.shared.mode = $0 }
                )) {
                    ForEach(WorkDetectionMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 132)
            }
            Text(detectionHint)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var detectionHint: String {
        let d = WorkDetector.shared
        guard d.mode != .off else { return "Detection off — start sessions yourself." }
        let snoozed = d.suppressionRemaining
        if snoozed > 60 { return "Snoozed for \(Int(snoozed / 60))m." }
        if d.currentAppIsWork { return "\(d.currentAppName) counts as work." }
        return "Watching for Cursor, iTerm2, VS Code…"
    }

    private var sliders: some View {
        VStack(spacing: 9) {
            SettingRow(title: "Focus Duration", value: settings.workMinutes, range: 1...90, unit: "min") {
                settings.workMinutes = $0
            }
            SettingRow(title: "Short Break", value: settings.shortBreakMinutes, range: 1...30, unit: "min") {
                settings.shortBreakMinutes = $0
            }
            SettingRow(title: "Long Break", value: settings.longBreakMinutes, range: 1...60, unit: "min") {
                settings.longBreakMinutes = $0
            }
            SettingRow(title: "Cycles before Long Break", value: settings.cycleCount, range: 1...12, unit: "") {
                settings.cycleCount = $0
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Today's breakdown") {
                openWindow(id: DayReportWindow.id)
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(Color.accentColor)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

private struct SettingRow: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    let unit: String
    let onChanged: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text(unit.isEmpty ? "\(value)" : "\(value) \(unit)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
            }
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { onChanged(Int($0.rounded())) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
            .controlSize(.mini)
        }
    }
}

private struct PanelButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 13).padding(.vertical, 5)
                .background(
                    Capsule().fill(prominent ? AnyShapeStyle(Color.accentColor)
                                             : AnyShapeStyle(.quaternary))
                )
        }
        .buttonStyle(.plain)
    }
}
