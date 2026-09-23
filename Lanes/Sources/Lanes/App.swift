import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaneStore.shared.bootstrap()
        ImageStore.install()
        MainMenu.install(target: self)
        Theme.watchSystem()
        NotificationCenter.default.addObserver(
            forName: Theme.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.applyTheme() }
        }
        showWindow()
        if ProcessInfo.processInfo.environment["LANES_WINTEST"] == "1" { WindowCheck.schedule() }
        if ProcessInfo.processInfo.environment["LANES_RENAMETEST"] == "1" { WindowCheck.scheduleRenameTest() }
        if let path = ProcessInfo.processInfo.environment["LANES_SNAPSHOT"], !path.isEmpty {
            WindowCheck.scheduleSnapshot(to: path)
        }
    }

    private func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Lanes"
            w.minSize = NSSize(width: 480, height: 360)
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("LanesBoard")
            let host = NSHostingView(rootView: LanesBoard())
            // Without this the hosting view publishes the content's minimum
            // size as the window's, and an NSHostingView's idea of "minimum"
            // has inflated a window past the screen before (Frontier).
            host.sizingOptions = []
            w.contentView = host
            w.delegate = self
            window = w
        }
        applyTheme()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyTheme() {
        window?.appearance = Theme.nsAppearance
        window?.backgroundColor = Theme.paper(.grey)
    }

    /// Dock click with the window closed: bring the board back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func windowWillClose(_ notification: Notification) { LaneStore.shared.flushAll() }
    func applicationWillTerminate(_ notification: Notification) { LaneStore.shared.flushAll() }

    @objc func menuNew() { showWindow(); LaneStore.shared.add() }
    @objc func menuVaultFolder() {
        try? FileManager.default.createDirectory(at: LaneStore.vault, withIntermediateDirectories: true)
        NSWorkspace.shared.open(LaneStore.vault)
    }

    /// The Restore from Vault submenu: one item per vaulted lane or project.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let names = LaneStore.shared.vaulted()
        if names.isEmpty {
            let empty = menu.addItem(withTitle: "Nothing in the vault", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            return
        }
        for name in names {
            let item = menu.addItem(withTitle: name.hasSuffix("/") ? String(name.dropLast()) + " (project)" : name,
                                    action: #selector(menuRestore(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
        }
    }

    @objc func menuRestore(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        showWindow()
        LaneStore.shared.restore(name)
    }
    @objc func menuFolder() { NSWorkspace.shared.open(LaneStore.root) }
    @objc func menuQuit() { NSApp.terminate(nil) }
    @objc func menuToggleTheme() { Theme.toggle() }
}

@main
enum LanesMain {
    static var delegate: AppDelegate?

    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            MainActor.assumeIsolated { SelfTest.run() }
        }
        let app = NSApplication.shared
        let d = MainActor.assumeIsolated { AppDelegate() }
        delegate = d
        app.delegate = d
        // A regular app: this is a board you sit in front of, not a note that
        // floats over your work, so it gets a Dock tile and an app-switcher
        // entry like any document window.
        app.setActivationPolicy(.regular)
        app.run()
    }
}
