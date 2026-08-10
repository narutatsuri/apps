import Foundation
import PDFKit

/// The notes repository: plain markdown in a git working tree you own. The app is a
/// lens over these files, never their owner — which is the point, given the two
/// previous tools that went dormant took their contents with them.
@MainActor
final class Library {
    static let shared = Library()

    // nonisolated: `Git` is a plain enum with no actor, and these are immutable.
    // Without this they are an error under the Swift 6 language mode.
    /// `~/Library/Application Support/Paper Notes/`, where macOS keeps an app's
    /// data — not the home folder, which is yours. Still a git repo of plain
    /// markdown, so nothing about how you read, grep or push it changes; only
    /// where it sits. Never inside the `.app` bundle: `build.sh` replaces that
    /// on every rebuild, which would take the library with it.
    nonisolated static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Paper Notes")

    /// Where the library used to live.
    nonisolated private static let legacyRoot = FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent("paper-notes")

    /// Moves the library out of the home folder, once.
    ///
    /// A move, not a copy: this is a git repo, and two clones of it with
    /// different commits would be a genuinely bad afternoon. Only ever done
    /// when the new location does not already exist.
    nonisolated static func migrateFromHome() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: legacyRoot.path),
              !manager.fileExists(atPath: root.path) else { return }
        try? manager.createDirectory(at: root.deletingLastPathComponent(),
                                     withIntermediateDirectories: true)
        try? manager.moveItem(at: legacyRoot, to: root)
    }
    nonisolated static var papersDir: URL { root.appendingPathComponent("papers") }
    /// PDFs live beside the notes but are **git-ignored**. Two reasons: 269 MB of
    /// binaries would wreck a notes repo, and pushing published papers to a repo —
    /// this one is public — is a copyright problem the notes themselves are not.
    nonisolated static var pdfStore: URL { root.appendingPathComponent("pdfs") }

    /// Copies a PDF into the app's own store and returns its new path, so the note
    /// no longer depends on wherever the file happened to be downloaded to.
    /// Verifies the copy opens before reporting success — a truncated copy that
    /// still lets you delete the original would be the worst possible outcome.
    nonisolated static func adopt(_ source: URL, for id: String) -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(at: pdfStore, withIntermediateDirectories: true)
        let destination = pdfStore.appendingPathComponent("\(PDFRefs.normalise(id)).pdf")

        if source.standardizedFileURL == destination.standardizedFileURL {
            return destination.path                       // already adopted
        }
        guard fm.fileExists(atPath: source.path) else { return nil }
        if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
        do { try fm.copyItem(at: source, to: destination) } catch { return nil }

        guard let copied = PDFDocument(url: destination), copied.pageCount > 0 else {
            try? fm.removeItem(at: destination)
            return nil
        }
        return destination.path
    }
    nonisolated static let remote = "https://github.com/narutatsuri/paper-notes.git"

    private(set) var papers: [Paper] = []

    private init() {}

    func bootstrap() {
        Self.migrateFromHome()
        defer { TrustedAuthors.bootstrap(); ArxivFeed.bootstrap() }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.papersDir, withIntermediateDirectories: true)

        let readme = Self.root.appendingPathComponent("README.md")
        if !fm.fileExists(atPath: readme.path) {
            try? """
            # paper-notes

            Reading notes, one markdown file per paper, written by hand.

            Each note records the claim in my own words, what actually convinced me,
            what would have to be true for it to be wrong, and — most usefully —
            what I did not understand. Frontmatter carries the arXiv id and the
            references extracted from the PDF, which is what the relation graph is
            built from.

            Managed by the PaperNotes app (`~/Developer/PaperNotes`), but the files
            are the source of truth and outlive it.
            """.write(to: readme, atomically: true, encoding: .utf8)
        }
        let ignore = Self.root.appendingPathComponent(".gitignore")
        if !fm.fileExists(atPath: ignore.path) {
            try? "pdfs/\n.DS_Store\n".write(to: ignore, atomically: true, encoding: .utf8)
        }
        Git.ensureRepo(at: Self.root, remote: Self.remote)
        reload()
    }

    func reload() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: Self.papersDir,
                                                includingPropertiesForKeys: nil)) ?? []
        papers = urls
            .filter { $0.pathExtension == "md" }
            .compactMap { url -> Paper? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return Paper(markdown: text)
            }
            .sorted { ($0.readOn ?? .distantPast) > ($1.readOn ?? .distantPast) }
    }

    func paper(withID id: String) -> Paper? {
        let target = PDFRefs.normalise(id)
        return papers.first { PDFRefs.normalise($0.arxivID) == target }
    }

    /// Set while a batch pass is running. Writes still land on disk immediately;
    /// only the commit is deferred, so one `--rank` over 62 papers produces one
    /// commit instead of 62. Without this the reading history — which is the
    /// point of keeping notes in git — disappears under machine bookkeeping:
    /// 346 of this repo's first 355 commits were single-line field writes.
    private var batchDepth = 0
    private var batchTouched = 0

    /// Runs `body` with commits deferred, then makes one commit describing the
    /// whole pass. Nested calls collapse into the outermost one.
    func batch(_ message: (Int) -> String, _ body: () -> Void) {
        batchDepth += 1
        if batchDepth == 1 { batchTouched = 0 }
        body()
        batchDepth -= 1
        guard batchDepth == 0 else { return }
        let n = batchTouched
        batchTouched = 0
        guard n > 0 else { return }
        Git.commit(at: Self.root, message: message(n))
    }

    /// Writes the note, replacing any earlier file for the same paper whose title —
    /// and therefore filename — has since changed.
    @discardableResult
    func save(_ paper: Paper) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.papersDir, withIntermediateDirectories: true)

        let target = Self.papersDir.appendingPathComponent(paper.filename)
        if let existing = (try? fm.contentsOfDirectory(at: Self.papersDir, includingPropertiesForKeys: nil))?
            .first(where: { $0.lastPathComponent.hasPrefix(paper.arxivID) && $0 != target }) {
            try? fm.removeItem(at: existing)
        }
        try? paper.markdown.write(to: target, atomically: true, encoding: .utf8)
        reload()
        if batchDepth > 0 {
            batchTouched += 1
        } else {
            Git.commit(at: Self.root, message: commitMessage(for: paper))
        }
        return target
    }

    /// Removes the note and its stored PDF. The PDF goes too — leaving a 4 MB
    /// orphan behind for every deleted paper is how a store silently fills up.
    func delete(_ paper: Paper) {
        let fm = FileManager.default
        if let match = (try? fm.contentsOfDirectory(at: Self.papersDir, includingPropertiesForKeys: nil))?
            .first(where: { $0.lastPathComponent.hasPrefix(paper.arxivID) }) {
            try? fm.removeItem(at: match)
        }
        let stored = Self.pdfStore.appendingPathComponent("\(PDFRefs.normalise(paper.arxivID)).pdf")
        if fm.fileExists(atPath: stored.path) { try? fm.removeItem(at: stored) }
        reload()
        Git.commit(at: Self.root, message: "remove: \(paper.title.isEmpty ? paper.arxivID : String(paper.title.prefix(60)))")
    }

    private func commitMessage(for paper: Paper) -> String {
        let name = paper.title.isEmpty ? paper.arxivID : paper.title
        return "notes: \(name.prefix(60))"
    }

    var readCount: Int { papers.filter(\.isSubstantive).count }
}

