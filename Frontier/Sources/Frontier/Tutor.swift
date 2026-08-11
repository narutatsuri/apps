import Foundation

/// The `claude` CLI, used to grow the curriculum and to write it.
///
/// The app has no model inside it, but the CLI is on this machine and already
/// authenticated, so it is shelled out to the way `git` is.
///
/// Everything here is written against one worry: a fluent, confident, wrong
/// sentence about warp scheduling is worse than no sentence, because there is
/// nothing in it that looks wrong. So the prompts do not ask for an explanation;
/// they ask for claims with sources attached, and require anything the model is
/// not sure of to be marked rather than smoothed over. The reader then has
/// somewhere to go when a line smells off.
enum Tutor {
    static var cliPath: String? {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool { cliPath != nil }

    /// Reports how long it took and why it stopped, because a silent nil
    /// after four minutes is indistinguishable from a broken CLI.
    static var lastError: String?

    static func ask(_ prompt: String, timeout: TimeInterval = 600) -> String? {
        let started = Date()
        guard let cli = cliPath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        // Tools off, explicitly.
        //
        // Left on, the CLI decides it wants to read a file or run a command to
        // check something, and in a nested session those calls never return —
        // the same prompt hung for twenty minutes and then answered in seventy
        // seconds with this flag. Nothing here needs a tool: the model is being
        // asked what it knows, and the app checks the links itself afterwards.
        p.arguments = ["-p", "--disallowedTools",
                       "WebSearch,WebFetch,Bash,Read,Write,Edit,Glob,Grep,Task,NotebookEdit"]

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        do { try p.run() } catch { lastError = "could not launch \(cli)"; return nil }
        stdin.fileHandleForWriting.write(Data(prompt.utf8))
        stdin.fileHandleForWriting.closeFile()

        // Both pipes are drained, each on its own queue.
        //
        // A pipe nobody reads holds 64 KB and then blocks the writer forever.
        // Draining stdout alone is not enough: this hung for the full ten-minute
        // timeout on longer prompts while a one-line prompt returned in three
        // seconds, because the difference was how much the CLI had written to
        // *stderr* before it blocked.
        var output = Data(), errors = Data()
        let lock = NSLock()
        let group = DispatchGroup()
        DispatchQueue(label: "tutor.out").async(group: group) {
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); output = data; lock.unlock()
        }
        DispatchQueue(label: "tutor.err").async(group: group) {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); errors = data; lock.unlock()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { usleep(100_000) }
        if p.isRunning {
            p.terminate()
            lastError = "timed out after \(Int(timeout))s"
            return nil
        }
        p.waitUntilExit()
        // Wait for the readers rather than sleeping and hoping.
        _ = group.wait(timeout: .now() + 10)
        lock.lock(); let data = output; let errorData = errors; lock.unlock()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let seconds = Int(Date().timeIntervalSince(started))
        if text?.isEmpty ?? true {
            let err = String(data: errorData, encoding: .utf8) ?? ""
            lastError = "empty reply after \(seconds)s"
                + (err.isEmpty ? "" : " — \(err.prefix(200))")
            return nil
        }
        lastError = "answered in \(seconds)s"
        return text
    }

    /// Who this is for. Prepended to every prompt, because "explain paged
    /// attention" to a first-year and to someone who works on LLM safety are
    /// different requests, and the second one is the only one worth writing.
    static let reader = """
        The reader is a computer science PhD student working on empirical LLM \
        safety — reasoning-model robustness, misalignment, self-improvement, \
        chain-of-thought monitorability. Strong maths and theory background. \
        They train and serve models and want to understand the systems and \
        hardware underneath rigorously, not by analogy. Assume they know \
        transformers, attention, standard optimisation, and PyTorch. Do not \
        explain those. Assume they do not know internals they have never had to \
        implement — GPU memory hierarchy, kernel scheduling, collective \
        communication, serving internals — unless the graph says otherwise.
        """

    // MARK: - Growing the graph

