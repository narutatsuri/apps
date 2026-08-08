import Foundation

/// One dated thing you can submit to.
///
/// An absolute instant, not a wall-clock date. Every conference states its
/// deadline in its own zone and most of them use Anywhere on Earth, so the only
/// safe internal representation is the moment itself; the zone is kept purely
/// to show you which rules you are living under.
struct Deadline: Equatable {
    enum Kind: String, Equatable {
        case abstract, paper

        var label: String {
            switch self {
            case .abstract: return "abstract"
            case .paper: return "paper"
            }
        }
    }

    var conference: String
    var year: Int
    var kind: Kind
    var at: Date
    /// As written by the source — "AoE", "UTC+0". Displayed, because a deadline
    /// without its zone is the thing that loses papers.
    var zone: String
    var place: String = ""
    var link: String = ""

    var title: String { "\(conference) \(year)" }
}

/// Turning a conference's stated zone into an offset.
enum Zone {
    /// Anywhere on Earth is UTC-12 — the last place on the planet where it is
    /// still that date. Treating it as UTC is a twelve-hour error in the
    /// direction that loses papers, so it is spelled out here and tested.
    static let anywhereOnEarth = -12 * 3600

    /// Seconds east of UTC, or nil if the label is not one we understand.
    /// Nil rather than a guess: a deadline shown in the wrong zone is worse
    /// than a deadline not shown.
    static func offset(_ label: String) -> Int? {
        let text = label.trimmingCharacters(in: .whitespaces)
        if text.uppercased() == "AOE" { return anywhereOnEarth }

        // UTC+8, UTC-12, UTC+5:30, or a bare UTC.
        guard text.uppercased().hasPrefix("UTC") else { return nil }
        let rest = String(text.dropFirst(3))
        if rest.isEmpty { return 0 }
        guard let sign = rest.first, sign == "+" || sign == "-" else { return nil }
        let magnitude = rest.dropFirst()
        let parts = magnitude.split(separator: ":", maxSplits: 1)
        guard let hours = Int(parts.first ?? "") else { return nil }
        let minutes = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let seconds = hours * 3600 + minutes * 60
        return sign == "-" ? -seconds : seconds
    }

    /// `2026-09-25 23:59:59` in `label`'s zone, as an instant.
    static func date(_ stamp: String, in label: String) -> Date? {
        guard let offset = offset(label) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: offset)
        if let date = formatter.date(from: stamp) { return date }
        // Some entries carry only minutes.
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        if let date = formatter.date(from: stamp) { return date }
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: stamp)
    }
}

/// How long is left, in the words you would use out loud.
enum Countdown {
    /// Coarse on purpose. Seconds ticking down on a desktop widget is a
    /// distraction, and past a day the hours are what you actually plan around.
    static func text(from now: Date, to deadline: Date) -> String {
        let seconds = Int(deadline.timeIntervalSince(now))
        guard seconds > 0 else { return "passed" }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(String(format: "%02d", hours))h" }
        if hours > 0 { return "\(hours)h \(String(format: "%02d", minutes))m" }
        return "\(minutes)m"
    }

    /// Red inside two days, amber inside a week. Anything further out is just
    /// information, and colouring it makes the urgent ones stop standing out.
    enum Urgency { case past, imminent, soon, distant }

    static func urgency(from now: Date, to deadline: Date) -> Urgency {
        let seconds = deadline.timeIntervalSince(now)
        if seconds <= 0 { return .past }
        if seconds < 2 * 86_400 { return .imminent }
        if seconds < 7 * 86_400 { return .soon }
        return .distant
    }
}

/// What to show for one conference.
///
/// A tracked conference with nothing upcoming is a real state, not an empty
/// one: NeurIPS 2027's dates do not exist in August 2026, and showing last
/// year's date, or silently dropping the row, both read as "nothing to do".
enum Standing: Equatable {
    case upcoming(Deadline)
    case unannounced(conference: String, lastKnown: Int?)
}

enum Schedule {
    /// The next deadline for each tracked conference, soonest first.
    ///
    /// Abstract and paper deadlines are separate rows when both are ahead —
    /// the abstract one is the one people miss, and folding them into a single
    /// "next" hides it the moment the paper deadline is the later of the two.
    static func standings(for tracked: [String], in all: [Deadline],
                          now: Date) -> [Standing] {
        var out: [Standing] = []
        for conference in tracked {
            let mine = all.filter { $0.conference.caseInsensitiveCompare(conference) == .orderedSame }
            let ahead = mine.filter { $0.at > now }.sorted { $0.at < $1.at }
            if ahead.isEmpty {
                out.append(.unannounced(conference: conference,
                                        lastKnown: mine.map(\.year).max()))
            } else {
                // Only the next round, but both of its deadlines.
                let year = ahead[0].year
                for deadline in ahead where deadline.year == year {
                    out.append(.upcoming(deadline))
                }
            }
        }
        return out.sorted { a, b in
            switch (a, b) {
            case (.upcoming(let x), .upcoming(let y)): return x.at < y.at
            case (.upcoming, .unannounced): return true
            case (.unannounced, .upcoming): return false
            case (.unannounced(let x, _), .unannounced(let y, _)): return x < y
            }
        }
    }
}
