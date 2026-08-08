import Foundation

/// The list you keep, and the dates fetched for it.
///
/// `~/deadlines/conferences.txt` is the only thing you edit, and it is plain
/// text for the same reason the notes are: it survives the app, it is greppable,
/// and adding a workshop is one line in any editor. Fetched dates land in a
/// cache beside it so the panel is right on the first frame and stays right on
/// a train.
@MainActor
final class Store {
    static let shared = Store()

    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("deadlines")
    static var list: URL { root.appendingPathComponent("conferences.txt") }
    static var cache: URL { root.appendingPathComponent(".cache.tsv") }

    private(set) var tracked: [String] = []
    private(set) var manual: [Deadline] = []
    private(set) var fetched: [Deadline] = []

    var all: [Deadline] { manual + fetched }

    func bootstrap() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: Self.list.path) {
            try? Self.starter.write(to: Self.list, atomically: true, encoding: .utf8)
        }
        reload()
        loadCache()
    }

    func reload() {
        let text = (try? String(contentsOf: Self.list, encoding: .utf8)) ?? ""
        let parsed = Self.parseList(text)
        tracked = parsed.tracked
        manual = parsed.manual
    }

    /// What the file means. Pure, so the format can be tested without a disk.
    static func parseList(_ text: String) -> (tracked: [String], manual: [Deadline]) {
        var tracked: [String] = []
        var manual: [Deadline] = []

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            guard line.contains("|") else {
                tracked.append(line)
                continue
            }
            // NAME | 2026-10-01 23:59 AoE | abstract
            let parts = line.split(separator: "|").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count >= 2 else { continue }
            let name = parts[0]
            let when = parts[1]
            let kind: Deadline.Kind = parts.count > 2 && parts[2].lowercased().hasPrefix("abs")
                ? .abstract : .paper

            // The zone is the last word; everything before it is the timestamp.
            let words = when.split(separator: " ").map(String.init)
            guard words.count >= 2 else { continue }
            let zone = words[words.count - 1]
            var stamp = words.dropLast().joined(separator: " ")
            if stamp.split(separator: " ").count == 1 { stamp += " 23:59:59" }
            guard let at = Zone.date(stamp, in: zone) else { continue }

            let year = Calendar(identifier: .gregorian).component(.year, from: at)
            manual.append(Deadline(conference: name, year: year, kind: kind, at: at, zone: zone))
        }
        return (tracked, manual)
    }

    // MARK: - Cache

    func loadCache() {
        guard let text = try? String(contentsOf: Self.cache, encoding: .utf8) else { return }
        fetched = Self.decode(text)
    }

    func store(_ deadlines: [Deadline]) {
        fetched = deadlines
        try? Self.encode(deadlines).write(to: Self.cache, atomically: true, encoding: .utf8)
    }

    /// Tab-separated, because the cache is something you might want to read
    /// when the panel says something surprising.
    static func encode(_ deadlines: [Deadline]) -> String {
        let iso = ISO8601DateFormatter()
        return deadlines.map {
            [$0.conference, "\($0.year)", $0.kind.rawValue, iso.string(from: $0.at),
             $0.zone, $0.place, $0.link].joined(separator: "\t")
        }.joined(separator: "\n") + "\n"
    }

    static func decode(_ text: String) -> [Deadline] {
        let iso = ISO8601DateFormatter()
        return text.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: "\t")
            guard f.count >= 5, let year = Int(f[1]),
                  let kind = Deadline.Kind(rawValue: f[2]),
                  let at = iso.date(from: f[3]) else { return nil }
            return Deadline(conference: f[0], year: year, kind: kind, at: at, zone: f[4],
                            place: f.count > 5 ? f[5] : "", link: f.count > 6 ? f[6] : "")
        }
    }

    static let starter = """
        # Conferences to count down to. One per line.
        #
        # A name on its own is looked up automatically — dates come from
        # ccfddl/ccf-deadlines, which is maintained by people who submit to
        # these venues, so a slipped deadline fixes itself.
        NeurIPS
        ICML
        ICLR
        COLM

        # Anything else, state yourself:
        #   Name | 2026-10-01 23:59 AoE | paper
        #   Some Workshop | 2026-11-14 23:59 UTC-8 | abstract
        #
        # The zone matters. AoE is UTC-12 — the last place on earth where it is
        # still that date — and is what most ML conferences mean.
        #
        # TMLR and JMLR are not here on purpose: they are rolling-submission
        # journals with no deadline, so there is nothing to count down to.

        """
}
