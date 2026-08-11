import Foundation

/// One thing worth understanding, and what it rests on.
///
/// A markdown file with frontmatter, the same shape the other apps use: the file
/// is the truth, so the curriculum is greppable, editable in any editor, and
/// outlives this app. What makes it a curriculum rather than a glossary is
/// `requires` — the concepts that have to make sense before this one can.
struct Concept: Identifiable, Equatable {
    enum Status: String, CaseIterable {
        /// Not looked at. Most of the graph, most of the time.
        case unread
        /// Started, not yet solid. Comes back around.
        case learning
        /// Understood well enough to build on.
        case known

        var label: String {
            switch self {
            case .unread: return "Not started"
            case .learning: return "Learning"
            case .known: return "Known"
            }
        }
    }

    /// Broad area, so a day's session can be steered rather than random.
    enum Area: String, CaseIterable {
        case hardware, systems, training, architecture, theory, safety, evaluation, tooling

        var label: String { rawValue.capitalized }
    }

    var id: String
    var title: String
    var area: Area = .systems
    var status: Status = .unread
    /// Concept ids this rests on. The edges of the graph.
    var requires: [String] = []
    /// Why this matters for someone doing empirical LLM safety work — the
    /// sentence that decides whether it earns a morning.
    var relevance: String = ""
    /// Written when the concept is first seen, so "what have I learned lately"
    /// is answerable.
    var addedOn: Date = Date()
    var learnedOn: Date?
    /// Anything time-sensitive — a release, a new architecture — so the daily
    /// pick can favour it while it is still news.
    var dated: Date?
    /// Courses whose syllabus covers this. Recorded because "MIT 6.5940 and
    /// CMU 15-418 both teach it" is a real signal about what is canonical
    /// and what is one department's taste.
    var courses: [String] = []
    var sources: [Source] = []
    var body: String = ""

    /// The same concept, unfolded from nothing.
    ///
    /// The entry is written as a reference for someone who already has the
    /// area — "a CUDA kernel launch creates a grid of thread blocks" assumes
    /// kernel, grid and block. This is the version that assumes none of it and
    /// still keeps every number, mechanism and citation: not a simpler claim,
    /// the same claim with the steps put back in.
    var walkthrough: String = ""

    struct Source: Equatable {
        var title: String
        var url: String
        /// Whether the link was found to resolve. A citation that 404s is not a
        /// citation, and the whole point of this app is that claims are checkable.
        var reachable: Bool?
    }

    var isKnown: Bool { status == .known }

    /// Substantive once there is prose that is not scaffolding.
    var isWritten: Bool {
        body.components(separatedBy: "\n").contains {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return !line.isEmpty && !line.hasPrefix("#") && !line.hasPrefix("<!--")
        }
    }
}

// MARK: - File round-trip

extension Concept {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    var filename: String { "\(id).md" }

    var markdown: String {
        var out = "---\n"
        out += "id: \(id)\n"
        out += "title: \(Self.escape(title))\n"
        out += "area: \(area.rawValue)\n"
        out += "status: \(status.rawValue)\n"
        if !requires.isEmpty { out += "requires: \(requires.joined(separator: ", "))\n" }
        if !relevance.isEmpty { out += "relevance: \(Self.escape(relevance))\n" }
        if !courses.isEmpty { out += "courses: \(courses.joined(separator: "; "))\n" }
        out += "added: \(Self.iso.string(from: addedOn))\n"
        if let learnedOn { out += "learned: \(Self.iso.string(from: learnedOn))\n" }
        if let dated { out += "dated: \(Self.iso.string(from: dated))\n" }
        for s in sources {
            // Pipe-separated: a URL cannot contain an unescaped pipe, and a title
            // that does is not worth a parser.
            // All three states are written. Recording only failures meant a
            // link that had been checked and found good read back as unchecked,
            // so the app reported "0 sources verified" about seven verified
            // sources — and would have re-checked them all on every launch.
            let mark: String
            switch s.reachable {
            case true: mark = " | ok"
            case false: mark = " | unreachable"
            case nil: mark = ""
            }
            out += "source: \(Self.escape(s.title)) | \(s.url)\(mark)\n"
        }
        out += "---\n\n"
        out += body.hasSuffix("\n") ? body : body + "\n"
        if !walkthrough.isEmpty {
            // One file per concept still. A separate file would drift out of
            // step with its entry the first time one was edited by hand.
            out += "\n" + Self.walkthroughMarker + "\n\n" + walkthrough + "\n"
        }
        return out
    }

