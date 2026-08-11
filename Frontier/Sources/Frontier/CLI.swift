import Foundation

@MainActor
enum CLI {
    static func run(_ args: [String]) {
        guard !args.isEmpty else { return }
        // Line-buffered: these commands take minutes, and a redirected log that
        // stays empty until the process exits is indistinguishable from a hang.
        setvbuf(stdout, nil, _IOLBF, 0)
        Store.shared.bootstrap()
        if let i = args.firstIndex(of: "--seed"), i + 1 < args.count { seed(args[i + 1]) }
        if args.contains("--grow") {
            grow(args.firstIndex(of: "--grow").flatMap { args.count > $0 + 1 ? Int(args[$0 + 1]) : nil } ?? 12)
        }
        if let i = args.firstIndex(of: "--write"), i + 1 < args.count { write(args[i + 1]) }
        if args.contains("--syllabus") { syllabus() }
        if args.contains("--latexify") { latexify() }
        if let i = args.firstIndex(of: "--walk"), i + 1 < args.count { walk(args[i + 1]) }
        if args.contains("--verify") { verify() }
        if args.contains("--next") { next() }
        if args.contains("--status") { status() }
    }

    /// Reads a scratch file of half-understood terms and turns it into a graph.
    static func seed(_ path: String) -> Never {
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
        let proposed = Tutor.expand(seeds: seeds, existing: Store.shared.concepts, count: 18)
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
