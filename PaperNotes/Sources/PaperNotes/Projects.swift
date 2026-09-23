import Foundation

/// The colours a project can be. A fixed palette rather than a picker, for the
/// same reason Jot has six paper colours: a colour is only a usable index while
/// there are few enough to tell apart at seven points across a sidebar.
enum ProjectColour: String, CaseIterable, Codable {
    case red, orange, yellow, green, teal, blue, purple, pink

    /// Chip fill, and the ink that stays readable on it. Explicit per colour —
    /// a computed contrast goes wrong on exactly the mid-tones a palette picks.
    var fill: UInt32 {
        switch self {
        case .red:    return 0xD64545
        case .orange: return 0xE07A1F
        case .yellow: return 0xE3B505
        case .green:  return 0x3E9B4F
        case .teal:   return 0x2A9D8F
        case .blue:   return 0x2A78D6
        case .purple: return 0x7C5CD6
        case .pink:   return 0xD65C9B
        }
    }

    var ink: UInt32 { self == .yellow ? 0x2B2500 : 0xFFFFFF }
}

/// One project: a name and its colour. The name is the identity — it is what a
/// paper's frontmatter carries, so renaming a project in the file orphans its
/// papers' tags (they keep the old name, shown in grey until it exists again).
struct Project: Identifiable, Equatable {
    var name: String
    var colour: ProjectColour
    var id: String { name }
}

/// The project registry: plain text in the notes repo, one line per project,
/// versioned with the notes and editable without the app — the same deal as
/// `trusted-authors.txt`. Papers point at projects by name in their own
/// frontmatter; this file only says which colour each name gets.
enum Projects {
    static var fileURL: URL { Library.root.appendingPathComponent("projects.txt") }

    static let header = """
    # Projects — one per line, "<colour> <name>".
    # Colours: red orange yellow green teal blue purple pink
    # A line without a colour word is still a project; it gets the least-used
    # colour when the app loads it. Papers reference these by name in their
    # frontmatter ("project: …"), so renaming a line orphans its papers' tags.
    """

    static func load() -> [Project] {
        parse((try? String(contentsOf: fileURL, encoding: .utf8)) ?? "")
    }

    static func save(_ projects: [Project]) {
        try? serialise(projects).write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// First word a palette colour → that colour, rest is the name. Anything
    /// else is a hand-written line: the whole of it is the name, and it gets a
    /// colour rather than being refused — a registry that drops entries over a
    /// missing colour word would lose the projects it exists to keep.
    static func parse(_ raw: String) -> [Project] {
        var out: [Project] = []
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let first = trimmed.prefix { !$0.isWhitespace }
            var name = trimmed
            var colour: ProjectColour?
            if let c = ProjectColour(rawValue: first.lowercased()) {
                let rest = trimmed.dropFirst(first.count)
                    .trimmingCharacters(in: .whitespaces)
                // "red" alone is a project named red, not a colour with no name.
                if !rest.isEmpty { colour = c; name = rest }
            }
            guard !out.contains(where: { $0.name.lowercased() == name.lowercased() })
            else { continue }
            out.append(Project(name: name, colour: colour ?? nextColour(out)))
        }
        return out
    }

    static func serialise(_ projects: [Project]) -> String {
        header + "\n\n"
            + projects.map { "\($0.colour.rawValue) \($0.name)" }.joined(separator: "\n")
            + (projects.isEmpty ? "" : "\n")
    }

    /// The sidebar filter. `nil` shows everything; a name shows that project's
    /// papers, case-insensitively — the same rule the registry uses for
    /// duplicate names. `""` therefore matches exactly the untagged papers,
    /// which is what the "No project" choice passes.
    static func papers(_ papers: [Paper], matching filter: String?) -> [Paper] {
        guard let filter else { return papers }
        return papers.filter {
            $0.project.compare(filter, options: .caseInsensitive) == .orderedSame
        }
    }

    /// The least-used colour, ties broken by palette order — so eight projects
    /// get eight different colours before any repeats.
    static func nextColour(_ existing: [Project]) -> ProjectColour {
        var counts: [ProjectColour: Int] = [:]
        for p in existing { counts[p.colour, default: 0] += 1 }
        return ProjectColour.allCases.min {
            (counts[$0] ?? 0, index($0)) < (counts[$1] ?? 0, index($1))
        } ?? .red
    }

    private static func index(_ c: ProjectColour) -> Int {
        ProjectColour.allCases.firstIndex(of: c) ?? 0
    }
}