    /// Proposes concepts to add, each with what it rests on.
    ///
    /// Asked for prerequisites *by id* so the result is a graph rather than a
    /// list; a curriculum without edges cannot tell you what to read first.
    static func expand(seeds: [String], existing: [Concept], count: Int = 12) -> [Concept] {
        let known = existing.map { "\($0.id) — \($0.title) [\($0.status.rawValue)]" }
            .joined(separator: "\n")
        let prompt = """
            \(reader)

            You are building a dependency graph of concepts they should master \
            to be genuinely well-rounded — not only the areas they already work \
            in. Hardware and systems are a known gap and deserve weight, but so \
            do training at scale, architectures, evaluation, and the theory they \
            will need to read others' work.

            Concepts already in the graph (do not repeat these ids):
            \(known.isEmpty ? "(none yet)" : known)

            Seeds the reader wrote down as things they do not understand:
            \(seeds.isEmpty ? "(none)" : seeds.map { "- \($0)" }.joined(separator: "\n"))

            Propose \(count) concepts. Cover the seeds first, then whatever the \
            graph most obviously lacks. Include prerequisites even if they are \
            elementary — a graph with holes teaches in the wrong order.

            Output one concept per block, exactly this format, nothing else:

            ID: kebab-case-id
            TITLE: Human readable title
            AREA: one of hardware, systems, training, architecture, theory, safety, evaluation, tooling
            REQUIRES: comma-separated ids, or none
            RELEVANCE: one sentence on why this specific reader should know it. Concrete. Not "it is fundamental". LaTeX for any mathematics, as $…$.
            ---
            """
        guard let reply = ask(prompt) else { return [] }
        return parse(reply)
    }

