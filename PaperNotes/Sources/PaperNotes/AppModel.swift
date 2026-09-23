import SwiftUI
import Observation

enum Prefs {
    private static let d = UserDefaults.standard
    /// Off until the repo's visibility is settled. Notes record what you did not
    /// understand and candid verdicts on other people's work; that is a deliberate
    /// decision to publish, not a default.
    static var pushEnabled: Bool {
        get { d.bool(forKey: "pushEnabled") }
        set { d.set(newValue, forKey: "pushEnabled") }
    }

    /// How far back the arXiv scan looks, in days. Short by default because the
    /// point of that source is work nothing else can reach yet.
    static var freshWindowDays: Int {
        get { d.object(forKey: "freshWindowDays") == nil ? 21 : d.integer(forKey: "freshWindowDays") }
        set { d.set(max(1, min(120, newValue)), forKey: "freshWindowDays") }
    }

}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var papers: [Paper] = []
    var selectedID: String?
    var draft: Paper?
    var related: [Relation] = []
    var status = ""
    var isBusy = false
    var showingAdd = false
    var unpushed = 0
    var sort: SortOrder = .published
    var confirmDelete: Paper?

    /// The project registry, reloaded with the library so a hand edit to
    /// `projects.txt` shows up on the next refresh.
    var projects: [Project] = []
    var showingNewProject = false
    var showingProjects = false
    /// The papers the New Project sheet will tag once the project exists —
    /// creating a project always starts from a paper you wanted to put in it.
    var newProjectTargets: [String] = []

    // Grading and recommending both call out to the claude CLI, which takes tens of
    // seconds, so both are async with visible progress rather than a frozen window.
    var gradeResult: String?
    var isGrading = false
    /// Whether the shown grade came off disk. Surfaced so a result that appears
    /// instantly is explained rather than mistaken for the model repeating itself.
    var gradeWasCached = false
    var isRanking = false
    /// What the Next window recommends for. Session-only on purpose: a scope
    /// that silently survived a relaunch would read as the recommender having
    /// gone strange.
    var recommendScope: Recommender.Scope = .library
    var recommendations: [Recommender.Candidate] = []
    var isRecommending = false
    var recommendProgress = ""

    private var pushTimer: Timer?

    private init() {}

    func bootstrap() {
        Library.shared.bootstrap()
        refresh()
        // Push on a timer rather than per note: a commit is instant and never fails,
        // a push needs the network and shouldn't sit between you and the next thought.
        let t = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushIfEnabled() }
        }
        RunLoop.main.add(t, forMode: .common)
        pushTimer = t
    }

    func delete(_ paper: Paper) {
        Library.shared.delete(paper)
        if selectedID == paper.arxivID { selectedID = nil; draft = nil; related = [] }
        refresh()
        status = "Removed \(paper.title.isEmpty ? paper.arxivID : String(paper.title.prefix(40)))"
    }

    /// Puts papers at the front of the reading queue. Multiple at once keeps the
    /// order you passed them in, so selecting three and choosing Read next reads
    /// them in the order you picked.
    func queue(_ ids: [String], atFront: Bool = true) {
        let changed = ReadingQueue.adding(ids, to: Library.shared.papers, atFront: atFront)
        guard !changed.isEmpty else { return }
        Library.shared.batch({ "queue: \($0) papers" }) {
            for p in changed { Library.shared.save(p) }
        }
        refresh()
        let n = ids.count
        status = atFront
            ? "Next up: \(n) paper\(n == 1 ? "" : "s")"
            : "Added \(n) paper\(n == 1 ? "" : "s") to the end of the queue"
    }

    func unqueue(_ ids: [String]) {
        let changed = ReadingQueue.removing(ids, from: Library.shared.papers)
        guard !changed.isEmpty else { return }
        Library.shared.batch({ "queue: removed \($0) papers" }) {
            for p in changed { Library.shared.save(p) }
        }
        refresh()
        status = "Removed from the queue"
    }

    /// The queue, in reading order.
    var upNext: [Paper] { ReadingQueue.ordered(papers) }

    func toggleStar(_ paper: Paper) {
        var p = paper
        p.starred.toggle()
        Library.shared.save(p)
        if draft?.arxivID == p.arxivID { draft?.starred = p.starred }
        refresh()
    }

    func refresh() {
        Library.shared.reload()
        papers = SortOrder.apply(sort, to: Library.shared.papers)
        projects = Projects.load()
        unpushed = Git.unpushedCount
        if let id = selectedID { select(id) }
    }

    // MARK: - Projects

    func project(named name: String) -> Project? {
        guard !name.isEmpty else { return nil }
        return projects.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Tags papers with a project, or clears the tag with nil. Works from disk
    /// and patches the open draft in place, so an unsaved note body cannot be
    /// clobbered by a tag change.
    func assign(project name: String?, to ids: [String]) {
        let value = name ?? ""
        let changed = ids.compactMap { Library.shared.paper(withID: $0) }
            .filter { $0.project != value }
        guard !changed.isEmpty else { return }
        Library.shared.batch({ n in
            value.isEmpty ? "projects: untagged \(n) paper\(n == 1 ? "" : "s")"
                          : "projects: \(n) paper\(n == 1 ? "" : "s") → \(value)"
        }) {
            for var p in changed {
                p.project = value
                Library.shared.save(p)
            }
        }
        if let d = draft, ids.contains(d.arxivID) { draft?.project = value }
        refresh()
        status = value.isEmpty
            ? "Removed from project"
            : "\(changed.count == 1 ? "Tagged" : "Tagged \(changed.count) papers") · \(value)"
    }

    /// Papers carrying a project, by id — what a delete would untag.
    func papers(inProject name: String) -> [String] {
        Projects.papers(Library.shared.papers, matching: name).map(\.arxivID)
    }

    func recolour(project name: String, to colour: ProjectColour) {
        guard let i = projects.firstIndex(where: { $0.name.lowercased() == name.lowercased() }),
              projects[i].colour != colour else { return }
        projects[i].colour = colour
        Projects.save(projects)
        Git.commit(at: Library.root, message: "projects: \(projects[i].name) → \(colour.rawValue)")
        refresh()
    }

    /// Removes the project and untags its papers — the papers stay. A grey
    /// orphan dot is what a hand edit to projects.txt leaves; an in-app
    /// delete is deliberate, so it cleans up after itself.
    func deleteProject(named name: String) {
        guard let proj = project(named: name) else { return }
        let tagged = papers(inProject: proj.name)
        if !tagged.isEmpty { assign(project: nil, to: tagged) }
        projects.removeAll { $0.name.lowercased() == proj.name.lowercased() }
        Projects.save(projects)
        Git.commit(at: Library.root, message: "projects: delete \(proj.name)")
        refresh()
        status = tagged.isEmpty
            ? "Deleted project \(proj.name)"
            : "Deleted project \(proj.name) · untagged \(tagged.count) paper\(tagged.count == 1 ? "" : "s")"
    }

    /// Makes the project and tags the papers the sheet was opened for. Returns
    /// false — sheet stays up — when the name is empty or already taken.
    @discardableResult
    func createProject(named rawName: String, colour: ProjectColour) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, project(named: name) == nil else { return false }
        var all = projects
        all.append(Project(name: name, colour: colour))
        Projects.save(all)
        projects = all
        Git.commit(at: Library.root, message: "projects: new project \(name)")
        assign(project: name, to: newProjectTargets)
        newProjectTargets = []
        return true
    }

    func select(_ id: String) {
        // Write any unsaved edits through before the draft is replaced.
        // Switching papers used to discard the draft outright — the note you
        // had been typing into silently reset to the template, because the
        // words had never existed anywhere but memory. It cost a real note.
        // A switch to a *different* paper also commits; a same-paper reload
        // (every refresh ends here) just writes the file.
        let switching = draft.map {
            PDFRefs.normalise($0.arxivID) != PDFRefs.normalise(id)
        } ?? false
        flushDraft(commit: switching)
        selectedID = id
        guard let p = Library.shared.paper(withID: id) else { draft = nil; related = []; return }
        draft = p
        related = Relations.related(to: p, in: papers)
    }

    /// The editor calls this on every change; the write lands after a pause.
    /// Typing a sentence should not be sixty writes, but the pause must be
    /// short enough that a crash costs a phrase, not an afternoon.
    private var autosaveWork: DispatchWorkItem?
    func noteEdited() {
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flushDraft() }
        }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Writes the draft's edits to disk — only the fields the editor owns.
    ///
    /// It re-reads the stored paper and copies the body and verdict onto it
    /// rather than writing the whole draft, for the same reason `appraise` did:
    /// the draft can be stale in every *other* field. Writing all of it once
    /// undid a queue change that had landed after the draft was loaded.
    func flushDraft(commit: Bool = false) {
        autosaveWork?.cancel()
        autosaveWork = nil
        guard let d = draft, var stored = Library.shared.paper(withID: d.arxivID) else { return }
        guard stored.body != d.body || stored.verdict != d.verdict else { return }
        stored.body = d.body
        stored.verdict = d.verdict
        if stored.readOn == nil { stored.readOn = Date() }
        Library.shared.save(stored, commit: commit)
    }

    /// ⌘S — still here, now meaning "commit this instant" rather than being
    /// the only thing standing between the words and oblivion.
    func save() {
        guard var p = draft else { return }
        if p.readOn == nil { p.readOn = Date() }
        Library.shared.save(p)
        draft = p
        status = "Saved · \(p.arxivID)"
        refresh()
        select(p.arxivID)
    }

    func pushIfEnabled() {
        guard Prefs.pushEnabled else { return }
        unpushed = Git.unpushedCount
        guard unpushed > 0 else { return }
        // The website reads reading-graph.json straight from this repo on
        // GitHub, so the export travels with the notes: regenerated whenever
        // a push is about to carry changes, committed only when its bytes
        // moved — the export is deterministic, so a quiet cycle costs nothing.
        refreshGraphExport()
        unpushed = Git.unpushedCount
        let n = unpushed
        Task.detached {
            let failure = Git.push()
            await MainActor.run {
                self.status = failure ?? "Pushed \(n) commit\(n == 1 ? "" : "s")"
                self.unpushed = Git.unpushedCount
            }
        }
    }

    private func refreshGraphExport() {
        let target = Library.root.appendingPathComponent("reading-graph.json")
        let text = GraphExport.text(for: Library.shared.papers, wrap: false)
        guard (try? String(contentsOf: target, encoding: .utf8)) != text else { return }
        try? text.write(to: target, atomically: true, encoding: .utf8)
        Git.commit(at: Library.root, message: "graph: refresh the website export")
    }

    // MARK: - Adding

    /// Accepts an arXiv id, an arXiv URL, or a local PDF. References come from the
    /// PDF when one is supplied — that is the only source that works for preprints.
    func add(idOrURL raw: String, pdf: URL?) async {
        isBusy = true
        defer { isBusy = false }

        // A non-arXiv URL is a web page — a blog post, say — and becomes a
        // hand-keyed entry with the page's own title, author and date.
        if pdf == nil, let webURL = WebIngest.ingestableURL(raw) {
            await addWeb(webURL)
            return
        }

        var id = PDFRefs.normalise(raw.trimmingCharacters(in: .whitespaces))
        if id.isEmpty || id.contains("/") {
            id = PDFRefs.idFromFilename(raw) ?? ""
        }
        if id.isEmpty, let pdf { id = PDFRefs.idFromFilename(pdf.lastPathComponent) ?? "" }
        guard !id.isEmpty else { status = "No arXiv id found."; return }

        if Library.shared.paper(withID: id) != nil {
            status = "Already in the library."
            select(id)
            showingAdd = false
            return
        }

        var paper = Paper(arxivID: id)
        if let pdf {
            paper.refs = PDFRefs.references(in: pdf, excluding: id)
            paper.title = PDFRefs.guessTitle(in: pdf) ?? ""
            paper.pdfPath = Library.adopt(pdf, for: id) ?? pdf.path
        }
        status = "Looking up \(id)…"
        if let meta = await Metadata.fetch(arxivID: id) {
            paper.title = meta.title
            paper.authors = meta.authors
            paper.year = meta.year
            paper.venue = meta.venue
            paper.citations = meta.citations
        }
        paper.readOn = Date()

        Library.shared.save(paper)
        refresh()
        select(paper.arxivID)
        showingAdd = false
        status = paper.refs.isEmpty
            ? "Added \(id) — no PDF, so no citation edges yet."
            : "Added \(id) · \(paper.refs.count) references extracted"

        if pdf != nil { startReading(paper) }
    }

    /// A web page as a library entry: keyed off the URL's slug, metadata from
    /// the page itself (LessWrong and friends answer via their API; everyone
    /// else via the page's structured metadata). No PDF, no references — the
    /// entry is a note-holder with a link back to its source.
    private func addWeb(_ url: URL) async {
        let key = WebIngest.key(for: url)
        if Library.shared.paper(withID: key) != nil {
            status = "Already in the library."
            select(key)
            showingAdd = false
            return
        }
        status = "Reading \(url.host ?? "the page")…"
        guard let meta = await WebIngest.fetch(url) else {
            status = "Couldn't read that page — it declared no title."
            return
        }
        var paper = Paper(arxivID: key)
        paper.title = meta.title
        paper.authors = meta.authors
        paper.publishedOn = meta.published
        paper.year = meta.published.map { Calendar.current.component(.year, from: $0) }
        paper.venue = url.host?.replacingOccurrences(of: "www.", with: "") ?? ""
        paper.sourceURL = url.absoluteString
        paper.readOn = Date()
        Library.shared.save(paper)
        refresh()
        select(paper.arxivID)
        showingAdd = false
        status = "Added \(String(meta.title.prefix(50))) · \(paper.venue)"
    }

    // In-app appraisal was removed 2026-09-06 at the user's request: no
    // automatic Claude pass on add, no appraisal row in the header, no
    // Claude-grade badges in the sidebar. The stored appraisal_* fields keep
    // round-tripping (150 files carry them, and the interest sort reads them),
    // and the explicit CLI (`--appraise`, `--rank`) still exists for a
    // deliberate batch pass.

    /// Re-bands the whole library by ranking every paper against every other one.
    /// One call, so it is cheap enough to run whenever the library has grown.
    func rankLibrary() {
        guard !isRanking, Judge.isAvailable else {
            if !Judge.isAvailable { status = "claude CLI not found." }
            return
        }
        let batch = Array(Ranker.rankable(papers).prefix(Ranker.batchLimit))
        guard batch.count >= 4 else { status = "Too few appraised papers to rank."; return }
        isRanking = true
        status = "Ranking \(batch.count) papers against each other…"
        Task.detached {
            let reply = Judge.ask(Ranker.prompt(for: batch), timeout: 600)
            let placed = reply.map {
                Ranker.parse($0, known: Set(batch.map { PDFRefs.normalise($0.arxivID) }))
            } ?? []
            await MainActor.run {
                self.isRanking = false
                // Same rule as the command: a partial ranking would leave most of the
                // shelf carrying positions from a different ordering.
                guard placed.count >= batch.count * 9 / 10 else {
                    self.status = placed.isEmpty
                        ? "The judge did not reply — nothing changed."
                        : "Only \(placed.count) of \(batch.count) came back placed — nothing changed."
                    return
                }
                let byID = Dictionary(uniqueKeysWithValues:
                    batch.map { (PDFRefs.normalise($0.arxivID), $0) })
                Library.shared.batch({ "rank: \($0) papers by how interesting the idea is" }) {
                    for p in placed {
                        guard var paper = byID[p.arxivID] else { continue }
                        paper.appraisal = p.band
                        paper.appraisalRank = p.rank
                        Library.shared.save(paper)
                    }
                }
                self.refresh()
                self.status = "Ranked \(placed.count) papers"
            }
        }
    }

    /// Opens the PDF for reading and gets the two windows onto different screens.
    func startReading(_ paper: Paper) {
        guard !paper.pdfPath.isEmpty else { return }
        Reading.openPDF(paper.resolvedPDF?.path ?? paper.pdfPath)
        // Preview needs a moment to put a window on screen before we can tell
        // which display to avoid.
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            Reading.placeNotesAwayFrom()
            NSApp.activate(ignoringOtherApps: false)
        }
    }

    // MARK: - Judge-backed features

    /// Grades the note in front of you. Judges the note, not the paper: whether
    /// you understood it, what you missed — and answers what you asked.
    ///
    /// Content-addressed: an unchanged note over an unchanged PDF produces the
    /// same key, so pressing the button twice is instant and costs nothing.
    /// `force` is the Grade-again path, which drops the entry first.
    func gradeCurrentNote(force: Bool = false) {
        guard let paper = draft, !isGrading else { return }
        guard paper.isSubstantive else {
            status = "Write something first — there is nothing to grade."
            return
        }
        if !force, let cached = GradeCache.load(GradeCache.key(for: paper)) {
            gradeResult = cached
            gradeWasCached = true
            status = "Graded \(paper.arxivID) · saved from an earlier run"
            return
        }
        guard Judge.isAvailable else { status = "claude CLI not found."; return }

        isGrading = true
        gradeWasCached = false
        let asked = paper.questions
        status = asked.isEmpty
            ? "Grading…"
            : "Reading the paper for your \(asked.count) question\(asked.count == 1 ? "" : "s")…"
        Task.detached {
            let text = GradeCache.grade(paper, force: force).text
            await MainActor.run {
                self.isGrading = false
                guard let text else {
                    self.gradeResult = nil
                    self.status = "The judge did not reply."
                    return
                }
                self.gradeResult = text
                self.status = "Graded \(paper.arxivID)"
            }
        }
    }

    /// Ranks the unread papers your library keeps citing, and looks up what they are.
    ///
    /// Deliberately does *not* judge. Ranking is free — the references are already
    /// extracted — and the lookups take seconds, so this can run the moment the
    /// window opens. Judging is twelve `claude` invocations and minutes of waiting;
    /// spending that because a window was opened is not a decision the app gets to
    /// make on its own.
    func loadRecommendations(limit: Int = 12, fresh: Bool = false) {
        guard !isRecommending else { return }
        isRecommending = true
        recommendations = []
        // The scope decides what counts as evidence: the whole library (minus
        // archived reading), one project's papers, or a single paper.
        let scope = recommendScope
        let library = Recommender.scoped(papers, to: scope)
        guard !library.isEmpty else {
            isRecommending = false
            status = "That scope holds no papers."
            return
        }
        let days = Prefs.freshWindowDays
        Task.detached {
            func note(_ s: String) async { await MainActor.run { self.recommendProgress = s } }

            // 1. Followed authors — only for the whole-library run. A scoped
            //    run is "more like this", and a followed author's new paper
            //    has no relation to the scope.
            var found: [(name: String, papers: [TrustedAuthors.Paper])] = []
            if case .library = scope {
                let names = TrustedAuthors.names()
                for (i, name) in names.enumerated() {
                    await note("Checking \(name) — \(i + 1) of \(names.count)…")
                    found.append((name, await TrustedAuthors.recent(by: name)))
                }
            }
            let fromAuthors = Recommender.authorCandidates(from: library, found: found)

            // 2. Papers like these. The whole-library run seeds from the sharp
            //    end — starred plus top-ranked; a scoped run seeds from the
            //    scope itself, which is the point of scoping. Web entries have
            //    no registry to look up, so only arXiv-shaped keys seed.
            await note("Finding papers like these…")
            let seeds: [String]
            if case .library = scope {
                seeds = (library.filter(\.starred).map(\.arxivID)
                    + library.filter { $0.appraisalRank > 0 }
                        .sorted { $0.appraisalRank < $1.appraisalRank }
                        .prefix(15).map(\.arxivID))
            } else {
                seeds = library.map(\.arxivID)
            }
            let arxivSeeds = seeds.filter { Paper.isArxivID(PDFRefs.normalise($0)) }
            let fromSimilar = Recommender.similarCandidates(
                from: library,
                found: await SemanticScholar.recommendations(seedIDs: Array(Set(arxivSeeds))))

            // 3. Brand new on arXiv, shortlisted locally against the library's
            //    vocabulary before anything expensive runs.
            var feed: [FeedPaper] = []
            let categories = ArxivFeed.categories()
            for (i, cat) in categories.enumerated() {
                await note("Scanning \(cat) — last \(days) days (\(i + 1) of \(categories.count))…")
                feed += await ArxivFeed.recent(category: cat, days: days, useCache: !fresh)
            }
            // The background corpus is the feed itself: the population the
            // candidates are drawn from is exactly the right thing to measure
            // "how distinctive is this term" against.
            let vocabulary = Vocabulary.build(from: library, background: feed)
            let fromFresh = Recommender.freshCandidates(
                from: library, found: feed, vocabulary: vocabulary)

            // 4. What the scope's bibliographies keep pointing at. One paper
            //    cannot agree with itself three times, so the bar drops with
            //    the scope's size.
            let fromCited = Recommender.candidates(
                from: library,
                minimumCiting: Recommender.minimumCiting(for: scope, count: library.count))

            var candidates = Recommender.merge([
                (.fresh, fromFresh), (.similar, fromSimilar),
                (.author(""), fromAuthors), (.cited, fromCited),
            ], limit: limit)

            // Fill in what the feeds did not carry. Author and cited candidates
            // arrive without dates, and the date is what the ordering turns on.
            let total = candidates.count
            for i in candidates.indices {
                guard candidates[i].title.isEmpty || candidates[i].published == nil else { continue }
                await note("Looking up \(i + 1) of \(total)…")
                if let m = await Metadata.fetch(arxivID: candidates[i].arxivID) {
                    if candidates[i].title.isEmpty { candidates[i].title = m.title }
                    if candidates[i].authors.isEmpty { candidates[i].authors = m.authors }
                    candidates[i].year = candidates[i].year ?? m.year
                    candidates[i].citations = m.citations
                    candidates[i].published = candidates[i].published ?? m.published
                }
            }
            let final = Recommender.merge([(.fresh, candidates)], limit: limit)
            await MainActor.run {
                self.recommendations = final
                self.isRecommending = false
                self.recommendProgress = ""
                let fresh = final.filter { ($0.ageInDays ?? 999) <= 31 }.count
                self.status = final.isEmpty
                    ? "Nothing to suggest — try widening the arXiv window or adding authors."
                    : "\(final.count) suggestions · \(fresh) from the last month"
            }
        }
    }

    /// Asks the judge whether each candidate is worth *this reader's* time, then
    /// reorders by verdict. Explicit, because it costs minutes.
    func judgeRecommendations() {
        guard !isRecommending, !recommendations.isEmpty else { return }
        guard Judge.isAvailable else { status = "claude CLI not found."; return }
        isRecommending = true
        // The judge weighs candidates against the same scope that produced
        // them — "worth reading for this project" is a different question
        // from "worth reading at all".
        let library = Recommender.scoped(papers, to: recommendScope)
        var candidates = recommendations
        let total = candidates.count
        Task.detached {
            for i in candidates.indices {
                await MainActor.run { self.recommendProgress = "Judging \(i + 1) of \(total)…" }
                let prompt = Recommender.judgePrompt(candidates[i], library: library)
                if let reply = Judge.ask(prompt, timeout: 120) {
                    let parsed = Recommender.parseVerdict(reply)
                    candidates[i].verdict = parsed.verdict
                    candidates[i].reason = parsed.reason
                } else {
                    candidates[i].verdict = "UNRATED"
                }
                // Publish as they land, so a slow pass is readable while it runs
                // rather than a spinner that hides twelve minutes of work.
                let sofar = candidates
                await MainActor.run { self.recommendations = sofar }
            }
            candidates.sort {
                let l = Recommender.ranking[$0.verdict] ?? 3, r = Recommender.ranking[$1.verdict] ?? 3
                return l == r ? $0.weight > $1.weight : l < r
            }
            let final = candidates
            await MainActor.run {
                self.recommendations = final
                self.isRecommending = false
                self.recommendProgress = ""
                self.status = "Judged \(final.count) candidates"
            }
        }
    }

    /// Adds a recommended paper by id. No PDF, so it arrives catalogued-only until
    /// you drop the file in.
    func addRecommendation(_ c: Recommender.Candidate, queue wantsQueue: Bool = false) {
        Task {
            await add(idOrURL: c.arxivID, pdf: nil)
            if wantsQueue { queue([c.arxivID]) }
        }
        recommendations.removeAll { $0.arxivID == c.arxivID }
    }

    /// Records a no, so the same suggestion does not come back every time.
    func dismissRecommendation(_ c: Recommender.Candidate) {
        TrustedAuthors.dismiss(c.arxivID, title: c.title)
        recommendations.removeAll { $0.arxivID == c.arxivID }
        status = "Won't suggest \(c.title.isEmpty ? c.arxivID : String(c.title.prefix(40))) again"
    }

    /// Opens the list in whatever edits .txt — the file is the interface, so there
    /// is no editor to build here.
    func editTrustedAuthors() {
        TrustedAuthors.bootstrap()
        NSWorkspace.shared.open(TrustedAuthors.fileURL)
    }

    /// Entry point for Finder — "Open With" and the Services menu both land here.
    func ingest(fileURL: URL) {
        guard fileURL.pathExtension.lowercased() == "pdf" else { return }
        Task { await add(idOrURL: fileURL.lastPathComponent, pdf: fileURL) }
    }
}
