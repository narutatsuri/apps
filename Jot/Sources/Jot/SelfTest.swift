import Foundation
import CoreGraphics
import AppKit
import WebKit

/// The parts that would fail silently: the file round-trip (a lossy one eats
/// what you typed) and the title extraction (a wrong one makes the menu useless
/// without ever looking broken). Run with --selftest.
enum SelfTest {
    @MainActor
    static func run() -> Never {
        func rgbText(_ colour: NSColor) -> String {
            let c = colour.usingColorSpace(.sRGB) ?? colour
            return "rgb(\(Int((c.redComponent * 255).rounded())), "
                 + "\(Int((c.greenComponent * 255).rounded())), "
                 + "\(Int((c.blueComponent * 255).rounded())))"
        }

        // Line-buffered: piped to a file, a crash or a hang would otherwise
        // swallow every result printed before it, which is exactly when you
        // most want to see them.
        setvbuf(stdout, nil, _IOLBF, 0)
        var fails = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { fails += 1 }
        }

        // --- round-trip
        var s = Sticky(id: "20260806-101500-abcd")
        s.colour = .blue
        s.floats = false
        s.rendered = true
        s.frame = CGRect(x: 120, y: 340, width: 400, height: 300)
        // The characters that break naive round-trips: a leading ---, markdown
        // fences, tabs, unicode, and a line that looks like frontmatter.
        s.text = """
        # Ideas

        - [ ] a thing with `code` and $x_i^2$
        - colour: not-a-field

        ```swift
        let x = 1  // tabs\tand \\backslashes
        ```

        ---

        …and a trailing unicode ellipsis
        """

        guard let back = Sticky(markdown: s.markdown, id: "wrong-id") else {
            print("FAIL  round-trip — did not parse at all"); exit(1)
        }
        check("round-trip: text byte-identical", back.text == s.text,
              "fences, tabs, backslashes and a --- line all survive")
        check("round-trip: id comes from the file, not the filename",
              back.id == s.id, "renaming a file must not fork a sticky")
        check("round-trip: colour", back.colour == .blue)
        check("round-trip: floats false survives",
              back.floats == false, "the default is true, so this is the one that can silently flip")
        check("round-trip: rendered", back.rendered == true)
        check("round-trip: important survives",
              { var o = s; o.important = true
                return Sticky(markdown: o.markdown, id: "x")?.important == true }(),
              "a never-delete flag that does not survive a relaunch protects nothing")
        check("a note never marked important carries no important field",
              !s.markdown.contains("important"),
              "every pre-existing file must round-trip byte-identically")
        check("absent means not important", back.important == false)
        check("round-trip: open state",
              { var o = s; o.isOpen = false
                return Sticky(markdown: o.markdown, id: "x")?.isOpen == false }(),
              "a note you closed must not reappear on every launch")
        check("a note with no open field defaults to showing",
              Sticky(markdown: "no frontmatter here", id: "x")?.isOpen == true,
              "a note made from the terminal has never had a window; it still has to appear")
        check("round-trip: frame", back.frame == s.frame)
        check("a body line that looks like a field is not eaten",
              back.text.contains("colour: not-a-field"),
              "only the block before the first closing --- is frontmatter")

        // --- a plain markdown file dropped into the folder
        let bare = Sticky(markdown: "just some text\nover two lines", id: "fallback-id")
        check("a file with no frontmatter is still a sticky", bare != nil)
        check("its id falls back to the filename", bare?.id == "fallback-id")
        check("its text is intact", bare?.text == "just some text\nover two lines")
        check("it gets the default colour", bare?.colour == .yellow)

        // --- titles, which are all the menu has to go on
        func title(_ text: String) -> String {
            var s = Sticky(id: "x"); s.text = text; return s.title
        }
        check("heading marks are stripped", title("# Project ideas") == "Project ideas")
        check("list bullets are stripped", title("- buy milk") == "buy milk")
        check("blank leading lines are skipped", title("\n\n\nreal content") == "real content")
        check("a horizontal rule is not a title", title("---\n\nthe actual line") == "the actual line",
              "otherwise a note that starts with a rule is titled with the rule")
        check("an empty sticky says so", title("   \n  ") == "Empty sticky")
        check("blockquote marks are stripped", title("> quoted thought") == "quoted thought")

        // --- blankness decides whether a file is kept
        check("whitespace only counts as blank",
              { var s = Sticky(id: "x"); s.text = "  \n\t\n "; return s.isBlank }(),
              "a scratch buffer emptied out should not leave a file behind")
        check("one character is not blank",
              { var s = Sticky(id: "x"); s.text = "x"; return !s.isBlank }())

        // --- frames, which come back off disk as text
        check("a frame parses", Sticky.parseFrame("10,20,300,200")
              == CGRect(x: 10, y: 20, width: 300, height: 200))
        check("a degenerate frame is refused", Sticky.parseFrame("10,20,0,0") == nil,
              "a zero-size window is invisible and unrecoverable by dragging")
        check("a malformed frame is refused", Sticky.parseFrame("10,20") == nil)
        check("a missing frame is fine", Sticky.parseFrame(nil) == nil)

        // --- ids
        // 200 is more than the birthday bound tolerates on 16 random bits, so
        // this failed about a quarter of the time until the id gained a counter.
        let ids = (0..<200).map { _ in Sticky.newID() }
        check("ids are unique even when made in the same second",
              Set(ids).count == ids.count,
              "holding the hotkey down makes several at once")
        check("ids sort by creation time",
              ids.first! < ids.last! || ids.allSatisfy { $0.hasPrefix(String(ids[0].prefix(8))) })

        // --- every colour is usable
        check("every colour defines both papers",
              StickyColour.allCases.allSatisfy { $0.paper.light != 0 && $0.paper.dark != 0 })
        check("colours are distinct",
              Set(StickyColour.allCases.map { $0.paper.light }).count == StickyColour.allCases.count)

