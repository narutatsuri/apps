import SwiftUI

/// What the window is looking at, and the few things it can do.
@MainActor
final class Model: ObservableObject {
    @Published var concepts: [Concept] = []
    @Published var selected: String?
    @Published var busy: String?
    /// Set when a background job says something worth reading — a count, or a
    /// reason it could not run.
    @Published var note: String?

    /// Stored, not computed. These walk the whole dependency graph (~9 ms at
    /// 275 concepts, measured with --bench), and as computed properties the
    /// sidebar recomputed them for every row of every body evaluation — a
    /// hundred milliseconds per click. Statuses only change through this
    /// class, so recomputing on load() is both cheaper and still correct.
    @Published private(set) var session: [Concept] = []
    @Published private(set) var ready: [Concept] = []
    /// Marked "still learning" and waiting for their next turn, soonest first.
    /// Shown in their own section: a concept that drops out of the running with
    /// nowhere to see it again reads as one the app lost.
    @Published private(set) var deferred: [Concept] = []

    func load() {
        Store.shared.bootstrap()
        concepts = Store.shared.concepts
        let now = Date()
        session = Frontier.session(concepts, now: now)
        // `ready` means actionable this morning, which is what the sidebar
        // section says it means; the scheduled ones are listed separately.
        let frontier = Frontier.ready(concepts, now: now)
        deferred = frontier.filter { $0.isDeferred(at: now) }
            .sorted { ($0.dueOn ?? .distantFuture) < ($1.dueOn ?? .distantFuture) }
        ready = frontier.filter { !$0.isDeferred(at: now) }
        if selected == nil { selected = session.first?.id }
    }

    var current: Concept? { selected.flatMap { id in concepts.first { $0.id == id } } }

    func mark(_ concept: Concept, _ status: Concept.Status) {
        var c = concept
        c.status = status
        c.learnedOn = status == .known ? Date() : nil
        switch status {
        case .learning:
            // Reached only when something other than a test says "not yet" —
            // the CLI, or a concept with no test written. A middling score, so
            // the gap holds rather than growing on no evidence.
            record(score: 0.6, for: c)
            return
        case .known, .unread:
            // Learned, or reset: nothing is owed. The history stays as a record
            // of how many passes it took and how the last one went.
            c.dueOn = nil
        }
        Store.shared.save(c)
        load()
        // Learning something changes what is ready, so the next pick is
        // recomputed rather than left stale.
        if status == .known, selected == concept.id { selected = session.first?.id }
    }

    /// Files a test result, and schedules the concept from it.
    ///
    /// This is what the "Still learning" button used to do badly. Pressing a
    /// button is not evidence about what you know, so the gap grew whether or
    /// not you were learning; a score is evidence, so the gap now follows it.
    func record(score: Double, for concept: Concept) {
        var c = concept
        c.status = .learning
        c.lastScore = score
        let next = Frontier.nextDue(for: c, score: score)
        c.dueOn = next.due
        c.intervalDays = next.interval
        c.revisits += 1
        Store.shared.save(c)
        load()
    }

    /// Writes the entry for a concept. Off the main thread — the CLI takes
    /// minutes, and a frozen window is not a progress indicator.
    func write(_ concept: Concept) {
        guard busy == nil else { return }
        guard Tutor.isAvailable else {
            note = "The claude CLI was not found. Frontier writes entries by shelling out to it."
            return
        }
        busy = concept.id
        let context = concepts
        Task.detached {
            let written = Tutor.write(concept, context: context)
            await MainActor.run {
                self.busy = nil
                guard let written else { self.note = "No answer from the model."; return }
                var c = concept
                c.body = written.body
                c.questions = written.questions
                c.sources = written.sources
                Store.shared.save(c)
                self.load()
            }
            // Link checking is slower than writing and matters less, so the
            // entry appears first and the ticks arrive after.
            let checked = written?.sources.map { s -> Concept.Source in
                var s = s; s.reachable = SourceCheck.reachable(s.url); return s
            } ?? []
            await MainActor.run {
                guard var c = Store.shared.concept(concept.id), !checked.isEmpty else { return }
                c.sources = checked
                Store.shared.save(c)
                self.load()
            }
        }
    }

