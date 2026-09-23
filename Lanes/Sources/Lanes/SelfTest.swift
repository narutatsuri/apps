import Foundation
import AppKit

/// The parts that would fail silently: the file round-trip (a lossy one eats
/// what you wrote), naming (a title is a filename, and two lanes cannot share
/// one), order and view-mode persistence (the board must come back the way it
/// was left), and the editor actually being Jot's. Run with --selftest.
///
/// Everything runs in a private temp folder — LANES_ROOT is set before the
/// store is first touched — so the real lanes are never written to.
enum SelfTest {
    @MainActor
    static func run() -> Never {
        let temp = NSTemporaryDirectory() + "lanes-selftest-\(getpid())"
        setenv("LANES_ROOT", temp, 1)

        var fails = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { fails += 1 }
        }
        func file(_ title: String) -> String { LaneStore.root.appendingPathComponent(title + ".md").path }
        func exists(_ title: String) -> Bool { FileManager.default.fileExists(atPath: file(title)) }
        let fm = FileManager.default

        let store = LaneStore.shared
        store.bootstrap()
        check("the lanes folder is created", fm.fileExists(atPath: LaneStore.root.path))
        check("a fresh board is empty", store.lanes.isEmpty)

        // --- adding
        let a = store.add()
        check("a new lane is a file named after it", exists("Untitled"),
              "the title is the filename — the folder reads like the board")
        let b = store.add()
        check("a second untitled lane does not overwrite the first",
              b.title == "Untitled 2" && exists("Untitled 2"), "got \(b.title)")

        // --- the words, on disk
        let words = "# Plan\n\n- [ ] read **the** paper — $x^2$\n\n> second paragraph, with `code`"
        store.update(a.id, text: words)
        store.flush(a.id)
        let raw = (try? String(contentsOfFile: file("Untitled"), encoding: .utf8)) ?? ""
        check("the file is exactly the words plus a newline", raw == words + "\n",
              "no frontmatter: a lane copies straight into a report")
        store.reload()
        check("the words round-trip", store.lane(a.id)?.text == words,
              "blank lines, markers, quotes and maths all survive")

        store.update(a.id, text: words + "\ntyped later")
        check("typing is on disk before update() even returns",
              ((try? String(contentsOfFile: file("Untitled"), encoding: .utf8)) ?? "")
                  .hasSuffix("typed later\n"),
              "no debounce window — a crash mid-sentence must cost nothing")

        // --- never overwrite what could not be read
        let opaque = LaneStore.root.appendingPathComponent("Binary.md")
        try? Data([0xFF, 0xFE, 0x00, 0xC3, 0x28]).write(to: opaque)
        store.reload()
        check("a file that is not readable text is left alone, not shown as empty",
              !store.lanes.contains { $0.title == "Binary" }
              && (try? Data(contentsOf: opaque))?.count == 5,
              "an unreadable file shown as an empty lane would be overwritten by the first keystroke")
        try? fm.removeItem(at: opaque)
        store.reload()

        // --- the previous version is kept
        LaneStore.historyInterval = 0
        store.update(a.id, text: "rewritten entirely")
        let history = (try? fm.contentsOfDirectory(
            atPath: LaneStore.root.appendingPathComponent(".history").path)) ?? []
        let kept = history.first { $0.hasPrefix("Untitled-") }
            .flatMap { try? String(contentsOfFile: LaneStore.root.appendingPathComponent(".history/\($0)").path,
                                   encoding: .utf8) } ?? ""
        check("the version being overwritten is kept in .history",
              kept.hasSuffix("typed later\n"),
              "got \(history) — a select-all-and-type must be recoverable")
        LaneStore.historyInterval = 600
        store.update(a.id, text: words + "\ntyped later")

        // --- titles are filenames
        let renamed = store.rename(a.id, to: "Alpha / Beta: gamma")
        check("a title is sanitised for the filesystem",
              renamed == "Alpha - Beta- gamma", "got \(renamed ?? "nil")")
        check("the file moved with the title",
              exists("Alpha - Beta- gamma") && !exists("Untitled"))
        check("the words moved with it",
              store.lane(a.id)?.text.hasSuffix("typed later") == true
              && ((try? String(contentsOfFile: file("Alpha - Beta- gamma"), encoding: .utf8)) ?? "")
                  .contains("typed later"))
        check("its id and place are stable across a rename",
              store.lanes.map(\.id) == [a.id, b.id])
        let c = store.add()
        check("the freed name is available again", c.title == "Untitled")
        let clash = store.rename(c.id, to: "alpha - beta- gamma")
        check("a clashing title gets a number, case-insensitively",
              clash?.lowercased() == "alpha - beta- gamma 2", "got \(clash ?? "nil")")
        check("an empty title falls back rather than vanishing",
              LaneStore.sanitise("   ") == "Untitled" && LaneStore.sanitise(".hidden") == "hidden")

