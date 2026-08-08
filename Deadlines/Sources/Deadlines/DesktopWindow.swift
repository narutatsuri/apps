import AppKit
import SwiftUI

/// A window that lives on the desktop rather than in front of you.
///
/// Pinned below every ordinary window and above the wallpaper, on every Space,
/// and transparent to the mouse — so it is simply part of the desk, not another
/// thing to dismiss. That last part is why it cannot be dragged: a window that
/// ignores clicks cannot also catch them. Position is set from the menu bar.
///
/// This is not a WidgetKit widget, which would need an app extension bundle and
/// Xcode's build system to produce and register one. It occupies the same place
/// on screen and needs no gallery, no container app, and no signing dance.
final class DesktopWindow: NSWindowController {
    static var shared: DesktopWindow?

    enum Corner: String, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        var label: String {
            switch self {
            case .topLeft: return "Top Left"
            case .topRight: return "Top Right"
            case .bottomLeft: return "Bottom Left"
            case .bottomRight: return "Bottom Right"
            }
        }
    }

    private static let cornerKey = "deadlines.corner"
    static var corner: Corner {
        get { Corner(rawValue: UserDefaults.standard.string(forKey: cornerKey) ?? "") ?? .topRight }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: cornerKey)
            shared?.reposition()
        }
    }

    static let width: CGFloat = 300
    private static let inset: CGFloat = 24

    convenience init(model: Model) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: DesktopWindow.width,
                                                  height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // Desktop-icon level is a large negative number: above the wallpaper,
        // below anything you are actually working in.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Never takes focus, never appears in Exposé or the window cycle, and
        // follows you between Spaces instead of hiding on the one it was made on.
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PanelView(model: model))

        self.init(window: window)
        fit()
        window.orderFrontRegardless()
        DesktopWindow.shared = self
    }

    /// Shrinks the window to whatever the panel currently needs, then puts it
    /// back in its corner — the height changes as deadlines pass and appear.
    func fit() {
        if let hosting = window?.contentView as? NSHostingView<PanelView> {
            hosting.layoutSubtreeIfNeeded()
            let height = max(80, hosting.fittingSize.height)
            window?.setContentSize(NSSize(width: DesktopWindow.width, height: height))
        }
        reposition()
    }

    /// The screen with the menu bar on it.
    ///
    /// Not `NSScreen.main`, which means "the screen with the focused window" —
    /// and this app never takes focus, so that answers with whichever display
    /// happened to be active. On a multi-monitor desk it put the panel on a
    /// screen above the primary one, off in the corner of an eye.
    private var homeScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
    }

    func reposition() {
        guard let window, let screen = homeScreen else { return }
        // visibleFrame, so it clears the menu bar and the Dock rather than
        // sliding underneath them.
        let area = screen.visibleFrame
        let size = window.frame.size
        let inset = DesktopWindow.inset
        let x: CGFloat
        let y: CGFloat
        switch DesktopWindow.corner {
        case .topLeft, .bottomLeft: x = area.minX + inset
        case .topRight, .bottomRight: x = area.maxX - size.width - inset
        }
        switch DesktopWindow.corner {
        case .topLeft, .topRight: y = area.maxY - size.height - inset
        case .bottomLeft, .bottomRight: y = area.minY + inset
        }
        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height),
                        display: true)
    }
}
