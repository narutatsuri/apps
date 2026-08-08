import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let model = Model()
    private var tick: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Store.shared.bootstrap()
        model.recompute()
        installStatusItem()
        _ = DesktopWindow(model: model)

        // Every thirty seconds: enough that the minutes are never wrong, cheap
        // enough that it does not matter.
        tick = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated {
                self.model.recompute()
                DesktopWindow.shared?.fit()
            }
        }
        // Watch the file, so editing conferences.txt takes effect without a
        // relaunch — the file is the interface, so it has to behave like one.
        watchList()
        sync()
        // Plugging in a monitor changes where the corners are.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DesktopWindow.shared?.fit() }
        }
        // Dates move. Six-hourly is far more often than a conference changes
        // its mind, and costs four requests a day.
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { self.sync() }
        }
    }

    // MARK: - Fetching

    private func sync() {
        let tracked = Store.shared.tracked
        Task { @MainActor in
            let fetched = await Feed.fetch(tracked)
            if fetched.isEmpty {
                // Keep the cache rather than blanking the panel: the last known
                // dates are far more useful than an empty card.
                model.offline = !tracked.isEmpty
            } else {
                Store.shared.store(fetched)
                model.offline = false
                model.checked = Date()
            }
            model.recompute()
            DesktopWindow.shared?.fit()
        }
    }

    private var watcher: DispatchSourceFileSystemObject?

    private func watchList() {
        let descriptor = open(Store.list.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                Store.shared.reload()
                self?.model.recompute()
                self?.sync()
                // An editor that saves by replacing the file leaves the old
                // descriptor watching nothing, so start again.
                self?.watcher?.cancel()
                self?.watcher = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.watchList() }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    // MARK: - Menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "calendar.badge.clock",
                                     accessibilityDescription: "Deadlines")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // The next deadline, in the menu bar itself, so it is answerable
        // without looking at the desktop.
        if let next = model.standings.compactMap({ standing -> Deadline? in
            if case .upcoming(let d) = standing { return d }
            return nil
        }).first {
            let title = "\(next.title) \(next.kind.label) — \(Countdown.text(from: Date(), to: next.at))"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        let position = NSMenuItem(title: "Position", action: nil, keyEquivalent: "")
        let corners = NSMenu()
        for corner in DesktopWindow.Corner.allCases {
            let item = NSMenuItem(title: corner.label, action: #selector(menuCorner(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = corner.rawValue
            item.state = DesktopWindow.corner == corner ? .on : .off
            corners.addItem(item)
        }
        position.submenu = corners
        menu.addItem(position)

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(menuRefresh),
                                 keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let edit = NSMenuItem(title: "Edit Conferences…", action: #selector(menuEdit),
                              keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Deadlines", action: #selector(menuQuit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func menuCorner(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let corner = DesktopWindow.Corner(rawValue: raw) else { return }
        DesktopWindow.corner = corner
    }
    @objc private func menuRefresh() { sync() }
    @objc private func menuEdit() { NSWorkspace.shared.open(Store.list) }
    @objc private func menuQuit() { NSApp.terminate(nil) }
}

@main
enum Main {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--selftest") {
            MainActor.assumeIsolated { SelfTest.run() }
        }
        if let i = arguments.firstIndex(of: "--preview"), i + 1 < arguments.count {
            let path = arguments[i + 1]
            MainActor.assumeIsolated { CLI.preview(path) }
        }
        if arguments.contains("--list") {
            MainActor.assumeIsolated { CLI.list() }
        }

        let app = NSApplication.shared
        // No Dock tile: this is furniture, not something you switch to.
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