        // --- order and view mode come back
        store.setRendered(b.id, true)
        store.move(c.id, by: -1)
        store.move(c.id, by: -1)
        check("a lane moves one place at a time", store.lanes.map(\.id) == [c.id, a.id, b.id])
        store.move(c.id, by: -1)
        check("and cannot fall off the edge", store.lanes.first?.id == c.id)
        store.reload()
        check("column order and the rendered flag survive a relaunch",
              store.lanes.map(\.id) == [c.id, a.id, b.id]
              && store.lane(b.id)?.rendered == true,
              "the index beside the files carries what a bare markdown file cannot")

        // --- a file dropped into the folder by hand
        try? "hello from vim\n".write(toFile: file("Dropped"), atomically: true, encoding: .utf8)
        store.reload()
        check("a markdown file dropped into the folder becomes a lane",
              store.lanes.last?.title == "Dropped" && store.lanes.last?.text == "hello from vim",
              "appended after the ordered ones, never lost")

        // --- blank is not deleted
        store.update(a.id, text: "")
        store.flush(a.id)
        check("an emptied lane keeps its file", exists("Alpha - Beta- gamma"),
              "a project column with nothing in it yet is still a project")

        // --- deletion is recoverable
        store.delete(b.id)
        let trashed = (try? fm.contentsOfDirectory(atPath: LaneStore.trash.path)) ?? []
        check("a deleted lane's file goes to .trash",
              !exists("Untitled 2") && trashed.contains { $0.hasPrefix("Untitled 2-") },
              "got \(trashed)")
        store.reload()
        check("and it stays gone", store.lane(b.id) == nil)

        // --- widths: dragged once, remembered
        check("a lane starts at the default width",
              store.lanes.allSatisfy { $0.width == Lane.defaultWidth })
        store.setWidth(a.id, 560)
        store.setWidth(c.id, 9000)
        check("a dragged width is clamped to something usable",
              store.lane(c.id)?.width == 1200 && Lane.clampWidth(10) == 240,
              "a column that swallows the window is no longer a column")
        let indexText = (try? String(contentsOfFile: LaneStore.root.appendingPathComponent("lanes.json").path,
                                     encoding: .utf8)) ?? ""
        check("only non-default widths are written to the index",
              indexText.contains("560") && !indexText.contains("380"),
              "the index stays small for the common case")
        store.reload()
        check("widths survive a relaunch",
              store.lane(a.id)?.width == 560 && store.lane(c.id)?.width == 1200
              && store.lane(store.lanes.last!.id)?.width == Lane.defaultWidth)