    static let walkthroughMarker = "<!-- walkthrough -->"

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
    }

    /// Parses our own dialect. `source:` may appear many times, so the generic
    /// key-value pass cannot own it.
    init?(markdown text: String) {
        guard text.hasPrefix("---") else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard let close = lines.dropFirst().firstIndex(of: "---") else { return nil }

        var front: [String: String] = [:]
        var sources: [Source] = []
        for line in lines[1..<close] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if key == "source" {
                let parts = value.components(separatedBy: "|").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard parts.count >= 2 else { continue }
                let state: Bool? = parts.count > 2
                    ? (parts[2] == "ok" ? true : (parts[2] == "unreachable" ? false : nil))
                    : nil
                sources.append(Source(title: parts[0], url: parts[1], reachable: state))
            } else if !key.isEmpty {
                front[key] = value
            }
        }
        guard let id = front["id"], !id.isEmpty else { return nil }

        self.id = id
        self.title = front["title"] ?? id
        self.area = Area(rawValue: front["area"] ?? "") ?? .systems
        self.status = Status(rawValue: front["status"] ?? "") ?? .unread
        self.requires = (front["requires"] ?? "")
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        self.relevance = front["relevance"] ?? ""
        self.courses = (front["courses"] ?? "").components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        self.addedOn = front["added"].flatMap { Self.iso.date(from: $0) } ?? Date()
        self.learnedOn = front["learned"].flatMap { Self.iso.date(from: $0) }
        self.dated = front["dated"].flatMap { Self.iso.date(from: $0) }
        self.sources = sources
        let rest = lines[(close + 1)...].joined(separator: "\n")
        if let split = rest.range(of: Self.walkthroughMarker) {
            self.body = String(rest[..<split.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.walkthrough = String(rest[split.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            self.body = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            self.walkthrough = ""
        }
    }

    /// LaTeX flattened to readable text, for the places that cannot typeset it.
    ///
    /// A sidebar row and a graph label are drawn by AppKit, not by KaTeX, so
    /// "$S \\le 1/(s + (1-s)/p)$" arrives there as literal dollar signs and
    /// backslashes. The reading pane typesets properly; this is what the rest of
    /// the app shows instead, and it is a fallback, not a renderer.
    static func plain(_ text: String) -> String {
        var out = text
        let symbols = ["\\times": "×", "\\approx": "≈", "\\le": "≤", "\\ge": "≥",
                       "\\neq": "≠", "\\cdot": "·", "\\sim": "~", "\\to": "→",
                       "\\alpha": "α", "\\beta": "β", "\\eta": "η", "\\theta": "θ",
                       "\\lambda": "λ", "\\mu": "μ", "\\sigma": "σ", "\\Delta": "Δ",
                       "\\nabla": "∇", "\\top": "ᵀ", "\\tfrac12": "½", "\\frac12": "½",
                       "\\ll": "≪", "\\gg": "≫", "\\infty": "∞", "\\propto": "∝"]
        for (tex, symbol) in symbols { out = out.replacingOccurrences(of: tex, with: symbol) }
        out = out.replacingOccurrences(of: "$$", with: "")
        out = out.replacingOccurrences(of: "$", with: "")
        // Anything left is a command this does not know; drop the backslash
        // rather than showing it, and keep the word.
        out = out.replacingOccurrences(of: "\\\\[a-zA-Z]+", with: "",
                                       options: .regularExpression)
        out = out.replacingOccurrences(of: "[{}]", with: "", options: .regularExpression)
        return out.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }

    var plainTitle: String { Self.plain(title) }

    /// What fits under a node. These titles are written to be informative in a
    /// list — "GPU Execution Model: SMs, Warps, Occupancy, Tensor Cores" — and
    /// at that length forty of them on one canvas is a wall of text with a graph
    /// hidden behind it. The part before the colon is the name of the thing.
    var shortTitle: String {
        let head = plainTitle.components(separatedBy: ":")[0]
            .trimmingCharacters(in: .whitespaces)
        return head.count > 26 ? String(head.prefix(25)) + "…" : head
    }
    var plainRelevance: String { Self.plain(relevance) }

    /// `Paged Attention` → `paged-attention`. The id is the filename and the
    /// edge label, so it has to be stable and typeable.
    static func slug(_ title: String) -> String {
        let lower = title.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
        return lower.split(separator: " ").prefix(6).joined(separator: "-")
    }
}
