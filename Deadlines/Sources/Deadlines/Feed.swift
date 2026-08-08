import Foundation

/// Where the dates come from.
///
/// `ccfddl/ccf-deadlines` is maintained by people who actually submit to these
/// venues, which is worth more than any date I could hard-code: conference
/// deadlines slip, and a widget confidently counting down to a date that moved
/// last week is worse than no widget. The fetched dates are cached to disk, so
/// the panel is correct offline and on the first frame after launch.
///
/// The file it serves is YAML, and this parses only the handful of keys it
/// needs rather than taking on a YAML library. That is a deliberate trade: the
/// shape is regular and machine-generated, and the parser is tested against a
/// real sample so a change in the source shows up as a failing test rather than
/// as a blank panel.
enum Feed {
    /// Slugs in the source's AI directory, by the name people use.
    static let known: [String: String] = [
        "neurips": "nips", "nips": "nips",
        "icml": "icml",
        "iclr": "iclr",
        "colm": "colm",
        "aaai": "aaai", "ijcai": "ijcai", "aistats": "aistats",
        "acl": "acl", "emnlp": "emnlp", "naacl": "naacl",
        "cvpr": "cvpr", "iccv": "iccv", "eccv": "eccv",
    ]

    static func url(forSlug slug: String) -> URL? {
        URL(string: "https://raw.githubusercontent.com/ccfddl/ccf-deadlines/main/conference/AI/\(slug).yml")
    }

    /// Pulls every tracked conference, keeping whatever succeeds.
    ///
    /// One venue failing must not empty the panel, so failures are dropped and
    /// the cache keeps yesterday's answer for them.
    static func fetch(_ conferences: [String]) async -> [Deadline] {
        var out: [Deadline] = []
        for name in conferences {
            guard let slug = known[name.lowercased()], let url = url(forSlug: slug) else { continue }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8) else { continue }
            out.append(contentsOf: parse(text))
        }
        return out
    }

    /// The subset of the format that matters: a title, then a list of years,
    /// each with a timezone and one or more timeline entries.
    static func parse(_ yaml: String) -> [Deadline] {
        var out: [Deadline] = []
        var title = ""

        // Per year block.
        var year: Int?
        var zone = ""
        var place = ""
        var link = ""
        var stamps: [(Deadline.Kind, String)] = []

        func flush() {
            guard let year, !zone.isEmpty, !title.isEmpty else { return }
            for (kind, stamp) in stamps {
                guard let at = Zone.date(stamp, in: zone) else { continue }
                out.append(Deadline(conference: title, year: year, kind: kind, at: at,
                                    zone: zone, place: place, link: link))
            }
        }

        for raw in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("- title:") {
                flush()
                year = nil; zone = ""; place = ""; link = ""; stamps = []
                title = value(after: "- title:", in: trimmed)
                continue
            }
            if trimmed.hasPrefix("- year:") {
                flush()
                zone = ""; place = ""; link = ""; stamps = []
                year = Int(value(after: "- year:", in: trimmed))
                continue
            }
            if trimmed.hasPrefix("timezone:") { zone = value(after: "timezone:", in: trimmed) }
            else if trimmed.hasPrefix("place:") { place = value(after: "place:", in: trimmed) }
            else if trimmed.hasPrefix("link:") && link.isEmpty { link = value(after: "link:", in: trimmed) }
            else if trimmed.hasPrefix("- abstract_deadline:") {
                stamps.append((.abstract, value(after: "- abstract_deadline:", in: trimmed)))
            } else if trimmed.hasPrefix("abstract_deadline:") {
                stamps.append((.abstract, value(after: "abstract_deadline:", in: trimmed)))
            } else if trimmed.hasPrefix("- deadline:") {
                stamps.append((.paper, value(after: "- deadline:", in: trimmed)))
            } else if trimmed.hasPrefix("deadline:") {
                stamps.append((.paper, value(after: "deadline:", in: trimmed)))
            }
        }
        flush()
        return out
    }

    private static func value(after key: String, in line: String) -> String {
        var text = String(line.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("'"), text.hasSuffix("'"), text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }
}