        // --- threads: a project that is a folder
        //
        // Splitting moves the file into the folder as the project's own
        // `_above.md`, never copies it; the words stay above the threads with
        // nothing lost, and every thread file is written the same synchronous
        // way a lane is.
        let proj = store.add(title: "Thesis")
        store.update(proj.id, text: "chapter outline")
        let second = store.addThread(to: proj.id, title: "Experiments")
        let folder = LaneStore.root.appendingPathComponent("Thesis")
        check("adding a thread turns the lane into a folder",
              store.lane(proj.id)?.isSplit == true
              && fm.fileExists(atPath: folder.appendingPathComponent("_above.md").path)
              && !exists("Thesis"),
              "the single file moved into the folder as _above.md")
        check("the words stay above the threads, and the thread is the only thread",
              store.lane(proj.id)?.text == "chapter outline"
              && store.lane(proj.id)?.threads.map(\.title) == ["Experiments"])
        store.updateThread(proj.id, second!.id, text: "run 1: $\\alpha = 0.1$")
        check("a thread's words are on disk before update returns",
              (try? String(contentsOfFile: folder.appendingPathComponent("Experiments.md").path,
                           encoding: .utf8)) == "run 1: $\\alpha = 0.1$\n")
        store.update(proj.id, text: "chapter outline, revised")
        store.updateBelow(proj.id, text: "so far: nothing works")
        check("the project's own writing above and below is on disk at once",
              (try? String(contentsOfFile: folder.appendingPathComponent("_above.md").path,
                           encoding: .utf8)) == "chapter outline, revised\n"
              && (try? String(contentsOfFile: folder.appendingPathComponent("_below.md").path,
                              encoding: .utf8)) == "so far: nothing works\n")
        let third = store.addThread(to: proj.id, title: "experiments")
        check("thread titles are unique within their folder, case-insensitively",
              third?.title.lowercased() == "experiments 2", "got \(third?.title ?? "nil")")
        store.renameThread(proj.id, third!.id, to: "Writing")
        check("a thread rename moves its file",
              fm.fileExists(atPath: folder.appendingPathComponent("Writing.md").path)
              && !fm.fileExists(atPath: folder.appendingPathComponent("experiments 2.md").path))
        store.setThreadWidth(proj.id, second!.id, 500)
        store.setThreadRendered(proj.id, second!.id, true)
        store.setBelowRendered(proj.id, true)
        store.moveThread(proj.id, third!.id, by: -1)
        store.reload()
        let back = store.lane(proj.id)
        check("thread order, width and rendered view survive a relaunch",
              back?.threads.map(\.title) == ["Writing", "Experiments"]
              && back?.threads.last?.width == 500 && back?.threads.last?.rendered == true,
              "got \(back?.threads.map(\.title) ?? [])")
        check("the above and below writing survive too, with their view modes",
              back?.text == "chapter outline, revised" && back?.belowText == "so far: nothing works"
              && back?.belowRendered == true)
        check("underscored files are never threads",
              back?.threads.contains { $0.title.hasPrefix("_") } == false)
        store.rename(proj.id, to: "Dissertation")
        check("renaming a split project renames its folder",
              fm.fileExists(atPath: LaneStore.root.appendingPathComponent("Dissertation/_above.md").path)
              && !fm.fileExists(atPath: folder.path))
        store.deleteThread(proj.id, second!.id)
        check("a deleted thread goes to .trash",
              ((try? fm.contentsOfDirectory(atPath: LaneStore.trash.path)) ?? [])
                  .contains { $0.hasPrefix("Dissertation — Experiments-") })
        store.deleteThread(proj.id, third!.id)
        check("with words below, a project keeps its folder when its last thread goes",
              store.lane(proj.id)?.isSplit == true && store.lane(proj.id)?.threads.isEmpty == true,
              "folding it into one file would have to decide what to do with the below-text")
        check("merging back joins above and below into one file, words intact",
              store.unsplit(proj.id) && exists("Dissertation")
              && store.lane(proj.id)?.isSplit == false
              && store.lane(proj.id)?.text == "chapter outline, revised\n\nso far: nothing works"
              && !fm.fileExists(atPath: LaneStore.root.appendingPathComponent("Dissertation").path))
        let quick = store.add(title: "Quick")
        store.update(quick.id, text: "just this")
        let only = store.addThread(to: quick.id)
        store.deleteThread(quick.id, only!.id)
        check("with nothing below, deleting the last thread folds the project back on its own",
              store.lane(quick.id)?.isSplit == false && exists("Quick")
              && store.lane(quick.id)?.text == "just this")