    /// Writes a test for an entry that has none.
    ///
    /// New entries come with one — the same call that writes the entry writes
    /// the questions, so they are about what the page actually says. This is for
    /// the entries that predate that, and for when the questions have gone stale.
    func retest(_ concept: Concept) {
        guard busy == nil else { return }
        guard Tutor.isAvailable else { note = "The claude CLI was not found."; return }
        busy = concept.id
        Task.detached {
            let questions = Tutor.retest(concept)
            await MainActor.run {
                self.busy = nil
                guard !questions.isEmpty else {
                    self.note = "No test came back — \(Tutor.lastError ?? "no detail")"
                    return
                }
                var c = concept
                c.questions = questions
                Store.shared.save(c)
                self.load()
            }
        }
    }

    /// Generates the walked-through version.
    func explain(_ concept: Concept) {
        guard busy == nil else { return }
        guard Tutor.isAvailable else { note = "The claude CLI was not found."; return }
        busy = concept.id
        let context = concepts
        Task.detached {
            let text = Tutor.walkthrough(concept, context: context)
            await MainActor.run {
                self.busy = nil
                guard let text, !text.isEmpty else {
                    self.note = "No answer — \(Tutor.lastError ?? "no detail")"
                    return
                }
                var c = concept
                c.walkthrough = text
                Store.shared.save(c)
                self.load()
            }
        }
    }

    /// One resource, covered end to end. What "Import" in the toolbar runs.
    @Published var importProgress: String?

    func importResource(_ spec: String) {
        guard busy == nil else { return }
        guard Tutor.isAvailable else { note = "The claude CLI was not found."; return }
        busy = "import"
        importProgress = "Reading it…"
        let existing = concepts
        Task.detached {
            guard let loaded = Resource.load(spec.trimmingCharacters(in: .whitespaces)) else {
                await MainActor.run {
                    self.busy = nil; self.importProgress = nil
                    self.note = "Could not read that — give a PDF path or an http(s) URL."
                }
                return
            }
            let batches = Resource.batches(loaded.sections)
            var proposed: [Concept] = []
            var addedTotal = 0
            for (i, batch) in batches.enumerated() {
                await MainActor.run {
                    self.importProgress = "\(loaded.name) — section \(i + 1) of \(batches.count)…"
                }
                let concepts = Tutor.digest(
                    resource: loaded.name,
                    sections: batch.map { ($0.title, $0.text) },
                    existing: existing, proposed: proposed)
                proposed += concepts
                // Saved as they arrive, so a failure halfway keeps the chapters
                // already digested rather than discarding twenty minutes.
                addedTotal += await MainActor.run { Store.shared.add(concepts) }
                await MainActor.run { self.load() }
            }
            let total = addedTotal, name = loaded.name
            await MainActor.run {
                self.busy = nil; self.importProgress = nil
                self.note = total == 0
                    ? "Nothing came back — \(Tutor.lastError ?? "no detail")."
                    : "Imported \(total) concepts from \(name). The daily session now walks through it in order."
                self.load()
            }
        }
    }

    /// Extends the graph, filling its own holes first.
    func grow(_ count: Int = 12) {
        guard busy == nil else { return }
        guard Tutor.isAvailable else {
            note = "The claude CLI was not found."
            return
        }
        busy = "grow"
        let existing = concepts
        Task.detached {
            // From the courses, not from thin air: extending the graph should
            // continue the syllabi it was built from.
            let fetched = Courses.all.compactMap { course -> (name: String, topics: [String])? in
                let topics = Courses.topics(of: course)
                return topics.isEmpty ? nil : (course.name, topics)
            }
            let proposed = fetched.isEmpty
                ? Tutor.expand(seeds: Frontier.missing(existing), existing: existing, count: count)
                : Tutor.next(from: fetched, existing: existing, count: count)
            await MainActor.run {
                let added = Store.shared.add(proposed)
                self.busy = nil
                self.note = added == 0 ? "Nothing new came back." : "Added \(added) concepts."
                self.load()
            }
        }
    }
}
