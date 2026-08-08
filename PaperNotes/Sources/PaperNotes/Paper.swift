import Foundation

/// Reuses the vocabulary already established in the existing summary rubric, so the
/// two systems speak the same language rather than inventing a second scale.
enum Verdict: String, CaseIterable, Codable {
    case unset, gold, solid, mixed, thin, garbage

    var label: String {
        switch self {
        case .unset: return "—"
        default: return rawValue.uppercased()
        }
    }
}

/// One paper, one markdown file. The file is the source of truth; this struct is a
/// view of it, so notes stay readable and greppable without the app.
///
/// The note body is edited as raw markdown rather than as separate fields — the
/// prompts survive as headings. That keeps LaTeX and markdown working anywhere in
/// the note, and matches how you'd write in any other editor.
struct Paper: Identifiable, Equatable {
    var arxivID: String              // "2510.23966" — also the identity for graph edges
    var title: String = ""
    var authors: [String] = []
    var year: Int?
    var venue: String = ""
    var readOn: Date?
    /// Yours. Never written by the app.
    var verdict: Verdict = .unset
    /// Claude's, written when the paper is added. Kept in a separate field rather
    /// than filling `verdict` in: overwriting your judgement with a machine's is the
    /// one thing a reading tool must not do, and once they are separate you can also
    /// see where you disagreed.
    var appraisal: Verdict = .unset
    var appraisalNote: String = ""
    /// 0–100, from the per-paper pass. Retained only as a tiebreaker for papers the
    /// ranking has not reached: measured across the library it clusters hard
    /// (p25 66, median 72, p75 74), so it cannot carry an ordering by itself.
    var appraisalScore: Int = -1
    /// Position in the last whole-library ranking, 1 = most interesting. This is the
    /// signal that actually orders the shelf; the band is derived from it.
    var appraisalRank: Int = -1
    /// Position in the reading queue, 1-based. -1 means not queued.
    ///
    /// An ordered position rather than a flag: "read these next" is a list, and
    /// once there is more than one paper in it the order is the whole point.
    var queuePosition: Int = -1
    var tags: [String] = []
    /// arXiv ids extracted from this paper's bibliography. The graph is built from
    /// these, because the free APIs have no reference lists for recent preprints.
    var refs: [String] = []
    /// Everything below the frontmatter, verbatim.
    var body: String = Paper.template
    /// Set when the note came from a PDF, so it can be reopened for reading.
    var pdfPath: String = ""
    /// Times cited, from OpenAlex. Drives node size in the graph, the way
    /// Connected Papers sizes by citation count.
    var citations: Int = 0
    /// Thumbs-up. Starred papers count for more when ranking recommendations, so
    /// "more like this" has something concrete to work from.
    var starred: Bool = false

    var id: String { arxivID }

    var isQueued: Bool { queuePosition > 0 }

    /// What the badge shows. Yours wins whenever you have one; otherwise Claude's
    /// stands in, which is the whole point — the shelf is labelled without you
    /// having to label it.
    var effectiveVerdict: Verdict { verdict != .unset ? verdict : appraisal }

    /// True once you have disagreed with the appraisal in writing. Worth surfacing:
    /// the papers where your read diverges from a first-pass machine read are the
    /// ones you actually thought about.
    var overridesAppraisal: Bool {
        verdict != .unset && appraisal != .unset && verdict != appraisal
    }

    /// Prompts chosen because a summary structurally cannot answer them for you.
    static let template = """
    ## Claim, in my words

    <!-- The argument as you'd tell a colleague — not the abstract. -->

    ## Evidence — what convinced me, or didn't

    <!-- Which result carries the claim? Sample size, baselines, seeds. -->

    ## This would be wrong if

    <!-- The assumption the whole thing rests on. -->

    ## What I didn't understand

    <!-- The most useful field here. Confusion is where the next paper comes from. -->

    ## Connections

    """

