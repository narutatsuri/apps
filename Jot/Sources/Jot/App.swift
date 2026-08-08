import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotKeys: [HotKey] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Store.shared.bootstrap()
        installStatusItem()
        MainMenu.install(target: self)
        Theme.watchSystem()
        NotificationCenter.default.addObserver(
            forName: Theme.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { StickyWindow.applyTheme() }
        }

        // Same checks as --selftest, but here: real app, real .accessory
        // policy, no menu bar, launched the way it is normally launched.
        if ProcessInfo.processInfo.environment["JOT_KEYTEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                KeyTest.run(nonactivating: false) { bare in
                KeyTest.runOpenDoesNotErase { safety in
                KeyTest.runInRealNote { real in
                    let results = bare + safety + real
                    let lines = results.map {
                        "\($0.ok ? "PASS" : "FAIL")  \($0.label)"
                            + ($0.ok || $0.detail.isEmpty ? "" : " — \($0.detail)")
                    }
                    let report = lines.joined(separator: "\n")
                        + "\n\(results.filter { !$0.ok }.count) FAILURE(S)\n"
                    let out = ProcessInfo.processInfo.environment["JOT_KEYTEST_OUT"]
                        ?? NSTemporaryDirectory() + "jot-keytest.txt"
                    try? report.write(toFile: out, atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                }
                }
                }
            }
        }
        installHotKeys()

        // A note made from the terminal should appear, not wait for a relaunch.
        DistributedNotificationCenter.default().addObserver(
            forName: .init("local.jot.reload"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                Store.shared.reload()
                if let id = note.object as? String { StickyWindow.show(id) }
            }
        }

        // Reopen whatever was on screen last time. A note you left on the desktop
        // should be there after a restart, the way a paper one would be; one you
        // closed should stay closed and live in the menu.
        let reopening = Store.shared.ordered.filter(\.isOpen)
        for sticky in reopening {
            StickyWindow.show(sticky.id, activate: false)
        }
        if Store.shared.stickies.isEmpty { newSticky() }

        // JOT_WINDOWS=1 reports what actually reached the screen. "the window is
        // there but not visible" is a claim about NSWindow state, and reading it
        // from outside the process cannot tell a panel from a stray host view.
        if ProcessInfo.processInfo.environment["JOT_WINDOWS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                print("NSApp.windows — \(NSApp.windows.count)")
                for w in NSApp.windows {
                    print("  \(type(of: w))  visible=\(w.isVisible)  level=\(w.level.rawValue)"
                          + "  frame=\(Int(w.frame.width))x\(Int(w.frame.height))"
                          + "@(\(Int(w.frame.minX)),\(Int(w.frame.minY)))"
                          + "  key=\(w.isKeyWindow)  canBecomeKey=\(w.canBecomeKey)")
                }
                print("store: \(Store.shared.stickies.count) stickies")
                exit(0)
            }
        }
    }

    /// Quitting must not lose the last sentence — the store writes on a debounce.
    func applicationWillTerminate(_ notification: Notification) {
        Store.shared.flushAll()
    }

    /// Clicking the Dock icon or the app in Spotlight brings the stickies up
    /// rather than doing nothing, since there is no main window to restore.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        StickyWindow.showAll()
        return true
    }

    // MARK: - Actions

    func newSticky(colour: StickyColour = .yellow) {
        let s = Store.shared.create(colour: colour)
        // Written immediately: the window reads it back by id, and a debounced
        // write would not be there yet.
        Store.shared.flush(s.id)
        StickyWindow.show(s.id)
    }

    /// One key that does the obvious thing in both directions.
    func toggleAll() {
        if StickyWindow.visibleCount > 0 {
            StickyWindow.hideAll()
        } else {
            StickyWindow.showAll()
        }
    }

    // MARK: - Setup

    private func installHotKeys() {
        hotKeys = [
            HotKey(key: Shortcuts.newSticky.key, modifiers: Shortcuts.newSticky.mods) { [weak self] in
                self?.newSticky()
            },
            HotKey(key: Shortcuts.toggleAll.key, modifiers: Shortcuts.toggleAll.mods) { [weak self] in
                self?.toggleAll()
            },
        ].compactMap { $0 }

        if hotKeys.count < 2 {
            // Another app already owns the combination. Say so rather than
            // leaving the user pressing a key that silently does nothing.
            let alert = NSAlert()
            alert.messageText = "A shortcut is already taken"
            alert.informativeText = "⌃⌥Space (new sticky) or ⌃⌥S (show/hide) is registered "
                + "by another app, so it won't work here. Everything else still does — "
                + "use the menu bar icon."
            alert.alertStyle = .informational
            alert.runModal()
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "note.text",
                                     accessibilityDescription: "Jot")
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Rebuilt on open so the list is never stale — stickies are created and
    /// deleted from windows, not from here.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let new = NSMenuItem(title: "New Sticky", action: #selector(menuNew), keyEquivalent: "n")
        new.target = self
        menu.addItem(new)

        let toggle = NSMenuItem(title: StickyWindow.visibleCount > 0 ? "Hide All" : "Show All",
                                action: #selector(menuToggle), keyEquivalent: "s")
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        let stickies = Store.shared.ordered
        if stickies.isEmpty {
            menu.addItem(NSMenuItem(title: "No stickies yet", action: nil, keyEquivalent: ""))
        } else {
            for sticky in stickies.prefix(20) {
                let item = NSMenuItem(title: sticky.title, action: #selector(menuOpen(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = sticky.id
                // A colour swatch, so the menu reads the same way the desktop does.
                item.image = Self.swatch(sticky.colour)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let theme = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let themes = NSMenu()
        for option in Theme.Preference.allCases {
            let item = NSMenuItem(title: option.label, action: #selector(menuTheme(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = Theme.preference == option ? .on : .off
            themes.addItem(item)
        }
        theme.submenu = themes
        menu.addItem(theme)

        menu.addItem(.separator())
        let folder = NSMenuItem(title: "Open ~/jot", action: #selector(menuFolder),
                                keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)

        // No menu bar to read them off — this app is LSUIElement — so the
        // shortcuts are listed here or they are not discoverable at all.
        for line in ["⌃⌥Space  new · ⌃⌥S  show/hide",
                     "⌘B bold · ⌘I italic · ⌘E code",
                     "⌘⇧H highlight · ⌘⇧X strike · ⌘⇧M maths",
                     "⌘R render · ⌘1–6 colour · ⌘⇧D dark · ⌘⌫ delete"] {
            let hint = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            hint.isEnabled = false
            hint.attributedTitle = NSAttributedString(string: line, attributes: [
                .font: NSFont.menuFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            menu.addItem(hint)
        }

        let quit = NSMenuItem(title: "Quit Jot", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private static func swatch(_ colour: StickyColour) -> NSImage {
        let size = NSSize(width: 11, height: 11)
        let image = NSImage(size: size)
        image.lockFocus()
        let hex = Theme.current == .dark ? colour.paper.dark : colour.paper.light
        NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }

    @objc func menuNew() { newSticky() }
    @objc func menuToggle() { toggleAll() }
    @objc func menuOpen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        StickyWindow.show(id)
    }
    @objc func menuTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let choice = Theme.Preference(rawValue: raw) else { return }
        Theme.preference = choice
    }
    @objc func menuToggleTheme() { Theme.toggle() }
    @objc func menuFolder() {
        NSWorkspace.shared.open(Store.root)
    }
    @objc func menuQuit() {
        Store.shared.flushAll()
        NSApp.terminate(nil)
    }
}

@main
enum Main {
    /// Held strongly: NSApplication.delegate is weak.
    private static var delegate: AppDelegate?

    static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest") {
            MainActor.assumeIsolated { SelfTest.run() }
        }
        // `jot "an idea"` or `something | jot` — the case the app exists for is
        // having an idea while your hands are already in a terminal, and making
        // you reach for a hotkey and a window is a worse answer than a pipe.
        if let i = args.firstIndex(of: "--new") {
            MainActor.assumeIsolated { CLI.new(Array(args[(i + 1)...])) }
        }
        if args.contains("--list") {
            MainActor.assumeIsolated { CLI.list() }
        }

        let app = NSApplication.shared
        let d = MainActor.assumeIsolated { AppDelegate() }
        delegate = d
        app.delegate = d
        // .accessory: a menu bar icon and floating notes, no Dock tile and no
        // app-switcher entry. A scratchpad should not be something you alt-tab
        // to; it should already be on top.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
