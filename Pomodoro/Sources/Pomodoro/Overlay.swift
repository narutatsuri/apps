import AppKit
import SwiftUI

/// Borderless windows can't take key focus by default, which leaves the buttons
/// feeling dead on first click.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OverlayController {
    static let shared = OverlayController()

    enum Mode { case hidden, breakRunning, workPrompt }

    private(set) var mode: Mode = .hidden
    private var windows: [OverlayWindow] = []

    var onStartWork: (() -> Void)?
    var onSkipToWork: (() -> Void)?
    var onClose: (() -> Void)?

    private init() {
        // Plugging in or unplugging a display used to leave the overlay stranded on a
        // screen that no longer exists — rebuild against the current arrangement.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.mode != .hidden else { return }
                self.present(self.mode)
            }
        }
    }

    func show(_ mode: Mode) {
        guard mode != .hidden else { return hide() }
        present(mode)
    }

    func hide() {
        mode = .hidden
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    private func present(_ mode: Mode) {
        self.mode = mode
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()

        // One window per screen — a break you can dodge by glancing at the other
        // monitor isn't a break.
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.level = .screenSaver
            // fullScreenAuxiliary is what lets it draw over apps in fullscreen;
            // canJoinAllSpaces keeps it present after a Space switch.
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.ignoresMouseEvents = false
            w.isReleasedWhenClosed = false

            let root = OverlayContentView(
                mode: mode,
                onStartWork: { [weak self] in self?.onStartWork?() },
                onSkipToWork: { [weak self] in self?.onSkipToWork?() },
                onClose: { [weak self] in self?.onClose?() }
            )
            let host = NSHostingView(rootView: root)
            host.frame = CGRect(origin: .zero, size: screen.frame.size)
            w.contentView = host
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
        windows.first?.makeKey()
    }
}

struct OverlayContentView: View {
    let mode: OverlayController.Mode
    let onStartWork: () -> Void
    let onSkipToWork: () -> Void
    let onClose: () -> Void

    private var timer: TimerManager { TimerManager.shared }

    var body: some View {
        ZStack {
            Color.black.opacity(0.86).ignoresSafeArea()

            VStack(spacing: 26) {
                Text(mode == .workPrompt ? "Break over" : timer.phase.title)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))

                if mode == .breakRunning {
                    Text(timer.timeString)
                        .font(.system(size: 108, weight: .thin).monospacedDigit())
                        .foregroundStyle(.white)
                } else {
                    Text("Ready when you are.")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.55))
                }

                HStack(spacing: 12) {
                    if mode == .breakRunning {
                        OverlayButton(title: "Skip to Focus", prominent: true, action: onSkipToWork)
                    } else {
                        OverlayButton(title: "Start Focus", prominent: true, action: onStartWork)
                    }
                    OverlayButton(title: "Dismiss", prominent: false, action: onClose)
                }
                .padding(.top, 6)
            }
        }
    }
}

private struct OverlayButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(prominent ? .black : .white)
                .padding(.horizontal, 20).padding(.vertical, 9)
                .background(
                    Capsule().fill(prominent ? AnyShapeStyle(.white)
                                             : AnyShapeStyle(.white.opacity(0.16)))
                )
        }
        .buttonStyle(.plain)
    }
}
