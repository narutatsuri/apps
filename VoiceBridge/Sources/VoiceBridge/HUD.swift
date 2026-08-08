import AppKit
import SwiftUI

/// The floating indicator that replaces the menu bar item — visible only while
/// something is happening, like Dictation's own bubble.
@MainActor
final class HUD {
    static let shared = HUD()

    struct Model {
        var symbol: String
        var text: String
        var tint: Color
        /// 0...1 microphone level, shown as bars while listening.
        var level: Double?
    }

    private var panel: NSPanel?
    private var host: NSHostingView<HUDView>?
    private var hideTask: Task<Void, Never>?

    func show(_ model: Model, hideAfter: TimeInterval? = nil) {
        hideTask?.cancel()
        hideTask = nil

        let view = HUDView(model: model)
        if let host {
            host.rootView = view
        } else {
            build(with: view)
        }
        layout()
        panel?.orderFrontRegardless()

        if let delay = hideAfter {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
    }

    private func build(with view: HUDView) {
        let host = NSHostingView(rootView: view)
        // .nonactivatingPanel is essential: taking focus would pull it away from
        // whatever the user is actually working in.
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        self.panel = p
        self.host = host
    }

    private func layout() {
        guard let panel, let host else { return }
        let size = host.fittingSize
        // Follow the screen the pointer is on, not always the primary display.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let origin = CGPoint(x: frame.midX - size.width / 2,
                             y: frame.minY + 96)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}

struct HUDView: View {
    let model: HUD.Model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(model.tint)

            if let level = model.level {
                LevelBars(level: level, tint: model.tint)
            }

            Text(model.text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 260, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .overlay(Capsule(style: .continuous).stroke(.quaternary, lineWidth: 0.5))
        )
        .fixedSize()
        .padding(8)      // room for the shadow inside the borderless panel
    }
}

private struct LevelBars: View {
    let level: Double
    let tint: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let threshold = Double(i) / 5.0
                Capsule()
                    .fill(level > threshold ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 2.5, height: 6 + CGFloat(i) * 2.5)
            }
        }
        .frame(height: 18)
        .animation(.linear(duration: 0.1), value: level)
    }
}
