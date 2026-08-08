import AppKit
import SwiftUI

/// A small floating ask — "Starting work?" — rather than a silent auto-start.
/// Non-activating, so answering it never pulls focus out of whatever you were
/// doing, and it times out on its own if you ignore it.
@MainActor
final class NudgePanel {
    static let shared = NudgePanel()

    private var panel: NSPanel?
    private var timeout: Task<Void, Never>?

    /// Seconds before an unanswered nudge gives up. Long enough to notice, short
    /// enough that a stale question isn't sitting there ten minutes later.
    static let lifetime: TimeInterval = 25

    private init() {}

    func ask(_ question: String,
             detail: String? = nil,
             confirmTitle: String,
             onConfirm: @escaping () -> Void,
             onDecline: @escaping () -> Void) {
        dismiss()

        let root = NudgeView(
            question: question,
            detail: detail,
            confirmTitle: confirmTitle,
            onConfirm: { [weak self] in self?.dismiss(); onConfirm() },
            onDecline: { [weak self] in self?.dismiss(); onDecline() }
        )
        let host = NSHostingView(rootView: root)
        // .nonactivatingPanel keeps the click from stealing focus from the editor
        // the question is about.
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false

        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            // Top-right, out of the way of what you're reading.
            p.setFrame(CGRect(x: visible.maxX - size.width - 18,
                              y: visible.maxY - size.height - 18,
                              width: size.width, height: size.height),
                       display: true)
        }
        p.orderFrontRegardless()
        panel = p

        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.lifetime))
            guard !Task.isCancelled else { return }
            self?.dismiss()
            onDecline()
        }
    }

    func dismiss() {
        timeout?.cancel()
        timeout = nil
        panel?.orderOut(nil)
        panel = nil
    }

    var isShowing: Bool { panel != nil }
}

private struct NudgeView: View {
    let question: String
    let detail: String?
    let confirmTitle: String
    let onConfirm: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "timer")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(question)
                    .font(.system(size: 13, weight: .medium))
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 7) {
                Button(confirmTitle, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Not now", action: onDecline)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 250, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.quaternary, lineWidth: 0.5))
        )
        .padding(10)   // room for the shadow inside the borderless panel
    }
}