    static func parse(_ reply: String) -> [Concept] {
        var out: [Concept] = []
        for block in reply.components(separatedBy: "---") {
            var fields: [String: String] = [:]
            for line in block.components(separatedBy: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).uppercased()
                let value = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                if ["ID", "TITLE", "AREA", "REQUIRES", "RELEVANCE", "COURSES"].contains(key) {
                    fields[key] = value
                }
            }
            guard let rawID = fields["ID"], !rawID.isEmpty, let title = fields["TITLE"],
                  !title.isEmpty else { continue }
            var c = Concept(id: Concept.slug(rawID), title: title)
            c.area = Concept.Area(rawValue: (fields["AREA"] ?? "").lowercased()) ?? .systems
            let requires = (fields["REQUIRES"] ?? "").lowercased()
            if requires != "none" {
                c.requires = requires.components(separatedBy: ",")
                    .map { Concept.slug($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { !$0.isEmpty }
            }
            c.relevance = fields["RELEVANCE"] ?? ""
            let courses = fields["COURSES"] ?? ""
            if courses.lowercased() != "none" {
                c.courses = courses.components(separatedBy: ";")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            out.append(c)
        }
        return out
    }

    /// Builds the curriculum out of what several courses actually teach.
    ///
    /// Not one syllabus copied. Each course is shaped by its department — CS149
    /// and 15-418 are for people about to write CUDA, 6.5940 is for people
    /// shrinking models, CS336 is for building an LM end to end — and the union,
    /// ordered by dependency rather than by semester, is the thing none of them
    /// is. Where several courses teach the same idea, that is a signal it is
    /// canonical rather than one department's taste, so the overlap is recorded.
    static func synthesise(courses: [(name: String, topics: [String])],
                           existing: [Concept], count: Int = 24) -> [Concept] {
        let known = existing.map { "\($0.id) — \($0.title)" }.joined(separator: "\n")
        let syllabi = courses.map { course in
            "## \(course.name)\n" + course.topics.prefix(90).joined(separator: "\n")
        }.joined(separator: "\n\n")

        let prompt = """
            \(reader)

            Below are the syllabus pages of several courses that teach this
            material. They are scraped, so they contain navigation text and
            noise; read past it.

            \(syllabi)

            Already in the graph (do not repeat these ids):
            \(known.isEmpty ? "(none yet)" : known)

            Synthesise these into ONE curriculum — not a copy of any single
            course. Where several courses teach the same idea, treat it as
            canonical and place it early. Where only one does, keep it if it
            matters for this reader and drop it if it is that department's local
            taste. Add anything the courses assume and never teach.

            Propose \(count) concepts, ordered so prerequisites come first.

            Output one block each, exactly this, nothing else:

            ID: kebab-case-id
            TITLE: Human readable title
            AREA: one of hardware, systems, training, architecture, theory, safety, evaluation, tooling
            REQUIRES: comma-separated ids, or none
            RELEVANCE: one concrete sentence for this reader. LaTeX for any maths, as $…$.
            COURSES: semicolon-separated course names that cover it, or none
            ---
            """
        guard let reply = ask(prompt, timeout: 900) else { return [] }
        return parse(reply)
    }

    /// Rewrites Unicode mathematics as LaTeX.
    ///
    /// The first concepts were generated before the prompt asked for LaTeX, so
    /// they carry things like "L(θ+Δ) ≈ L + gᵀΔ + ½ΔᵀHΔ" — which reads fine as
    /// text and is invisible to KaTeX, so it sits on screen unset while
    /// everything around it is typeset. Converting it by regular expression
    /// means deciding where a formula starts and ends inside prose, which is
    /// the hard part and the part that goes wrong; the model already knows.
    ///
    /// One call for the whole library rather than one per concept: this is a
    /// mechanical rewrite, and thirty-one round trips would take half an hour.
    static func latexify(_ concepts: [Concept]) -> [String: (title: String, relevance: String)] {
        let listing = concepts.map { c in
            "ID: \(c.id)\nTITLE: \(c.title)\nRELEVANCE: \(c.relevance)"
        }.joined(separator: "\n---\n")

        let prompt = """
            Below are entries from a study app. Some contain mathematics written \
            in Unicode — Greek letters, ᵀ, ½, ≈, subscripts — which the app \
            cannot typeset.

            Rewrite each so that every mathematical expression is LaTeX inside \
            $…$ delimiters. "L(θ+Δ) ≈ L + gᵀΔ + ½ΔᵀHΔ" becomes \
            "$L(\\theta + \\Delta) \\approx L + g^\\top \\Delta + \\tfrac12 \
            \\Delta^\\top H \\Delta$".

            Rules:
            - Change nothing but the mathematics. Same claims, same wording, \
            same order. This is a transcription, not an edit.
            - Prose stays prose. A stray "2x faster" or a version number is not \
            mathematics; do not wrap it.
            - Return every entry, including ones that needed no change.

            \(listing)

            Output exactly this per entry, nothing else:

            ID: the-same-id
            TITLE: the title, with LaTeX where there is mathematics
            RELEVANCE: the relevance line, with LaTeX where there is mathematics
            ---
            """
        guard let reply = ask(prompt, timeout: 900) else { return [:] }

        var out: [String: (title: String, relevance: String)] = [:]
        for block in reply.components(separatedBy: "---") {
            var fields: [String: String] = [:]
            for line in block.components(separatedBy: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).uppercased()
                guard ["ID", "TITLE", "RELEVANCE"].contains(key) else { continue }
                fields[key] = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
            }
            guard let id = fields["ID"], let title = fields["TITLE"],
                  let relevance = fields["RELEVANCE"], !title.isEmpty else { continue }
            out[id] = (title, relevance)
        }
        return out
    }

    /// The next concepts these courses actually teach.
    ///
    /// Different from `synthesise`, which builds the union and is run once. This
    /// walks the same syllabi and takes what the graph has not covered yet,
    /// keeping each course's own topics and its own order — so extending the
    /// graph continues CS336 or 15-418 rather than inventing a plausible next
    /// step. The courses are the curriculum; the graph is how far through it you
    /// are.
    static func next(from courses: [(name: String, topics: [String])],
                     existing: [Concept], count: Int = 12) -> [Concept] {
        let covered = existing.map { c in
            c.courses.isEmpty ? c.title : "\(c.title) [\(c.courses.joined(separator: "; "))]"
        }.joined(separator: "\n")
        let syllabi = courses.map { course in
            "## \(course.name)\n" + course.topics.prefix(90).joined(separator: "\n")
        }.joined(separator: "\n\n")

        let prompt = """
            \(reader)

            These are the syllabus pages of the courses this curriculum follows. \
            They are scraped, so read past the navigation noise.

            \(syllabi)

            The graph already covers:
            \(covered.isEmpty ? "(nothing yet)" : covered)

            Add the next \(count) concepts **that these courses actually teach** \
            and the graph does not have yet. Follow their syllabi: take their \
            topics, in their order, at their granularity — one concept per \
            lecture or lecture group. Do not invent topics the courses do not \
            cover, and do not skip ahead past material they teach first.

            Where a course's lecture is too coarse to be a single sitting, split \
            it, and say so in RELEVANCE. Where two courses teach the same \
            lecture, make one concept and list both.

            Output one block each, exactly this, nothing else:

            ID: kebab-case-id
            TITLE: Human readable title
            AREA: one of hardware, systems, training, architecture, theory, safety, evaluation, tooling
            REQUIRES: comma-separated ids already in the graph or proposed above, or none
            RELEVANCE: one concrete sentence for this reader. LaTeX for any maths, as $…$.
            COURSES: semicolon-separated course names whose syllabus covers it
            ---
            """
        guard let reply = ask(prompt, timeout: 900) else { return [] }
        return parse(reply)
    }

    /// Turns one batch of a resource's sections into concepts that cover it.
    ///
    /// Different from `synthesise`, which unions six syllabi into one taste-free
    /// curriculum, and from `next`, which continues those courses. This walks a
    /// single resource the reader has chosen — a book, a course PDF, a long post
    /// — and covers *all of it, in its own order*: the point of importing the
    /// RLHF book is to come out the other side having read the RLHF book, not a
    /// judged selection of it. Depth of coverage is the model's call per
    /// section; what is not negotiable is that nothing is skipped.
    static func digest(resource: String, sections: [(title: String, text: String)],
                       existing: [Concept], proposed: [Concept]) -> [Concept] {
        let known = (existing.map { "\($0.id) — \($0.title)" }
                     + proposed.map { "\($0.id) — \($0.title) (from this resource, earlier sections)" })
            .joined(separator: "\n")
        let material = sections.map { "### SECTION: \($0.title)\n\($0.text)" }
            .joined(separator: "\n\n")

        let prompt = """
            \(reader)

            They are working through "\(resource)" end to end, in order. Below \
            \(sections.count == 1 ? "is one section" : "are consecutive sections") \
            of it, as extracted text — read past any extraction noise.

            Already in their graph (do not repeat these ids):
            \(known.isEmpty ? "(nothing yet)" : known)

            Turn this material into concepts, covering ALL of it — every method, \
            derivation and mechanism these sections actually teach. One concept \
            is one sitting of fifteen to forty minutes. A dense section becomes \
            several concepts; a thin one becomes one; a section that only \
            restates what the graph already has becomes none, with its content \
            noted in REQUIRES of what follows. Do not summarise the resource \
            into highlights — the reader chose to learn the whole thing.

            REQUIRES must chain the resource's own reading order: a concept \
            rests on the concepts from earlier in the resource it builds on, \
            plus any graph ids it genuinely needs. That chain is what lets the \
            app walk them through the resource front to back.

            RELEVANCE names where in the resource this is taught (section or \
            chapter), then why it matters for this reader.

            Output one block per concept, exactly this format, nothing else:

            ID: kebab-case-id
            TITLE: Human readable title
            AREA: one of hardware, systems, training, architecture, theory, safety, evaluation, tooling
            REQUIRES: comma-separated ids, or none
            RELEVANCE: "\(resource)", the section, then one concrete sentence. LaTeX for any maths, as $…$.
            ---

            \(material)
            """
        guard let reply = ask(prompt, timeout: 900) else { return [] }
        var out = parse(reply)
        // Provenance is recorded by the app, not trusted to the model: every
        // imported concept says what it was imported from.
        for i in out.indices where !out[i].courses.contains(resource) {
            out[i].courses.append(resource)
        }
        return out
    }

    // MARK: - Writing one concept

    /// The same concept, taught from nothing.
    ///
    /// Not a simpler version — a longer one. The entry is dense because it is a
    /// reference; this is the walk through it, where every term is introduced
    /// the first time it appears and every number is arrived at rather than
    /// stated. Written from the entry so the two cannot disagree about facts,
    /// and carrying the same citations so it is no less checkable for being
    /// gentler.
    static func walkthrough(_ concept: Concept, context: [Concept]) -> String? {
        let prereqs = concept.requires
            .compactMap { id in context.first { $0.id == id }?.title }
            .joined(separator: ", ")
        let prompt = """
            You are teaching one concept to a strong reader who has no background \
            in this particular area. They are a computer science PhD student — \
            they are not slow, and they will notice if you wave your hands. They \
            simply have not worked on this, and every unexplained term is a wall.

            Concept: \(concept.title)
            \(concept.relevance.isEmpty ? "" : "Why it is on their list: \(concept.relevance)")
            \(prereqs.isEmpty ? "" : "Related things they may have met: \(prereqs)")

            Here is the reference entry for it. Your job is to unfold this, not to \
            replace it or summarise it:

            \(concept.body.isEmpty ? "(none yet — write the walkthrough from scratch)" : concept.body)

            Rules:

            1. Every term is introduced the first time it is used, in the sentence \
            that uses it. "A kernel — the function you launch on the GPU — …". \
            Never use a word from this area before defining it. This is the whole \
            point; the entry failed exactly here.
            2. Keep every number, mechanism and comparison from the entry. This is \
            the same content with the steps put back in, not a gentler claim. If \
            the entry says 132 SMs and 65536 registers, so does this, and the \
            arithmetic is *shown*: where 25% occupancy comes from, step by step.
            3. Keep the source lines. Same "  └ source" format, under the claim \
            they support.
            4. Build in an order someone could follow with no prior context: what \
            problem exists → what the hardware or system does about it → what that \
            forces to be true → why anyone should care. Never forward-reference.
            5. An analogy may come *after* a mechanism to settle it. It may never \
            stand in for one. If you catch yourself writing "think of it like", \
            check that the real mechanism is already on the page.
            6. Say plainly when something is genuinely subtle rather than \
            pretending it is obvious. "This is the part that takes a while" is \
            more useful than false ease.
            7. 700–1200 words. Long is fine. Skipping a step is not.

            Structure it with ## headings that follow the argument. End with a \
            "## The one thing to remember" section of two or three sentences.

            Mathematics in LaTeX, inline as $…$ and displayed as $$…$$.
            """
        return ask(prompt, timeout: 900)
    }

    struct Written {
        var body: String
        var sources: [Concept.Source]
    }

    /// The explanation, with every claim attached to something checkable.
    static func write(_ concept: Concept, context: [Concept]) -> Written? {
        let prereqs = concept.requires
            .compactMap { id in context.first { $0.id == id }?.title }
            .joined(separator: ", ")
        let prompt = """
            \(reader)

            Write the entry for: \(concept.title)
            \(concept.relevance.isEmpty ? "" : "Why it is on their list: \(concept.relevance)")
            \(prereqs.isEmpty ? "" : "They already know: \(prereqs). Build on it, do not re-explain it.")

            Rules, in order of importance:

            1. Every factual claim — a number, a mechanism, a comparison, a date, \
            a hardware detail — is followed by an indented line naming where it \
            comes from: a paper and section, official documentation, a spec sheet. \
            Format: "  └ vLLM paper §4.1 · Kwon et al. 2023".
            2. Anything you are not confident is correct and sourceable goes under \
            a final "## Not verified" heading, written as the claim plus what \
            would settle it. Do not quietly drop it and do not state it as fact. \
            An honest gap is useful; a smooth paragraph hiding one is not.
            3. No analogies as explanation. An analogy may follow a mechanism, \
            never replace it.
            3a. Mathematics in LaTeX, always: $\\eta$, not η; $L(\\theta + \\Delta) \\approx \
            L + g^\\top \\Delta + \\tfrac12 \\Delta^\\top H \\Delta$, not a line of \
            Unicode. Inline as $…$, displayed as $$…$$. The app typesets it.
            4. Roughly 250-400 words. This is fifteen minutes, not a lecture.

            Structure:

            ## What it actually is
            (the mechanism, concretely)

            ## Why it matters for your work
            (specific to LLM safety research — how it changes what they can measure, \
            train, or trust. Say plainly if the honest answer is "mostly it does not, \
            but you will hit it when...")

            ## Check yourself
            (2-3 questions with short answers, testing the mechanism rather than the vocabulary)

            ## Not verified
            (anything from rule 2, or "nothing" if everything above is sourced)

            Then, after a line containing only SOURCES:, list every source used, \
            one per line, as: Title | https://url
            Only URLs you are confident exist. A guessed URL is worse than none.
            """
        guard let reply = ask(prompt) else { return nil }
        let parts = reply.components(separatedBy: "\nSOURCES:")
        let body = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        var sources: [Concept.Source] = []
        if parts.count > 1 {
            for line in parts[1].components(separatedBy: "\n") {
                let bits = line.components(separatedBy: "|").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard bits.count >= 2, bits[1].hasPrefix("http") else { continue }
                sources.append(.init(title: bits[0], url: bits[1]))
            }
        }
        return Written(body: body, sources: sources)
    }
}
