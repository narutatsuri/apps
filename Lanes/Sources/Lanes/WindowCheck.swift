import AppKit

/// `LANES_WINTEST=1` — is the board actually a sideways canvas of full-height
/// columns? Reads the live view tree, since a screenshot is not available on
/// this machine: the outer scroll view's document must be wider than the
/// window once there are more lanes than fit, and every lane's text view must
/// stand nearly the full height of the content — a column that came out
/// short is the whole layout wrong, and invisible to a logic test.
enum WindowCheck {
    /// `LANES_SNAPSHOT=<path.png>` — the window's content, drawn offscreen
    /// through AppKit's own display cache. Not a screenshot (no permission
    /// needed) and web views do not paint, but the editors, headers and
    /// separators do, which is what a layout complaint is about.
    static func scheduleSnapshot(to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            MainActor.assumeIsolated {
                guard let content = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                      let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                    print("FAIL  snapshot — no window"); exit(1)
                }
                content.cacheDisplay(in: content.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("wrote \(path) \(Int(content.bounds.width))×\(Int(content.bounds.height))")
                }
                exit(0)
            }
        }
    }

    /// `LANES_RENAMETEST=1` — the gesture that lost three lanes their names:
    /// click a title, type a new one, click somewhere else. Drives the real
    /// AppKit field editor and then takes focus away, exactly as a click
    /// elsewhere does, and asks the store and the disk what the lane is
    /// called. Expects a fixture with a lane titled "Alpha".
    static func scheduleRenameTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            MainActor.assumeIsolated { runRenameTest() }
        }
    }

    @MainActor
    private static func runRenameTest() {
        var fails = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { fails += 1 }
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let content = window.contentView else {
            print("FAIL  rename test — no visible window"); exit(1)
        }
        var fields: [NSTextField] = []
        func walk(_ v: NSView) {
            for sub in v.subviews {
                if let f = sub as? NSTextField, f.isEditable, f.stringValue == "Alpha" { fields.append(f) }
                walk(sub)
            }
        }
        walk(content)
        guard let field = fields.first else {
            print("FAIL  rename test — no title field showing 'Alpha'"); exit(1)
        }
        // Click into the title, type a new name, click away — no Return.
        window.makeFirstResponder(field)
        print("  focused: editor=\(field.currentEditor() != nil) firstResponder=\(type(of: window.firstResponder as Any))")
        field.currentEditor()?.selectAll(nil)
        field.currentEditor()?.insertText("Beta")
        print("  typed: field shows '\(field.stringValue)'")
        window.makeFirstResponder(nil)
        print("  blurred: editor=\(field.currentEditor() != nil) field shows '\(field.stringValue)'")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            MainActor.assumeIsolated {
                let store = LaneStore.shared
                let titles = store.lanes.map(\.title)
                check("clicking away from a retyped title renames the lane",
                      titles.contains("Beta") && !titles.contains("Alpha"),
                      "store says \(titles) — the name used to live only in the field")
                let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: LaneStore.root.path)) ?? []
                check("and the file on disk follows",
                      onDisk.contains("Beta.md") && !onDisk.contains("Alpha.md"),
                      "disk has \(onDisk.filter { $0.hasSuffix(".md") })")
                check("the words went with it",
                      store.lanes.first { $0.title == "Beta" }?.text == "alpha's words")
                print(fails == 0 ? "\nALL PASS" : "\n\(fails) FAILURE(S)")
                exit(fails == 0 ? 0 : 1)
            }
        }
    }

    static func schedule() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            MainActor.assumeIsolated { run() }
        }
    }

    @MainActor
    private static func run() {
        var fails = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { fails += 1 }
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let content = window.contentView else {
            print("FAIL  window check — no visible window"); exit(1)
        }
        var scrolls: [NSScrollView] = []
        var editors: [NSView] = []
        func walk(_ v: NSView) {
            for sub in v.subviews {
                if let s = sub as? NSScrollView { scrolls.append(s) }
                if String(describing: type(of: sub)).contains("JotTextView") { editors.append(sub) }
                walk(sub)
            }
        }
        walk(content)
        let lanes = LaneStore.shared.lanes
        // Every column the board should show, left to right: a lane's own
        // width, or each of its threads' widths when it is split.
        let columns: [CGFloat] = lanes.flatMap { $0.isSplit ? $0.threads.map(\.width) : [$0.width] }
        let outer = scrolls.max { ($0.documentView?.frame.width ?? 0) < ($1.documentView?.frame.width ?? 0) }
        let docWidth = outer?.documentView?.frame.width ?? 0
        let wanted = columns.reduce(0, +)
        check("the canvas is as wide as the columns it holds",
              docWidth >= wanted,
              "document \(Int(docWidth))pt for column widths \(columns.map { Int($0) })")
        check("wider than the window, so it scrolls sideways",
              docWidth > content.bounds.width,
              "document \(Int(docWidth))pt, window \(Int(content.bounds.width))pt")
        // A split project also has two note areas, above and below its
        // threads, at known heights; everything else is a column. Sorting by
        // height ratio was wrong here: a thread came out at exactly half the
        // window and fell on the threshold.
        let scrollViews = editors.compactMap { $0.enclosingScrollView }
        func isPane(_ s: NSScrollView) -> Bool {
            abs(s.frame.height - Lane.aboveHeight) <= 2 || abs(s.frame.height - Lane.belowHeight) <= 2
        }
        let panes = scrollViews.filter(isPane)
        let columnViews = scrollViews.filter { !isPane($0) }
        let splitLanes = lanes.filter(\.isSplit)
        check("one editor per column, threads included", columnViews.count == columns.count,
              "\(columnViews.count) column editors, \(columns.count) columns")
        check("two note areas per split project, above and below the threads",
              panes.count == splitLanes.count * 2,
              "\(panes.count) note areas for \(splitLanes.count) split projects, "
            + "heights \(panes.map { Int($0.frame.height) })")
        // Columns in left-to-right order, each as wide as its lane or thread
        // says — this is what proves a dragged width is honoured, not just
        // stored.
        let ordered = columnViews.sorted {
            $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
        }
        let widths = ordered.map { $0.frame.width }
        check("each column is as wide as its lane or thread says",
              widths.count == columns.count
              && zip(widths, columns).allSatisfy { abs($0 - $1) <= 2 },
              "on screen \(widths.map { Int($0) }), wanted \(columns.map { Int($0) })")
        // Heights: a lane's editor stands nearly the full window; a thread's
        // yields exactly the note areas above and below it, plus chrome.
        let kinds: [Bool] = lanes.flatMap { $0.isSplit ? $0.threads.map { _ in true } : [false] }
        let full = content.bounds.height
        let threadRoom = full - Lane.aboveHeight - Lane.belowHeight
        check("lanes stand nearly the full height; threads yield the note areas' height",
              ordered.count == kinds.count && zip(ordered, kinds).allSatisfy { view, isThread in
                  let h = view.frame.height
                  return isThread ? (h < threadRoom && h > threadRoom - 120) : h > full * 0.75
              },
              "heights \(ordered.map { Int($0.frame.height) }), window \(Int(full)), "
            + "thread room \(Int(threadRoom)) minus headers and dividers")
        print(fails == 0 ? "\nALL PASS" : "\n\(fails) FAILURE(S)")
        exit(fails == 0 ? 0 : 1)
    }
}
