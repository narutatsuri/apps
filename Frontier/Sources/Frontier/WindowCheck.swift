import AppKit

/// `FRONTIER_WINTEST=1` — asserts the real window still fits on the screen, in
/// the shipping configuration, and exits non-zero if it does not.
///
/// This is a GUI fact and so cannot go in `--selftest`, but it is exactly the
/// kind of fault that is invisible in a transcript and obvious in use: the
/// window is *born* at its saved size and then grows, a second later, to
/// several times the height of the display — so the app looks fine for one
/// frame and then puts its own controls below the bottom edge of the screen.
///
/// It has happened twice for different reasons. An NSHostingView publishes its
/// SwiftUI content's minimum size as the window's `contentMinSize`, and the
/// sidebar List asks for the height of every row it holds; the frame restore
/// armed at +1s is a resize, and AppKit clamps a resize up to that minimum.
/// Measured at 1040×3554 against a 949pt screen before `sizingOptions = []`.
/// The window sizes the content, never the other way round — this checks that
/// that is still true.
@MainActor
enum WindowCheck {
    static func scheduleIfAsked() {
        guard ProcessInfo.processInfo.environment["FRONTIER_WINTEST"] == "1" else { return }
        // After the frame restore has had its chance to grow the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            MainActor.assumeIsolated { run() }
        }
    }

    private static func run() {
        var fails = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { fails += 1 }
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let screen = window.screen ?? NSScreen.main else {
            print("FAIL  window-check — no visible window")
            exit(1)
        }
        let visible = screen.visibleFrame
        check("the window fits on the screen",
              window.frame.height <= visible.height + 1
              && window.frame.width <= visible.width + 1,
              "window \(Int(window.frame.width))×\(Int(window.frame.height)), "
            + "screen \(Int(visible.width))×\(Int(visible.height))")
        check("the content does not impose a minimum bigger than the screen",
              window.contentMinSize.height <= visible.height,
              "contentMinSize \(Int(window.contentMinSize.width))×"
            + "\(Int(window.contentMinSize.height)) — the sidebar List asking for "
            + "every row it holds is how the window grew off the bottom of the display")
        check("the window is still on screen at all",
              visible.intersects(window.frame),
              "frame \(window.frame)")
        print(fails == 0 ? "\nwindow OK" : "\n\(fails) FAILURE(S)")
        exit(fails == 0 ? 0 : 1)
    }
}
