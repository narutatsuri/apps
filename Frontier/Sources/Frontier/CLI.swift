import AppKit
import Foundation
import WebKit

@MainActor
enum CLI {
    static func run(_ args: [String]) {
        guard !args.isEmpty else { return }
        // Line-buffered: these commands take minutes, and a redirected log that
        // stays empty until the process exits is indistinguishable from a hang.
        setvbuf(stdout, nil, _IOLBF, 0)
        Store.shared.bootstrap()
        if let i = args.firstIndex(of: "--seed"), i + 1 < args.count {
            // An optional count: a scratch list of thirty terms does not fit in
            // eighteen concepts, and the shortfall is silent — you get a graph
            // that looks fine and quietly omits a third of what you wrote down.
            seed(args[i + 1], count: args.count > i + 2 ? Int(args[i + 2]) : nil)
        }
        if args.contains("--grow") {
            grow(args.firstIndex(of: "--grow").flatMap { args.count > $0 + 1 ? Int(args[$0 + 1]) : nil } ?? 12)
        }
        if let i = args.firstIndex(of: "--write"), i + 1 < args.count { write(args[i + 1]) }
        if let i = args.firstIndex(of: "--import"), i + 1 < args.count {
            let name = args.firstIndex(of: "--name")
                .flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
            importResource(args[i + 1], name: name, planOnly: args.contains("--plan"))
        }
        if args.contains("--syllabus") { syllabus() }
        if args.contains("--latexify") { latexify() }
        if let i = args.firstIndex(of: "--walk"), i + 1 < args.count { walk(args[i + 1]) }
        if args.contains("--verify") { verify() }
        if args.contains("--next") { next() }
        if args.contains("--courses") { courses(raw: args.contains("--raw")) }
        if args.contains("--relink") { relink(apply: args.contains("--apply")) }
        if let i = args.firstIndex(of: "--page"), i + 1 < args.count { page(args[i + 1]) }
        if let i = args.firstIndex(of: "--mark"), i + 2 < args.count {
            // An optional third argument is the score, 0…1, so the scheduler
            // can be driven from the command line the way a test drives it.
            mark(args[i + 1], args[i + 2],
                 score: args.count > i + 3 ? Double(args[i + 3]) : nil)
        }
        if let i = args.firstIndex(of: "--retest"), i + 1 < args.count { retest(args[i + 1]) }
        if let i = args.firstIndex(of: "--test"), i + 1 < args.count { showTest(args[i + 1]) }
        if args.contains("--status") { status() }
        if args.contains("--bench") { bench() }
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count { render(args[i + 1]) }
    }

