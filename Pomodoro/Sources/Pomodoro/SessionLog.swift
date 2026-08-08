import Foundation

enum EndReason: String, Codable {
    case completed   // ran to its natural end
    case early       // user cut it short (break taken early, or break skipped)
    case stopped     // timer stopped outright
    case paused      // interval closed by a pause; paused time is not counted
}

/// One contiguous stretch of work or break. Paused time is excluded by closing the
/// interval on pause and opening a fresh one on resume, so logged minutes are minutes
/// actually spent.
struct SessionRecord: Codable {
    let kind: String            // Phase.rawValue
    let start: Date
    let end: Date
    let endedBy: EndReason
    /// What the duration was configured to be when this ran. Not needed today, but
    /// it is what makes "is 25 minutes right for me?" answerable later without
    /// having to guess at historical settings.
    let plannedMinutes: Int

    var duration: TimeInterval { end.timeIntervalSince(start) }
    var isWork: Bool { kind == Phase.work.rawValue }
}

struct HourBucket: Identifiable {
    let hour: Int
    let workMinutes: Double
    let breakMinutes: Double
    var id: Int { hour }
    var totalMinutes: Double { workMinutes + breakMinutes }
}

struct DaySummary {
    var buckets: [HourBucket] = []
    var workMinutes: Double = 0
    var breakMinutes: Double = 0
    var completedFocusSessions: Int = 0
    var earlyBreaks: Int = 0

    var isEmpty: Bool { buckets.isEmpty }
    /// Share of logged time spent working. Nil when nothing was logged.
    var focusShare: Double? {
        let total = workMinutes + breakMinutes
        return total > 0 ? workMinutes / total : nil
    }
}

/// Append-only JSONL. One line per interval — cheap to write, trivially greppable,
/// and safe to accumulate for years.
enum SessionLog {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Pomodoro")
    static var fileURL: URL { dir.appendingPathComponent("sessions.jsonl") }

    /// Anything shorter than this is a mis-click, not a session.
    static let minimumDuration: TimeInterval = 5

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// `url` is a parameter purely so tests can round-trip through a temp file
    /// instead of the user's real log.
    static func append(_ record: SessionRecord, to url: URL = fileURL) {
        guard record.duration >= minimumDuration else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)   // newline

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    static func allRecords(from url: URL = fileURL) -> [SessionRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(SessionRecord.self, from: data)
        }
    }

    /// Days that have at least one record, most recent first — drives day navigation.
    static func loggedDays(calendar: Calendar = .current) -> [Date] {
        let days = Set(allRecords().map { calendar.startOfDay(for: $0.start) })
        return days.sorted(by: >)
    }

    static func summary(for day: Date, calendar: Calendar = .current) -> DaySummary {
        summarize(allRecords(), for: day, calendar: calendar)
    }

    /// Pure — no file access — so the hour-splitting arithmetic can be exercised
    /// directly without touching the real log.
    static func summarize(_ records: [SessionRecord], for day: Date,
                          calendar: Calendar = .current) -> DaySummary {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return DaySummary()
        }
        // Overlap test, not containment: a session running across midnight must
        // contribute its minutes to both days.
        let relevant = records.filter { $0.end > dayStart && $0.start < dayEnd }
        guard !relevant.isEmpty else { return DaySummary() }

        var work = [Double](repeating: 0, count: 24)
        var rest = [Double](repeating: 0, count: 24)

        for r in relevant {
            for h in 0..<24 {
                let hourStart = dayStart.addingTimeInterval(Double(h) * 3600)
                let hourEnd = hourStart.addingTimeInterval(3600)
                let overlap = min(r.end, hourEnd).timeIntervalSince(max(r.start, hourStart))
                guard overlap > 0 else { continue }
                if r.isWork { work[h] += overlap / 60 } else { rest[h] += overlap / 60 }
            }
        }

        var summary = DaySummary()
        summary.workMinutes = work.reduce(0, +)
        summary.breakMinutes = rest.reduce(0, +)
        summary.completedFocusSessions = relevant.filter { $0.isWork && $0.endedBy == .completed }.count
        summary.earlyBreaks = relevant.filter { $0.isWork && $0.endedBy == .early }.count

        // Keep the span contiguous from first to last active hour: the empty hours
        // in between are signal, not noise.
        let active = (0..<24).filter { work[$0] + rest[$0] > 0.05 }
        guard let first = active.first, let last = active.last else { return summary }
        summary.buckets = (first...last).map {
            HourBucket(hour: $0, workMinutes: work[$0], breakMinutes: rest[$0])
        }
        return summary
    }
}

enum Fmt {
    /// "1h 45m" / "45m" / "—"
    static func minutes(_ m: Double) -> String {
        let total = Int(m.rounded())
        guard total > 0 else { return "—" }
        return total >= 60 ? "\(total / 60)h \(total % 60)m" : "\(total)m"
    }

    static func hourLabel(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }
}
