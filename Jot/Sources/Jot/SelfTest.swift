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
