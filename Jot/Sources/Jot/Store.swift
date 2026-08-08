import Foundation

/// Every sticky, on disk as plain markdown.
///
/// `~/jot/` rather than Application Support: these are your notes, you
/// should be able to find them in Finder, grep them, edit one in vim, and back
/// them up without knowing anything about this app.
@MainActor
final class Store {
    static let shared = Store()

    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("jot")
    /// Deleted stickies land here rather than vanishing. Deletion has to be one
    /// keystroke for a scratch buffer to be worth using, and one keystroke is
    /// also how you lose something you meant to keep.
    static let trash = root.appendingPathComponent(".trash")

    private(set) var stickies: [String: Sticky] = [:]
    private var saveWork: [String: DispatchWorkItem] = [:]

    private init() {}

    func bootstrap() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.trash, withIntermediateDirectories: true)
        reload()
    }

    func url(for id: String) -> URL {
        Self.root.appendingPathComponent("\(id).md")
    }

    func reload() {
        stickies = [:]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.root, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "md" {
            guard let raw = try? String(contentsOf: file, encoding: .utf8),
                  let sticky = Sticky(markdown: raw,
                                      id: file.deletingPathExtension().lastPathComponent)
            else { continue }
            stickies[sticky.id] = sticky
        }
    }

    /// Newest first — the sticky you just made should be at the top of the list.
    var ordered: [Sticky] {
        stickies.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func sticky(_ id: String) -> Sticky? { stickies[id] }

    /// Writes after a short pause. Typing a sentence should not be sixty file
    /// writes, but the pause has to be short enough that a crash costs a word,
    /// not a paragraph.
    func save(_ sticky: Sticky, debounce: TimeInterval = 0.6) {
        var s = sticky
        s.updatedAt = Date()
        stickies[s.id] = s

        saveWork[s.id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.writeNow(s) }
        }
        saveWork[s.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// Used when a window closes or the app quits, where waiting for a debounce
    /// would mean losing whatever was typed last.
    func flush(_ id: String) {
        saveWork[id]?.cancel()
        saveWork[id] = nil
        guard let s = stickies[id] else { return }
        writeNow(s)
    }

    func flushAll() {
        for id in stickies.keys { flush(id) }
    }

    private func writeNow(_ sticky: Sticky) {
        // A sticky emptied out is a sticky you are done with, and a folder of
        // scratch buffers should not fill with blank files. But it goes to the
        // trash, not to nothing: this used to call removeItem, and any path
        // that made an in-memory copy blank — a second instance of the app with
        // a stale store, an editor that had not loaded yet — destroyed the file
        // with no way back. It cost a real note. Deletion has exactly one
        // meaning here now, and it is recoverable.
        guard !sticky.isBlank else {
            bin(sticky.id)
            return
        }
        try? sticky.markdown.write(to: url(for: sticky.id), atomically: true, encoding: .utf8)
    }

    /// Moves a note's file into `.trash`, keeping whatever is already there.
    private func bin(_ id: String) {
        let from = url(for: id)
        guard FileManager.default.fileExists(atPath: from.path) else { return }
        let to = Self.trash.appendingPathComponent(
            "\(id)-\(Int(Date().timeIntervalSince1970)).md")
        try? FileManager.default.moveItem(at: from, to: to)
    }

    @discardableResult
    func create(colour: StickyColour = .yellow, text: String = "") -> Sticky {
        let s = Sticky(id: Sticky.newID(), text: text, colour: colour)
        stickies[s.id] = s
        return s
    }

    /// Moves the file to `.trash` instead of deleting it. Recoverable by hand,
    /// which is the compromise that lets deletion be a single keystroke.
    func delete(_ id: String) {
        saveWork[id]?.cancel()
        saveWork[id] = nil
        bin(id)
        stickies[id] = nil
    }
}
