import Foundation

/// Why two papers are connected. Shown verbatim to the reader — an edge you can't
/// explain is an edge you won't trust.
enum RelationKind: String {
    case cites            // this paper cites the other
    case citedBy          // the other cites this one
    case coupling         // shared references — the connectedpapers signal
    case topical          // title term overlap; the weakest, and labelled as such

    var weight: Double {
        switch self {
        case .cites, .citedBy: return 1.0
        case .coupling: return 0.7
        case .topical: return 0.3
        }
    }
}

struct Relation: Identifiable {
    let other: Paper
    let kind: RelationKind
    /// Shared references, for `coupling`.
    let shared: Int
    let score: Double

    var id: String { other.arxivID + kind.rawValue }

    var explanation: String {
        switch kind {
        case .cites: return "cites this"
        case .citedBy: return "cited by this"
        case .coupling: return "shares \(shared) reference\(shared == 1 ? "" : "s")"
        case .topical: return "similar topic"
        }
    }
}

enum Relations {
    /// Stop words plus the vocabulary of this particular field, which would
    /// otherwise link every paper to every other.
    private static let stop: Set<String> = [
        "the", "a", "an", "of", "for", "and", "or", "to", "in", "on", "with", "via",
        "is", "are", "can", "do", "does", "how", "what", "why", "we", "our", "using",
        "towards", "toward", "language", "model", "models", "large", "llm", "llms",
        "learning", "neural", "deep", "ai", "study", "analysis", "approach", "method",
        "framework", "evaluation", "benchmark", "understanding", "improving"
    ]

    // Broken into steps deliberately: as one chained expression the type checker
    // gives up ("unable to type-check in reasonable time").
    static func terms(_ paper: Paper) -> Set<String> {
        let lowered = paper.title.lowercased()
        let cleaned = lowered.replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ",
                                                   options: .regularExpression)
        let words: [String] = cleaned.split(separator: " ").map(String.init)
        var kept = Set<String>()
        for w in words where w.count > 3 && !stop.contains(w) { kept.insert(w) }
        return kept
    }

    /// Every paper already read that connects to `paper`, strongest first.
    /// One relation per other paper — the strongest reason wins, so the list reads
    /// as "these papers", not "these reasons".
    static func related(to paper: Paper, in library: [Paper], limit: Int = 8) -> [Relation] {
        let mine = Set(paper.refs.map(PDFRefs.normalise))
        let myID = PDFRefs.normalise(paper.arxivID)
        let myTerms = terms(paper)

        var best: [String: Relation] = [:]
        func offer(_ r: Relation) {
            let key = r.other.arxivID
            if let existing = best[key], existing.score >= r.score { return }
            best[key] = r
        }

        for other in library where PDFRefs.normalise(other.arxivID) != myID {
            let theirs = Set(other.refs.map(PDFRefs.normalise))
            let theirID = PDFRefs.normalise(other.arxivID)

            if mine.contains(theirID) {
                offer(Relation(other: other, kind: .citedBy, shared: 0,
                               score: RelationKind.citedBy.weight))
            }
            if theirs.contains(myID) {
                offer(Relation(other: other, kind: .cites, shared: 0,
                               score: RelationKind.cites.weight))
            }
            let shared = mine.intersection(theirs).count
            if shared >= 2 {
                // Saturating rather than linear: 40 shared refs is not four times
                // more meaningful than 10, it just means both have long bibliographies.
                let strength = min(1.0, Double(shared) / 12.0)
                offer(Relation(other: other, kind: .coupling, shared: shared,
                               score: RelationKind.coupling.weight * strength))
            }
            let overlap = myTerms.intersection(terms(other)).count
            if overlap >= 2 {
                let strength = min(1.0, Double(overlap) / 4.0)
                offer(Relation(other: other, kind: .topical, shared: overlap,
                               score: RelationKind.topical.weight * strength))
            }
        }

        return best.values.sorted {
            $0.score == $1.score ? $0.other.arxivID < $1.other.arxivID : $0.score > $1.score
        }.prefix(limit).map { $0 }
    }

    /// Undirected edges across the whole library, for the graph view.
    ///
    /// Deliberately applies no score floor of its own. `related` already decides what
    /// counts as a relation (≥2 shared references, ≥2 shared title terms); a second
    /// threshold here made the graph silently drop edges the note panel was showing —
    /// two shared references scores 0.12, which an earlier 0.25 floor discarded. One
    /// decision belongs in one place.
    static func edges(in library: [Paper]) -> [(String, String, Double)] {
        var seen = Set<String>()
        var out: [(String, String, Double)] = []
        for paper in library {
            for r in related(to: paper, in: library, limit: 12) {
                let pair = [paper.arxivID, r.other.arxivID].sorted()
                let key = pair.joined(separator: "|")
                if seen.insert(key).inserted {
                    out.append((pair[0], pair[1], r.score))
                }
            }
        }
        return out
    }
}
