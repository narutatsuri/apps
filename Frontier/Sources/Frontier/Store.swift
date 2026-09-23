import Foundation

/// The curriculum on disk.
///
/// `~/Library/Application Support/Frontier/concepts/`, one markdown file per
/// concept — where macOS keeps an app's data, and plain enough that the graph
/// can be read, edited or diffed without this app existing.
@MainActor
final class Store {
    static let shared = Store()

    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Frontier")
    static var conceptsDir: URL { root.appendingPathComponent("concepts") }

    private(set) var concepts: [Concept] = []
    private init() {}

    func bootstrap() {
        try? FileManager.default.createDirectory(at: Self.conceptsDir,
                                                 withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.conceptsDir, includingPropertiesForKeys: nil)) ?? []
        concepts = files
            .filter { $0.pathExtension == "md" }
            .compactMap { (try? String(contentsOf: $0, encoding: .utf8)).flatMap(Concept.init(markdown:)) }
            .sorted { $0.id < $1.id }
    }

    func concept(_ id: String) -> Concept? { concepts.first { $0.id == id } }

    @discardableResult
    func save(_ concept: Concept) -> URL {
        try? FileManager.default.createDirectory(at: Self.conceptsDir,
                                                 withIntermediateDirectories: true)
        let url = Self.conceptsDir.appendingPathComponent(concept.filename)
        try? concept.markdown.write(to: url, atomically: true, encoding: .utf8)
        reload()
        return url
    }

    /// Adds only what is not already there, so re-running an import or an
    /// expansion cannot overwrite a concept you have since read and marked.
    @discardableResult
    func add(_ concepts: [Concept]) -> Int {
        let existing = Set(self.concepts.map(\.id))
        let incoming = concepts.filter { !existing.contains($0.id) }
        // Prerequisites are repaired on the way in, against the graph as it will
        // be. The model writes `requires:` by inventing an id from a title, so
        // left alone every expansion adds a fresh crop of edges that point at
        // nothing — and an edge pointing at nothing is silently no edge at all
        // (see Frontier.resolve). Repairing here is what stops the loose ends
        // accumulating faster than --grow can fill them.
        let (repaired, _) = Frontier.relinked(self.concepts + incoming)
        let byID = Dictionary(uniqueKeysWithValues: repaired.map { ($0.id, $0) })
        var added = 0
        for c in incoming {
            save(byID[c.id] ?? c)
            added += 1
        }
        return added
    }
}
