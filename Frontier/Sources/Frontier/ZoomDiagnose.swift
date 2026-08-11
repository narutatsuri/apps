import AppKit

/// FRONTIER_ZOOMTEST=1 — measures what the title bar actually does.
///
/// "Double-clicking the title bar doesn't zoom" is a claim about which view is
/// under the cursor and who handles the double-click; guessing at it is how the
/// wrong thing gets fixed. This prints the hit-test result across the title bar,
/// then sends a real double-click through the window and reports whether the
/// frame changed, then calls performZoom directly as the control.
enum ZoomDiagnose {
    static func scheduleIfAsked() {
        guard ProcessInfo.processInfo.environment["FRONTIER_ZOOMTEST"] == "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { run() }
    }

    private static func run() {
        guard let w = NSApp.windows.first(where: { $0.isVisible }) else {
            print("ZOOMTEST: no visible window"); exit(1)
        }
        // Start from a known, un-zoomed frame — the window restores whatever it
        // last had, and a test that starts zoomed measures nothing.
        w.setFrame(NSRect(x: 200, y: 200, width: 1000, height: 700), display: true)
        let f = w.frame
        print("ZOOMTEST window frame: \(Int(f.width))x\(Int(f.height)) at (\(Int(f.origin.x)),\(Int(f.origin.y)))")
        print("  styleMask: resizable=\(w.styleMask.contains(.resizable))"
              + " fullSizeContent=\(w.styleMask.contains(.fullSizeContentView))"
              + " titlebarTransparent=\(w.titlebarAppearsTransparent)"
              + " toolbarStyle=\(w.toolbarStyle.rawValue)"
              + " titleVisibility=\(w.titleVisibility.rawValue)")
        print("  contentLayoutRect: h=\(Int(w.contentLayoutRect.height)) of frame h=\(Int(f.height))")

        // Who is under the title bar? frame coords: y from bottom, titlebar ≈ top 14pt.
        let frameView = w.contentView?.superview
        print("  hit-test across the title bar (top 14pt):")
        for fx in [0.18, 0.30, 0.45, 0.60, 0.75, 0.92] {
            let p = NSPoint(x: f.width * fx, y: f.height - 14)
            let hit = frameView?.hitTest(p)
            print(String(format: "    x=%.0f%%: %@", fx * 100,
                         hit.map { String(describing: type(of: $0)) } ?? "nil"))
        }

        // A real double-click, sent through the window at a clear stretch of bar.
        let before = w.frame
        let clickPoint = NSPoint(x: f.width * 0.45, y: f.height - 12)
        for count in 1...2 {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(
                    with: type, location: clickPoint,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: w.windowNumber, context: nil,
                    eventNumber: 0, clickCount: count, pressure: 1) {
                    // Through the app, not the window: local event monitors —
                    // including the double-click fix under test — sit in
                    // NSApplication's dispatch, and window.sendEvent skips them.
                    NSApp.sendEvent(e)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let after = w.frame
            print("  after synthetic double-click: \(Int(after.width))x\(Int(after.height))"
                  + "  changed=\(after != before)")
            w.performZoom(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let zoomed = w.frame
                print("  after performZoom: \(Int(zoomed.width))x\(Int(zoomed.height))"
                      + "  changed=\(zoomed != after)")
                exit(0)
            }
        }
    }
}
