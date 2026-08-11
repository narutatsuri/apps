import AppKit

/// Makes double-clicking the title bar zoom the window, as it does everywhere else.
///
/// Measured before fixing (FRONTIER_ZOOMTEST=1): `performZoom` resizes the window
/// fine, but a double-click on the bar does nothing, because NSToolbarTitleView —
/// which SwiftUI's toolbar stretches across most of the bar — swallows the click
/// instead of forwarding it to the frame. So the standard gesture was dead on
/// arrival everywhere except the few points of bare frame.
///
/// A *local* monitor (this app's events only, no permissions) watches for the
/// second mouse-up in the bar region, ignores anything on a real control so the
/// view picker and buttons keep working, and performs the action the user chose
/// in System Settings.
enum TitlebarZoom {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            guard event.clickCount == 2,
                  let window = event.window,
                  window.styleMask.contains(.titled) else { return event }

            // The bar is everything above the content layout rect.
            guard event.locationInWindow.y >= window.contentLayoutRect.maxY else { return event }

            // Only the bar's own inert furniture may zoom — a whitelist, not an
            // "is it a control" blacklist. SwiftUI's toolbar controls are not
            // reliably NSControl subclasses, and the first version of this
            // swallowed a quick second click on the view-mode tabs and zoomed
            // the window instead: "clicking a tab went fullscreen vertically".
            //
            // hitTest takes the root view's own base coordinates here —
            // verified empirically by ZoomDiagnose, whose bar probes only
            // resolve to NSToolbarTitleView with the *unconverted* window
            // location. convert(from: nil) flips y on the theme frame and
            // quietly hit-tests the bottom of the window instead.
            guard let frameView = window.contentView?.superview else { return event }
            let hit = frameView.hitTest(event.locationInWindow)
            let name = hit.map { String(describing: type(of: $0)) } ?? ""
            let inert = hit === frameView
                || name.contains("TitleView") || name.contains("FlexibleSpace")
                || name.contains("ThemeFrame") || name.contains("Titlebar")
            guard inert else { return event }

            // What the user asked double-click to mean, system-wide. "Fill" (new
            // in recent macOS) has no public API, so it gets zoom, the nearest
            // honest approximation.
            let action = UserDefaults.standard
                .persistentDomain(forName: UserDefaults.globalDomain)?["AppleActionOnDoubleClick"]
                as? String ?? "Maximize"
            switch action {
            case "None": return event
            case "Minimize": window.performMiniaturize(nil)
            default: window.performZoom(nil)
            }
            return nil    // handled; a second zoom from the frame would undo it
        }
    }
}
