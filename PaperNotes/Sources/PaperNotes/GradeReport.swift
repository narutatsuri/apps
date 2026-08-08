import Foundation
import CryptoKit

/// The grader's reply, split into its sections.
///
/// Parsed rather than shown raw: the answers section is long, carries markdown
/// and LaTeX, and putting it in a single `Text` view meant reading a proof of
/// Appendix C as one unbroken grey paragraph with `∂/∂z_i` spelled out literally.
struct GradeReport: Equatable {
    var answers = ""
    var grade = ""
    var missed = ""
    var check = ""
    var ask = ""
    /// The answer to `ask`. Shown collapsed: leaving you to work it out is the
    /// point of the question, but leaving you stuck is not.
    var askAnswer = ""
    /// Anything the judge said outside the expected labels. Kept rather than
    /// dropped — silently eating part of a reply is how a parser hides a
    /// regression in the prompt.
    var preamble = ""

    /// Longest first, so "ANSWERS:" is never matched as "ANSWER:" plus a stray S.
    static let labels = ["ANSWERS", "MISSED", "ANSWER", "GRADE", "CHECK", "ASK"]

    static func parse(_ reply: String) -> GradeReport {
        var out = GradeReport()
        var current: String?
        var buffer: [String: [String]] = [:]
        var loose: [String] = []

        for line in reply.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A label only counts at the start of a line, so a sentence that
            // happens to mention CHECK mid-paragraph does not split the section.
            if let label = labels.first(where: { trimmed.uppercased().hasPrefix($0 + ":") }) {
                current = label
                let rest = String(trimmed.dropFirst(label.count + 1))
                    .trimmingCharacters(in: .whitespaces)
                buffer[label, default: []].append(rest)
            } else if let c = current {
                buffer[c, default: []].append(line)
            } else if !trimmed.isEmpty {
                loose.append(line)
            }
        }

        func joined(_ key: String) -> String {
            (buffer[key] ?? []).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        out.answers = joined("ANSWERS")
        out.grade = joined("GRADE").split(separator: " ").first.map(String.init)?.uppercased() ?? ""
        out.missed = joined("MISSED")
        out.check = joined("CHECK")
        out.ask = joined("ASK")
        out.askAnswer = joined("ANSWER")
        out.preamble = loose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return out
    }

    /// True when nothing matched — the reply is then shown verbatim rather than
    /// as a set of empty section headings.
    var isEmpty: Bool {
        answers.isEmpty && grade.isEmpty && missed.isEmpty
            && check.isEmpty && ask.isEmpty && askAnswer.isEmpty
    }

    /// The body, as one markdown document for the renderer. The grade itself is
    /// drawn natively as a badge, so it is deliberately absent here.
    func markdown(rawFallback: String) -> String {
        guard !isEmpty else { return rawFallback }
        var out = ""
        if !preamble.isEmpty { out += preamble + "\n\n" }
        if !answers.isEmpty { out += "## Your questions\n\n\(answers)\n\n" }
        if !missed.isEmpty { out += "## What the paper argues that you didn't engage with\n\n\(missed)\n\n" }
        if !check.isEmpty { out += "## Check this claim\n\n\(check)\n\n" }
        if !ask.isEmpty {
            out += "## Could you answer this?\n\n\(ask)\n\n"
            // Raw HTML, which marked passes through: the answer is one click
            // away rather than sitting under the question spoiling it.
            if !askAnswer.isEmpty {
                out += "<details>\n<summary>Show the answer</summary>\n\n\(askAnswer)\n\n</details>\n"
            }
        }
        return out
    }
}

/// Grades are content-addressed on disk, so pressing the button twice on an
/// unchanged note costs nothing.
///
/// Lives in Application Support rather than the notes repo: a cache is not a
/// note, and it should not turn up in `git status` or get pushed.
enum GradeCache {
    /// Bump when the prompt changes — every stored grade is then a miss, because
    /// a cached answer from an older rubric is worse than no cached answer.
    static let promptVersion = "2026-08-05.answers+ask"

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PaperNotes/grades")
    }

    /// Everything the reply depends on. The note body and the PDF are the whole
    /// input to the prompt; the version pins the prompt itself.
    static func key(for paper: Paper) -> String {
        let size = (try? FileManager.default
            .attributesOfItem(atPath: paper.pdfPath)[.size] as? Int) ?? 0
        let material = [promptVersion, paper.arxivID, paper.pdfPath,
                        String(size ?? 0), paper.body].joined(separator: "\u{1}")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func load(_ key: String) -> String? {
        let url = directory.appendingPathComponent("\(key).txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty
        else { return nil }
        return text
    }

    static func save(_ key: String, _ text: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? text.write(to: directory.appendingPathComponent("\(key).txt"),
                        atomically: true, encoding: .utf8)
    }

    /// The one entry point both the button and the CLI use, so neither can end up
    /// calling the model while the other reads from disk.
    static func grade(_ paper: Paper, force: Bool = false) -> (text: String?, cached: Bool) {
        let k = key(for: paper)
        if force { forget(k) }
        if !force, let hit = load(k) { return (hit, true) }
        guard let fresh = Judge.gradeNote(paper) else { return (nil, false) }
        save(k, fresh)
        return (fresh, false)
    }

    /// Used by Grade again: drop this one entry so the next run is live.
    static func forget(_ key: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(key).txt"))
    }
}