        // --- emptying a note must be recoverable, not final
        //
        // The store treats a blank note as one you are finished with, and this
        // used to call removeItem: any path that produced a transiently empty
        // note — a second instance of the app, a view that had not read its
        // file yet — destroyed it outright. That happened, twice, to real
        // notes. The root cause is guarded against in the view now, but this is
        // the guarantee that does not depend on having found every such path.
        let probeID = "selftest-recoverable-" + Sticky.newID()
        let probeURL = Store.shared.url(for: probeID)
        let trashed = Store.trash.appendingPathComponent(probeID)
        try? "---\nid: \(probeID)\n---\n\nwords worth keeping\n"
            .write(to: probeURL, atomically: true, encoding: .utf8)
        Store.shared.reload()
        check("the probe note was picked up", Store.shared.sticky(probeID) != nil)

        var emptied = Store.shared.sticky(probeID) ?? Sticky(id: probeID)
        emptied.text = ""
        Store.shared.save(emptied, debounce: 0)
        Store.shared.flush(probeID)

        let stillThere = FileManager.default.fileExists(atPath: probeURL.path)
        let inTrash = (try? FileManager.default.contentsOfDirectory(
            atPath: Store.trash.path))?.filter { $0.hasPrefix(probeID) } ?? []
        check("an emptied note leaves the folder", !stillThere)
        check("but lands in .trash rather than being destroyed", !inTrash.isEmpty,
              "emptying a note has to be recoverable — it has cost real writing twice")
        if let name = inTrash.first {
            let saved = (try? String(contentsOf: Store.trash.appendingPathComponent(name),
                                     encoding: .utf8)) ?? ""
            check("and the trashed copy still holds the words",
                  saved.contains("words worth keeping"))
        }
        // Leave no litter behind.
        for name in inTrash {
            try? FileManager.default.removeItem(at: Store.trash.appendingPathComponent(name))
        }
        _ = trashed
        Store.shared.reload()

        // --- important means the store refuses, not that a button hides
        //
        // The view drops its delete button when the flag is on, but the button
        // is courtesy. The guarantee is here: delete() declines, and even the
        // emptied-out path — the one that bins blank notes — leaves the file.
        let keepID = "selftest-important-" + Sticky.newID()
        let keepURL = Store.shared.url(for: keepID)
        try? "---\nid: \(keepID)\nimportant: true\n---\n\ndo not lose this\n"
            .write(to: keepURL, atomically: true, encoding: .utf8)
        Store.shared.reload()
        check("the important probe was picked up",
              Store.shared.sticky(keepID)?.important == true)

        Store.shared.delete(keepID)
        check("delete() refuses an important note",
              Store.shared.sticky(keepID) != nil
              && FileManager.default.fileExists(atPath: keepURL.path),
              "the missing button is the view's courtesy; this is the guarantee")

        var blanked = Store.shared.sticky(keepID) ?? Sticky(id: keepID)
        blanked.text = ""
        Store.shared.save(blanked, debounce: 0)
        Store.shared.flush(keepID)
        check("even emptied out, an important note keeps its file",
              FileManager.default.fileExists(atPath: keepURL.path),
              "blank-means-done must not outrank never-delete")

