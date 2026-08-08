import SwiftUI

/// One usage window, normalized across providers.
struct Meter: Identifiable {
    let id: String
    let label: String
    /// 0...100
    let percent: Double
    let resetsAt: Date?
    /// Providers mark which window is currently the binding one.
    let isActive: Bool

    var severity: Severity { Severity(percent: percent) }
}

/// Status is reserved for state, never for identity. Below the warning floor the
/// bar stays monochrome so it reads as recessive until it actually needs attention.
enum Severity {
    case normal, warning, serious, critical

    init(percent: Double) {
        switch percent {
        case ..<60: self = .normal
        case ..<80: self = .warning
        case ..<92: self = .serious
        default: self = .critical
        }
    }

    func color(_ scheme: ColorScheme) -> Color {
        switch self {
        case .normal: return scheme == .dark ? Color(hex: 0xC3C2B7) : Color(hex: 0x52514E)
        case .warning: return Color(hex: 0xFAB219)
        case .serious: return Color(hex: 0xEC835A)
        case .critical: return Color(hex: 0xD03B3B)
        }
    }

    /// Paired with every color so state is never carried by hue alone.
    var symbol: String? {
        switch self {
        case .normal: return nil
        case .warning: return "exclamationmark.circle.fill"
        case .serious: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }
}

struct ProviderSnapshot {
    var meters: [Meter] = []
    var plan: String?
    var note: String?
    var error: String?
    var fetchedAt: Date?
    /// The last fetch failed, but these numbers are from an earlier success and are
    /// still worth showing.
    var isStale = false
    /// Server-supplied backoff hint, when it supplies a usable one.
    var retryAfter: TimeInterval?

    /// The window closest to its ceiling — what the menu bar should surface.
    var headline: Meter? {
        meters.max(by: { $0.percent < $1.percent })
    }
}

enum HTTPHint {
    /// The usage endpoint answers 429 with `retry-after: 0`, which is not a usable
    /// hint. Treat non-positive values as absent and let our own backoff decide.
    static func retryAfter(_ response: HTTPURLResponse?) -> TimeInterval? {
        guard let raw = response?.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw), seconds > 0 else { return nil }
        return seconds
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

enum Fmt {
    /// "2h 14m" / "3d 4h" / "12m"
    static func countdown(to date: Date) -> String? {
        let s = date.timeIntervalSinceNow
        guard s > 0 else { return nil }
        let d = Int(s) / 86400, h = (Int(s) % 86400) / 3600, m = (Int(s) % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(max(m, 1))m"
    }

    static func pct(_ v: Double) -> String {
        v < 10 && v != v.rounded() ? String(format: "%.1f%%", v) : "\(Int(v.rounded()))%"
    }
}
