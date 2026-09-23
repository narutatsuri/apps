import Foundation

/// Every lane, on disk as markdown.
///
/// `~/Library/Application Support/Lanes/`: an unsplit project is one
/// `<Title>.md`, a split one is a folder `<Title>/` holding one `<Thread>.md`
/// per thread plus the project's own writing in `_above.md` and `_below.md`
/// — underscored so they are never mistaken for threads, and visible so they
/// export with the folder. **No frontmatter anywhere**: a file is exactly what you typed,
/// so a lane copies straight into a report and a project exports as its
/// folder. What bare files cannot carry — order, widths, which columns were
/// left in rendered view — lives in `lanes.json` beside them. Anything
/// dropped into the folder by hand becomes a lane on the next launch; a
/// deleted lane or thread goes to `.trash`, not to nothing; a *vaulted* one
/// goes to `_vault/` — off the board, but kept whole and visible, for the
/// project that has no promise but too much in it to throw away; and every
/// ten minutes of editing the previous version of a file is kept in
/// `.history` before being overwritten.
@MainActor
final class LaneStore {
    static let shared = LaneStore()
    /// Posted when the set or order of lanes changes; the object is the id of
    /// a lane worth scrolling to (a new lane, or the project a thread was
    /// just added to), when there is one.
    static let changed = Notification.Name("lanes.changed")