    /// Reads a scratch file of half-understood terms and turns it into a graph.
    static func seed(_ path: String, count: Int? = nil) -> Never {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("cannot read \(path)"); exit(1)
        }
        // Anything that reads like a term rather than prose: short lines, and
        // headings. The file is someone's scratchpad, not a format.
        var seeds: [String] = []
        for raw in text.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let f = line.first, "-*•\"".contains(f) { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line.count < 90, line.split(separator: " ").count <= 12,
                  !line.hasPrefix("http") else { continue }
            seeds.append(line)
        }
        print("read \(seeds.count) seed terms from \(path)")
        for s in seeds.prefix(30) { print("   · \(s)") }
        guard Tutor.isAvailable else { print("\nclaude CLI not found"); exit(1) }
        print("\nasking for a first pass of the graph…")
        // Room for the terms themselves plus the prerequisites they turn out to
        // need — asking for exactly as many concepts as terms guarantees the
        // graph has holes the moment one of them rests on something missing.
        let wanted = count ?? max(18, seeds.count + seeds.count / 2)
        print("asking for \(wanted) concepts")
        let proposed = Tutor.expand(seeds: seeds, existing: Store.shared.concepts, count: wanted)
        let added = Store.shared.add(proposed)
        print("added \(added) concepts (\(proposed.count) proposed)")
        report()
        exit(0)
    }

    static func grow(_ count: Int) -> Never {
        guard Tutor.isAvailable else { print("claude CLI not found"); exit(1) }
        let existing = Store.shared.concepts
        // The graph's own holes are the best prompt for what to add next.
        print("reading the syllabi…")
        let fetched = Courses.all.compactMap { course -> (name: String, topics: [String])? in
            let topics = Courses.topics(of: course)
            return topics.isEmpty ? nil : (course.name, topics)
        }
        print("growing by \(count), following \(fetched.count) courses…")
        let proposed = fetched.isEmpty
            ? Tutor.expand(seeds: Frontier.missing(existing), existing: existing, count: count)
            : Tutor.next(from: fetched, existing: existing, count: count)
        print("added \(Store.shared.add(proposed)) concepts")
        report()
        exit(0)
    }

    static func write(_ id: String) -> Never {
        guard var c = Store.shared.concept(id) else { print("no concept: \(id)"); exit(1) }
        guard Tutor.isAvailable else { print("claude CLI not found"); exit(1) }
        print("writing \(c.title)…")
        guard let written = Tutor.write(c, context: Store.shared.concepts) else {
            print("the model did not answer — \(Tutor.lastError ?? "no detail")"); exit(1)
        }
        c.body = written.body
        c.questions = written.questions
        c.sources = written.sources.map { s in
            var s = s
            s.reachable = SourceCheck.reachable(s.url)
            return s
        }
        Store.shared.save(c)
        print(c.body)
        print("\nsources:")
        for s in c.sources {
            let mark = s.reachable == false ? "✗ unreachable" : (s.reachable == true ? "✓" : "?")
            print("  \(mark) \(s.title) — \(s.url)")
        }
        exit(0)
    }

    /// `--import <pdf-or-url> [--name "…"]` — one resource, covered end to end.
    ///
    /// Unlike --syllabus, which unions courses into a curriculum, this takes a
    /// single resource the reader has chosen — the RLHF book, a course PDF, a
    /// long post — and turns *all of it* into chained concepts, so the daily
    /// session walks through it front to back.
    static func importResource(_ spec: String, name: String?, planOnly: Bool = false) -> Never {
        if !planOnly { guard Tutor.isAvailable else { print("claude CLI not found"); exit(1) } }
        print("loading \(spec)…")
        guard let loaded = Resource.load(spec, nameOverride: name) else {
            print("could not read \(spec) — give a PDF path or an http(s) URL"); exit(1)
        }
        let batches = Resource.batches(loaded.sections)
        let chars = loaded.sections.reduce(0) { $0 + $1.text.count }
        print("\"\(loaded.name)\" — \(loaded.sections.count) sections, \(chars / 1000)k chars, "
              + "\(batches.count) model call\(batches.count == 1 ? "" : "s")")
        for s in loaded.sections.prefix(40) { print("   · \(s.title)  (\(s.text.count / 1000)k)") }
        // --plan: what would be read and how many calls it costs, without
        // spending any of them. The way to check an extraction before a
        // twenty-minute import trusts it.
        if planOnly { exit(0) }

        var proposed: [Concept] = []
        var addedTotal = 0
        for (i, batch) in batches.enumerated() {
            print("\n[\(i + 1)/\(batches.count)] \(batch.map(\.title).joined(separator: " · ").prefix(90))")
            let concepts = Tutor.digest(
                resource: loaded.name,
                sections: batch.map { ($0.title, $0.text) },
                existing: Store.shared.concepts, proposed: proposed)
            guard !concepts.isEmpty else {
                print("   nothing came back — \(Tutor.lastError ?? "no detail")")
                continue
            }
            proposed += concepts
            let added = Store.shared.add(concepts)
            addedTotal += added
            for c in concepts { print("   + \(c.id)  [\(c.area.label)]") }
            if added < concepts.count { print("   (\(concepts.count - added) already existed)") }
        }
        print("\nimported \(addedTotal) concepts from \"\(loaded.name)\"")
        report()
        exit(addedTotal > 0 ? 0 : 1)
    }

    static func walk(_ id: String) -> Never {
        guard var c = Store.shared.concept(id) else { print("no concept: \(id)"); exit(1) }
        guard Tutor.isAvailable else { print("claude CLI not found"); exit(1) }
        print("walking through \(c.title)…")
        guard let text = Tutor.walkthrough(c, context: Store.shared.concepts) else {
            print("no answer — \(Tutor.lastError ?? "no detail")"); exit(1)
        }
        c.walkthrough = text
        Store.shared.save(c)
        print(text)
        exit(0)
    }

    static func verify() -> Never {
        var checked = 0, broken = 0
        for var c in Store.shared.concepts where !c.sources.isEmpty {
            c.sources = c.sources.map { s in
                var s = s
                s.reachable = SourceCheck.reachable(s.url)
                checked += 1
                if s.reachable == false { broken += 1; print("  ✗ \(c.id): \(s.url)") }
                return s
            }
            Store.shared.save(c)
        }
        print("checked \(checked) sources, \(broken) unreachable")
        exit(0)
    }

    /// Rebuilds the curriculum from what real courses teach.
    static func syllabus() -> Never {
        guard Tutor.isAvailable else { print("claude CLI not found"); exit(1) }
        print("reading \(Courses.all.count) syllabi…")
        var fetched: [(name: String, topics: [String])] = []
        for course in Courses.all {
            let topics = Courses.topics(of: course)
            print("  \(topics.isEmpty ? "✗" : "✓") \(topics.count) lines — \(course.name)")
            if !topics.isEmpty { fetched.append((course.name, topics)) }
        }
        guard !fetched.isEmpty else { print("no syllabus could be read"); exit(1) }
        print("\nsynthesising — this takes a few minutes…")
        let proposed = Tutor.synthesise(courses: fetched, existing: Store.shared.concepts)
        if proposed.isEmpty { print("no answer — \(Tutor.lastError ?? "no detail")"); exit(1) }
        print("added \(Store.shared.add(proposed)) of \(proposed.count) proposed")
        report()
        exit(0)
    }

    static func latexify() -> Never {
        guard Tutor.isAvailable else { print("claude CLI not found"); exit(1) }
        let all = Store.shared.concepts
        print("rewriting mathematics as LaTeX in \(all.count) concepts…")
        let rewritten = Tutor.latexify(all)
        guard !rewritten.isEmpty else {
            print("no answer — \(Tutor.lastError ?? "no detail")"); exit(1)
        }
        var changed = 0
        for var c in all {
            guard let new = rewritten[c.id] else { continue }
            // Only the two fields, and only when they actually differ: this is
            // a transcription, so anything else changing is a mistake.
            guard new.title != c.title || new.relevance != c.relevance else { continue }
            c.title = new.title
            c.relevance = new.relevance
            Store.shared.save(c)
            changed += 1
            print("  \(c.id)")
        }
        print("\nrewrote \(changed) of \(all.count)")
        exit(0)
    }

    static func next() -> Never {
        let all = Store.shared.concepts
        guard !all.isEmpty else { print("Nothing yet — run --seed <file>."); exit(0) }
        print("Today:")
        for c in Frontier.session(all) {
            let mark = c.isWritten ? " " : " (not written yet)"
            print("\n  \(c.title)  [\(c.area.label)]\(mark)")
            if !c.relevance.isEmpty { print("    \(c.relevance)") }
            if !c.requires.isEmpty { print("    rests on: \(c.requires.joined(separator: ", "))") }
        }
        exit(0)
    }

    static func status() -> Never { report(); exit(0) }

    /// `--retest <id>` — write a fresh test for an entry that already exists.
    static func retest(_ id: String) -> Never {
        guard var c = Store.shared.concept(id) else { print("no concept: \(id)"); exit(1) }
        guard c.isWritten else { print("\(c.title) has no entry to test on"); exit(1) }
        guard Tutor.isAvailable else { print("claude CLI not found"); exit(1) }
        print("writing a test for \(c.title)…")
        let questions = Tutor.retest(c)
        guard !questions.isEmpty else {
            print("nothing came back — \(Tutor.lastError ?? "no detail")"); exit(1)
        }
        c.questions = questions
        Store.shared.save(c)
        print("\n" + Concept.markdown(for: questions))
        exit(0)
    }

    /// `--test <id>` — the questions as stored, so a generated test can be read
    /// and a hand-edited one checked without opening the app.
    static func showTest(_ id: String) -> Never {
        guard let c = Store.shared.concept(id) else { print("no concept: \(id)"); exit(1) }
        guard !c.questions.isEmpty else {
            print("\(c.title) has no test. --retest \(id) writes one."); exit(1)
        }
        let choice = c.questions.filter { !$0.isWritten }.count
        print("\(c.title) — \(c.questions.count) questions "
              + "(\(choice) multiple choice, \(c.questions.count - choice) written)")
        if let s = c.lastScore { print("last attempt: \(Int((s * 100).rounded()))%") }
        print()
        print(Concept.markdown(for: c.questions))
        exit(0)
    }

    /// `--relink` — point prerequisites at the concepts they meant.
    ///
    /// Prints the repairs and changes nothing; `--relink --apply` writes them.
    /// A dry run by default because this edits every file it touches and the
    /// matching is a heuristic: the list is meant to be read.
    static func relink(apply: Bool) -> Never {
        let all = Store.shared.concepts
        let (fixed, repairs) = Frontier.relinked(all)
        guard !repairs.isEmpty else {
            print("every prerequisite already points at a concept that exists.")
            let loose = Frontier.missing(all)
            if !loose.isEmpty {
                print("\n\(loose.count) genuinely undefined — nothing in the graph is close:")
                for l in loose { print("   \(l)") }
            }
            exit(0)
        }
        print("\(repairs.count) prerequisite\(repairs.count == 1 ? "" : "s") "
              + "point\(repairs.count == 1 ? "s" : "") at a concept that does not exist "
              + "but plainly meant one that does:\n")
        for r in repairs {
            print("  \(r.concept)")
            print("      \(r.from)")
            print("   →  \(r.to)")
        }
        // A repair joins two concepts that were not joined before, so it can
        // close a loop — and a cycle makes both ends permanently unreachable,
        // which is a worse outcome than the dangling edge it replaced.
        let cyclesBefore = Frontier.cycles(all).count
        let cyclesAfter = Frontier.cycles(fixed).count
        if cyclesAfter > cyclesBefore {
            print("\n⚠️  this would create \(cyclesAfter - cyclesBefore) cycle(s) — "
                  + "a cycle makes both concepts unreachable. Not safe to apply as is:")
            for cycle in Frontier.cycles(fixed) { print("   \(cycle.joined(separator: " → "))") }
        }
        let after = Frontier.missing(fixed)
        print("\nloose ends: \(Frontier.missing(all).count) → \(after.count)"
              + "   ·   cycles: \(cyclesBefore) → \(cyclesAfter)")
        if !after.isEmpty {
            print("still undefined — these look like concepts the graph really lacks:")
            for l in after { print("   \(l)") }
        }
        guard apply else {
            print("\nnothing written. Re-run with --relink --apply to make these changes.")
            exit(0)
        }
        guard cyclesAfter <= cyclesBefore else {
            print("\nrefusing to apply: it would make concepts unreachable.")
            exit(1)
        }
        var written = 0
        let changed = Set(repairs.map(\.concept))
        for c in fixed where changed.contains(c.id) { Store.shared.save(c); written += 1 }
        print("\nrewrote \(written) concept file\(written == 1 ? "" : "s").")
        exit(0)
    }

    /// `--page <url>` — the text a real web view gets from a page, verbatim.
    ///
    /// "The scrape came back thin" has two very different causes — the page did
    /// not render, or it rendered and the line filter threw the content away —
    /// and they are indistinguishable from a line count.
    static func page(_ target: String) -> Never {
        guard let url = URL(string: target) else { print("not a url: \(target)"); exit(1) }
        guard let text = MainActor.assumeIsolated({ PageReader.readPumping(url) }) else {
            print("nothing rendered"); exit(1)
        }
        let lines = text.components(separatedBy: "\n")
        print("\(text.count) chars, \(lines.count) lines\n")
        for line in lines.prefix(60) {
            print("  [\(line.count)] \(line.replacingOccurrences(of: "\t", with: " ⇥ ").prefix(150))")
        }
        exit(0)
    }

    /// `--courses` — what each syllabus actually yields, without spending a
    /// model call to find out.
    ///
    /// "The curriculum is the union of six courses" is only true if all six can
    /// be read, and two of them build their schedule with JavaScript. This is
    /// how that is checked: line counts per course, and `--raw` to compare
    /// against the old served-HTML path. It exits non-zero if any course comes
    /// back with less than a syllabus' worth, so a page that quietly changes
    /// shape is noticed before it silently narrows the graph.
    static func courses(raw: Bool) -> Never {
        print("reading \(Courses.all.count) syllabi — served HTML and rendered, "
              + "the better of the two is used\n")
        print("   html  rendered   used   course")
        var thin: [String] = []
        for course in Courses.all {
            let (rawLines, rendered) = Courses.bothReadings(course)
            let used = max(rawLines.count, rendered.count)
            let winner = rendered.count > rawLines.count ? "rendered" : "html"
            let mark = used >= 60 ? "✓" : (used == 0 ? "✗" : "·")
            print("\(mark) \(String(format: "%5d", rawLines.count))"
                  + "  \(String(format: "%8d", rendered.count))"
                  + "  \(String(format: "%5d", used)) (\(winner))  \(course.name)")
            if used < 60 { thin.append(course.name) }
            if raw {
                for line in (rendered.count > rawLines.count ? rendered : rawLines).prefix(4) {
                    print("           \(line.prefix(86))")
                }
            }
        }
        if thin.isEmpty {
            print("\nall \(Courses.all.count) syllabi read")
        } else {
            print("\n\(thin.count) thin: \(thin.joined(separator: "; "))")
        }
        exit(thin.isEmpty ? 0 : 1)
    }

    /// `--mark <id> known|learning|unread` — the two buttons at the bottom of
    /// the reading pane, headlessly.
    ///
    /// Marking is where the revisit schedule is set, and "the concept moved to
    /// Coming back and returns in three days" is a claim about live data that
    /// otherwise needs a person with a mouse. Prints what the schedule became.
    static func mark(_ id: String, _ status: String, score: Double? = nil) -> Never {
        guard let wanted = Concept.Status(rawValue: status) else {
            print("status must be one of: \(Concept.Status.allCases.map(\.rawValue).joined(separator: ", "))")
            exit(1)
        }
        guard var c = Store.shared.concept(id) else { print("no concept: \(id)"); exit(1) }
        c.status = wanted
        c.learnedOn = wanted == .known ? Date() : nil
        if wanted == .learning {
            // No test taken, so no evidence: a middling score, which holds the
            // gap where it is rather than growing it on nothing.
            let next = Frontier.nextDue(for: c, score: score ?? 0.6)
            c.lastScore = score
            c.dueOn = next.due
            c.intervalDays = next.interval
            c.revisits += 1
        } else {
            c.dueOn = nil
        }
        Store.shared.save(c)
        print("\(c.title) → \(wanted.label)"
              + (c.revisitDescription().map { ", \($0) (pass \(c.revisits))" } ?? ""))
        let session = Frontier.session(Store.shared.concepts)
        print("\nToday is now:")
        for s in session {
            print("  \(s.title)\(s.status == .learning ? "  [carried over]" : "")")
        }
        exit(0)
    }

    /// `--render <id|all>` — push a concept's document through the real bundled
    /// renderer, offscreen, and report whether anything comes out.
    ///
    /// "The pane went blank when I clicked X" is a claim about one concept's
    /// content meeting the renderer; this answers it for every concept in
    /// seconds, without clicking 275 times. Renders are serialised — one web
    /// view, one DOM, and two concurrent renders race (a known gotcha).
    static func render(_ target: String) -> Never {
        let all = Store.shared.concepts
        let subjects = target.lowercased() == "all" ? all : all.filter { $0.id == target }
        guard !subjects.isEmpty else { print("no concept: \(target)"); exit(1) }
        guard let html = Bundle.main.url(forResource: "render", withExtension: "html",
                                         subdirectory: "web") else {
            print("render.html is not in this build — run the installed app's binary"); exit(1)
        }
        let verbose = subjects.count == 1
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())

        var i = 0, failures = 0
        func step(retry: Int = 0) {
            if i == subjects.count {
                print(failures == 0
                      ? "all \(subjects.count) concepts render"
                      : "\(failures) of \(subjects.count) FAILED to render")
                exit(failures == 0 ? 0 : 1)
            }
            let c = subjects[i]
            let doc = c.document(preferWalkthrough: false)
            let json = String(data: (try? JSONSerialization.data(withJSONObject: [doc]))
                                ?? Data(), encoding: .utf8) ?? "[\"\"]"
            web.evaluateJavaScript(
                "window.renderMarkdown ? (renderMarkdown(\(json)[0]), "
                + "document.getElementById('out').innerHTML.length) : -1") { value, error in
                let n = (value as? Int) ?? -2
                if n == -1 {           // page still loading; wait, do not advance
                    guard retry < 100 else { print("renderer never became ready"); exit(1) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { step(retry: retry + 1) }
                    return
                }
                if let error {
                    failures += 1
                    print("  ✗ \(c.id) — \(error.localizedDescription)")
                } else if n <= 0 {
                    failures += 1
                    print("  ✗ \(c.id) — rendered to nothing")
                } else if verbose {
                    print("  ✓ \(c.id) — \(n) chars of HTML")
                }
                i += 1
                step()
            }
        }
        DispatchQueue.main.async { step() }
        app.run()
        exit(failures == 0 ? 0 : 1)
    }

    /// `--bench` — how long the graph mathematics takes on the *real* store.
    ///
    /// Exists because "the graph overloads the PC" is a claim about milliseconds,
    /// and milliseconds are measurable. The draw-loop number is what one Canvas
    /// frame used to cost when every node recomputed the downstream cones.
    static func bench() -> Never {
        let all = Store.shared.concepts
        func time(_ label: String, _ runs: Int = 1, _ work: () -> Void) {
            let t0 = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<runs { work() }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / Double(runs)
            print(String(format: "  %-46s %8.2f ms", (label as NSString).utf8String!, ms))
        }
        print("\(all.count) concepts")
        time("Frontier.unlocks, once", 5) { _ = Frontier.unlocks(all) }
        time("Frontier.ready, once", 5) { _ = Frontier.ready(all) }
        time("Frontier.session, once", 5) { _ = Frontier.session(all) }
        time("one graph frame, old draw (unlocks per node)") {
            for _ in all { _ = Frontier.unlocks(all) }
        }
        time("one graph frame, cached (lookups only)") {
            let unlocks = Frontier.unlocks(all)
            for c in all { _ = unlocks[c.id] }
        }
        exit(0)
    }

    static func report() {
        let all = Store.shared.concepts
        let known = all.filter(\.isKnown).count
        let written = all.filter(\.isWritten).count
        print("\n\(all.count) concepts · \(known) known · \(written) written "
              + "· \(Frontier.ready(all).count) ready to learn")
        var byArea: [Concept.Area: Int] = [:]
        for c in all { byArea[c.area, default: 0] += 1 }
        for (area, n) in byArea.sorted(by: { $0.value > $1.value }) {
            print("   \(area.label.padding(toLength: 14, withPad: " ", startingAt: 0)) \(n)")
        }
        let missing = Frontier.missing(all)
        if !missing.isEmpty {
            print("   \(missing.count) prerequisites not yet in the graph — run --grow")
        }
        for cycle in Frontier.cycles(all) {
            print("   ⚠ cycle: \(cycle.joined(separator: " → "))")
        }
    }
}