    var slug: String {
        let base = title.isEmpty ? arxivID : title
        let stripped = base.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9 ]"#, with: "", options: .regularExpression)
        let words: [Substring] = stripped.split(separator: " ").prefix(6).map { $0 }
        let joined = words.joined(separator: "-")
        return joined.isEmpty ? arxivID : "\(arxivID)--\(joined)"
    }

    var filename: String { "\(slug).md" }

    /// A note counts as written only once there is prose that isn't scaffolding.
    var isSubstantive: Bool {
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("<!--") { continue }
            return true
        }
        return false
    }

    /// Text under a heading, for search and for showing a preview in the list.
    func section(_ headingPrefix: String) -> String {
        let lines = body.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.hasPrefix("## ") && $0.dropFirst(3).hasPrefix(headingPrefix)
        }) else { return "" }
        var collected: [String] = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix("## ") { break }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("<!--") { continue }
            collected.append(line)
        }
        return collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var confusions: String { section("What I didn't understand") }

    /// The note with its scaffolding removed — headings and the template's own
    /// comment prompts are furniture, not your writing. Searching the raw body
    /// means every paper in the library matches "as you'd tell a colleague".
    var prose: String {
        body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("<!--") }
            .joined(separator: "\n")
    }

    /// What you asked yourself while reading, for the grader to answer.
    ///
    /// The whole "What I didn't understand" section counts, punctuation or not —
    /// that heading exists to collect confusion, and "no idea why the proxy
    /// correlates" is a question with a full stop on it. Anything ending in a
    /// question mark elsewhere in the note counts too, since the good questions
    /// tend to arrive while writing about something else.
    struct Questions: Equatable {
        var confusionSection = ""
        var elsewhere: [String] = []
        var isEmpty: Bool { confusionSection.isEmpty && elsewhere.isEmpty }

        /// How many things were actually asked. The confusion section is one field
        /// but usually several questions, so counting it as one under-reports what
        /// the grader is about to answer.
        var count: Int {
            confusionSection.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
                + elsewhere.count
        }
    }

    var questions: Questions {
        let confusion = confusions
        let inConfusion = Set(confusion.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) })
        var elsewhere: [String] = []
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasSuffix("?") else { continue }
            // Headings and the template's own comment prompts are not your questions.
            guard !line.hasPrefix("#"), !line.hasPrefix("<!--"), !inConfusion.contains(line)
            else { continue }
            elsewhere.append(line)
        }
        return Questions(confusionSection: confusion, elsewhere: elsewhere)
    }
}

// MARK: - Markdown round-trip

extension Paper {
    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    var markdown: String {
        var out = "---\n"
        out += "arxiv: \(arxivID)\n"
        out += "title: \(Self.escape(title))\n"
        if !authors.isEmpty { out += "authors: \(authors.joined(separator: "; "))\n" }
        if let year { out += "year: \(year)\n" }
        if !venue.isEmpty { out += "venue: \(Self.escape(venue))\n" }
        if let readOn { out += "read: \(Self.iso.string(from: readOn))\n" }
        if verdict != .unset { out += "verdict: \(verdict.rawValue)\n" }
        if appraisal != .unset { out += "appraisal: \(appraisal.rawValue)\n" }
        if !appraisalNote.isEmpty { out += "appraisal_note: \(Self.escape(appraisalNote))\n" }
        if appraisalScore >= 0 { out += "appraisal_score: \(appraisalScore)\n" }
        if appraisalRank > 0 { out += "appraisal_rank: \(appraisalRank)\n" }
        if !tags.isEmpty { out += "tags: \(tags.joined(separator: ", "))\n" }
        if !refs.isEmpty { out += "refs: \(refs.joined(separator: ", "))\n" }
        if !pdfPath.isEmpty { out += "pdf: \(pdfPath)\n" }
        if citations > 0 { out += "cited: \(citations)\n" }
        if starred { out += "starred: true\n" }
        if queuePosition > 0 { out += "queue: \(queuePosition)\n" }
        out += "---\n\n"
        out += body.hasSuffix("\n") ? body : body + "\n"
        return out
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
    }

    /// Parses our own dialect rather than general YAML — the format is ours, so a
    /// full parser would be a dependency bought for nothing.
    init?(markdown text: String) {
        guard text.hasPrefix("---") else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard let close = lines.dropFirst().firstIndex(of: "---") else { return nil }

        var front: [String: String] = [:]
        for line in lines[1..<close] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { front[key] = value }
        }
        guard let id = front["arxiv"], !id.isEmpty else { return nil }

        self.arxivID = id
        self.title = front["title"] ?? ""
        self.authors = Self.list(front["authors"], separator: ";")
        self.year = front["year"].flatMap(Int.init)
        self.venue = front["venue"] ?? ""
        self.readOn = front["read"].flatMap { Self.iso.date(from: $0) }
        self.verdict = Verdict(rawValue: front["verdict"] ?? "") ?? .unset
        self.appraisal = Verdict(rawValue: front["appraisal"] ?? "") ?? .unset
        self.appraisalNote = front["appraisal_note"] ?? ""
        self.appraisalScore = front["appraisal_score"].flatMap(Int.init) ?? -1
        self.appraisalRank = front["appraisal_rank"].flatMap(Int.init) ?? -1
        self.tags = Self.list(front["tags"], separator: ",")
        self.refs = Self.list(front["refs"], separator: ",")
        self.pdfPath = front["pdf"] ?? ""
        self.citations = front["cited"].flatMap(Int.init) ?? 0
        self.starred = (front["starred"] ?? "") == "true"
        self.queuePosition = front["queue"].flatMap(Int.init) ?? -1
        self.body = lines[(close + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    private static func list(_ raw: String?, separator: Character) -> [String] {
        (raw ?? "").split(separator: separator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