        var released = Store.shared.sticky(keepID) ?? blanked
        released.important = false
        Store.shared.save(released, debounce: 0)
        Store.shared.flush(keepID)
        Store.shared.delete(keepID)
        check("toggled off, the note is deletable again",
              Store.shared.sticky(keepID) == nil
              && !FileManager.default.fileExists(atPath: keepURL.path),
              "the flag is a latch, not a life sentence")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: Store.trash.path))?
            .filter({ $0.hasPrefix(keepID) }) ?? [] {
            try? FileManager.default.removeItem(at: Store.trash.appendingPathComponent(name))
        }
        Store.shared.reload()

        // --- the parser, which is invisible in a screenshot and exact here
        func kinds(_ text: String) -> [Highlighter.Kind] {
            Highlighter.styles(in: text).map(\.kind)
        }
        func styled(_ text: String, _ kind: Highlighter.Kind) -> String? {
            guard let s = Highlighter.styles(in: text).first(where: { $0.kind == kind })
            else { return nil }
            return (text as NSString).substring(with: s.range)
        }

        check("bold styles the words, not the asterisks",
              styled("a **strong** word", .bold) == "strong")
        check("italic does not swallow bold",
              styled("**bold** and *slanted*", .italic) == "slanted",
              "a naive single-star pattern matches the inside of ** first")
        check("bold-italic is both, not bold with stray stars",
              styled("***both***", .bold) == "both" && styled("***both***", .italic) == "both")
        check("highlight is its own thing", styled("==look here== ok", .highlight) == "look here")

        // --- emphasis around an equation
        //
        // Maths claims its range so nothing styles *inside* it — the `*` in
        // `$a^*$` is a superscript. That rule used to reject any emphasis whose
        // range merely touched an equation, so a highlight wrapping one was
        // discarded whole and its `==` stayed on screen as literal text.
        check("a highlight may wrap an equation",
              styled("==energy $x^2$ here==", .highlight) == "energy $x^2$ here",
              "both markers are outside the maths; only straddling is ambiguous")
        check("so may bold", styled("**energy $x^2$ here**", .bold) == "energy $x^2$ here")
        check("so may strikethrough",
              styled("~~gone $x^2$ here~~", .strikethrough) == "gone $x^2$ here")
        check("a highlight may contain an equals sign",
              styled("==a = b==", .highlight) == "a = b",
              "the old pattern forbade `=` in the content, so any highlight over "
            + "an equation failed twice over")
        check("and an equation full of them",
              styled("==energy $E=mc^2$ here==", .highlight) == "energy $E=mc^2$ here")
        check("emphasis that straddles an equation is still rejected",
              styled("==a $b== c$", .highlight) == nil,
              "the closing == is inside the maths, so what was meant is anyone's guess")
        check("a star inside maths is still a superscript, not italic",
              styled("$a^* + b^*$", .italic) == nil)
        check("two highlights on one line stay two",
              Highlighter.styles(in: "==first== and ==second==")
                  .filter { $0.kind == .highlight }.count == 2,
              "the lazy pattern must not run the first opener to the last closer")
        check("headings style the text after the hashes",
              styled("## Ideas for later", .heading(level: 2)) == "Ideas for later")
        check("heading level is read from the hashes",
              kinds("### deep").contains(.heading(level: 3)))
        check("inline code is styled", styled("run `git push` now", .code) == "git push")
        check("a fenced block is styled whole",
              styled("```\nlet x = 1\n```", .codeBlock)?.contains("let x = 1") == true)
        check("emphasis inside code is left alone", kinds("`**not bold**`").allSatisfy { $0 != .bold },
              "code is claimed before emphasis for exactly this")
        check("strikethrough", styled("~~dropped~~", .strikethrough) == "dropped")
        check("a link styles its text and keeps the url",
              styled("see [the paper](https://arxiv.org/abs/1)", .link(url: "https://arxiv.org/abs/1"))
                == "the paper")
        check("list bullets are marked", kinds("- one\n- two").filter { $0 == .listBullet }.count == 2)
        check("numbered lists too", kinds("1. first").contains(.listBullet))
        check("plain prose is left completely alone", kinds("just a sentence").isEmpty,
              "every span costs an attribute pass on every keystroke")
        check("an unclosed marker styles nothing",
              kinds("**never closed").isEmpty, "otherwise typing ** makes the rest of the note bold")

        // --- maths
        check("inline maths is recognised",
              styled("energy is $E = mc^2$ here", .math(display: false)) == "E = mc^2")
        check("display maths is recognised",
              styled("$$\\int_0^1 x\\,dx$$", .math(display: true)) == "\\int_0^1 x\\,dx")
        check("$$ is not read as two empty inline spans",
              kinds("$$a$$").filter { $0 == .math(display: false) }.isEmpty)
        check("a price is not maths",
              kinds("it cost $5 and then $7 more").allSatisfy { $0 != .math(display: false) },
              "the renderer applies the same guard, so styling it would mislead")
        check("maths survives inside a heading",
              styled("# The bound $n \\log n$", .math(display: false)) == "n \\log n")
        check("asterisks inside maths are not italics",
              kinds("$a^*b$").allSatisfy { $0 != .italic }, "a superscript star is not emphasis")
        check("a $ inside a code span stays code",
              kinds("`cd $HOME && cd $PWD`").allSatisfy { $0 != .math(display: false) })

        // --- markers come out of the text
        //
        // The point of the whole exercise: you type ** and the ** goes away.
        func shown(_ markdown: String) -> String {
            Attributed.make(from: markdown, ink: .black, paper: .white).string
        }
        check("bold loses its asterisks", shown("a **strong** word") == "a strong word")
        check("italic loses its asterisk", shown("*slanted*") == "slanted")
        check("bold-italic loses all six", shown("***both***") == "both")
        check("highlight loses its equals", shown("==look here==") == "look here")
        check("strikethrough loses its tildes", shown("~~dropped~~") == "dropped")
        check("inline code loses its backticks", shown("run `git push` now") == "run git push now")
        check("a heading loses its hashes and the space after",
              shown("## Ideas for later") == "Ideas for later")
        check("a link shows its text, not its url",
              shown("see [the paper](https://arxiv.org/abs/1)") == "see the paper")
        check("a fenced block keeps its fences",
              shown("```\nlet x = 1\n```").contains("```"),
              "there would otherwise be no way to see where the block ends")
        check("list bullets stay", shown("- one\n- two") == "- one\n- two",
              "a bullet reads as a bullet; taking it out would mean owning indentation")
        check("an equation becomes one character",
              shown("mass $E = mc^2$ here") == "mass \u{FFFC} here",
              "so the caret steps over an equation the way it steps over a letter")
        check("money is left alone", shown("it cost $5") == "it cost $5")

        // --- and the styling goes on
        func style(_ markdown: String, at index: Int) -> InlineStyle {
            let a = Attributed.make(from: markdown, ink: .black, paper: .white)
            guard index < a.length else { return [] }
            return InlineStyle(rawValue: a.attribute(Attributed.styleKey, at: index,
                                                     effectiveRange: nil) as? Int ?? 0)
        }
        check("the styling lands on the word", style("a **strong** word", at: 2) == .bold)
        check("and not on its neighbours", style("a **strong** word", at: 0) == [])
        check("bold-italic carries both", style("***both***", at: 0) == [.bold, .italic])
        // The equation is one attachment character; index 7 is it, in "energy ⍰ here".
        check("the equation inside a highlight is itself highlighted",
              style("==energy $x^2$ here==", at: 7) == .highlight,
              "otherwise the highlight has a hole in it where the maths is, and "
            + "the markdown written back out breaks into two highlights")
        check("an equation outside any emphasis carries no style",
              style("energy $x^2$ here", at: 7) == [])
        // An equation is a picture rendered over an opaque background, so it
        // paints over any highlight drawn behind it — measured as a rectangular
        // hole in the tint. The highlight has to go into the render instead.
        check("a highlighted equation is drawn against the highlight",
              rgbText(Attributed.mathPaper(style: .highlight, paper: .white))
                  != rgbText(NSColor.white),
              "otherwise the tint stops either side of the maths")
        check("an unhighlighted one is drawn against the paper",
              rgbText(Attributed.mathPaper(style: [], paper: .white)) == rgbText(NSColor.white))
        check("the highlight is flattened, not left translucent",
              Attributed.mathPaper(style: .highlight, paper: .white).alphaComponent == 1,
              "the renderer wants a solid background")

        // --- images: `![alt](path)` is one picture, and round-trips exactly
        check("an image link is an image, not a link",
              kinds("see ![shot](_assets/a.png) here").contains { if case .image = $0 { return true }; return false }
              && !kinds("see ![shot](_assets/a.png) here").contains { if case .link = $0 { return true }; return false },
              "the `[alt](path)` inside must not be read as a link")
        check("a plain link is still a link",
              kinds("see [docs](https://x.y) here").contains { if case .link = $0 { return true }; return false })
        check("a bang before a space is not an image",
              !kinds("wow! [docs](https://x.y)").contains { if case .image = $0 { return true }; return false })
        for text in ["see ![shot](_assets/a.png) here",
                     "==a ![i](p.png) b==",
                     "**![only](x.jpg)**",
                     "![](no-alt.png) and $x$ and ![two](2.png)"] {
            let back = Attributed.markdown(from: Attributed.make(from: text, ink: .black, paper: .white))
            check("an image round-trips byte-identically: \(text)", back == text, "got \(back)")
        }
        let pictured = Attributed.make(from: "a ![shot](missing.png) b", ink: .black, paper: .white)
        check("the picture is one attachment character carrying its source",
              pictured.length == 5
              && (pictured.attribute(Attributed.imageKey, at: 2, effectiveRange: nil) as? ImageSpec)?.path == "missing.png"
              && (pictured.attribute(.attachment, at: 2, effectiveRange: nil) as? ImageAttachment)?.image != nil,
              "a file that cannot be found still shows *something* where it was")

        // A picture fits the column it is in: asked by a 380pt column, a
        // 600×300 image comes back 354 wide (380 − 2×5 padding − 2×8 margin)
        // and 177 tall; asked by a wide one, it stays its own size.
        let big = NSImage(size: NSSize(width: 600, height: 300))
        Attributed.imageResolver = { _ in big }
        let fitted = Attributed.make(from: "![big](anywhere.png)", ink: .black, paper: .white)
        if let att = fitted.attribute(.attachment, at: 0, effectiveRange: nil) as? ImageAttachment {
            let narrow = NSTextContainer(size: NSSize(width: 380, height: 1000))
            let wide = NSTextContainer(size: NSSize(width: 1000, height: 1000))
            let inNarrow = att.attachmentBounds(for: narrow, proposedLineFragment: .zero,
                                                glyphPosition: .zero, characterIndex: 0)
            let inWide = att.attachmentBounds(for: wide, proposedLineFragment: .zero,
                                              glyphPosition: .zero, characterIndex: 0)
            check("a picture fits its column, aspect kept",
                  inNarrow.size == NSSize(width: 354, height: 177), "got \(inNarrow.size)")
            check("and is never scaled up past its own size",
                  inWide.size == NSSize(width: 600, height: 300), "got \(inWide.size)")
        } else {
            check("a resolved picture is an ImageAttachment", false)
        }
        Attributed.imageResolver = { NSImage(contentsOfFile: $0) }

        // --- what counts as changing a note
        //
        // The menu sorts by `updated`, and saves happen for things that are not
        // edits — a window moved, a note opened, the state written back at
        // launch. Stamping the time on all of them made every note share a
        // timestamp after a restart and the order arbitrary.
        let stampID = "selftest-stamp-" + Sticky.newID()
        var stamped = Sticky(id: stampID)
        stamped.text = "the words"
        Store.shared.save(stamped, debounce: 0)
        Store.shared.flush(stampID)
        let firstStamp = Store.shared.sticky(stampID)?.updatedAt

        var moved = Store.shared.sticky(stampID) ?? stamped
        moved.frame = CGRect(x: 10, y: 10, width: 300, height: 200)
        Store.shared.save(moved, debounce: 0)
        Store.shared.flush(stampID)
        check("moving a note is not editing it",
              Store.shared.sticky(stampID)?.updatedAt == firstStamp,
              "otherwise a restart restamps every note and the list order is lost")

        var edited = Store.shared.sticky(stampID) ?? stamped
        edited.text = "different words"
        Store.shared.save(edited, debounce: 0)
        Store.shared.flush(stampID)
        check("changing the words is",
              Store.shared.sticky(stampID)?.updatedAt != firstStamp,
              "a note you just typed into has to sort to the top")
        try? FileManager.default.removeItem(at: Store.shared.url(for: stampID))
        Store.shared.reload()

        // --- typing a heading, one keystroke at a time
        //
        // The reported bug: "# T" collapses into a heading, and then the very
        // next letter typed comes out unformatted, while everything after it is
        // fine. Reproduced here by driving a real NSTextView through the real
        // Coordinator the way typing does — insertText goes through the same
        // delegate path as the keyboard.
        let typeParent = MarkdownEditor(text: .constant(""), paper: .white,
                                        handle: nil as EditorHandle?, ink: .black)
        let typeCoord = MarkdownEditor.Coordinator(typeParent)
        let typeStorage = NSTextStorage()
        let typeLayout = NSLayoutManager()
        typeStorage.addLayoutManager(typeLayout)
        let typeContainer = NSTextContainer(
            size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        typeLayout.addTextContainer(typeContainer)
        let typeView = JotTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300),
                                   textContainer: typeContainer)
        typeView.isRichText = true
        typeView.allowsUndo = true
        typeView.delegate = typeCoord
        typeView.typingAttributes = Attributed.attributes(style: [], ink: .black)
        typeCoord.view = typeView

        for ch in "# Title" {
            typeView.insertText(String(ch), replacementRange: typeView.selectedRange())
        }

        check("typing '# Title' leaves the buffer reading 'Title'",
              typeView.string == "Title",
              "was '\(typeView.string)' — the marker should have collapsed at the first letter")
        var unstyled: [Int] = []
        for i in 0..<(typeView.textStorage?.length ?? 0) {
            let level = typeView.textStorage?.attribute(Attributed.headingKey, at: i,
                                                        effectiveRange: nil) as? Int ?? 0
            if level != 1 { unstyled.append(i) }
        }
        check("every letter of the title is heading-styled",
              unstyled.isEmpty,
              "unstyled at \(unstyled) — index 1 is the reported bug: the collapse "
            + "suppresses the selection callback that refreshes typingAttributes, "
            + "so the next keystroke inserts with the stale plain ones")
        check("and the file gets one heading, not a heading with a plain letter inside",
              Attributed.markdown(from: typeView.attributedString()) == "# Title",
              "was '\(Attributed.markdown(from: typeView.attributedString()))'")

        // --- reformatting a heading that has already collapsed
        //
        // Once "## Title" is styled there are no hashes left on screen to edit,
        // so retyping the marker is the only way to change the level — and the
        // marker you type is the level you mean, absolutely. "# " makes it a
        // title whatever it was; "### " a sub-sub-heading; down as well as up.
        func typeAtFront(_ marker: String) {
            typeView.setSelectedRange(NSRange(location: 0, length: 0))
            for ch in marker {
                typeView.insertText(String(ch), replacementRange: typeView.selectedRange())
            }
        }
        // The buffer holds "# Title" from the sequence above.
        typeAtFront("## ")
        check("typing '## ' at the front of a title makes it a subtitle",
              Attributed.markdown(from: typeView.attributedString()) == "## Title",
              "was '\(Attributed.markdown(from: typeView.attributedString()))' — "
            + "the typed marker is the level, not an increment")
        check("and the screen shows no hashes",
              typeView.string == "Title", "was '\(typeView.string)'")
        typeAtFront("# ")
        check("typing '# ' takes it back to a title — down, not just up",
              Attributed.markdown(from: typeView.attributedString()) == "# Title",
              "was '\(Attributed.markdown(from: typeView.attributedString()))' — "
            + "reformatting has to work in both directions")
        typeAtFront("### ")
        check("and '### ' jumps straight to level three",
              Attributed.markdown(from: typeView.attributedString()) == "### Title",
              "no stepping through level two on the way")
        check("the next letter typed is styled at the new level",
              { typeView.setSelectedRange(NSRange(location: 0, length: 0))
                typeView.insertText("A", replacementRange: typeView.selectedRange())
                let level = typeView.textStorage?.attribute(Attributed.headingKey, at: 0,
                            effectiveRange: nil) as? Int
                typeView.setSelectedRange(NSRange(location: 1, length: 0))
                typeView.deleteBackward(nil)
                return level == 3 }())
        check("hashes without a trailing space do not re-level",
              { typeView.setSelectedRange(NSRange(location: 0, length: 0))
                typeView.insertText("#", replacementRange: typeView.selectedRange())
                let out = Attributed.markdown(from: typeView.attributedString())
                typeView.deleteBackward(nil)
                return out == "### #Title" }(),
              "the space is the trigger, same as every other marker — a heading "
            + "whose text happens to start with '#1' must stay a literal")

        // --- ⌫ at the start of a heading un-titles it
        //
        // The marker collapsed when the heading was made, so there is nothing
        // visible to delete; ⌫ at the line's first position deletes the
        // title-ness instead, and only then behaves like ⌫ again.
        // The buffer holds "### Title" from the sequence above.
        typeView.setSelectedRange(NSRange(location: 0, length: 0))
        typeView.deleteBackward(nil)
        check("⌫ at the start of a heading makes it plain text",
              Attributed.markdown(from: typeView.attributedString()) == "Title",
              "was '\(Attributed.markdown(from: typeView.attributedString()))' — "
            + "this is the only way back; the marker gesture stops at level one")
        check("the words survive it",
              typeView.string == "Title", "was '\(typeView.string)'")
        check("and what is typed next is plain",
              { typeView.setSelectedRange(NSRange(location: 0, length: 0))
                typeView.insertText("A", replacementRange: typeView.selectedRange())
                let level = typeView.textStorage?.attribute(Attributed.headingKey, at: 0,
                            effectiveRange: nil) as? Int ?? 0
                typeView.setSelectedRange(NSRange(location: 1, length: 0))
                typeView.deleteBackward(nil)
                return level == 0 }())
        check("⌫ on a plain line still deletes a character",
              { typeView.setSelectedRange(NSRange(location: 2, length: 0))
                typeView.deleteBackward(nil)
                let out = typeView.string
                typeView.insertText("i", replacementRange: typeView.selectedRange())
                return out == "Ttle" }(),
              "only the start of a heading line is special")
        check("⌫ mid-heading still deletes a character too",
              { typeAtFront("## ")
                typeView.setSelectedRange(NSRange(location: 2, length: 0))
                typeView.deleteBackward(nil)
                let out = Attributed.markdown(from: typeView.attributedString())
                typeView.insertText("i", replacementRange: typeView.selectedRange())
                typeView.setSelectedRange(NSRange(location: 0, length: 0))
                typeView.deleteBackward(nil)
                return out == "## Ttle" }(),
              "the heading survives ordinary editing inside the line")
        check("and a heading can be made again afterwards",
              { typeAtFront("# ")
                let out = Attributed.markdown(from: typeView.attributedString())
                typeView.setSelectedRange(NSRange(location: 0, length: 0))
                typeView.deleteBackward(nil)
                return out == "# Title" }(),
              "un-title and re-title must be a round trip, not a one-way door")

        // --- ⌃⌫
        //
        // The system binding sent it somewhere much bigger — "deleted
        // everything before my cursor" was the report. It now deletes one word,
        // the same as ⌥⌫.
        let wordView = JotTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        wordView.string = "delete the last word"
        wordView.setSelectedRange(NSRange(location: wordView.string.count, length: 0))
        if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                     modifierFlags: [.control], timestamp: 0,
                                     windowNumber: 0, context: nil,
                                     characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
                                     isARepeat: false, keyCode: 51) {
            wordView.keyDown(with: ev)
            check("⌃⌫ deletes one word, not the line",
                  wordView.string == "delete the last ",
                  "was '\(wordView.string)'")
            wordView.keyDown(with: ev)
            check("and again for the word before it",
                  wordView.string == "delete the ",
                  "was '\(wordView.string)'")
        } else {
            check("⌃⌫ event could be synthesised", false)
        }

        // --- the menu bar menu
        //
        // There is no menu bar to read this off — the app is LSUIElement — and
        // driving the status item needs assistive access this process does not
        // have. So the menu is built and read here instead. It matters because
        // "Show All" used to be one item that renamed itself to "Hide All" as
        // soon as a single note was on screen, which is exactly when you want to
        // bring the others back.
        let barMenu = NSMenu()
        AppDelegate().menuNeedsUpdate(barMenu)
        let titles = barMenu.items.map(\.title)
        check("the menu offers Show All", titles.contains("Show All Stickies"),
              "got \(titles.prefix(4))")
        check("and Hide All, separately", titles.contains("Hide All Stickies"),
              "one item that renames itself cannot show what it is currently hiding")
        check("Show All comes before Hide All",
              (titles.firstIndex(of: "Show All Stickies") ?? 99)
                  < (titles.firstIndex(of: "Hide All Stickies") ?? 0))
        check("Hide All is greyed when nothing is showing",
              barMenu.items.first { $0.title == "Hide All Stickies" }?.isEnabled
                  == (StickyWindow.visibleCount > 0))

        // --- a single tilde strikes out too
        check("one tilde either side strikes text out",
              styled("~gone~ but not this", .strikethrough) == "gone")
        check("two tildes still work", styled("~~gone~~ ok", .strikethrough) == "gone")
        check("a single tilde does not match inside a double",
              Highlighter.styles(in: "~~gone~~").filter { $0.kind == .strikethrough }.count == 1,
              "matching the inside of ~~a~~ would leave a stray marker on screen")
        check("two home directories are not a strikethrough",
              styled("see ~/Developer and ~/Documents", .strikethrough) == nil,
              "the same hazard as \"$5 and $7\" being read as maths")
        check("a lone tilde with spaces around it is just a tilde",
              styled("a ~ b ~ c", .strikethrough) == nil)
        check("a path on its own is untouched",
              styled("cd ~/Developer", .strikethrough) == nil)
        check("one tilde loses its marker on screen", shown("~gone~") == "gone")
        // Both spellings mean the same thing, and the file gets the canonical
        // one. Stated as a test rather than left to be discovered: `~a~` is
        // accepted on the way in and written back as `~~a~~`.
        check("a single tilde is written back as a double",
              Attributed.markdown(from: Attributed.make(from: "~gone~", ink: .black,
                                                        paper: .white)) == "~~gone~~",
              "was \(Attributed.markdown(from: Attributed.make(from: "~gone~", ink: .black, paper: .white)))")

        // --- snapping one note's size to another's
        //
        // A live resize cannot be photographed mid-drag, so the arithmetic is
        // the thing to check. Throughout: `top` is a note 400 wide sitting above
        // the one being resized, which starts at x=100 and is dragged by its
        // right-hand side (so its left edge is what stays put).
        let top = CGRect(x: 100, y: 600, width: 400, height: 200)
        let below = CGRect(x: 100, y: 300, width: 380, height: 200)
        let byTheRight = Snap.Anchor(fixedMinX: true, fixedMinY: true)

        func width(_ proposed: CGFloat, _ others: [CGRect] = [top],
                   from: CGRect = below, anchor: Snap.Anchor = byTheRight) -> CGFloat {
            Snap.resize(from: from, to: CGSize(width: proposed, height: from.height),
                        anchor: anchor, others: others).width
        }

        check("a width dragged near a neighbour's takes it exactly",
              width(396) == 400,
              "got \(width(396)) — this is the whole feature: two notes the same "
            + "width without measuring them")
        check("and from the other side too", width(405) == 400)
        check("a width nowhere near one is left alone",
              width(340) == 340, "got \(width(340))")
        check("just outside the threshold does not snap",
              width(400 - Snap.threshold - 1) == 400 - Snap.threshold - 1)
        check("exactly on the threshold does",
              width(400 - Snap.threshold) == 400)
        check("with no other notes nothing snaps",
              width(396, []) == 396, "the first note on screen must resize freely")

        // The right edge landing on the neighbour's right edge. Here the notes
        // are offset, so matching widths and aligning edges disagree — 40 wide
        // would put this note's right edge on the top note's left edge.
        let offset = CGRect(x: 60, y: 300, width: 380, height: 200)
        check("an edge that lands on a neighbour's edge snaps to it",
              width(438, [top], from: offset) == 440,
              "got \(width(438, [top], from: offset)) — 60 + 440 = 500, the top "
            + "note's right edge")
        check("the nearer of the two kinds of snap wins",
              width(402, [top], from: offset) == 400,
              "matching the width is 2 away, aligning the right edge is 38; "
            + "got \(width(402, [top], from: offset))")

        // Dragging the left-hand side: the right edge is what stays put, so the
        // same target width means moving the opposite edge.
        let byTheLeft = Snap.Anchor(fixedMinX: false, fixedMinY: true)
        check("dragging the other side snaps the other edge",
              width(396, [top], from: below, anchor: byTheLeft) == 400,
              "got \(width(396, [top], from: below, anchor: byTheLeft))")
        check("aligning to the left edge of a neighbour",
              // below.maxX is 480; snapping the left edge to top.minX (100)
              // means a width of 380 — which it already is, so ask for 384.
              width(384, [top], from: below, anchor: byTheLeft) == 380)

        check("a snap is refused if it would go under the minimum size",
              Snap.resize(from: below, to: CGSize(width: 396, height: 200),
                          anchor: byTheRight, others: [top],
                          minimum: CGSize(width: 420, height: 140)).width == 396,
              "shrinking a note below what it is allowed to be is not a snap")
        check("height snaps the same way",
              Snap.resize(from: below, to: CGSize(width: 380, height: 196),
                          anchor: byTheRight, others: [top]).height == 200)
        check("the anchor is read from where the drag started",
              Snap.Anchor.from(mouse: CGPoint(x: 470, y: 400), in: below).fixedMinX
              && !Snap.Anchor.from(mouse: CGPoint(x: 110, y: 400), in: below).fixedMinX,
              "grab the right-hand side and the left edge is what stays put")

        // --- the equation-measuring window, which must never be seen
        //
        // It is a 2400×1200 borderless slab parked at -10000. AppKit pulls
        // windows back onto a display when the screen arrangement changes, and
        // a monitor being plugged in was enough to drop this one in the middle
        // of a screen — the paper colour, no title bar, nothing to close.
        let far = NSRect(x: -10000, y: -10000, width: 2400, height: 1200)
        let measuring = MeasuringWindow(contentRect: NSRect(x: 0, y: 0, width: 2400, height: 1200),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
        check("the measuring window refuses to be pulled onto a screen",
              measuring.constrainFrameRect(far, to: NSScreen.main) == far,
              "got \(measuring.constrainFrameRect(far, to: NSScreen.main))")
        // The constraint is real and this is what it does — a titled window of
        // the same size is dragged to roughly where the stray was found. Named
        // here so the override above is not mistaken for cargo cult.
        let titled = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 2400, height: 1200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        check("AppKit really does relocate an offscreen window",
              titled.constrainFrameRect(far, to: NSScreen.main) != far,
              "got \(titled.constrainFrameRect(far, to: NSScreen.main)) — if this "
            + "ever stops being true, the constraint is gone and so is the bug")
        // The defence that holds however it got moved: nothing is drawn.
        check("the measuring window is never on screen at all",
              MathRenderer.measuringWindowIsInvisible,
              "offscreen is a position and positions get changed; transparent "
            + "stopped it being seen but not being there — it still landed under "
            + "an external monitor's menu bar and made it glitch. A window never "
            + "ordered in cannot be relocated onto a display at all")
        check("a heading is recorded as a heading",
              (Attributed.make(from: "# Title", ink: .black, paper: .white)
                .attribute(Attributed.headingKey, at: 0, effectiveRange: nil) as? Int) == 1)
        check("bold is drawn bold, not just labelled bold",
              (Attributed.make(from: "**x**", ink: .black, paper: .white)
                .attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
                .map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)

        // --- and comes back off again, losslessly
        //
        // This is the one that matters. The buffer holds no markers, so the
        // markers have to be reconstructed on the way to disk; a serialiser that
        // drops one silently eats what was written, and nothing on screen says so.
        for source in ["plain text with no markup at all",
                       "a **strong** word",
                       "*slanted*",
                       "***both***",
                       "==look here==",
                       "~~dropped~~",
                       "run `git push` now",
                       "# Title",
                       "### deep heading",
                       "- one\n- two\n- three",
                       "> a quoted line",
                       "see [the paper](https://arxiv.org/abs/1)",
                       "mass $E = mc^2$ here",
                       "$$\\sum_{i=1}^n i = \\frac{n(n+1)}{2}$$",
                       "it cost $5 and then $7 more",
                       "**bold** then *italic* then `code` then ==mark==",
                       "# Heading with **bold** and $x^2$ in it",
                       // Nested emphasis. Each of these used to come back with
                       // its outer markers doubled around the inner run —
                       // `==a ====**b**==== c==` — because every run was
                       // wrapped in its whole style set instead of the markers
                       // being opened and closed as the style changed.
                       "==a **b** c==",
                       "==a *b* c==",
                       "**bold with ==mark== inside**",
                       "==see [the paper](https://arxiv.org/abs/1) here==",
                       "==a **b** and $x^2$ and *c*==",
                       "==energy $x^2$ here==",
                       "==energy $E=mc^2$ here==",
                       "**energy $x^2$ here**",
                       "~~gone $x^2$ here~~",
                       "==a = b==",
                       "==first== and ==second==",
                       "==maths $x^2$ then **bold** after==",
                       "## # Title",
                       "```\nlet x = 1\n```",
                       "line one\n\nline three after a blank\n",
                       "trailing spaces  \nand a second line"] {
            let back = Attributed.markdown(from: Attributed.make(from: source, ink: .black,
                                                                 paper: .white))
            check("round-trips: \(source.replacingOccurrences(of: "\n", with: "⏎"))",
                  back == source, "came back as \(back.replacingOccurrences(of: "\n", with: "⏎"))")
        }

        // --- ⌘B without markers: it sets an attribute, and the file gets the stars
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        editor.textStorage?.setAttributedString(
            Attributed.make(from: "make this bold", ink: .black, paper: .white))
        editor.setSelectedRange(NSRange(location: 5, length: 4))
        editor.jotToggle(.bold)
        check("⌘B leaves the text alone on screen",
              editor.string == "make this bold", "was \(editor.string)")
        check("⌘B puts the markers in the file",
              Attributed.markdown(from: editor.attributedString()) == "make **this** bold",
              "was \(Attributed.markdown(from: editor.attributedString()))")
        editor.setSelectedRange(NSRange(location: 5, length: 4))
        editor.jotToggle(.bold)
        check("⌘B twice takes it back off",
              Attributed.markdown(from: editor.attributedString()) == "make this bold",
              "toggling has to be symmetric or ⌘B becomes a one-way door")

        // --- ⌘⇧H across an equation
        //
        // The equation is one attachment character, and the toggle used to skip
        // it — "you cannot embolden a picture". But the style is also what says
        // where the markers go, so dragging a highlight over an equation left
        // the middle unstyled and the file was written as two highlights with a
        // bare `$x^2$` stranded between them.
        let mathEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        mathEditor.textStorage?.setAttributedString(
            Attributed.make(from: "energy $x^2$ here", ink: .black, paper: .white))
        let whole = NSRange(location: 0, length: mathEditor.textStorage?.length ?? 0)
        mathEditor.setSelectedRange(whole)
        mathEditor.jotToggle(.highlight)
        check("⌘⇧H over an equation highlights the whole phrase",
              Attributed.markdown(from: mathEditor.attributedString())
                  == "==energy $x^2$ here==",
              "was \(Attributed.markdown(from: mathEditor.attributedString()))")
        check("the equation survived being highlighted",
              mathEditor.textStorage?.attribute(Attributed.mathKey, at: 7,
                                                effectiveRange: nil) != nil,
              "the attachment's own attributes are the equation; replacing them "
            + "wholesale would delete it")
        mathEditor.setSelectedRange(NSRange(location: 0, length: mathEditor.textStorage?.length ?? 0))
        mathEditor.jotToggle(.highlight)
        check("and ⌘⇧H again takes it off, equation included",
              Attributed.markdown(from: mathEditor.attributedString()) == "energy $x^2$ here",
              "was \(Attributed.markdown(from: mathEditor.attributedString()))")

        // --- the main menu, which is what makes ⌘C and ⌘V work at all
        //
        // Not a check that the menu items exist — a check that pressing the key
        // actually moves text to the pasteboard. The bug this replaces was
        // invisible in every other way.
        //
        // --selftest never reaches Main.main(), so there is no NSApplication
        // yet and NSApp is nil; and a process launched from a shell cannot be
        // made frontmost, so the panel has to be non-activating to take key
        // focus. Run `JOT_KEYTEST=1 open -a Jot` for the same checks inside the
        // real app under the real policy.
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        MainMenu.install(target: app.delegate ?? NSNull())
        // Everything left runs inside the event loop and exits from there.
        // NSApplication.stop() is only honoured while an event is being
        // dispatched, so unwinding run() from a dispatched block is more
        // trouble than it is worth in a test binary that is about to exit.
        KeyTest.run(nonactivating: true) { results in
            for r in results { check(r.label, r.ok, r.ok ? "" : r.detail) }
            // --- KaTeX, in the actual web view the rendered note uses
            //
            // Polled with asyncAfter rather than a nested RunLoop.run: this
            // already runs inside NSApplication's event loop, and spinning a
            // second one inside it starves the web view's replies — the test
            // reported a broken renderer when what was broken was the test.
            let webRoot = Bundle.main.resourceURL?.appendingPathComponent("web")
            guard let webRoot,
                  FileManager.default.fileExists(
                    atPath: webRoot.appendingPathComponent("render.html").path) else {
                check("KaTeX resources are bundled", false, "Resources/web/render.html missing")
                print(fails == 0 ? "\nALL PASS" : "\n\(fails) FAILURE(S)")
                exit(fails == 0 ? 0 : 1)
            }
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            // Deliberately dark. The rendered view is drawn on the sticky's own
            // paper colour, so a system-appearance rule put pale grey text on
            // yellow and the note became unreadable — a failure that only ever
            // showed up for someone running the OS in dark mode.
            web.appearance = NSAppearance(named: .darkAqua)
            web.loadFileURL(webRoot.appendingPathComponent("render.html"),
                            allowingReadAccessTo: webRoot)
            let script = "window.renderMarkdown ? (renderMarkdown("
                + "'mass $E = mc^2$ and $$\\\\sum_i x_i$$'), "
                + "document.getElementById('out').innerHTML) : null"

            func whenRendered(_ attempt: Int, _ body: @escaping (String) -> Void) {
                web.evaluateJavaScript(script) { value, _ in
                    if let html = value as? String, !html.isEmpty { body(html); return }
                    if attempt > 60 { body(""); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        whenRendered(attempt + 1, body)
                    }
                }
            }

            whenRendered(0) { html in
                check("KaTeX typesets inline maths in the rendered view",
                      html.contains("katex") && !html.contains("$E = mc^2$"),
                      html.isEmpty ? "the web view never answered" : "no .katex markup in the output")
                check("KaTeX typesets display maths", html.contains("katex-display"))
                check("the typeset output is real markup, not the source",
                      html.contains("<span") && !html.contains("\\sum"))

                // --- and nothing is drawn in a colour you cannot read
                //
                // Checked under a dark system appearance on purpose: the page
                // used to take its colour from prefers-color-scheme, which put
                // pale grey text on yellow paper for anyone running the OS in
                // dark mode. The palette is handed in by the app now, so both
                // of Jot's own themes are checked against the ink they claim.
                let inkScript = """
                    (function () {
                      renderMarkdown('# One\\n## Two\\n### Three\\n\\nbody **bold** text\\n\\n- item\\n\\n> quoted\\n\\n| a | b |\\n| - | - |\\n| c | d |');
                      var look = function (s) {
                        var e = document.querySelector(s);
                        if (!e) return 'missing';
                        var c = getComputedStyle(e);
                        return c.color + ' @' + c.opacity;
                      };
                      return JSON.stringify({
                        body: look('body'), h1: look('h1'), h2: look('h2'), h3: look('h3'),
                        p: look('p'), li: look('li'), quote: look('blockquote'),
                        cell: look('td'), strong: look('strong')
                      });
                    })()
                    """

            @MainActor func inkCheck(_ preference: Theme.Preference,
                                     _ done: @escaping () -> Void) {
                Theme.preference = preference
                let expected = rgbText(Theme.ink)
                let palette = MarkdownPreview.palette()
                let vars = String(data: (try? JSONSerialization.data(withJSONObject: palette))
                                    ?? Data(), encoding: .utf8) ?? "{}"
                // Applied on its own rather than prepended to the measuring
                // script: a combined body came back as "an unsupported type"
                // from WebKit on the second call, and one statement per call is
                // not worth debugging around.
                // evaluateJavaScript with an expression, not callAsyncJavaScript:
                // a second call of the latter came back as "an unsupported
                // type" whatever the body, and this form already works above.
                web.evaluateJavaScript("window.applyTheme(\(vars));")
                web.evaluateJavaScript(inkScript) { value, error in
                    let json = value as? String ?? ""
                    let failure = error.map { " js error: \($0.localizedDescription)" } ?? ""
                    let colours = (try? JSONSerialization.jsonObject(
                        with: Data(json.utf8))) as? [String: String] ?? [:]
                    // Anything not fully opaque in the note's own ink is text
                    // someone cannot read on that paper.
                    let wrong = colours.filter { $0.value != expected + " @1" }
                    check("\(preference.rawValue) mode renders every kind of text in its ink",
                          !colours.isEmpty && wrong.isEmpty,
                          colours.isEmpty ? "no answer\(failure) raw=\(json.prefix(120))"
                                          : "expected \(expected), got "
                                            + wrong.map { "\($0.key)=\($0.value)" }
                                                   .sorted().joined(separator: " "))
                    done()
                }
            }

            inkCheck(.light) {
                inkCheck(.dark) {
                    Theme.preference = .system    // leave the app as it was found
                    print(fails == 0 ? "\nALL PASS" : "\n\(fails) FAILURE(S)")
                    exit(fails == 0 ? 0 : 1)
                }
            }

            }
        }
        app.run()

        print(fails == 0 ? "\nALL PASS" : "\n\(fails) FAILURE(S)")
        exit(fails == 0 ? 0 : 1)
    }
}
