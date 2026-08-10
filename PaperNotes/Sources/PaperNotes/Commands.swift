import Foundation

/// `--recommend [n]` and `--grade <arxivID|all>`, both of which use the `claude` CLI
/// as a judge. Kept as commands rather than buttons so they can run unattended and
/// be checked before anything touches the library.
enum Commands {

    // MARK: - Metadata

    /// `--meta <id>…` resolves ids through exactly the path the app uses. Added
    /// because three of six recommender lookups came back blank and there was no way
    /// to tell a dead id from a throttled request without one.
    static func meta(_ args: [String]) -> Never {
        guard !args.isEmpty else { print("usage: --meta <arxiv-id> [...]"); exit(1) }
        var failures = 0
        for id in args {
            let done = DispatchSemaphore(value: 0)
            var result: Metadata.Result?
            Task.detached { result = await Metadata.fetch(arxivID: id); done.signal() }
            _ = done.wait(timeout: .now() + 60)
            if let r = result {
                print("✓ \(id)  \(r.title)")
                print("    \(r.authors.prefix(3).joined(separator: ", "))"
                      + "  ·  \(r.year.map(String.init) ?? "no year")"
                      + "  ·  \(r.citations) citations")
            } else {
                print("✗ \(id)  no metadata")
                failures += 1
            }
        }
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Search

    /// `--search <terms>` runs the same matcher the sidebar uses, so what the
    /// field returns can be checked against the real library rather than fixtures.
    static func search(_ args: [String]) -> Never {
        guard !args.isEmpty else { print("usage: --search <terms>"); exit(1) }
        MainActor.assumeIsolated { Library.shared.bootstrap() }
        let library = MainActor.assumeIsolated { Library.shared.papers }
        let hits = Search.matches(args.joined(separator: " "), in: library)
        print("\(hits.count) of \(library.count) papers match \"\(args.joined(separator: " "))\"")
        for h in hits.prefix(12) {
            let where_ = h.field.label.isEmpty ? "" : "  (\(h.field.label))"
            print("  \(h.paper.arxivID)  \(h.paper.title.prefix(58))\(where_)")
            if !h.snippet.isEmpty { print("      \(h.snippet.prefix(110))") }
        }
        exit(0)
    }

    // MARK: - Queue

    /// `--queue` lists what is up next; `--queue <id>…` puts them at the front,
    /// `--queue --end <id>…` at the back, `--queue --clear` empties it.
    static func queue(_ args: [String]) -> Never {
        MainActor.assumeIsolated { Library.shared.bootstrap() }
        let library = MainActor.assumeIsolated { Library.shared.papers }
        let ids = args.filter { !$0.hasPrefix("--") }

        if args.contains("--clear") {
            let queued = ReadingQueue.ordered(library).map(\.arxivID)
            let changed = ReadingQueue.removing(queued, from: library)
            MainActor.assumeIsolated {
                Library.shared.batch({ "queue: cleared \($0) papers" }) {
                    for p in changed { Library.shared.save(p) }
                }
            }
            print("cleared \(queued.count) from the queue")
            exit(0)
        }

        if !ids.isEmpty {
            let changed = ReadingQueue.adding(ids, to: library,
                                              atFront: !args.contains("--end"))
            guard !changed.isEmpty else { print("Nothing matched."); exit(1) }
            MainActor.assumeIsolated {
                Library.shared.batch({ "queue: \($0) papers" }) {
                    for p in changed { Library.shared.save(p) }
                }
                Library.shared.reload()
            }
        }

        let now = MainActor.assumeIsolated { ReadingQueue.ordered(Library.shared.papers) }
        guard !now.isEmpty else { print("Nothing queued."); exit(0) }
        print("up next:")
        for p in now {
            print(String(format: "  %2d  %-12s %@", p.queuePosition,
                         (p.arxivID as NSString).utf8String!,
                         String((p.title.isEmpty ? p.arxivID : p.title).prefix(58))))
        }
        exit(0)
    }

    // MARK: - Appraise

    /// `--appraise [all|<id>…] [--force]` — grades papers on how interesting the
    /// idea is. New papers get this automatically; this exists to backfill a library
    /// that predates the feature, and to re-run one paper after a rubric change.
    static func appraise(_ args: [String]) -> Never {
        guard Judge.isAvailable else { print("claude CLI not found."); exit(1) }
        MainActor.assumeIsolated { Library.shared.bootstrap() }
        let all = MainActor.assumeIsolated { Library.shared.papers }
        let force = args.contains("--force")
        let ids = Set(args.filter { !$0.hasPrefix("--") && $0 != "all" }.map(PDFRefs.normalise))

        var targets = ids.isEmpty ? all : all.filter { ids.contains(PDFRefs.normalise($0.arxivID)) }
        // Re-grading a paper costs a minute and changes nothing, so by default skip
        // the ones already done.
        if !force { targets = targets.filter { $0.appraisal == .unset } }
        let skipped = targets.filter { $0.pdfPath.isEmpty }
        targets = targets.filter { !$0.pdfPath.isEmpty }

        print("\(all.count) papers · \(targets.count) to appraise"
              + (skipped.isEmpty ? "" : " · \(skipped.count) skipped, no PDF"))
        guard !targets.isEmpty else { exit(0) }

        var counts: [Verdict: Int] = [:]
        var scores: [Int] = []
        MainActor.assumeIsolated {
        Library.shared.batch({ "appraise: \($0) papers" }) {
        for (i, paper) in targets.enumerated() {
            guard let result = Judge.appraise(paper) else {
                print(String(format: "  %2d/%d  ??  %@ — no verdict",
                             i + 1, targets.count, paper.arxivID))
                continue
            }
            var updated = paper
            updated.appraisal = result.verdict
            updated.appraisalNote = result.note
            updated.appraisalScore = result.score
            MainActor.assumeIsolated { Library.shared.save(updated) }
            counts[result.verdict, default: 0] += 1
            scores.append(result.score)
            print(String(format: "  %2d/%d  %-7s %3d  %@", i + 1, targets.count,
                         (result.verdict.label as NSString).utf8String!, result.score,
                         String(paper.title.isEmpty ? paper.arxivID : paper.title).prefix(52)
                            + "\n            " + result.note))
        }
        }
        }

        print("\nspread: " + Verdict.allCases
            .filter { $0 != .unset && (counts[$0] ?? 0) > 0 }
            .map { "\($0.label) \(counts[$0] ?? 0)" }
            .joined(separator: " · "))
        let valid = scores.filter { $0 >= 0 }.sorted()
        if valid.count > 1 {
            func pct(_ q: Double) -> Int { valid[min(valid.count - 1, Int(q * Double(valid.count)))] }
            print("scores: min \(valid[0]) · p25 \(pct(0.25)) · median \(pct(0.5))"
                  + " · p75 \(pct(0.75)) · max \(valid[valid.count - 1])")
        }
        // A rubric that grades everything the same has told you nothing.
        if counts.count == 1, let only = counts.keys.first {
            print("WARNING: every paper came back \(only.label) — the rubric is not discriminating.")
        }
        exit(0)
    }

    // MARK: - Rank

    /// `--rank` — bands the library by ranking every paper against every other one,
    /// in a single call. This is what the badges mean; the per-paper appraisal only
    /// supplies the one-clause idea that makes the comparison possible.
    static func rank(_ args: [String]) -> Never {
        guard Judge.isAvailable else { print("claude CLI not found."); exit(1) }
        MainActor.assumeIsolated { Library.shared.bootstrap() }
        let all = MainActor.assumeIsolated { Library.shared.papers }
        let papers = Ranker.rankable(all)

        print("\(all.count) papers · \(papers.count) with an appraisal to rank")
        if papers.count < all.count {
            print("\(all.count - papers.count) have no one-clause idea yet — run --appraise first.")
        }
        guard papers.count >= 4 else { print("Too few to rank."); exit(1) }
        if papers.count > Ranker.batchLimit {
            print("WARNING: \(papers.count) papers exceeds the \(Ranker.batchLimit) "
                  + "that rank well in one call; ranking the first \(Ranker.batchLimit).")
        }
        let batch = Array(papers.prefix(Ranker.batchLimit))

        print("ranking them against each other…")
        guard let reply = Judge.ask(Ranker.prompt(for: batch), timeout: 600) else {
            print("The judge did not reply."); exit(1)
        }
        let placements = Ranker.parse(reply, known: Set(batch.map { PDFRefs.normalise($0.arxivID) }))
        // A partial reply would silently re-band only some of the library and leave
        // the rest carrying stale positions, which is worse than not ranking at all.
        guard placements.count >= batch.count * 9 / 10 else {
            print("Only \(placements.count) of \(batch.count) papers came back placed — refusing to "
                  + "apply a partial ranking. Nothing was written.")
            exit(1)
        }

        var counts: [Verdict: Int] = [:]
        let byID = Dictionary(uniqueKeysWithValues: batch.map { (PDFRefs.normalise($0.arxivID), $0) })
        MainActor.assumeIsolated {
        Library.shared.batch({ "rank: \($0) papers by how interesting the idea is" }) {
        for p in placements {
            guard var paper = byID[p.arxivID] else { continue }
            paper.appraisal = p.band
            paper.appraisalRank = p.rank
            MainActor.assumeIsolated { Library.shared.save(paper) }
            counts[p.band, default: 0] += 1
            print(String(format: "  %3d  %-7s %@", p.rank,
                         (p.band.label as NSString).utf8String!,
                         String((paper.title.isEmpty ? paper.arxivID : paper.title).prefix(56))
                            + (p.reason.isEmpty ? "" : "\n              " + p.reason)))
        }
        }
        }
        print("\nbands: " + Verdict.allCases
            .filter { $0 != .unset && (counts[$0] ?? 0) > 0 }
            .map { "\($0.label) \(counts[$0] ?? 0)" }
            .joined(separator: " · "))
        if placements.count < batch.count {
            print("\(batch.count - placements.count) papers were not placed and kept their old band.")
        }
        exit(0)
    }

    // MARK: - Recommend

    static func recommend(_ args: [String]) -> Never {
        let limit = args.first.flatMap(Int.init) ?? 15
        MainActor.assumeIsolated { Library.shared.bootstrap() }
        let all = MainActor.assumeIsolated { Library.shared.papers }
        // Archived papers are the reading you have moved past, so they are not
        // evidence of what to read next: left in, a stretch of old multilingual
        // work pulls every recommendation back toward it. `--archaic` puts them
        // back for a run.
        let includeArchaic = args.contains("--archaic")
        let library = Recommender.eligible(all, includeArchaic: includeArchaic)
        let skipped = all.count - library.count
        if skipped > 0 {
            print("(\(skipped) archived paper\(skipped == 1 ? "" : "s") left out — "
                  + "pass --archaic to include them)")
        }
        guard !library.isEmpty else { print("Library is empty."); exit(1) }

        // Four sources, each answering a different question. Measured on this
        // library, the two original ones could reach only 13 of 64 papers.
        let days = Prefs.freshWindowDays
        func sync<T>(_ work: @escaping @Sendable () async -> T) -> T {
            let done = DispatchSemaphore(value: 0)
            var out: T!
            Task.detached { out = await work(); done.signal() }
            _ = done.wait(timeout: .now() + 600)
            return out
        }

        var found: [(name: String, papers: [TrustedAuthors.Paper])] = []
        for name in TrustedAuthors.names() {
            let papers = sync { await TrustedAuthors.recent(by: name) }
            print("  \(name): \(papers.count) recent on arXiv")
            found.append((name, papers))
        }
        let fromAuthors = Recommender.authorCandidates(from: library, found: found)

        let seeds = Array(Set(library.filter(\.starred).map(\.arxivID)
            + library.filter { $0.appraisalRank > 0 }
                .sorted { $0.appraisalRank < $1.appraisalRank }
                .prefix(15).map(\.arxivID)))
        let similarFeed = sync { await SemanticScholar.recommendations(seedIDs: seeds) }
        let fromSimilar = Recommender.similarCandidates(from: library, found: similarFeed)
        print("  semantic scholar: \(similarFeed.count) returned, \(fromSimilar.count) new")

        var feed: [FeedPaper] = []
        for cat in ArxivFeed.categories() {
            let batch = sync { await ArxivFeed.recent(category: cat, days: days) }
            print("  \(cat): \(batch.count) posted in the last \(days) days")
            feed += batch
        }
        let vocabulary = Vocabulary.build(from: library, background: feed)
        let fromFresh = Recommender.freshCandidates(from: library, found: feed,
                                                    vocabulary: vocabulary)
        print("  scored against your vocabulary: \(fromFresh.count) above the floor")

        let cited = Recommender.candidates(from: library)
        let starred = library.filter(\.starred).count
        print("\n\(library.count) papers (\(starred) starred) · \(cited.count) cited by 3+")

        var candidates = Recommender.merge([
            (.fresh, fromFresh), (.similar, fromSimilar),
            (.author(""), fromAuthors), (.cited, cited),
        ], limit: limit)
        guard !candidates.isEmpty else {
            print("Nothing to recommend yet.")
            exit(0)
        }

        print("\nfetching metadata…")
        for i in candidates.indices {
            let done = DispatchSemaphore(value: 0)
            var meta: Metadata.Result?
            let id = candidates[i].arxivID
            Task.detached { meta = await Metadata.fetch(arxivID: id); done.signal() }
            _ = done.wait(timeout: .now() + 60)
            if let m = meta {
                if candidates[i].title.isEmpty { candidates[i].title = m.title }
                if candidates[i].authors.isEmpty { candidates[i].authors = m.authors }
                candidates[i].published = candidates[i].published ?? m.published
                candidates[i].year = candidates[i].year ?? m.year
                candidates[i].citations = m.citations
            }
            Thread.sleep(forTimeInterval: 0.3)
        }

        if Judge.isAvailable {
            print("judging with claude…")
            for i in candidates.indices {
                let prompt = Recommender.judgePrompt(candidates[i], library: library)
                guard let reply = Judge.ask(prompt, timeout: 120) else {
                    candidates[i].verdict = "UNRATED"
                    candidates[i].reason = "judge did not reply"
                    continue
                }
                let parsed = Recommender.parseVerdict(reply)
                candidates[i].verdict = parsed.verdict
                candidates[i].reason = parsed.reason
                print("  \(parsed.verdict.padding(toLength: 9, withPad: " ", startingAt: 0)) "
                      + "\(candidates[i].ageLabel.padding(toLength: 13, withPad: " ", startingAt: 0)) "
                      + "\(candidates[i].title.prefix(46))")
            }
            candidates.sort {
                let l = Recommender.ranking[$0.verdict] ?? 3, r = Recommender.ranking[$1.verdict] ?? 3
                return l == r ? $0.weight > $1.weight : l < r
            }
        } else {
            print("claude CLI not found — ranking by citation weight only.")
        }

        write(candidates, library: library)
        exit(0)
    }

    /// Written as markdown into the notes repo, so recommendations are versioned
    /// alongside the notes and readable without the app.
    private static func write(_ candidates: [Recommender.Candidate], library: [Paper]) {
        var out = "# Recommended reading\n\n"
        let followed = candidates.filter { if case .author = $0.source { return true }; return false }
        out += "New work by the people you follow, and papers your library keeps citing.\n"
        out += "Generated from \(library.count) papers"
        out += followed.isEmpty ? "" : " and \(TrustedAuthors.names().count) trusted author(s)"
        out += "; starred papers count treble.\n\n"
        for c in candidates {
            let title = c.title.isEmpty ? "arXiv:\(c.arxivID)" : c.title
            out += "## \(c.verdict.isEmpty ? "" : c.verdict + " · ")\(title)\n\n"
            out += "- arXiv: [\(c.arxivID)](https://arxiv.org/abs/\(c.arxivID))\n"
            if !c.authors.isEmpty {
                out += "- \(c.authors.prefix(4).joined(separator: ", "))"
                    + (c.authors.count > 4 ? " et al." : "")
                    + (c.year.map { " · \($0)" } ?? "") + "\n"
            }
            if case .author(let who) = c.source {
                out += "- suggested because you follow **\(who)**"
            } else {
                out += "- cited by **\(c.citedByYours.count)** of your papers"
            }
            out += c.citations > 0 ? " · \(c.citations) citations overall\n" : "\n"
            if !c.reason.isEmpty { out += "- \(c.reason)\n" }
            out += "\n"
        }
        let url = Library.root.appendingPathComponent("RECOMMENDATIONS.md")
        try? out.write(to: url, atomically: true, encoding: .utf8)
        Git.commit(at: Library.root, message: "recommendations: \(candidates.count) papers")
        print("\nwrote \(url.path)")
    }

    // MARK: - Grade

    /// Grades your *note*, not the paper. The point is whether you understood it and
    /// what you missed — a summary of the paper is something you can already get, and
    /// getting it is the habit worth breaking.
    static func grade(_ args: [String]) -> Never {
        guard Judge.isAvailable else { print("claude CLI not found."); exit(1) }
        MainActor.assumeIsolated { Library.shared.bootstrap() }
        let library = MainActor.assumeIsolated { Library.shared.papers }

        let target = args.first ?? "all"
        let subjects = target.lowercased() == "all"
            ? library.filter(\.isSubstantive)
            : library.filter { PDFRefs.normalise($0.arxivID) == PDFRefs.normalise(target) }

        guard !subjects.isEmpty else {
            print(target == "all"
                  ? "No notes with anything written in them yet."
                  : "No paper matching \(target).")
            exit(1)
        }

        for paper in subjects {
            print("\n── \(paper.arxivID)  \(paper.title.prefix(56))")
            let asked = paper.questions
            if !asked.isEmpty {
                print("   answering \(asked.count) question\(asked.count == 1 ? "" : "s") from your note")
            }
            // Calls the shared prompt rather than carrying a copy. It carried one
            // for months, which is how the CLI came to be running an older rubric
            // than the button while a comment claimed the two could not drift.
            let force = args.contains("--force")
            let result = GradeCache.grade(paper, force: force)
            guard let reply = result.text else {
                print("   the judge did not reply")
                continue
            }
            if result.cached { print("   (saved from an earlier run — pass --force to redo)") }
            for line in reply.components(separatedBy: "\n") {
                print(line.isEmpty ? "" : "   " + line)
            }
        }
        exit(0)
    }
}
