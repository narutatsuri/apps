import Foundation

/// Sidebar search across the library.
///
/// Searches what you wrote, not just the catalogue. Title and author matching is
/// table stakes; the reason to have search at all in a reading tool is "what did
/// I say about steganography six weeks ago", and that lives in the note body.
///
/// Pure so the ranking can be checked. Ranking is the part that decides whether
/// search feels right, and it is invisible from the outside — a result list is
/// plausible whatever order it comes back in.
enum Search {
    /// Where a paper matched. The order of the cases is the ranking: a title hit
    /// outranks a note hit, because typing a title means you know what you want.
    enum Field: Int, Comparable {
        case title = 0
        case identity          // arXiv id, authors, venue, tags
        case note              // your own prose
        case appraisal         // Claude's one-clause idea

        var label: String {
            switch self {
            case .title: return ""
            case .identity: return ""
            case .note: return "in your note"
            case .appraisal: return "in the appraisal"
            }
        }

        static func < (l: Field, r: Field) -> Bool { l.rawValue < r.rawValue }
    }

    struct Hit: Equatable {
        let paper: Paper
        let field: Field
        /// Context for a body match, so you can see why it matched without
        /// opening it. Empty for title and identity hits, where the row already
        /// shows the matching text.
        let snippet: String
    }

    /// Case- and accent-insensitive: "Dubinski" should find "Dubiński", and
    /// nobody types the diacritic.
    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// A token matches a field when some word in it *starts* with the token.
    ///
    /// Not a plain substring match, which is what this was first: searching an
    /// author's surname "Tan" then matched "important", "instantiate", and
    /// "constant" across the whole library. Word-prefix keeps the useful half of
    /// substring matching — "stegan" still finds "steganographic" — and drops the
    /// half that just adds noise.
    static func words(_ text: String) -> [Substring] {
        fold(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    }

    private static func hit(_ token: String, in words: [Substring]) -> Bool {
        words.contains { $0.hasPrefix(token) }
    }

    /// Every whitespace-separated token must match somewhere in the paper — so
    /// "evans subliminal" narrows rather than widening, which is what a second
    /// word is for.
    static func matches(_ query: String, in papers: [Paper]) -> [Hit] {
        // The query is tokenised exactly like the fields, or "2506.01926" is one
        // token that prefix-matches neither "2506" nor "01926" and an arXiv id
        // finds nothing. Same rule both sides, one place.
        let tokens = words(query).map(String.init)
        guard !tokens.isEmpty else { return [] }

        var hits: [Hit] = []
        for paper in papers {
            let title = words(paper.title)
            let identity = words(([paper.arxivID, paper.venue] + paper.authors + paper.tags)
                .joined(separator: " "))
            let note = words(paper.prose)
            let appraisal = words(paper.appraisalNote)

            // AND across tokens, but a token may match in any field: searching
            // "betley owl" should find a Betley paper whose note mentions owls.
            let all = [title, identity, note, appraisal]
            guard tokens.allSatisfy({ t in all.contains { hit(t, in: $0) } }) else { continue }

            // Rank by the best field any token hit, so a title match wins even
            // when the other token only appears in the note.
            var best = Field.appraisal
            for t in tokens {
                if hit(t, in: title) { best = min(best, .title) }
                else if hit(t, in: identity) { best = min(best, .identity) }
                else if hit(t, in: note) { best = min(best, .note) }
            }
            let snippet = (best == .note || best == .appraisal)
                ? excerpt(around: tokens, in: best == .note ? paper.prose : paper.appraisalNote)
                : ""
            hits.append(Hit(paper: paper, field: best, snippet: snippet))
        }

        // Stable within a rank: keep the order the caller already sorted by, so
        // search does not silently reshuffle the sort you chose.
        return hits.enumerated()
            .sorted { ($0.element.field, $0.offset) < ($1.element.field, $1.offset) }
            .map(\.element)
    }

    /// A window of text around the first matching token, with the scaffolding
    /// stripped — a snippet of `<!-- The argument as you'd tell a colleague -->`
    /// tells you nothing about your own note.
    static func excerpt(around tokens: [String], in text: String, width: Int = 90) -> String {
        let prose = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("<!--") }
            .joined(separator: " ")
        guard !prose.isEmpty else { return "" }

        let folded = fold(prose)
        guard let range = tokens.compactMap({ folded.range(of: $0) })
            .min(by: { $0.lowerBound < $1.lowerBound }) else { return String(prose.prefix(width)) }

        // Fold preserves offsets for the scripts this library uses, but clamp
        // rather than trust it: an out-of-range index would crash the sidebar.
        let start = folded.distance(from: folded.startIndex, to: range.lowerBound)
        let lead = max(0, start - width / 3)
        let chars = Array(prose)
        guard lead < chars.count else { return String(prose.prefix(width)) }
        let slice = String(chars[lead..<min(chars.count, lead + width)])
        return (lead > 0 ? "…" : "") + slice + (lead + width < chars.count ? "…" : "")
    }
}
