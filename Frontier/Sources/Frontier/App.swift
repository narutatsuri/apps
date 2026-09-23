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
        WindowCheck.scheduleIfAsked()
    }

    var body: some Scene {
        // The real window is AppKit's, built in the delegate: a SwiftUI Window
        // scene restores its saved frame at launch, which is exactly the move
        // that stops the window compositing the reading pane's web view (see
        // makeWindow). Settings is the minimal scene SwiftUI demands.
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
        let hosting = NSHostingView(rootView: ContentView(model: model))
        // The window sizes the content, never the other way round.
        //
        // By default an NSHostingView publishes its SwiftUI content's minimum
        // size as the window's contentMinSize, and the sidebar List asks for
        // the height of every row it holds — measured at contentMinSize
        // 373×3522 against a 949pt screen. The window is born at its saved
        // 868pt, and then the frame restore armed below is a resize, which
        // AppKit clamps up to that minimum: the window silently grows to 3554pt
        // one second after launch, most of it off the bottom of the display.
        // The List scrolls perfectly well in a small window; it just must not
        // get a vote on how big the window is.
        if #available(macOS 13.0, *) { hosting.sizingOptions = [] }
        win.contentView = hosting
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