    /// `LANES_ROOT` points the whole store somewhere else — set by the selftest
    /// (via setenv, before this is first touched) so its probes never write
    /// into the real folder. `getenv`, not ProcessInfo: the selftest sets it at
    /// runtime and ProcessInfo's snapshot cannot be trusted to see that.
    nonisolated static let root: URL = {
        if let raw = getenv("LANES_ROOT"), raw.pointee != 0 {
            return URL(fileURLWithPath: String(cString: raw))
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lanes")
    }()
    static var trash: URL { root.appendingPathComponent(".trash") }
    static var history: URL { root.appendingPathComponent(".history") }
    /// Visible, unlike the trash: what is in here was kept on purpose.
    static var vault: URL { root.appendingPathComponent("_vault") }
    private static var indexURL: URL { root.appendingPathComponent("lanes.json") }

    private struct Entry: Codable {
        var id: String
        /// "Title.md" for a single file, "Title" for a folder of threads.
        var file: String
        var rendered: Bool
        /// Absent means the default — the index stays small for the common case.
        var width: Double?
        /// Present exactly when the lane is a folder.
        var threads: [Entry]?
        var belowRendered: Bool?
    }
    private struct Index: Codable { var lanes: [Entry] }

    /// In board order.
    private(set) var lanes: [Lane] = []

    private init() {}

    func bootstrap() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.trash, withIntermediateDirectories: true)
        reload()
    }

    // MARK: - Reading the folder back

    /// The index gives the order, the files give the words. Files and folders
    /// the index does not know are appended (dropped in by hand); index
    /// entries whose file has gone are dropped. Names starting with a dot
    /// (`.trash`, `.history`) are the store's own.
    func reload() {
        let fm = FileManager.default
        let index = (try? Data(contentsOf: Self.indexURL))
            .flatMap { try? JSONDecoder().decode(Index.self, from: $0) }?.lanes ?? []
        // Dot names (.trash, .history) and underscore names (_vault) are the
        // store's own, not lanes — the same convention as `_above.md` inside
        // a project.
        let items = ((try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && !$0.lastPathComponent.hasPrefix("_") }
        var files: [String: URL] = [:]     // "Title.md"
        var folders: [String: URL] = [:]   // "Title"
        for url in items {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { folders[url.lastPathComponent] = url }
            else if url.pathExtension == "md" { files[url.lastPathComponent] = url }
        }

        var out: [Lane] = []
        var seen = Set<String>()
        for entry in index {
            guard !seen.contains(entry.file) else { continue }
            if let threadEntries = entry.threads, let folder = folders[entry.file] {
                seen.insert(entry.file)
                out.append(Self.folderLane(id: entry.id, folder: folder, index: threadEntries,
                                           rendered: entry.rendered,
                                           belowRendered: entry.belowRendered ?? false))
            } else if entry.threads == nil, let url = files[entry.file] {
                seen.insert(entry.file)
                guard let text = Self.read(url) else {
                    print("lanes: cannot read \(entry.file) as text — left alone, not shown")
                    continue
                }
                out.append(Lane(id: entry.id, title: url.deletingPathExtension().lastPathComponent,
                                text: text, rendered: entry.rendered,
                                width: entry.width.map { Lane.clampWidth(CGFloat($0)) } ?? Lane.defaultWidth))
            }
        }
        for name in files.keys.sorted() where !seen.contains(name) {
            guard let text = Self.read(files[name]!) else {
                print("lanes: cannot read \(name) as text — left alone, not shown")
                continue
            }
            out.append(Lane(id: UUID().uuidString, title: String(name.dropLast(3)), text: text))
        }
        for name in folders.keys.sorted() where !seen.contains(name) {
            let folder = folders[name]!
            let hasMarkdown = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
                .contains { $0.hasSuffix(".md") && !$0.hasPrefix(".") }
            guard hasMarkdown else { continue }   // an empty folder is not a project
            out.append(Self.folderLane(id: UUID().uuidString, folder: folder, index: [],
                                       rendered: false, belowRendered: false))
        }
        lanes = out
        writeIndex()
    }

    static let aboveFile = "_above.md"
    static let belowFile = "_below.md"

    /// A folder as a lane: its own writing from `_above.md` / `_below.md`
    /// (absent means empty — a hand-made folder need not have them), and
    /// its threads from everything else.
    private static func folderLane(id: String, folder: URL, index: [Entry],
                                   rendered: Bool, belowRendered: Bool) -> Lane {
        var lane = Lane(id: id, title: folder.lastPathComponent, rendered: rendered)
        lane.isSplit = true
        lane.text = read(folder.appendingPathComponent(aboveFile)) ?? ""
        lane.belowText = read(folder.appendingPathComponent(belowFile)) ?? ""
        lane.belowRendered = belowRendered
        lane.threads = threads(in: folder, index: index)
        return lane
    }

    /// The threads of one folder: indexed ones in order, then any file the
    /// index did not know, sorted by name. Underscored files are the
    /// project's own, not threads.
    private static func threads(in folder: URL, index: [Entry]) -> [Thread] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" && !$0.lastPathComponent.hasPrefix(".")
                      && !$0.lastPathComponent.hasPrefix("_") }
        var byName: [String: URL] = [:]
        for f in files { byName[f.lastPathComponent] = f }
        var out: [Thread] = []
        var seen = Set<String>()
        for entry in index {
            guard let url = byName[entry.file], !seen.contains(entry.file) else { continue }
            seen.insert(entry.file)
            guard let text = read(url) else {
                print("lanes: cannot read \(folder.lastPathComponent)/\(entry.file) as text — left alone")
                continue
            }
            out.append(Thread(id: entry.id, title: url.deletingPathExtension().lastPathComponent,
                              text: text, rendered: entry.rendered,
                              width: entry.width.map { Lane.clampWidth(CGFloat($0)) } ?? Lane.defaultWidth))
        }
        for name in byName.keys.sorted() where !seen.contains(name) {
            guard let text = read(byName[name]!) else { continue }
            out.append(Thread(id: UUID().uuidString, title: String(name.dropLast(3)), text: text))
        }
        return out
    }

    /// nil when the file cannot be read as text. Nil, not "" — an unreadable
    /// file shown as an empty lane would be overwritten with emptiness on the
    /// first keystroke, which is how another app here once lost a note.
    private static func read(_ url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .newlines)
    }

    // MARK: - Paths

    /// The lane's file, or its folder when split.
    func url(for lane: Lane) -> URL {
        Self.root.appendingPathComponent(lane.isSplit ? lane.title : lane.title + ".md")
    }
    func aboveURL(for lane: Lane) -> URL { url(for: lane).appendingPathComponent(Self.aboveFile) }
    func belowURL(for lane: Lane) -> URL { url(for: lane).appendingPathComponent(Self.belowFile) }
    func url(for thread: Thread, in lane: Lane) -> URL {
        Self.root.appendingPathComponent(lane.title).appendingPathComponent(thread.title + ".md")
    }

    func lane(_ id: String) -> Lane? { lanes.first { $0.id == id } }
    private func index(of id: String) -> Int? { lanes.firstIndex { $0.id == id } }
    private func indices(lane laneID: String, thread threadID: String) -> (Int, Int)? {
        guard let i = index(of: laneID),
              let j = lanes[i].threads.firstIndex(where: { $0.id == threadID }) else { return nil }
        return (i, j)
    }

    private func writeIndex() {
        func entry(_ t: Thread) -> Entry {
            Entry(id: t.id, file: t.title + ".md", rendered: t.rendered,
                  width: t.width == Lane.defaultWidth ? nil : Double(t.width),
                  threads: nil, belowRendered: nil)
        }
        let index = Index(lanes: lanes.map { lane in
            lane.isSplit
                ? Entry(id: lane.id, file: lane.title, rendered: lane.rendered, width: nil,
                        threads: lane.threads.map(entry),
                        belowRendered: lane.belowRendered ? true : nil)
                : Entry(id: lane.id, file: lane.title + ".md", rendered: lane.rendered,
                        width: lane.width == Lane.defaultWidth ? nil : Double(lane.width),
                        threads: nil, belowRendered: nil)
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(index).write(to: Self.indexURL, options: .atomic)
    }

    private func post(_ id: String? = nil) {
        NotificationCenter.default.post(name: Self.changed, object: id)
    }

    // MARK: - Writing, which never waits

    /// How often a file's previous version is kept before being overwritten.
    /// Ten minutes of editing between snapshots: enough that an accidental
    /// select-all-and-type, noticed an hour later, is still recoverable from
    /// `.history`, cheap enough that nothing is ever thrown away for space.
    static var historyInterval: TimeInterval = 600
    private var lastSnapshot: [String: Date] = [:]

    /// Every change is written to disk before this returns. No debounce: a
    /// project log is the record, and a crash inside a save window costing
    /// even a sentence is the failure this app must not have. The files are
    /// small and the write is atomic, so the cost is nothing you can feel.
    /// A blank lane keeps its file — an empty column is a project you have
    /// not written about yet, and the column staying put is the reminder.
    func update(_ id: String, text: String) {
        guard let i = index(of: id), lanes[i].text != text else { return }
        lanes[i].text = text
        if lanes[i].isSplit {
            write(text, to: aboveURL(for: lanes[i]), snapshotKey: id + ":above",
                  snapshotName: "\(lanes[i].title) — above")
        } else {
            write(text, to: url(for: lanes[i]), snapshotKey: id, snapshotName: lanes[i].title)
        }
    }

    func updateBelow(_ id: String, text: String) {
        guard let i = index(of: id), lanes[i].isSplit, lanes[i].belowText != text else { return }
        lanes[i].belowText = text
        write(text, to: belowURL(for: lanes[i]), snapshotKey: id + ":below",
              snapshotName: "\(lanes[i].title) — below")
    }

    func updateThread(_ laneID: String, _ threadID: String, text: String) {
        guard let (i, j) = indices(lane: laneID, thread: threadID),
              lanes[i].threads[j].text != text else { return }
        lanes[i].threads[j].text = text
        write(text, to: url(for: lanes[i].threads[j], in: lanes[i]), snapshotKey: threadID,
              snapshotName: "\(lanes[i].title) — \(lanes[i].threads[j].title)")
    }

    /// Kept for the close/quit hooks; with synchronous writes it is a belt
    /// over braces.
    func flush(_ id: String) {
        guard let lane = lane(id) else { return }
        if lane.isSplit {
            write(lane.text, to: aboveURL(for: lane), snapshotKey: id + ":above",
                  snapshotName: "\(lane.title) — above")
            write(lane.belowText, to: belowURL(for: lane), snapshotKey: id + ":below",
                  snapshotName: "\(lane.title) — below")
            for t in lane.threads { write(t.text, to: url(for: t, in: lane), snapshotKey: t.id,
                                          snapshotName: "\(lane.title) — \(t.title)") }
        } else {
            write(lane.text, to: url(for: lane), snapshotKey: id, snapshotName: lane.title)
        }
    }
    func flushAll() { for lane in lanes { flush(lane.id) } }

    private func write(_ text: String, to target: URL, snapshotKey: String, snapshotName: String) {
        snapshotIfDue(previousAt: target, replacing: text, key: snapshotKey, name: snapshotName)
        let body = text.hasSuffix("\n") ? text : text + "\n"
        try? body.write(to: target, atomically: true, encoding: .utf8)
    }

    /// Copies what is on disk into `.history/<name>-<timestamp>.md` before it
    /// is overwritten, at most once per interval per file, and never for an
    /// empty file — there is nothing to lose there.
    private func snapshotIfDue(previousAt target: URL, replacing text: String, key: String, name: String) {
        let now = Date()
        if let last = lastSnapshot[key], now.timeIntervalSince(last) < Self.historyInterval { return }
        guard let previous = try? String(contentsOf: target, encoding: .utf8),
              !previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              previous.trimmingCharacters(in: .newlines) != text else { return }
        try? FileManager.default.createDirectory(at: Self.history, withIntermediateDirectories: true)
        let stamp = Int(now.timeIntervalSince1970)
        try? previous.write(to: Self.history.appendingPathComponent("\(name)-\(stamp).md"),
                            atomically: true, encoding: .utf8)
        lastSnapshot[key] = now
    }

    // MARK: - Lanes

    @discardableResult
    func add(title requested: String = "Untitled") -> Lane {
        let lane = Lane(id: UUID().uuidString,
                        title: uniqueTitle(Self.sanitise(requested), excluding: nil))
        try? "\n".write(to: url(for: lane), atomically: true, encoding: .utf8)
        lanes.append(lane)
        writeIndex()
        post(lane.id)
        return lane
    }

    /// The lane's own note — the whole lane, or the area above the threads.
    func setRendered(_ id: String, _ rendered: Bool) {
        guard let i = index(of: id) else { return }
        lanes[i].rendered = rendered
        writeIndex()
    }

    func setBelowRendered(_ id: String, _ rendered: Bool) {
        guard let i = index(of: id), lanes[i].isSplit else { return }
        lanes[i].belowRendered = rendered
        writeIndex()
    }

    /// Committed once, when the drag ends — the board holds the live width
    /// while the hand is still on it.
    func setWidth(_ id: String, _ width: CGFloat) {
        guard let i = index(of: id), !lanes[i].isSplit else { return }
        lanes[i].width = Lane.clampWidth(width)
        writeIndex()
        post()
    }

    /// Renames the lane and moves its file — or its folder, when split.
    /// Returns the title actually used (the request may have been sanitised
    /// or de-duplicated), or nil if the move failed and nothing changed.
    @discardableResult
    func rename(_ id: String, to requested: String) -> String? {
        guard let i = index(of: id) else { return nil }
        let title = uniqueTitle(Self.sanitise(requested), excluding: id)
        guard title != lanes[i].title else { return title }
        let from = url(for: lanes[i])
        var renamed = lanes[i]
        renamed.title = title
        let to = url(for: renamed)
        if FileManager.default.fileExists(atPath: from.path) {
            do { try FileManager.default.moveItem(at: from, to: to) } catch { return nil }
        } else if !lanes[i].isSplit {
            try? "\n".write(to: to, atomically: true, encoding: .utf8)
        }
        lanes[i].title = title
        writeIndex()
        post()
        return title
    }

    /// Swaps a lane with its neighbour. ±1 is what the menu offers.
    func move(_ id: String, by offset: Int) {
        guard let i = index(of: id), lanes.indices.contains(i + offset) else { return }
        lanes.swapAt(i, i + offset)
        writeIndex()
        post()
    }

    /// Moves the file — or the whole folder — into `.trash`, keeping whatever
    /// is already there.
    func delete(_ id: String) {
        guard let i = index(of: id) else { return }
        let from = url(for: lanes[i])
        if FileManager.default.fileExists(atPath: from.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            let to = Self.trash.appendingPathComponent(
                lanes[i].isSplit ? "\(lanes[i].title)-\(stamp)" : "\(lanes[i].title)-\(stamp).md")
            try? FileManager.default.moveItem(at: from, to: to)
        }
        lanes.remove(at: i)
        writeIndex()
        post()
    }

    // MARK: - Threads

    /// Adds a thread. An unsplit lane is split first: its file becomes the
    /// folder's `_above.md` — the project's words stay where they were, above
    /// the threads, with nothing copied: the file is moved.
    @discardableResult
    func addThread(to laneID: String, title requested: String = "Untitled") -> Thread? {
        guard let i = index(of: laneID) else { return nil }
        if !lanes[i].isSplit {
            let fm = FileManager.default
            let single = url(for: lanes[i])
            let folder = Self.root.appendingPathComponent(lanes[i].title)
            let above = folder.appendingPathComponent(Self.aboveFile)
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: false)
                if fm.fileExists(atPath: single.path) {
                    try fm.moveItem(at: single, to: above)
                } else {
                    try "\n".write(to: above, atomically: true, encoding: .utf8)
                }
            } catch { return nil }
            lanes[i].isSplit = true
        }
        let thread = Thread(id: UUID().uuidString,
                            title: uniqueThreadTitle(Self.sanitise(requested), in: i, excluding: nil))
        try? "\n".write(to: url(for: thread, in: lanes[i]), atomically: true, encoding: .utf8)
        lanes[i].threads.append(thread)
        writeIndex()
        post(laneID)
        return thread
    }

    func setThreadRendered(_ laneID: String, _ threadID: String, _ rendered: Bool) {
        guard let (i, j) = indices(lane: laneID, thread: threadID) else { return }
        lanes[i].threads[j].rendered = rendered
        writeIndex()
    }

    /// Several threads at once — one index write, one board refresh — for a
    /// drag of the project's own edge.
    func setThreadWidths(_ laneID: String, _ widths: [String: CGFloat]) {
        guard let i = index(of: laneID) else { return }
        for j in lanes[i].threads.indices {
            if let w = widths[lanes[i].threads[j].id] { lanes[i].threads[j].width = Lane.clampWidth(w) }
        }
        writeIndex()
        post()
    }

    func setThreadWidth(_ laneID: String, _ threadID: String, _ width: CGFloat) {
        guard let (i, j) = indices(lane: laneID, thread: threadID) else { return }
        lanes[i].threads[j].width = Lane.clampWidth(width)
        writeIndex()
        post()
    }

    @discardableResult
    func renameThread(_ laneID: String, _ threadID: String, to requested: String) -> String? {
        guard let (i, j) = indices(lane: laneID, thread: threadID) else { return nil }
        let title = uniqueThreadTitle(Self.sanitise(requested), in: i, excluding: threadID)
        guard title != lanes[i].threads[j].title else { return title }
        let from = url(for: lanes[i].threads[j], in: lanes[i])
        var renamed = lanes[i].threads[j]
        renamed.title = title
        let to = url(for: renamed, in: lanes[i])
        if FileManager.default.fileExists(atPath: from.path) {
            do { try FileManager.default.moveItem(at: from, to: to) } catch { return nil }
        } else {
            try? "\n".write(to: to, atomically: true, encoding: .utf8)
        }
        lanes[i].threads[j].title = title
        writeIndex()
        post()
        return title
    }

    func moveThread(_ laneID: String, _ threadID: String, by offset: Int) {
        guard let (i, j) = indices(lane: laneID, thread: threadID),
              lanes[i].threads.indices.contains(j + offset) else { return }
        lanes[i].threads.swapAt(j, j + offset)
        writeIndex()
        post()
    }

    /// Moves the thread's file to `.trash`. Deleting the last thread of a
    /// project whose below-area is empty folds it back into a single file —
    /// the project's words were above the threads all along, and with no
    /// threads left there is nothing for a folder to hold.
    func deleteThread(_ laneID: String, _ threadID: String) {
        guard let (i, j) = indices(lane: laneID, thread: threadID) else { return }
        let from = url(for: lanes[i].threads[j], in: lanes[i])
        if FileManager.default.fileExists(atPath: from.path) {
            let to = Self.trash.appendingPathComponent(
                "\(lanes[i].title) — \(lanes[i].threads[j].title)-\(Int(Date().timeIntervalSince1970)).md")
            try? FileManager.default.moveItem(at: from, to: to)
        }
        lanes[i].threads.remove(at: j)
        writeIndex()
        if lanes[i].threads.isEmpty, lanes[i].belowText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            unsplit(laneID)
        } else {
            post()
        }
    }

    /// A project with no threads left becomes a single file again: its
    /// above-text (and below-text, if any, after a blank line) becomes
    /// `<Title>.md`, and the folder goes once nothing else is in it.
    @discardableResult
    func unsplit(_ laneID: String) -> Bool {
        guard let i = index(of: laneID), lanes[i].isSplit, lanes[i].threads.isEmpty else { return false }
        let fm = FileManager.default
        let folder = url(for: lanes[i])
        let below = lanes[i].belowText.trimmingCharacters(in: .whitespacesAndNewlines)
        let merged = below.isEmpty ? lanes[i].text : lanes[i].text + "\n\n" + below
        var single = lanes[i]
        single.isSplit = false
        let to = url(for: single)
        do {
            try (merged.hasSuffix("\n") ? merged : merged + "\n")
                .write(to: to, atomically: true, encoding: .utf8)
            try? fm.removeItem(at: folder.appendingPathComponent(Self.aboveFile))
            try? fm.removeItem(at: folder.appendingPathComponent(Self.belowFile))
            let leftovers = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            if leftovers.allSatisfy({ $0.hasPrefix(".") }) { try? fm.removeItem(at: folder) }
        } catch { return false }
        lanes[i].isSplit = false
        lanes[i].text = merged
        lanes[i].belowText = ""
        lanes[i].belowRendered = false
        writeIndex()
        post()
        return true
    }

    // MARK: - The vault

    /// Off the board, kept whole: the lane's file or folder moves into
    /// `_vault/` under its own name (numbered if that name is already there)
    /// and leaves the index. Nothing is rewritten.
    @discardableResult
    func vault(_ id: String) -> Bool {
        guard let i = index(of: id) else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.vault, withIntermediateDirectories: true)
        let from = url(for: lanes[i])
        let to = Self.vault.appendingPathComponent(
            Self.uniqueName(lanes[i].title, ext: lanes[i].isSplit ? "" : ".md", in: Self.vault))
        if fm.fileExists(atPath: from.path) {
            do { try fm.moveItem(at: from, to: to) } catch { return false }
        }
        lanes.remove(at: i)
        writeIndex()
        post()
        return true
    }

    /// A thread goes to `_vault/<Project>/<Thread>.md`, so it can be found
    /// beside its project's other vaulted threads. The project folds back to
    /// one file if this was its last thread and nothing is written below.
    @discardableResult
    func vaultThread(_ laneID: String, _ threadID: String) -> Bool {
        guard let (i, j) = indices(lane: laneID, thread: threadID) else { return false }
        let fm = FileManager.default
        let folder = Self.vault.appendingPathComponent(lanes[i].title)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let from = url(for: lanes[i].threads[j], in: lanes[i])
        let to = folder.appendingPathComponent(
            Self.uniqueName(lanes[i].threads[j].title, ext: ".md", in: folder))
        if fm.fileExists(atPath: from.path) {
            do { try fm.moveItem(at: from, to: to) } catch { return false }
        }
        lanes[i].threads.remove(at: j)
        writeIndex()
        if lanes[i].threads.isEmpty, lanes[i].belowText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            unsplit(laneID)
        } else {
            post()
        }
        return true
    }

    /// What the vault holds, by name — files as "Title", folders as "Title/".
    func vaulted() -> [String] {
        let fm = FileManager.default
        let items = ((try? fm.contentsOfDirectory(at: Self.vault, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
        return items.compactMap { url -> String? in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { return url.lastPathComponent + "/" }
            return url.pathExtension == "md" ? url.deletingPathExtension().lastPathComponent : nil
        }.sorted {
            // By the bare name: with the marker on, "Big 2/" sorted before
            // "Big/" because a space sorts before a slash.
            String($0.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                .localizedCaseInsensitiveCompare(String($1.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
                == .orderedAscending
        }
    }

    /// Back onto the board, at the right, under a title not already in use.
    @discardableResult
    func restore(_ name: String) -> Lane? {
        let fm = FileManager.default
        let isFolder = name.hasSuffix("/")
        let base = isFolder ? String(name.dropLast()) : name
        let from = Self.vault.appendingPathComponent(isFolder ? base : base + ".md")
        guard fm.fileExists(atPath: from.path) else { return nil }
        let title = uniqueTitle(base, excluding: nil)
        let to = Self.root.appendingPathComponent(isFolder ? title : title + ".md")
        do { try fm.moveItem(at: from, to: to) } catch { return nil }
        let lane: Lane
        if isFolder {
            lane = Self.folderLane(id: UUID().uuidString, folder: to, index: [],
                                   rendered: false, belowRendered: false)
        } else {
            guard let text = Self.read(to) else { return nil }
            lane = Lane(id: UUID().uuidString, title: title, text: text)
        }
        lanes.append(lane)
        writeIndex()
        post(lane.id)
        return lane
    }

    // MARK: - Titles, which are filenames

    static func sanitise(_ raw: String) -> String {
        var title = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while title.hasPrefix(".") { title.removeFirst() }
        if title.count > 80 { title = String(title.prefix(80)) }
        return title.isEmpty ? "Untitled" : title
    }

    /// `base`, or `base 2`, `base 3`… — against the other lanes *and* the
    /// names on disk (files and folders alike), case-insensitively, since the
    /// filesystem is.
    func uniqueTitle(_ base: String, excluding id: String?) -> String {
        let own = id.flatMap(lane)?.title.lowercased()
        var taken = Set(lanes.filter { $0.id != id }.map { $0.title.lowercased() })
        let onDisk = ((try? FileManager.default.contentsOfDirectory(atPath: Self.root.path)) ?? [])
            .filter { !$0.hasPrefix(".") && !$0.hasPrefix("_") }
            .map { ($0.hasSuffix(".md") ? String($0.dropLast(3)) : $0).lowercased() }
        taken.formUnion(onDisk.filter { $0 != own })
        var candidate = base, n = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate
    }

    /// A name not yet used in `directory`, for either a file or a folder.
    private static func uniqueName(_ base: String, ext: String, in directory: URL) -> String {
        let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .map { ($0.hasSuffix(".md") ? String($0.dropLast(3)) : $0).lowercased() })
        var candidate = base, n = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate + ext
    }

    private func uniqueThreadTitle(_ base: String, in i: Int, excluding id: String?) -> String {
        let own = lanes[i].threads.first { $0.id == id }?.title.lowercased()
        var taken = Set(lanes[i].threads.filter { $0.id != id }.map { $0.title.lowercased() })
        let folder = Self.root.appendingPathComponent(lanes[i].title)
        let onDisk = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(3)).lowercased() }
        taken.formUnion(onDisk.filter { $0 != own })
        var candidate = base, n = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate
    }
}
