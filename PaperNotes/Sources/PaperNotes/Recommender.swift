import Foundation

/// What to read next, derived from the graph.
///
/// The obvious direction — "papers that cite yours" — does not work for this library:
/// only 7 of 66 papers have any citations at all, because they are mostly 2025–2026
/// preprints. Measured, not assumed.
///
/// The useful direction is the reverse. Your papers' bibliographies contain 923
/// distinct works you have *not* read, and how many of your papers cite a given one
/// is a strong signal: something 25 of them cite is foundational to what you work on.
/// It also needs no API call to generate candidates — the references are already
/// extracted.
enum Recommender {
    /// Where a suggestion came from. The two sources answer different questions —
    /// "what does my library keep pointing at" and "what have the people I follow
    /// published lately" — and the second reaches papers the first cannot see,
    /// because nothing in the library is new enough to cite them yet.
    enum Source: Equatable {
        case cited
        case author(String)
        /// Semantic Scholar, seeded from the papers you rated highest.
        case similar
        /// Posted to arXiv in the last few weeks, scored against your library's
        /// own vocabulary. The only source that can reach a paper from this week.
        case fresh

        var label: String {
            switch self {
            case .cited: return "cited by your library"
            case .author(let name): return name
            case .similar: return "like the papers you rated highest"
            case .fresh: return "new on arXiv"
            }
        }
    }

    struct Candidate {
        let arxivID: String
        /// How many library papers cite it, weighted — starred papers count treble.
        var weight: Double
        var citedByYours: [String] = []
        var source: Source = .cited
        var title: String = ""
        var authors: [String] = []
        var year: Int?
        var citations: Int = 0
        /// Filled in by the judge, when one is run.
        var verdict: String = ""
        var reason: String = ""
        var published: Date?
        var abstract: String = ""

        /// Days since it was posted, or nil when the date is unknown.
        var ageInDays: Int? {
            published.map { Int(Date().timeIntervalSince($0) / 86_400) }
        }

        var ageLabel: String {
            guard let d = ageInDays else { return "" }
            switch d {
            case ..<2: return "today"
            case ..<8: return "\(d) days ago"
            case ..<31: return "\(d / 7) week\(d / 7 == 1 ? "" : "s") ago"
            case ..<365: return "\(d / 30) month\(d / 30 == 1 ? "" : "s") ago"
            default: return "\(d / 365) year\(d / 365 == 1 ? "" : "s") ago"
            }
        }
    }

    /// How much a paper's age discounts it.
    ///
    /// Steep by request: a paper from this week on a topic beats one from last
    /// year on the same topic, because by the time a paper is a year old it has
    /// usually reached you some other way. Not a hard cutoff — a genuinely
    /// foundational paper you have never read is still worth surfacing, it just
    /// has to be much more relevant to outrank something current.
    static func recencyWeight(_ published: Date?) -> Double {
        guard let published else { return 0.30 }   // unknown date: mid discount
        let days = Date().timeIntervalSince(published) / 86_400
        switch days {
        case ..<8: return 1.00
        case ..<31: return 0.85
        case ..<91: return 0.50
        case ..<183: return 0.25
        case ..<366: return 0.12
        default: return 0.05
        }
    }

    /// Starred papers count for more, which is the whole point of the thumbs-up.
    static let starWeight = 3.0

    /// Recent work by the people you follow, minus anything you already have or
    /// have waved away. Newest first — the point of following someone is to hear
    /// about what they did *this year*.
    static func authorCandidates(from library: [Paper],
                                 found: [(name: String, papers: [TrustedAuthors.Paper])],
                                 since months: Int = 24) -> [Candidate] {
        let known = Set(library.map { PDFRefs.normalise($0.arxivID) })
        let skip = TrustedAuthors.dismissed()
        let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: Date())
            ?? .distantPast

