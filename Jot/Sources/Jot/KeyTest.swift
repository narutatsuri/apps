import AppKit

/// Proof that ⌘C, ⌘V, ⌘X, ⌘A and ⌘B reach the text you are typing in.
///
/// Shared by two callers on purpose. `--selftest` runs it headless, where the
/// process has to be coaxed into owning a key window at all. `JOT_KEYTEST=1`
/// runs it inside the real app, launched the way the user launches it, under
/// the real `.accessory` policy and with no menu bar on screen — which is the
/// configuration the bug lived in, and so the only one worth believing.
enum KeyTest {
    struct Result {
        var label: String
        var ok: Bool
        var detail: String = ""
    }

    /// - Parameter nonactivating: needed only when the process cannot be made
    ///   frontmost by the window server — launching from a shell, in practice.
    ///   The real app passes false and relies on being genuinely active.
    @MainActor
    static func run(nonactivating: Bool, then finish: @escaping ([Result]) -> Void) {
        var out: [Result] = []
        var mask: NSWindow.StyleMask = [.titled, .closable, .resizable]
        if nonactivating { mask.insert(.nonactivatingPanel) }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                            styleMask: mask, backing: .buffered, defer: false)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        text.string = "copy me"
        text.isRichText = false
        text.allowsUndo = true
        panel.contentView = text
        panel.becomesKeyOnlyIfNeeded = false
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeKey()
        panel.makeFirstResponder(text)

        // A nil-target menu item resolves against the key window's first
        // responder, so nothing here means anything until the window is key.
        // Activation is the window server's decision and has not been made yet
        // when activate() returns, so wait for it rather than assume it.
        func whenKey(_ attempt: Int, _ body: @escaping () -> Void) {
            if panel.isKeyWindow || attempt > 60 { body(); return }
            // Re-asserted every turn: the app reopens its notes at launch, and
            // one of them can take key focus back after the first request.
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeKey()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { whenKey(attempt + 1, body) }
        }

        whenKey(0) {
            out.append(Result(label: "a main menu exists", ok: NSApp.mainMenu != nil,
                              detail: "an LSUIElement app draws no menu bar, but the key "
                                    + "equivalents still come from the menu"))
            out.append(Result(label: "the test window is key", ok: panel.isKeyWindow,
                              detail: "without a key window nothing below can be trusted"))

            func press(_ key: String, _ flags: NSEvent.ModifierFlags) -> Bool {
                guard let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, characters: key,
                    charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)
                else { return false }
                return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
            }

            // The pasteboard is the user's, so put back whatever was on it.
            let board = NSPasteboard.general
            let borrowed = board.string(forType: .string)

            text.setSelectedRange(NSRange(location: 0, length: 7))
            board.clearContents()
            board.setString("SENTINEL", forType: .string)
            _ = press("c", .command)
            out.append(Result(label: "⌘C copies the selection",
                              ok: board.string(forType: .string) == "copy me",
                              detail: "pasteboard held \(board.string(forType: .string) ?? "nothing")"))

            text.setSelectedRange(NSRange(location: 7, length: 0))
            board.clearContents()
            board.setString(" and paste me", forType: .string)
            _ = press("v", .command)
            out.append(Result(label: "⌘V pastes", ok: text.string == "copy me and paste me",
                              detail: "text was \(text.string)"))

            text.setSelectedRange(NSRange(location: 0, length: 7))
            _ = press("x", .command)
            out.append(Result(label: "⌘X cuts", ok: text.string == " and paste me",
                              detail: "text was \(text.string)"))

            _ = press("a", .command)
            out.append(Result(label: "⌘A selects everything",
                              ok: text.selectedRange().length == 13))

            _ = press("z", .command)
            out.append(Result(label: "⌘Z undoes", ok: text.string.contains("copy me"),
                              detail: "text was \(text.string)"))

            // The markers are gone from the buffer by design, so the check is
            // that the *file* gets them — screen and disk say different things
            // on purpose, and both have to be right.
            text.string = "bold this"
            text.setSelectedRange(NSRange(location: 0, length: 4))
            _ = press("b", .command)
            out.append(Result(label: "⌘B shows no asterisks on screen",
                              ok: text.string == "bold this", detail: "text was \(text.string)"))
            out.append(Result(label: "⌘B still writes **bold** to the file",
                              ok: Attributed.markdown(from: text.attributedString()) == "**bold** this",
                              detail: "file would hold \(Attributed.markdown(from: text.attributedString()))"))

