import AppKit

/// Light or dark, and every colour that depends on it.
///
/// A sticky is a piece of paper, so its ink never drifted with the system
/// appearance — but paper can be dark paper. Each colour already carried a dark
/// shade in `StickyColour.paper`; this is what finally uses it. Yellow becomes a
/// deep olive-yellow with warm off-white ink rather than white-on-white, which
/// is what a naive `.labelColor` would have given.
///
/// Every colour in the app comes from here. That is the point: the editor, the
/// rendered view, the equations and the window chrome have to agree, and they
/// only agree if there is one place that decides.
@MainActor
enum Theme {
    enum Appearance: String { case light, dark }

    /// What the user asked for, which may be "whatever the system is doing".
    enum Preference: String, CaseIterable {
        case system, light, dark
        var label: String {
            switch self {
            case .system: return "Follow System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    static let changed = Notification.Name("jot.theme.changed")
    private static let key = "jot.theme"

    static var preference: Preference {
        get { Preference(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// The appearance actually in force.
    static var current: Appearance {
        switch preference {
        case .light: return .light
        case .dark: return .dark
        case .system:
            // NSApp is nil before the app finishes launching, and answering
            // "light" then and "dark" a moment later reads as a theme change —
            // which repaints every note. The defaults key is available
            // immediately and gives the same answer throughout.
            if let match = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) {
                return match == .darkAqua ? .dark : .light
            }
            let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
            return style?.lowercased().contains("dark") == true ? .dark : .light
        }
    }

    /// ⌘⇧D. Commits to a side rather than cycling back through "system": once
    /// you have reached for the toggle, following the system is not what you
    /// wanted.
    static func toggle() {
        preference = current == .dark ? .light : .dark
    }

    /// Keeps `system` honest when the OS flips at sunset.
    static func watchSystem() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard preference == .system else { return }
                NotificationCenter.default.post(name: changed, object: nil)
            }
        }
    }

    // MARK: - The palette

    static func paper(_ colour: StickyColour) -> NSColor {
        rgb(current == .dark ? colour.paper.dark : colour.paper.light)
    }

    /// Off-white rather than white on dark paper: pure white on a coloured
    /// ground glares, and these papers are coloured, not black.
    static var ink: NSColor { current == .dark ? rgb(0xF2F0EA) : .black }

    /// Markers, bullets and quote marks — present, but not competing with the
    /// words. An alpha of the ink, so it works on either paper.
    static func dimmedInk(_ alpha: CGFloat) -> NSColor { ink.withAlphaComponent(alpha) }

    static var codeInk: NSColor {
        current == .dark ? rgb(0xF3B7B2) : rgb(0x73292A)
    }
    static var codeTint: NSColor {
        current == .dark ? NSColor.white.withAlphaComponent(0.10)
                         : NSColor.black.withAlphaComponent(0.07)
    }
    static var linkInk: NSColor {
        current == .dark ? rgb(0x9CC4FF) : rgb(0x14448F)
    }
    /// Enough to read as a highlighter, not enough to bury the text under it.
    static var highlightTint: NSColor {
        current == .dark ? rgb(0xFFD84D).withAlphaComponent(0.30)
                         : NSColor.systemYellow.withAlphaComponent(0.55)
    }
    static var selectionTint: NSColor {
        current == .dark ? NSColor.white.withAlphaComponent(0.20)
                         : NSColor.black.withAlphaComponent(0.14)
    }
    /// The system appearance a window should adopt, so its title bar, scrollers
    /// and menus match the paper instead of fighting it.
    static var nsAppearance: NSAppearance? {
        NSAppearance(named: current == .dark ? .darkAqua : .aqua)
    }

    /// `#rrggbb`, for the rendered view — the only consumer that speaks CSS.
    static func css(_ colour: NSColor) -> String {
        let c = colour.usingColorSpace(.sRGB) ?? colour
        return String(format: "rgba(%d, %d, %d, %.3f)",
                      Int(c.redComponent * 255), Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255), c.alphaComponent)
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255, alpha: 1)
    }
}
