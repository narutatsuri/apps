import AppKit

/// Opening the PDF for reading, and getting the two windows onto different screens.
enum Reading {
    /// Opens in whatever handles PDFs — Preview unless it's been changed.
    static func openPDF(_ path: String) {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Which screen a given app's frontmost window sits on. Uses the window list
    /// rather than the Accessibility API, so it needs no permission.
    private static func screen(ofApp appName: String) -> NSScreen? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            guard (info[kCGWindowOwnerName as String] as? String) == appName,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width > 200, bounds.height > 200 else { continue }
            // CGWindow coordinates are top-left origin; NSScreen is bottom-left.
            let flippedY = (NSScreen.screens.first?.frame.maxY ?? 0) - bounds.midY
            let point = CGPoint(x: bounds.midX, y: flippedY)
            if let match = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
                return match
            }
        }
        return nil
    }

    /// Moves our window to a screen the reader isn't using. With three displays a
    /// fixed rule would be a guess, so this only avoids the one Preview occupies.
    static func placeNotesAwayFrom(readerApp: String = "Preview") {
        guard NSScreen.screens.count > 1,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })
        else { return }

        let taken = screen(ofApp: readerApp)
        let ours = window.screen
        guard taken == nil || taken == ours else { return }   // already apart

        guard let destination = NSScreen.screens.first(where: { $0 != taken }) else { return }
        let visible = destination.visibleFrame
        let width = min(max(visible.width * 0.46, 640), visible.width - 40)
        let frame = NSRect(x: visible.maxX - width - 20,
                           y: visible.minY + 20,
                           width: width,
                           height: visible.height - 40)
        window.setFrame(frame, display: true, animate: true)
    }

    /// Moves our window one display along — the manual escape hatch, since with
    /// three screens no automatic rule is right for everyone.
    static func moveNotesToNextScreen() {
        let screens = NSScreen.screens
        guard screens.count > 1,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let current = window.screen,
              let index = screens.firstIndex(of: current) else { return }
        let next = screens[(index + 1) % screens.count]
        let visible = next.visibleFrame
        let size = window.frame.size
        window.setFrame(NSRect(x: visible.midX - size.width / 2,
                               y: visible.midY - size.height / 2,
                               width: min(size.width, visible.width - 40),
                               height: min(size.height, visible.height - 40)),
                        display: true, animate: true)
    }
}