        var seen = Set<String>()
        var out: [Candidate] = []
        for (name, papers) in found {
            for paper in papers {
                let id = PDFRefs.normalise(paper.arxivID)
                guard !known.contains(id), !skip.contains(id), !seen.contains(id) else { continue }
                guard (paper.published ?? .distantPast) >= cutoff else { continue }
                seen.insert(id)
                // Recency is the weight here, not citation count: a paper from this
                // month has had no chance to be cited by anything.
                let age = Date().timeIntervalSince(paper.published ?? .distantPast)
                out.append(Candidate(arxivID: id,
                                     weight: max(0, 24 - age / (30 * 86_400)),
                                     source: .author(name),
                                     title: paper.title,
                                     authors: paper.authors,
                                     year: paper.year))
            }
        }
        return out.sorted { $0.weight > $1.weight }
    }

    static func candidates(from library: [Paper], minimumCiting: Int = 3) -> [Candidate] {
        let known = Set(library.map { PDFRefs.normalise($0.arxivID) })
        let dismissed = TrustedAuthors.dismissed()
        var weight: [String: Double] = [:]
        var sources: [String: [String]] = [:]

        for paper in library {
            let w = paper.starred ? starWeight : 1.0
            for raw in paper.refs {
                let ref = PDFRefs.normalise(raw)
                guard !known.contains(ref) else { continue }   // already read
                weight[ref, default: 0] += w
                sources[ref, default: []].append(paper.arxivID)
            }
        }

        return weight
            .filter { $0.value >= Double(minimumCiting) && !dismissed.contains($0.key) }
            .map { Candidate(arxivID: $0.key, weight: $0.value,
                             citedByYours: sources[$0.key] ?? []) }
            .sorted { $0.weight == $1.weight ? $0.arxivID < $1.arxivID : $0.weight > $1.weight }
    }

    /// Papers Semantic Scholar thinks are like the ones you rated highest.
    static func similarCandidates(from library: [Paper], found: [FeedPaper]) -> [Candidate] {
        let known = Set(library.map { PDFRefs.normalise($0.arxivID) })
        let skip = TrustedAuthors.dismissed()
        var seen = Set<String>()
        return found.compactMap { p in
            let id = PDFRefs.normalise(p.arxivID)
            guard !id.isEmpty, !known.contains(id), !skip.contains(id),
                  seen.insert(id).inserted else { return nil }
            return Candidate(arxivID: id, weight: 1.0, source: .similar,
                             title: p.title, authors: p.authors,
                             year: p.published.map { Calendar.current.component(.year, from: $0) },
                             citations: p.citations,
                             published: p.published, abstract: p.abstract)
        }
    }

    /// Brand-new arXiv papers, scored against the library's own vocabulary.
    ///
    /// A week of cs.LG is several hundred papers and the judge costs a minute
    /// each, so the shortlist has to happen locally. `minimumScore` is a floor,
    /// not a quota: a quiet week should return few papers rather than pad the
    /// list with whatever scored least badly.
    static func freshCandidates(from library: [Paper], found: [FeedPaper],
                                vocabulary: Vocabulary,
                                minimumScore: Double = 0.10,
                                limit: Int = 25) -> [Candidate] {
        let known = Set(library.map { PDFRefs.normalise($0.arxivID) })
        let skip = TrustedAuthors.dismissed()
        var seen = Set<String>()
        var scored: [(Double, Candidate)] = []
        for p in found {
            let id = PDFRefs.normalise(p.arxivID)
            guard !id.isEmpty, !known.contains(id), !skip.contains(id),
                  seen.insert(id).inserted else { continue }
            let score = vocabulary.score(title: p.title, abstract: p.abstract)
            guard score >= minimumScore else { continue }
            scored.append((score, Candidate(
                arxivID: id, weight: score, source: .fresh,
                title: p.title, authors: p.authors,
                year: p.published.map { Calendar.current.component(.year, from: $0) },
                published: p.published, abstract: p.abstract)))
        }
        return scored.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
    }

    /// Merges the sources into one list.
    ///
    /// Each source gets a guaranteed share rather than competing on one score:
    /// they answer different questions, and a single ranking always lets the
    /// loudest one crowd the others out. Within a source, ordering is relevance
    /// times recency — which is where the preference for this week's papers
    /// actually bites.
    static func merge(_ groups: [(Source, [Candidate])], limit: Int) -> [Candidate] {
        // Newest-first sources get the larger shares; `cited` is structurally
        // backward-looking and is capped so foundational gaps stay visible
        // without filling the list with 2024.
        func share(_ s: Source) -> Double {
            switch s {
            case .fresh: return 0.34
            case .similar: return 0.30
            case .author: return 0.22
            case .cited: return 0.14
            }
        }
        var taken = Set<String>()
        var out: [Candidate] = []
        for (source, candidates) in groups {
            let ranked = candidates
                .filter { !taken.contains($0.arxivID) }
                .sorted { l, r in
                    let ls = l.weight * recencyWeight(l.published)
                    let rs = r.weight * recencyWeight(r.published)
                    return ls == rs ? l.arxivID > r.arxivID : ls > rs
                }
            let quota = max(1, Int((Double(limit) * share(source)).rounded()))
            for c in ranked.prefix(quota) {
                taken.insert(c.arxivID)
                out.append(c)
            }
        }
        // Any shortfall — a quiet week, no trusted authors — is backfilled from
        // whatever is left rather than returning a short list.
        if out.count < limit {
            let rest = groups.flatMap(\.1)
                .filter { !taken.contains($0.arxivID) }
                .sorted { $0.weight * recencyWeight($0.published)
                        > $1.weight * recencyWeight($1.published) }
            for c in rest where out.count < limit {
                guard taken.insert(c.arxivID).inserted else { continue }
                out.append(c)
            }
        }
        // Final ordering: freshest first within the chosen set, so the top of
        // the list is what came out this week.
        return out.sorted {
            ($0.published ?? .distantPast) > ($1.published ?? .distantPast)
        }
    }

    /// The prompt deliberately asks whether the paper is worth *this reader's* time
    /// given what they already have, not whether it is a good paper in the abstract —
    /// a canonical paper already covered by the library is not a useful suggestion.
    static func judgePrompt(_ c: Candidate, library: [Paper]) -> String {
        let starred = library.filter(\.starred).prefix(12).map { "- \($0.title)" }
        let recent = library.filter { !$0.starred }.prefix(18).map { "- \($0.title)" }
        // Second person throughout: the reply is shown to the reader verbatim, and
        // a verdict written about them in the third person reads like a report card
        // someone else filed.
        return """
        You are advising an ML PhD student — the reader — on whether to read a
        specific paper. Address them as "you".

        Your library already contains these papers:
        \(recent.joined(separator: "\n"))

        \(starred.isEmpty ? "" : "You have explicitly starred these as especially relevant:\n" + starred.joined(separator: "\n"))

        Candidate paper: arXiv:\(c.arxivID)
        Title: \(c.title.isEmpty ? "(unknown)" : c.title)
        Authors: \(c.authors.prefix(4).joined(separator: ", "))
        Year: \(c.year.map(String.init) ?? "unknown")
        \(sourceLine(c))
        \(c.ageLabel.isEmpty ? "" : "Posted \(c.ageLabel).")
        \(c.abstract.isEmpty ? "" : "Abstract: \(c.abstract.prefix(1200))")

        You strongly prefer recent work. A paper from the last few weeks on a
        topic beats an older one on the same topic — by the time a paper is a
        year old it has usually reached you some other way. Say so plainly if a
        suggestion is good but stale.

        Answer in exactly two lines, no preamble:
        VERDICT: one of ESSENTIAL, USEFUL, MARGINAL, SKIP
        WHY: one sentence, max 25 words, concrete about what it adds beyond what
        you already have. If it is redundant with your library, say so. Do not
        qualify the verdict label itself; put any caveat in this line.
        """
    }

    /// Why this paper is being suggested, phrased so the judge does not read a
    /// missing citation count as evidence against a paper posted last week.
    private static func sourceLine(_ c: Candidate) -> String {
        switch c.source {
        case .cited:
            return "Cited by \(c.citedByYours.count) papers already in your library."
        case .author(let name):
            return "Suggested because you follow \(name). Nothing in your library cites "
                + "it yet — expected for new work, and not evidence against it."
        case .similar:
            return "Suggested because it is close to the papers you rated most "
                + "interesting. Judge whether it actually adds to them or merely "
                + "resembles them."
        case .fresh:
            return "Posted to arXiv recently and matched your library's own "
                + "vocabulary. Nothing has cited it yet because it is new; judge it "
                + "on the idea alone."
        }
    }

    static func parseVerdict(_ reply: String) -> (verdict: String, reason: String) {
        var verdict = "", reason = ""
        for line in reply.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.uppercased().hasPrefix("VERDICT:") {
                verdict = t.dropFirst(8).trimmingCharacters(in: .whitespaces).uppercased()
            } else if t.uppercased().hasPrefix("WHY:") {
                reason = String(t.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            }
        }
        // Judges sometimes qualify the label — "ESSENTIAL (PROVISIONAL)" came back
        // from a run where the judge could not verify the paper itself. Snap it back
        // onto the scale so ranking and colour still work, and keep the qualifier
        // where it belongs, in the reason.
        if !verdict.isEmpty, ranking[verdict] == nil,
           let known = ranking.keys.first(where: { verdict.hasPrefix($0) }) {
            reason = reason.isEmpty ? verdict : "\(verdict) — \(reason)"
            verdict = known
        }
        // A judge that ignores the format shouldn't silently produce a blank row.
        if verdict.isEmpty { verdict = "UNRATED" }
        if reason.isEmpty { reason = reply.components(separatedBy: "\n").first ?? "" }
        return (verdict, reason)
    }

    static let ranking = ["ESSENTIAL": 0, "USEFUL": 1, "MARGINAL": 2, "UNRATED": 3, "SKIP": 4]
}
