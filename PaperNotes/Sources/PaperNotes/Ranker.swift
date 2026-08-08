import Foundation

/// Bands the library by ranking papers **against each other** in a single call.
///
/// This exists because grading papers one at a time does not work, which was
/// measured rather than assumed. Asked to band a paper in isolation, the judge put
/// 44 of 68 in SOLID; rewriting the rubric as reading decisions and stating a target
/// distribution moved four papers and left it at 65% SOLID. Worse, two runs over the
/// same 17 papers with the same prompt disagreed by a full band on three of them, so
/// the absolute grade was not even self-consistent. Asking for a 0–100 score instead
/// produced p25 66, median 72, p75 74 — thirteen of seventeen inside an eight-point
/// window.
///
/// None of that is surprising in hindsight: a single paper in context has no
/// comparison class, and every competent paper on a topic the reader already follows
/// reads as "a real insight". Put seventeen in one prompt with mandatory band counts
/// and the reasons turn comparative — "less shocking than subliminal transmission",
/// "breaks the least new ground here" — which is exactly the signal that was missing.
///
/// It is also far cheaper: one call for the whole library instead of one per paper.
enum Ranker {
    struct Placement {
        let arxivID: String
        let band: Verdict
        let rank: Int          // 1 = most interesting
        let reason: String     // comparative, relative to this run only
    }

    /// Shares of the library per band. A ranking has to put someone last, and these
    /// proportions are what make the top of the list mean something. THIN is not an
    /// insult here — it means a reader who knows the area would have guessed it.
    static let shares: [(Verdict, Double)] = [
        (.gold, 0.03), (.solid, 0.22), (.mixed, 0.45), (.thin, 0.30)
    ]

    /// Largest number of papers to rank in one call. Each entry is a title and a
    /// one-clause idea, so a hundred and fifty is still a small prompt; beyond that
    /// the ranking quality falls off before the context does.
    static let batchLimit = 150

    /// Papers must carry the one-clause idea from the per-paper pass — that summary
    /// is what makes a comparative ranking possible without shipping 68 PDFs.
    static func rankable(_ papers: [Paper]) -> [Paper] {
        papers.filter { !$0.appraisalNote.isEmpty }
    }

    static func targetCounts(for n: Int) -> [(Verdict, Int)] {
        guard n > 0 else { return [] }
        var counts = shares.map { ($0.0, max(0, Int((Double(n) * $0.1).rounded()))) }
        // Rounding must not invent or lose papers; the remainder goes to MIXED,
        // the widest band, so the extremes keep the sizes that make them meaningful.
        let drift = n - counts.reduce(0) { $0 + $1.1 }
        if let i = counts.firstIndex(where: { $0.0 == .mixed }) {
            counts[i].1 = max(0, counts[i].1 + drift)
        }
        // A tiny library cannot support four bands; collapse rather than pretend.
        if n < 8 { return [(.gold, 0), (.solid, max(1, n / 3)), (.mixed, n - max(1, n / 3)), (.thin, 0)] }
        return counts
    }

    static func prompt(for papers: [Paper]) -> String {
        let counts = targetCounts(for: papers.count)
        let quota = counts.filter { $0.1 > 0 }
            .map { "\($0.0.label) \($0.1)" }.joined(separator: ", ")
        let listing = papers.enumerated().map { i, p in
            "\(i + 1). [\(p.arxivID)] \(p.title.isEmpty ? p.arxivID : p.title)\n"
            + "   idea: \(p.appraisalNote)"
        }.joined(separator: "\n\n")

        return """
        Below are \(papers.count) papers from one researcher's library, each with a
        one-clause summary of its central idea.

        They read to find ideas: surprising results, new framings, directions worth
        working on. They do not care how rigorous the work is, how many seeds it ran,
        how large the models were, or how well it is written. An interesting claim on
        thin evidence outranks a careful confirmation of the expected.

        Rank ALL \(papers.count) against EACH OTHER, then assign bands with these
        exact counts: \(quota).

        The counts are mandatory. You are ordering these papers relative to one
        another, not scoring them in isolation — someone has to come last, and a
        paper placed low is not a bad paper, only a less surprising one than the
        papers above it.

        \(listing)

        Reply one line per paper, most interesting first, no preamble, no numbering:
        <arxiv-id>  <BAND>  <at most 12 words on why it sits above or below its neighbours>
        """
    }

    /// Parses the reply. Ignores anything that is not a known id, so a stray
    /// preamble line cannot shift every rank by one.
    static func parse(_ reply: String, known: Set<String>) -> [Placement] {
        var out: [Placement] = []
        var seen = Set<String>()
        for line in reply.components(separatedBy: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".[]")) }
                .filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }
            let id = PDFRefs.normalise(parts[0])
            guard known.contains(id), !seen.contains(id) else { continue }
            guard let band = Verdict(rawValue: parts[1].lowercased()), band != .unset else { continue }
            seen.insert(id)
            out.append(Placement(arxivID: id, band: band, rank: out.count + 1,
                                 reason: parts.dropFirst(2).joined(separator: " ")))
        }
        return out
    }
}