        // a folder dropped in by hand
        let handmade = LaneStore.root.appendingPathComponent("Handmade")
        try? fm.createDirectory(at: handmade, withIntermediateDirectories: true)
        try? "one\n".write(to: handmade.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
        try? "two\n".write(to: handmade.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)
        store.reload()
        check("a folder of markdown dropped into the lanes folder is a split project",
              store.lanes.last?.title == "Handmade"
              && store.lanes.last?.threads.map(\.title) == ["A", "B"]
              && store.lanes.last?.text == "",
              "no _above.md yet is simply an empty area, not a missing project")
        store.delete(store.lanes.last!.id)
        check("deleting a split project moves the whole folder to .trash",
              !fm.fileExists(atPath: handmade.path)
              && ((try? fm.contentsOfDirectory(atPath: LaneStore.trash.path)) ?? [])
                  .contains { $0.hasPrefix("Handmade-") })

        // --- dragging a project's edge scales its threads together
        check("threads shrink in proportion",
              Lane.scaled([400, 400], toTotal: 600) == [300, 300]
              && Lane.scaled([300, 600], toTotal: 1800) == [600, 1200])
        check("and each thread still respects the clamp",
              Lane.scaled([240, 240], toTotal: 200) == [240, 240],
              "a project cannot be dragged into slivers")
        let wide = store.add(title: "Wide")
        let w1 = store.addThread(to: wide.id, title: "One")!
        let w2 = store.addThread(to: wide.id, title: "Two")!
        store.setThreadWidths(wide.id, [w1.id: 300, w2.id: 450])
        store.reload()
        check("several thread widths land in one write",
              store.lane(wide.id)?.threads.map(\.width) == [300, 450])

        // --- the vault: off the board, kept whole, and findable again
        let dud = store.add(title: "Dud Project")
        store.update(dud.id, text: "months of notes")
        check("vaulting a lane moves its file into _vault and off the board",
              store.vault(dud.id) && store.lane(dud.id) == nil && !exists("Dud Project")
              && fm.fileExists(atPath: LaneStore.vault.appendingPathComponent("Dud Project.md").path))
        store.reload()
        check("the vault is not a lane, and nothing in it is",
              !store.lanes.contains { $0.title == "_vault" || $0.title == "Dud Project" })
        check("the vault lists what it holds", store.vaulted() == ["Dud Project"],
              "got \(store.vaulted())")
        let big = store.add(title: "Big")
        store.update(big.id, text: "above")
        let keep = store.addThread(to: big.id, title: "Keep")!
        let drop = store.addThread(to: big.id, title: "Drop")!
        store.updateThread(big.id, drop.id, text: "a dead end, but a documented one")
        check("vaulting a thread files it under its project in the vault",
              store.vaultThread(big.id, drop.id)
              && store.lane(big.id)?.threads.map(\.title) == ["Keep"]
              && (try? String(contentsOfFile: LaneStore.vault.appendingPathComponent("Big/Drop.md").path,
                              encoding: .utf8)) == "a dead end, but a documented one\n")
        _ = keep
        check("vaulting a split project moves the whole folder",
              store.vault(big.id)
              && fm.fileExists(atPath: LaneStore.vault.appendingPathComponent("Big 2/_above.md").path),
              "the vault already held a 'Big' folder of vaulted threads, so the project is numbered")
        check("the vault lists folders as projects",
              store.vaulted() == ["Big/", "Big 2/", "Dud Project"], "got \(store.vaulted())")
        let restored = store.restore("Dud Project")
        check("restoring brings the lane back with its words",
              restored?.text == "months of notes" && exists("Dud Project")
              && store.lanes.last?.id == restored?.id
              && !fm.fileExists(atPath: LaneStore.vault.appendingPathComponent("Dud Project.md").path))
        let again = store.add(title: "Big 2")
        let restoredProject = store.restore("Big 2/")
        check("a restored project avoids a title already on the board",
              restoredProject?.title == "Big 2 2" && restoredProject?.isSplit == true
              && restoredProject?.text == "above",
              "got \(restoredProject?.title ?? "nil")")
        _ = again

        // --- pictures: dropped in, kept in _assets, shown in both modes
        ImageStore.install()
        let png = NSImage(size: NSSize(width: 600, height: 300))
        png.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 600, height: 300).fill()
        png.unlockFocus()
        let source = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Run Chart.png")
        if let tiff = png.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: source)
        }
        let link = ImageStore.adopt(source, depth: 0) ?? ""
        check("a dropped image is copied into _assets and linked from the lane",
              link.hasPrefix("![Run-Chart](_assets/Run-Chart-") && link.hasSuffix(".png)")
              && fm.fileExists(atPath: ImageStore.assets.path),
              "got \(link)")
        let deep = ImageStore.adopt(source, depth: 1) ?? ""
        check("a thread's link climbs out of its folder first",
              deep.hasPrefix("![Run-Chart](../_assets/"), "got \(deep)")
        check("two drops of the same file do not collide",
              link != deep && (try? fm.contentsOfDirectory(atPath: ImageStore.assets.path))?.count == 2)
        let path = String(link.dropFirst("![Run-Chart](".count).dropLast())
        check("the link is resolved by name whatever depth it was written at",
              ImageStore.resolve(path) != nil && ImageStore.resolve("../" + path) != nil
              && ImageStore.resolve("nowhere/" + (path as NSString).lastPathComponent) != nil)
        let pictured = Attributed.make(from: "before \(link) after", ink: .black, paper: .white)
        let att = pictured.attribute(.attachment, at: 7, effectiveRange: nil) as? ImageAttachment
        let column = NSTextContainer(size: NSSize(width: 260, height: 1000))
        let inColumn = att?.attachmentBounds(for: column, proposedLineFragment: .zero,
                                             glyphPosition: .zero, characterIndex: 0)
        check("the editor shows the picture itself, fitted to its column with margins",
              att?.image != nil && inColumn?.size == NSSize(width: 234, height: 117),
              "600×300 in a 260pt column → 234×117 — got \(inColumn.map { "\($0.size)" } ?? "no attachment")")
        check("and writes the link back out unchanged",
              Attributed.markdown(from: pictured) == "before \(link) after")
        check("the rendered view gets the picture inlined",
              ImageStore.inlined("x \(link) y").contains("![Run-Chart](data:image/png;base64,")
              && ImageStore.inlined("x ![gone](nowhere.png) y") == "x ![gone](nowhere.png) y",
              "the web view can only read the bundle, so the bytes travel in the markdown")
        try? fm.removeItem(at: source)

        // --- the editor is Jot's
        check("Jot's markdown parser is compiled in",
              !Highlighter.styles(in: "**bold**, ==mark== and $x_i$").isEmpty,
              "the shared files are symlinks into ~/Developer/Jot")

        try? fm.removeItem(atPath: temp)
        print(fails == 0 ? "\nALL PASS" : "\n\(fails) FAILURE(S)")
        exit(fails == 0 ? 0 : 1)
    }
}
