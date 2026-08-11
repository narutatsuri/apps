import Foundation

/// Runs the `claude` CLI as a judge. The app has no model inside it, but the CLI is
/// on this machine and already authenticated, so it can be shelled out to the same
/// way `git` is.
enum Judge {
    static var cliPath: String? {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool { cliPath != nil }

    /// Sends `prompt` on stdin and returns the reply. Synchronous on purpose — both
    /// callers are already off the main thread, and streaming buys nothing here.
    static func ask(_ prompt: String, timeout: TimeInterval = 240) -> String? {
        guard let cli = cliPath else { return nil }
        return run(executable: cli, arguments: ["-p"], stdin: prompt, timeout: timeout)
    }

    /// The subprocess plumbing, separated from "which CLI" so the self-test can
    /// push a deliberately chatty child through the exact code path the judge uses.
    static func run(executable: String, arguments: [String], stdin input: String,
                    timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr

        do { try p.run() } catch { return nil }
        stdin.fileHandleForWriting.write(Data(input.utf8))
        stdin.fileHandleForWriting.closeFile()

        // Read on background queues: a full pipe buffer would deadlock a judge that
        // writes more than 64 KB before we start reading. Both pipes — a child that
        // fills the *stderr* buffer blocks just as finally as one that fills stdout,
        // and nobody is coming back for either.
        var output = Data()
        let lock = NSLock()
        let reader = DispatchQueue(label: "judge.read")
        reader.async {
            let d = stdout.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); output = d; lock.unlock()
        }
        let drainer = DispatchQueue(label: "judge.drain")
        drainer.async {
            _ = stderr.fileHandleForReading.readDataToEndOfFile()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if p.isRunning { p.terminate(); return nil }
        reader.sync {}

        lock.lock(); let data = output; lock.unlock()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    /// The grading prompt, shared by the CLI and the button so they cannot drift.
    ///
    /// It answers your questions as well as grading you. The note template has a
    /// "What I didn't understand" heading precisely to collect confusion, and a
    /// grader that reads that section only to mark you down for it is using the
    /// most valuable thing in the note as evidence against you.
    static func gradeNote(_ paper: Paper) -> String? {
        let questions = paper.questions
        // A question about section 5 cannot be answered from the first six pages.
        // The wider excerpt is only paid for when there is something to answer.
        let excerpt = questions.isEmpty
            ? excerpt(of: paper.resolvedPDF?.path ?? paper.pdfPath)
            : excerpt(of: paper.pdfPath, pages: 25, limit: 90_000)
        guard !excerpt.isEmpty else { return "No PDF text available for this paper." }

        var asked = ""
        if !questions.confusionSection.isEmpty {
            asked += "\n=== WHAT THEY DID NOT UNDERSTAND ===\n\(questions.confusionSection)\n"
        }
        if !questions.elsewhere.isEmpty {
            asked += "\n=== QUESTIONS ELSEWHERE IN THE NOTE ===\n"
                + questions.elsewhere.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }

        let answerBlock = questions.isEmpty ? "" : """

        ANSWERS: answer every question and confusion listed above, each on its own
        line beginning "- ". Answer them properly, as a colleague who has read the
        paper would: give the actual explanation, cite the section or figure, and
        quote the paper where it settles the matter. If the paper genuinely does not
        answer one, say so plainly and say what it would take to find out — do not
        manufacture an answer. This section comes first because it is the reason
        they asked.
        """

        let noRepeat = questions.isEmpty
            ? "" : " Do not repeat a question they already asked above."

        return ask("""
        A researcher wrote the notes below after reading this paper. You have the
        paper for reference. Do two things: answer what they asked, and grade the
        NOTES — not the paper.

        Be specific and honest. Vague praise is useless to them. If the notes
        misstate the paper's claim, say so plainly and quote the paper.

        === PAPER ===
        \(excerpt)

        === THEIR NOTES ===
        \(paper.body)
        \(asked)
        Reply in exactly this shape, no preamble:\(answerBlock)
        GRADE: one of SOLID, PARTIAL, THIN, WRONG
        MISSED: the single most important thing the paper argues that the notes
        do not engage with, one sentence.
        CHECK: one claim in the notes that is inaccurate or overstated, quoting
        the paper — or "nothing inaccurate" if there is none.
        ASK: one question they should be able to answer about this paper but
        probably cannot from these notes alone.\(noRepeat)
        ANSWER: the answer to your ASK question, so they can check themselves
        after trying. Give the real answer with the section, figure, or quote it
        rests on — not a hint, and not a restatement of the question.
        """, timeout: 300)
    }

    /// Grades the *paper*, on whether the idea in it is worth your attention.
    ///
    /// Deliberately not a quality review. Rigour is what referees are for, and a
    /// referee's scale would sort this library exactly backwards: a ten-seed
    /// confirmation of the expected would outrank a one-seed result that overturns
    /// something. The rubric below is written to fight that, because the default
    /// behaviour of any model asked to "grade a paper" is to grade the execution.
    static func appraise(_ paper: Paper) -> (verdict: Verdict, note: String, score: Int)? {
        let excerpt = excerpt(of: paper.pdfPath, pages: 8)
        guard !excerpt.isEmpty else { return nil }
        guard let reply = ask("""
        Grade this paper for a researcher who reads to find ideas — surprising
        results, new framings, directions worth working on. Grade the IDEA and what
        it teaches, not how well the work was executed or written.

        Weigh heavily:
        - Does it change how you would frame the problem?
        - Is a result here genuinely surprising — something you would have bet
          against before reading?
        - Does it name a phenomenon the field had no word for?
        - Does it open work: can you immediately see experiments you would want to
          run next?
        - Is the mechanism insightful as science, rather than as engineering?

        Explicitly do NOT weigh:
        - Seeds, error bars, ablations, benchmark breadth. A single-seed result with
          a startling implication beats a thoroughly-validated confirmation of what
          everyone already assumed.
        - Compute, model scale, or dataset size.
        - Writing quality, structure, or how well the paper sells itself.
        - Whether the claim is fully established. An interesting claim on thin
          evidence is still interesting — note the weakness in your reason, do not
          let it lower the grade.
        - Leaderboard numbers on their own. A state-of-the-art result carrying no
          idea is THIN however large the margin.

        The scale is a reading decision, not a compliment. Grade by what the reader
        should do with the paper today:
        GOLD    — stop what you are doing and read it properly now. It changes how
                  you would frame the problem. A handful a year.
        SOLID   — read it in full this week. There is one specific idea you could
                  state in a single clause, and stating it would tell a colleague
                  something they did not know.
        MIXED   — skim for the one idea, then stop. The rest is routine, or you
                  cannot yet tell whether the idea is right.
        THIN    — read the abstract and move on. Competent and unsurprising; you
                  could have predicted the result from the title.
        GARBAGE — do not read it. Numbers moved and nothing was learned.

        Calibrate hard. These papers were all chosen and downloaded by a working
        researcher, so they are all competent and all on-topic; that is the baseline,
        not a qualification. In a library like this expect roughly GOLD 1 in 30,
        SOLID 1 in 4, and the bulk MIXED or THIN. Most competent papers are THIN on
        this scale, and that is not an insult — it means a reader who knows the area
        would have guessed the result.

        The test for SOLID: name the idea in one clause. If the best you can manage
        is that the paper does something well, studies something carefully, or
        provides a useful resource, it is not SOLID — it is THIN.

        === PAPER (opening pages) ===
        \(excerpt)

        Reply in exactly three lines, no preamble:
        SCORE: an integer 0-100 for how much this paper changes what the reader
        would work on or how they would frame the problem. 0 = they could have
        written the abstract themselves. 100 = it redirects a research agenda.
        Use the whole range; most papers are not near either end.
        VERDICT: one of GOLD, SOLID, MIXED, THIN, GARBAGE
        WHY: one sentence, at most 30 words, naming the specific idea and why it is
        or is not interesting. Name it concretely — "interesting approach" is useless.
        """, timeout: 240) else { return nil }
        return parseAppraisal(reply)
    }

    /// Split out from `appraise` so the parsing is testable without a model call.
    static func parseAppraisal(_ reply: String) -> (verdict: Verdict, note: String, score: Int)? {
        var verdict = Verdict.unset
        var note = ""
        var score = -1
        for line in reply.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            let upper = t.uppercased()
            if upper.hasPrefix("SCORE:") {
                let digits = t.dropFirst(6).filter(\.isNumber)
                score = Int(digits).map { min(100, $0) } ?? -1
            } else if upper.hasPrefix("VERDICT:") {
                // Tolerates a qualified label ("SOLID (leaning MIXED)") by taking the
                // first word, the same way the recommender does.
                let raw = t.dropFirst(8).trimmingCharacters(in: .whitespaces).lowercased()
                let head = raw.split(whereSeparator: { $0 == " " || $0 == "(" })
                    .first.map(String.init) ?? raw
                verdict = Verdict(rawValue: head) ?? .unset
            } else if upper.hasPrefix("WHY:") {
                note = String(t.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            }
        }
        // An unrecognised grade is dropped rather than defaulted, and `unset` is not
        // a grade the judge may return. A wrong label on a shelf is worse than none.
        guard verdict != .unset else { return nil }
        return (verdict, note, score)
    }

    /// First page or so of a PDF — enough for a judge to see the abstract and claims
    /// without pushing a 50-page paper through the CLI.
    static func excerpt(of path: String, pages: Int = 6, limit: Int = 24_000) -> String {
        guard !path.isEmpty else { return "" }
        let text = PDFRefs.text(of: URL(fileURLWithPath: path), pages: pages)
        return String(text.prefix(limit))
    }
}