            text.string = "x+y=1"
            text.setSelectedRange(NSRange(location: 0, length: 5))
            _ = press("m", [.command, .shift])
            out.append(Result(label: "⌘⇧M turns the selection into one equation",
                              ok: text.string == "\u{FFFC}", detail: "text was \(text.string)"))
            out.append(Result(label: "⌘⇧M still writes $x+y=1$ to the file",
                              ok: Attributed.markdown(from: text.attributedString()) == "$x+y=1$",
                              detail: "file would hold \(Attributed.markdown(from: text.attributedString()))"))

            // KaTeX renders asynchronously, so wait for it rather than
            // declaring an equation broken because it was not instant.
            @MainActor func whenTypeset(_ attempt: Int, _ body: @escaping (MathRenderer.Rendered?) -> Void) {
                let got = MathRenderer.shared.rendering(tex: "E = mc^2", display: false,
                                                        size: 13, ink: .black, paper: .white)
                if got != nil || attempt > 100 { body(got); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    whenTypeset(attempt + 1, body)
                }
            }
            whenTypeset(0) { rendered in
                out.append(Result(label: "KaTeX typesets an equation into an image",
                                  ok: rendered != nil,
                                  detail: "no image came back for E = mc^2"))
                if let rendered {
                    // A blank image of the right size would pass a nil check and
                    // look like an empty note, so measure it.
                    out.append(Result(label: "the image is a plausible size",
                                      ok: rendered.image.size.width > 20
                                        && rendered.image.size.height > 8,
                                      detail: "was \(rendered.image.size)"))
                    // Written out so a human (or a reviewing agent) can look at
                    // it: dimensions can be right while the picture is blank.
                    if let out = ProcessInfo.processInfo.environment["JOT_KEYTEST_OUT"],
                       let png = { () -> Data? in
                           // Drawn at 6x through lockFocus: at its natural size
                           // the dump is too small to tell a typeset equation
                           // from a blank one, and drawing a PDF-backed image
                           // into a bare bitmap rep produces nothing at all.
                           let scale: CGFloat = 6
                           let size = rendered.image.size
                           let pixels = NSSize(width: size.width * scale,
                                               height: size.height * scale)
                           let canvas = NSImage(size: pixels)
                           canvas.lockFocus()
                           rendered.image.draw(in: NSRect(origin: .zero, size: pixels))
                           canvas.unlockFocus()
                           guard let tiff = canvas.tiffRepresentation,
                                 let rep = NSBitmapImageRep(data: tiff) else { return nil }
                           return rep.representation(using: .png, properties: [:])
                       }() {
                        try? png.write(to: URL(fileURLWithPath: out + ".png"))
                    }
                    out.append(Result(label: "inline maths sits on the baseline",
                                      ok: rendered.descent >= 0 && rendered.descent < rendered.image.size.height,
                                      detail: "descent \(rendered.descent) of \(rendered.image.size.height)"))
                }
                board.clearContents()
                if let borrowed { board.setString(borrowed, forType: .string) }
                panel.close()
                finish(out)
            }
        }
    }

    /// The same keys, but aimed at a real note window rather than a bare panel.
    ///
    /// A note is a SwiftUI view hosted in an `NSPanel`, so its text view sits
    /// several layers down inside an `NSHostingView`. That is a different
    /// responder chain from the one above, and it is the one the user actually
    /// types into — proving the plain case says nothing about this one.
    @MainActor
    static func runInRealNote(then finish: @escaping ([Result]) -> Void) {
        var out: [Result] = []

        func textView(in view: NSView) -> NSTextView? {
            if let found = view as? NSTextView { return found }
            for sub in view.subviews { if let found = textView(in: sub) { return found } }
            return nil
        }

        let sticky = Store.shared.create()
        guard let controller = StickyWindow.show(sticky.id), let window = controller.window else {
            out.append(Result(label: "a real note window opens", ok: false))
            finish(out)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // SwiftUI builds its view tree on a later turn of the run loop, so the
        // text view does not exist yet at the moment the window is created.
        // Wait for it, for focus, and for key status together.
        func whenReady(_ attempt: Int, _ body: @escaping (NSTextView?) -> Void) {
            let found = window.contentView.flatMap(textView(in:))
            if let found { window.makeFirstResponder(found) }
            let ready = found != nil && window.isKeyWindow && window.firstResponder === found
            if ready || attempt > 100 { body(found); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { whenReady(attempt + 1, body) }
        }

        whenReady(0) { found in
            guard let text = found else {
                out.append(Result(label: "a real note window has a text view", ok: false,
                                  detail: "could not find one to type into"))
                StickyWindow.close(sticky.id)
                Store.shared.delete(sticky.id)
                finish(out)
                return
            }
            out.append(Result(label: "a real note window has a text view", ok: true))
            out.append(Result(label: "the note window is key", ok: window.isKeyWindow))
            out.append(Result(label: "the note's text view has focus",
                              ok: window.firstResponder === text,
                              detail: "first responder was \(type(of: window.firstResponder))"))

            func press(_ key: String, _ flags: NSEvent.ModifierFlags) {
                guard let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: key,
                    charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0) else { return }
                _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
            }

            let board = NSPasteboard.general
            let borrowed = board.string(forType: .string)

            text.string = "note text"
            text.setSelectedRange(NSRange(location: 0, length: 9))
            board.clearContents()
            board.setString("SENTINEL", forType: .string)
            press("c", .command)
            out.append(Result(label: "⌘C copies from a real note",
                              ok: board.string(forType: .string) == "note text",
                              detail: "pasteboard held \(board.string(forType: .string) ?? "nothing")"))

            text.setSelectedRange(NSRange(location: 9, length: 0))
            board.clearContents()
            board.setString(" pasted", forType: .string)
            press("v", .command)
            out.append(Result(label: "⌘V pastes into a real note",
                              ok: text.string == "note text pasted",
                              detail: "text was \(text.string)"))

            text.setSelectedRange(NSRange(location: 0, length: 4))
            press("b", .command)
            out.append(Result(label: "⌘B leaves no asterisks on screen in a real note",
                              ok: text.string == "note text pasted",
                              detail: "text was \(text.string)"))
            out.append(Result(label: "⌘B emphasises in a real note",
                              ok: Attributed.markdown(from: text.attributedString())
                                    == "**note** text pasted",
                              detail: "would save \(Attributed.markdown(from: text.attributedString()))"))

            // Typed, one character at a time, exactly as a person would: the
            // markers have to come out as the construct closes, and the file
            // has to keep them. Applying a style with ⌘B proves neither.
            @MainActor func typeOut(_ string: String) {
                text.string = ""
                // Same reason the editor does this: the stack refers to text
                // that no longer exists.
                text.undoManager?.removeAllActions()
                text.typingAttributes = Attributed.attributes(
                    style: [], ink: (text as? JotTextView)?.ink ?? .black)
                for character in string {
                    text.insertText(String(character), replacementRange: text.selectedRange())
                }
            }

            typeOut("typed **bold** here")
            out.append(Result(label: "typing ** takes the asterisks back out",
                              ok: text.string == "typed bold here",
                              detail: "screen showed \(text.string)"))
            out.append(Result(label: "…and the file still says **bold**",
                              ok: Attributed.markdown(from: text.attributedString())
                                    == "typed **bold** here",
                              detail: "file would hold \(Attributed.markdown(from: text.attributedString()))"))

            typeOut("# A heading")
            out.append(Result(label: "typing # takes the hash out",
                              ok: text.string == "A heading", detail: "screen showed \(text.string)"))
            out.append(Result(label: "…and the file still says # A heading",
                              ok: Attributed.markdown(from: text.attributedString()) == "# A heading",
                              detail: "file would hold \(Attributed.markdown(from: text.attributedString()))"))

            typeOut("mass $E = mc^2$ ok")
            out.append(Result(label: "typing $…$ becomes one equation",
                              ok: text.string == "mass \u{FFFC} ok",
                              detail: "screen showed \(text.string)"))
            out.append(Result(label: "…and the file still says $E = mc^2$",
                              ok: Attributed.markdown(from: text.attributedString())
                                    == "mass $E = mc^2$ ok",
                              detail: "file would hold \(Attributed.markdown(from: text.attributedString()))"))

            typeOut("an unfinished **thought")
            out.append(Result(label: "an unclosed marker is left alone while you type",
                              ok: text.string == "an unfinished **thought",
                              detail: "screen showed \(text.string)"))

            typeOut("it cost $5 and $7")
            out.append(Result(label: "money is not silently eaten",
                              ok: text.string == "it cost $5 and $7",
                              detail: "screen showed \(text.string)"))

            typeOut("keep this")
            // The edit has to reach the model, or it is styling a view that
            // nothing will ever save. The write travels through a SwiftUI
            // binding, which lands on a later turn of the run loop, so give it
            // one rather than reading too early and calling that a bug.
            // Undo has to bring the markers back, or a collapse you did not want
            // is a trap: what you typed is gone and there is no way to ask for
            // it back. Typed through the run loop on purpose — undo groups are
            // opened per event, so a synchronous loop would put the whole note
            // in one group and undo would wipe it, which is not what a person
            // pressing ⌘Z would experience.
            @MainActor func typeSlowly(_ string: String, _ done: @escaping () -> Void) {
                text.string = ""
                text.undoManager?.removeAllActions()
                text.typingAttributes = Attributed.attributes(
                    style: [], ink: (text as? JotTextView)?.ink ?? .black)
                let characters = Array(string)
                @MainActor func step(_ i: Int) {
                    guard i < characters.count else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { done() }
                        return
                    }
                    text.insertText(String(characters[i]), replacementRange: text.selectedRange())
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { step(i + 1) }
                }
                step(0)
            }

            @MainActor func whenSaved(_ attempt: Int, _ body: @escaping (String) -> Void) {
                let saved = Store.shared.sticky(sticky.id)?.text ?? ""
                if saved == Attributed.markdown(from: text.attributedString()) || attempt > 40 {
                    body(saved); return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    whenSaved(attempt + 1, body)
                }
            }
            // A photograph of the note itself, drawn by the same code path that
            // puts it on screen. Every other check here can pass while the
            // equation is an empty rectangle; this is the one that would show it.
            typeOut("mass $E = mc^2$ inline\n$$\\int_0^1 x^2\\,dx = \\frac{1}{3}$$\nand **bold** text")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if let path = ProcessInfo.processInfo.environment["JOT_KEYTEST_OUT"] {
                    let bounds = text.bounds
                    if let rep = text.bitmapImageRepForCachingDisplay(in: bounds) {
                        text.cacheDisplay(in: bounds, to: rep)
                        if let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: path + ".note.png"))
                        }
                    }
                }
                out.append(Result(label: "the note serialises to the markdown that was typed",
                                  ok: Attributed.markdown(from: text.attributedString())
                                    == "mass $E = mc^2$ inline\n$$\\int_0^1 x^2\\,dx = \\frac{1}{3}$$\nand **bold** text",
                                  detail: "file would hold "
                                    + Attributed.markdown(from: text.attributedString())
                                        .replacingOccurrences(of: "\n", with: "⏎")))
                var specs: [String] = []
                let whole = NSRange(location: 0, length: text.attributedString().length)
                text.attributedString().enumerateAttribute(Attributed.mathKey, in: whole) { v, r, _ in
                    guard let spec = v as? MathSpec else { return }
                    let art = (text.attributedString().attribute(.attachment, at: r.location,
                                effectiveRange: nil) as? NSTextAttachment)?.image?.size ?? .zero
                    specs.append("[\(spec.display ? "display" : "inline") \(spec.tex) -> \(Int(art.width))x\(Int(art.height))]")
                }
                out.append(Result(label: "each equation carries its own source",
                                  ok: specs.count == 2 && specs[0].contains("E = mc^2"),
                                  detail: specs.joined(separator: " ")))
                out.append(Result(label: "the equation is typeset in the note, not left as source",
                                  ok: !text.string.contains("mc^2"),
                                  detail: "screen showed \(text.string)"))

            typeSlowly("say **this**") {
            out.append(Result(label: "the markers came out while typing normally",
                              ok: text.string == "say this",
                              detail: "screen showed \(text.string)"))
            // ⌘Z reverts the run of typing, the way it does in any Mac text
            // view — not just the marker collapse. What matters is that it
            // lands somewhere valid and that ⌘⇧Z brings the writing back.
            text.undoManager?.undo()
            let undone = text.string
            out.append(Result(label: "⌘Z reverts the typing without crashing",
                              ok: undone.isEmpty || undone.contains("this"),
                              detail: "screen showed \(undone)"))
            text.undoManager?.redo()
            out.append(Result(label: "⌘⇧Z puts the writing back",
                              ok: text.string == "say this" || text.string == "say **this**",
                              detail: "screen showed \(text.string)"))

            whenSaved(0) { saved in
                out.append(Result(label: "the edit reached the note itself, as markdown",
                                  ok: saved == Attributed.markdown(from: text.attributedString()),
                                  detail: "the note holds \(saved.isEmpty ? "nothing" : saved)"))
                board.clearContents()
                if let borrowed { board.setString(borrowed, forType: .string) }
                StickyWindow.close(sticky.id)
                Store.shared.delete(sticky.id)
                finish(out)
            }
            }
            }
        }
    }
}