/// Thin wrapper over the git CLI. No library dependency — the CLI is already
/// installed, already authenticated through the osxkeychain helper, and behaves
/// identically to what happens when you use the repo by hand.
enum Git {
    @discardableResult
    static func run(_ args: [String], at url: URL) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = url
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func ensureRepo(at url: URL, remote: String) {
        if !FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
            run(["init", "-b", "main"], at: url)
        }
        let existing = run(["remote", "get-url", "origin"], at: url)
        if existing.status != 0 {
            run(["remote", "add", "origin", remote], at: url)
        }
    }

    static func commit(at url: URL, message: String) {
        run(["add", "-A"], at: url)
        // Nothing staged is the normal case when a note is saved unchanged.
        let status = run(["diff", "--cached", "--quiet"], at: url)
        guard status.status != 0 else { return }
        run(["commit", "-q", "-m", message], at: url)
    }

    static var unpushedCount: Int {
        let r = run(["rev-list", "--count", "@{u}..HEAD"], at: Library.root)
        if r.status == 0, let n = Int(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return n
        }
        // No upstream yet: everything local is unpushed.
        let all = run(["rev-list", "--count", "HEAD"], at: Library.root)
        return Int(all.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Returns nil on success, or a message to show.
    static func push() -> String? {
        let r = run(["push", "-u", "origin", "main"], at: Library.root)
        guard r.status != 0 else { return nil }
        return r.output
            .components(separatedBy: "\n")
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            ?? "push failed"
    }
}
