import AppKit
import SwiftUI

/// One sticky, one window.
///
/// An `NSPanel` rather than a SwiftUI `Window` scene: a sticky has to float over
/// whatever you are working in, appear on whichever Space you are on, and come
/// up without stealing the whole app forward. Those are window-server
/// properties, and SwiftUI's scene types do not expose them.
@MainActor
final class StickyWindow: NSWindowController, NSWindowDelegate {
    let stickyID: String
    private static var open: [String: StickyWindow] = [:]

    static var visibleCount: Int { open.values.filter { $0.window?.isVisible == true }.count }
    static var anyOpen: Bool { !open.isEmpty }

    /// Brings the sticky's window up, making it if it isn't already there.
    @discardableResult
    static func show(_ id: String, activate: Bool = true) -> StickyWindow? {
        guard Store.shared.sticky(id) != nil else { return nil }
        let controller = open[id] ?? StickyWindow(stickyID: id)
        open[id] = controller
        controller.showWindow(nil)
        if var s = Store.shared.sticky(id), !s.isOpen {
            s.isOpen = true
            Store.shared.save(s, debounce: 0)
        }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
        }
        return controller
    }

    /// Ordered out, not closed: ⌃⌥S is "get these off my screen for a minute",
    /// and marking them closed would mean they never came back on relaunch.
    static func hideAll() {
        for c in open.values { c.window?.orderOut(nil) }
    }

    static func showAll() {
        for sticky in Store.shared.ordered { show(sticky.id, activate: false) }
        NSApp.activate(ignoringOtherApps: true)
        open.values.first?.window?.makeKeyAndOrderFront(nil)
    }

    static func close(_ id: String) {
        open[id]?.window?.close()
        open[id] = nil
    }

    static func forget(_ id: String) { open[id] = nil }

    private init(stickyID: String) {
        self.stickyID = stickyID
        let sticky = Store.shared.sticky(stickyID)

        let saved = sticky?.frame.flatMap { Self.onScreen($0) ? $0 : nil }
        let panel = NSPanel(
            contentRect: saved ?? Self.cascadeFrame(),
            // .titled gives the traffic lights and drag; .utilityWindow keeps the
            // title bar slim, the way a sticky should look.
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        // Appear on whichever Space you are on rather than yanking you back to
        // the one where the sticky was made, and stay put in Exposé.
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.minSize = NSSize(width: 220, height: 140)

        super.init(window: panel)
        panel.delegate = self
        panel.level = (sticky?.floats ?? true) ? .floating : .normal
        panel.contentView = NSHostingView(rootView: StickyView(id: stickyID))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Where a new note appears: near the pointer, on whichever display the
    /// pointer is on, staggered so a burst does not stack into one pile.
    ///
    /// Not centred on the main screen, which is what this did first — with more
    /// than one display that puts the note somewhere you are not looking, and
    /// the entire premise is "I had a thought while working *here*". The centre
    /// call also silently discarded the stagger, so every note landed on the
    /// same pixel.
    private static var cascadeStep = 0
    private static func cascadeFrame() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 340, height: 260)
        let offset = CGFloat(cascadeStep % 8) * 26
        cascadeStep += 1

        // Up and to the right of the pointer, which is where a sticky note lands
        // when you put one down — then clamped so it cannot open half off-screen.
        var origin = CGPoint(x: mouse.x + 24 + offset, y: mouse.y - size.height - 24 - offset)
        origin.x = min(max(visible.minX + 8, origin.x), visible.maxX - size.width - 8)
        origin.y = min(max(visible.minY + 8, origin.y), visible.maxY - size.height - 8)
        return NSRect(origin: origin, size: size)
    }

    /// A saved frame that no longer lands on any display — an external monitor
    /// unplugged since — is worse than no frame at all, because the note comes
    /// back invisible and cannot be dragged back.
    static func onScreen(_ frame: CGRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }

    func setFloats(_ floats: Bool) {
        window?.level = floats ? .floating : .normal
    }

    // MARK: - NSWindowDelegate

    /// Position and size are part of the note. Recorded on every move so a
    /// crash does not lose where things were.
    func windowDidMove(_ notification: Notification) { rememberFrame() }
    func windowDidResize(_ notification: Notification) { rememberFrame() }

    private func rememberFrame() {
        guard let window, var s = Store.shared.sticky(stickyID) else { return }
        s.frame = window.frame
        Store.shared.save(s, debounce: 1.5)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing is not deleting — the note stays on disk and in the menu, and
        // is simply not reopened at launch. Flush after recording that, because
        // whatever was typed last has not been written yet.
        if var s = Store.shared.sticky(stickyID) {
            s.isOpen = false
            Store.shared.save(s, debounce: 0)
        }
        Store.shared.flush(stickyID)
        Self.forget(stickyID)
    }
}
