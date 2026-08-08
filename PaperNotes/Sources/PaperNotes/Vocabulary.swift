import Foundation

/// What this library is *about*, learned from the library itself.
///
/// Needed because the recent-arXiv source fetches hundreds of papers a week and
/// something has to shortlist them before a judge is worth spending. No API and
/// no embeddings: the terms your own titles and notes keep using are a usable
/// fingerprint of your agenda, and they cost nothing to compute.
///
/// A term earns weight by appearing across *many* of your papers, not many times
/// in one. One paper about photonic lattices should not make "photonic" a term
/// this library cares about.
struct Vocabulary {
    /// term → how many of your papers use it, capped so one ubiquitous word
    /// cannot dominate the score.
    private(set) var weights: [String: Double] = [:]
    private(set) var documentCount = 0

    /// Words too common to carry meaning. Deliberately short: a long stop list
    /// starts deleting real terms, and the document-frequency floor below
    /// already removes most noise.
    static let stop: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "are", "can", "not",
        "but", "its", "into", "than", "then", "when", "what", "which", "while",
        "have", "has", "had", "was", "were", "been", "being", "does", "did",
        "using", "used", "use", "via", "our", "their", "they", "more", "most",
        "some", "such", "only", "also", "other", "over", "under", "between",
        "however", "these", "those", "there", "here", "how", "why",
        "paper", "papers", "work", "results", "result", "show", "shows", "shown",
        "model", "models", "method", "methods", "approach", "task", "tasks",
        "based", "propose", "proposed", "study", "studies", "new", "novel",
    ]

    static func terms(_ text: String) -> Set<String> {
        Set(Search.words(text)
            .map(String.init)
            .filter { $0.count >= 4 && !stop.contains($0) && !$0.allSatisfy(\.isNumber) })
    }

    /// Builds the profile from titles and your own prose, weighted by how *rare*
    /// each term is in the wider literature.
    ///
    /// Two things this gets wrong without care, both found by looking at what it
    /// actually rewarded:
    ///
    /// 1. Appraisal notes are excluded. They are Claude's prose, not yours, and
    ///    counting them put "reframes" and "genuinely" among the library's top
    ///    terms — the judge's writing habits, not your research interests.
    ///
    /// 2. Library frequency alone measures nothing. "training" appears in 11 of
    ///    these papers and in 37% of everything posted to cs.LG; "misalignment"
    ///    appears in 6 and in 0.8%. Weighting by count alone made the generic
    ///    term worth more, which is how a ternary-quantization paper and a
    ///    prompt-rewriting paper reached a list about reward hacking. Inverse
    ///    document frequency against `background` — the same recent-arXiv corpus
    ///    the candidates come from — fixes the comparison, because that corpus
    ///    is exactly the population being ranked within.
    static func build(from papers: [Paper], background: [FeedPaper] = []) -> Vocabulary {
        var v = Vocabulary()
        v.documentCount = papers.count
        guard !papers.isEmpty else { return v }

        var docFreq: [String: Double] = [:]
        for paper in papers {
            for t in terms(paper.title) { docFreq[t, default: 0] += 1 }
            // Your own prose counts double: what you chose to write about is a
            // sharper signal than what the title happened to say.
            for t in terms(paper.prose) { docFreq[t, default: 0] += 2 }
        }

        // Rarity in the wider literature. With no background corpus every term
        // scores the same idf, which degrades to the old count-only behaviour
        // rather than breaking.
        var backgroundFreq: [String: Double] = [:]
        for p in background {
            for t in terms(p.title + " " + p.abstract) { backgroundFreq[t, default: 0] += 1 }
        }
        let n = Double(background.count)
        func idf(_ term: String) -> Double {
            guard n > 0 else { return 1 }
            return log((n + 1) / (1 + (backgroundFreq[term] ?? 0)))
        }

        let floor = max(2.0, Double(papers.count) * 0.04)
        let cap = Double(papers.count) * 0.5
        v.weights = docFreq
            .filter { $0.value >= floor }
            .reduce(into: [:]) { out, kv in out[kv.key] = min(kv.value, cap) * idf(kv.key) }
        v.ceiling = max(1, (v.weights.values.sorted(by: >).prefix(8).reduce(0, +)) * 2)
        return v
    }

    /// The score a maximally on-topic paper could reach, so scores are comparable
    /// across libraries and across background corpora of different sizes.
    private(set) var ceiling: Double = 1

    /// How much this library would care about a paper, from its title and
    /// abstract. Normalised by the number of distinct terms matched rather than
    /// text length, so a long abstract does not win on volume alone.
    func score(title: String, abstract: String) -> Double {
        let candidate = Self.terms(title + " " + abstract)
        guard !candidate.isEmpty, !weights.isEmpty else { return 0 }
        // Title matches count double — a term in the title is what the paper is
        // about; a term in the abstract may be background.
        let titleTerms = Self.terms(title)
        var total = 0.0
        for t in candidate {
            guard let w = weights[t] else { continue }
            total += titleTerms.contains(t) ? w * 2 : w
        }
        return min(1, total / ceiling)
    }
}
