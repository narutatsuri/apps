import AppKit
import WebKit
import SwiftUI

@main
struct FrontierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--selftest") { MainActor.assumeIsolated { SelfTest.run() } }
        MainActor.assumeIsolated { CLI.run(args) }
        TitlebarZoom.install()
        ZoomDiagnose.scheduleIfAsked()
        LayoutDump.scheduleIfAsked()
        WebProbe.scheduleIfAsked()
    }

    var body: some Scene {
        // The real window is AppKit's, built in the delegate. Inside the SwiftUI
        // Window scene's own AppKitWindow, a WKWebView never composites on this
        // macOS — full DOM, correct frame, visible, alpha 1, zero paint, even
        // when added by plain AppKit (FRONTIER_INJECT). The same content in a
        // plain NSWindow + NSHostingView paints (FRONTIER_WEBPROBE probes 2 and
        // 3, toolbar included). Settings is the minimal scene SwiftUI demands.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var warmup: NSWindow?
    private let model = Model()

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeWindow()
    }

    /// The window is created *at* its final frame and never moved before its
    /// first compositor commit. On this macOS, a window whose frame changes
    /// between creation and that first commit — a `center()`, or the restore
    /// that `setFrameAutosaveName` performs — permanently stops compositing
    /// out-of-process layers, which is a WKWebView pane that builds a full DOM
    /// at the right frame and paints nothing, ever. Bisected to exactly these
    /// two calls with a probe-window series (see git history for the probes);
    /// the same move applied one second later is harmless. This is also why
    /// the SwiftUI Window scene could not host the pane: a scene restores its
    /// saved frame at launch, poisoning itself the same way.
    private func makeWindow() {
        let mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let win = NSWindow(contentRect: Self.startingRect(for: mask),
                           styleMask: mask, backing: .buffered, defer: false)
        win.title = "Frontier"
        // One curriculum, one window; closing hides rather than deallocates,
        // so a Dock click brings the same window back.
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: ContentView(model: model))
        win.makeKeyAndOrderFront(nil)
        // Frame persistence is armed only after the first commit. It restores
        // the frame the window was already born at, so nothing jumps.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            win.setFrameAutosaveName("FrontierMain")
        }
        window = win
    }

    /// The saved frame, read by hand so the window can *start* there instead of
    /// being moved there after creation — the move is the poison.
    private static func startingRect(for mask: NSWindow.StyleMask) -> NSRect {
        if let saved = UserDefaults.standard.string(forKey: "NSWindow Frame FrontierMain") {
            let parts = saved.split(separator: " ").compactMap { Double($0) }
            if parts.count >= 4, parts[2] > 300, parts[3] > 300 {
                let frame = NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
                return NSWindow.contentRect(forFrameRect: frame, styleMask: mask)
            }
        }
        let size = NSSize(width: 1040, height: 720)
        guard let screen = NSScreen.main else {
            return NSRect(x: 200, y: 200, width: size.width, height: size.height)
        }
        let v = screen.visibleFrame
        return NSRect(x: (v.midX - size.width / 2).rounded(),
                      y: (v.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }
}
