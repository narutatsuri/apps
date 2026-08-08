import AppKit
import SwiftUI

/// The text area of a note.
///
/// An `NSTextView` rather than SwiftUI's `TextEditor`, for reasons that each
/// matter here: the text has to be black on the paper colour regardless of the
/// system appearance (a sticky is a piece of paper, and `TextEditor` draws with
/// the system label colour, which is white in dark mode and therefore
/// invisible); the markers have to come out of the text as you write them,
/// which needs the text storage; equations have to become images, which needs
/// attachments; and paste has to arrive plain, because half the point of a
/// scratch buffer is that things come out of it the way they went in.
///
/// What is on screen is styled text with no `**` in it. What is on disk is
/// `**bold**`. `Attributed` converts between the two on every edit, so the file
/// stays greppable and the note stays readable.

/// Lets the surrounding SwiftUI view reach the text view, which is the only
/// thing that knows what is selected.
@MainActor
final class EditorHandle {
    weak var view: NSTextView?
    func apply(_ style: InlineStyle) { view?.jotToggle(style) }
    func applyMath() { view?.jotMath(nil) }
}

/// Plain paste and a place to keep the note's colours.
///
/// The colours live on the view because the emphasis commands arrive through
/// the responder chain from the main menu, which knows nothing about which note
/// it is talking to.
final class JotTextView: NSTextView {
    var ink: NSColor = .black
    var paper: NSColor = .white

    /// Everything here is plain text. A paste that carried fonts and colours in
    /// from a web page would be the exact thing this app exists to avoid.
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
}

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var paper: NSColor
    var handle: EditorHandle?
    /// Black on light paper, always. Not `.labelColor`: a note is a physical
    /// object here, and its ink does not change when the OS switches to dark.
    var ink: NSColor = .black

    func makeNSView(context: Context) -> NSScrollView {
        // Built by hand rather than with NSTextView.scrollableTextView() so the
        // TextKit 1 stack is explicit: attachment images are swapped in place
        // when KaTeX finishes, and that needs a layout manager to invalidate.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let view = JotTextView(frame: .zero, textContainer: container)
        view.ink = ink
        view.paper = paper
        view.delegate = context.coordinator
        view.isRichText = true                  // the styling lives in the storage
        view.usesFontPanel = false              // but the user never picks a font
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false   // "smart" quotes break code
        view.isAutomaticDashSubstitutionEnabled = false    // and -- becomes an em dash
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = NSSize.zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [NSView.AutoresizingMask.width]
        view.textColor = ink
        view.insertionPointColor = ink
        view.backgroundColor = paper
        view.drawsBackground = true
        view.textContainerInset = NSSize(width: 6, height: 10)
        view.typingAttributes = Attributed.attributes(style: [], ink: ink)
        // Selection has to stay legible on coloured paper; the system accent at
        // full strength hides the text under it. Inverts with the theme, or the
        // wash disappears entirely on dark paper.
        let selection: [NSAttributedString.Key: Any] = [.backgroundColor: Theme.selectionTint]
        view.selectedTextAttributes = selection

        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.drawsBackground = true
        scroll.backgroundColor = paper
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        context.coordinator.view = view
        handle?.view = view
        storage.setAttributedString(Attributed.make(from: text, ink: ink, paper: paper))
        context.coordinator.observeMath()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? JotTextView else { return }
        context.coordinator.parent = self
        handle?.view = view
        view.ink = ink
        view.paper = paper
        view.backgroundColor = paper
        view.insertionPointColor = ink
        view.selectedTextAttributes = [.backgroundColor: Theme.selectionTint]
        scroll.backgroundColor = paper

        // A theme change repaints everything: the styling and the equations are
        // baked into the storage as colours and images, so nothing short of
        // rebuilding them picks up new ink. Cheap, and only on an actual change.
        guard let storage = view.textStorage else { return }
        // The binding is the source of truth, except when it has not been
        // filled in yet: rebuilding from an empty `text` over a buffer that has
        // content is how a note gets erased by a repaint.
        let stale = text.isEmpty && storage.length > 0
        if context.coordinator.appearance != Theme.current, !stale {
            context.coordinator.appearance = Theme.current
            let caret = view.selectedRange()
            storage.setAttributedString(Attributed.make(from: text, ink: ink, paper: paper))
            view.undoManager?.removeAllActions()
            view.setSelectedRange(NSRange(location: min(caret.location, storage.length),
                                          length: min(caret.length, storage.length - min(caret.location, storage.length))))
            view.typingAttributes = Attributed.attributes(style: [], ink: ink)
            return
        }

        // Only touch the text when it changed underneath us — rebuilding
        // unconditionally would drop the selection on every keystroke. The
        // comparison is in markdown, because that is the shared language
        // between the styled buffer and the note.
        guard !stale, Attributed.markdown(from: storage) != text else { return }
        let caret = view.selectedRange()
        storage.setAttributedString(Attributed.make(from: text, ink: ink, paper: paper))
        // The undo stack still holds ranges into the text that was just thrown
        // away. Undoing into it reads past the end and takes the app down with
        // it — reachable for real by editing a note that the CLI then rewrites.
        view.undoManager?.removeAllActions()
        view.setSelectedRange(NSRange(location: min(caret.location, storage.length), length: 0))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        weak var view: NSTextView?
        /// The collapse edits the text, which calls back in here. Without this
        /// the first `**bold**` would recurse until the stack ran out.
        private var isCollapsing = false
        private var editedRange: NSRange?
        /// What the storage was last built for, so a theme change is noticed.
        var appearance = Theme.current

        init(_ parent: MarkdownEditor) { self.parent = parent }

        /// Equations arrive late, because KaTeX has to lay them out first.
        func observeMath() {
            NotificationCenter.default.addObserver(
                self, selector: #selector(mathArrived),
                name: MathRenderer.didRender, object: nil)
        }

        @objc private func mathArrived() { fillMath() }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange,
                      replacementString text: String?) -> Bool {
            // Where to look for a finished construct afterwards. Both ends
            // matter: pasting a block of markdown should collapse all of it,
            // not just the line the caret landed on.
            editedRange = NSRange(location: range.location, length: (text as NSString?)?.length ?? 0)
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let view, !isCollapsing else { return }
            // An undo that puts the markers back is immediately a text change,
            // and collapsing it again would take them straight back out — ⌘Z
            // would appear to do nothing at all.
            let reverting = (view.undoManager?.isUndoing ?? false)
                || (view.undoManager?.isRedoing ?? false)
            if !reverting { collapse(around: editedRange ?? view.selectedRange()) }
            editedRange = nil
            guard let storage = view.textStorage else { return }
            parent.text = Attributed.markdown(from: storage)
        }

        /// Typing next to bold text should not silently continue it. The style
        /// carries on only when the caret is genuinely inside a run — between
        /// two characters that agree — which is what closing `**` meant.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view, let storage = view.textStorage, !isCollapsing else { return }
            let caret = view.selectedRange()
            guard caret.length == 0 else { return }

            func style(at index: Int) -> InlineStyle? {
                guard index >= 0, index < storage.length else { return nil }
                return InlineStyle(rawValue:
                    storage.attribute(Attributed.styleKey, at: index, effectiveRange: nil) as? Int ?? 0)
            }
            let before = style(at: caret.location - 1)
            let after = style(at: caret.location)
            let inherited = (before != nil && before == after) ? before! : []

            // The heading level belongs to the line, not to the run, so it is
            // read from the start of the paragraph. Without this, everything
            // typed after the hashes came out as body text.
            let ns = storage.string as NSString
            let paragraph = ns.paragraphRange(for: NSRange(location: min(caret.location, ns.length),
                                                           length: 0))
            var heading = 0
            if paragraph.length > 0, paragraph.location < storage.length {
                heading = storage.attribute(Attributed.headingKey, at: paragraph.location,
                                            effectiveRange: nil) as? Int ?? 0
            }
            view.typingAttributes = Attributed.attributes(style: inherited, heading: heading,
                                                          ink: parent.ink)
        }

        /// Turns finished markdown into styling, and takes the markers out.
        ///
        /// The whole thing is done by round-tripping the affected lines: back to
        /// markdown, then forward again. That way there is exactly one parser
        /// and one serialiser, and a construct can never be recognised by the
        /// collapse but not by the file format, or the other way round.
        private func collapse(around range: NSRange) {
            guard let view, let storage = view.textStorage else { return }
            let ns = storage.string as NSString
            let clamped = NSRange(location: min(range.location, ns.length),
                                  length: min(range.length, max(0, ns.length - min(range.location, ns.length))))
            let lines = ns.paragraphRange(for: clamped)
            guard lines.length > 0 else { return }

            let source = Attributed.markdown(from: storage.attributedSubstring(from: lines))
            let rebuilt = Attributed.make(from: source, ink: parent.ink, paper: parent.paper)
            guard rebuilt.string != ns.substring(with: lines) else { return }

            let caret = view.selectedRange().location
            let delta = (rebuilt.string as NSString).length - lines.length
            isCollapsing = true
            defer { isCollapsing = false }
            // Undo, honestly: NSTextView coalesces a run of typing into one
            // action, and the collapse lands inside it however it is grouped —
            // breaking coalescing, an explicit group and deferring past the
            // event were all tried, and none of them separates the two. So ⌘Z
            // reverts the burst of typing rather than just the markers, which
            // is what TextEdit does with a burst of typing too. Nothing is
            // lost that was not just typed, and ⌘⇧Z puts it back.
            view.breakUndoCoalescing()
            view.undoManager?.beginUndoGrouping()
            guard view.shouldChangeText(in: lines, replacementString: rebuilt.string) else {
                view.undoManager?.endUndoGrouping()
                return
            }
            storage.replaceCharacters(in: lines, with: rebuilt)
            view.didChangeText()
            view.undoManager?.endUndoGrouping()
            view.breakUndoCoalescing()
            let moved = caret >= NSMaxRange(lines) ? caret + delta
                      : min(max(caret + delta, lines.location), lines.location + rebuilt.length)
            view.setSelectedRange(NSRange(location: max(0, min(moved, storage.length)), length: 0))
        }

        /// Puts newly typeset equations into the attachments already in place,
        /// rather than rebuilding the text — which would move the caret out from
        /// under whoever is typing.
        private func fillMath() {
            guard let view, let storage = view.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            var touched = false
            storage.enumerateAttribute(Attributed.mathKey, in: full) { value, range, _ in
                guard let spec = value as? MathSpec,
                      let attachment = storage.attribute(.attachment, at: range.location,
                                                         effectiveRange: nil) as? MathAttachment,
                      !attachment.isTypeset,
                      let rendered = MathRenderer.shared.rendering(
                        tex: spec.tex, display: spec.display, size: Attributed.baseSize,
                        ink: parent.ink, paper: parent.paper) else { return }
                Attributed.apply(rendered, to: attachment, spec: spec, ink: parent.ink)
                touched = true
            }
            guard touched else { return }
            view.layoutManager?.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
            view.layoutManager?.invalidateDisplay(forCharacterRange: full)
        }
    }
}

/// The emphasis commands, on `NSTextView` so a menu item can target the first
/// responder. Going through the responder chain is what lets one menu drive
/// whichever note is focused, without the menu having to track which that is.
///
/// These set attributes rather than typing markers: the markers are the file
/// format, not the interface.
extension NSTextView {
    @objc func jotBold(_ sender: Any?) { jotToggle(.bold) }
    @objc func jotItalic(_ sender: Any?) { jotToggle(.italic) }
    @objc func jotHighlight(_ sender: Any?) { jotToggle(.highlight) }
    @objc func jotCode(_ sender: Any?) { jotToggle(.code) }
    @objc func jotStrike(_ sender: Any?) { jotToggle(.strikethrough) }

    /// ⌘⇧M turns the selection into an equation, treating what is selected as
    /// the TeX. With nothing selected there is no equation to make, so it types
    /// the delimiters and lets the collapse take over once you close them.
    @objc func jotMath(_ sender: Any?) {
        guard let storage = textStorage else { return }
        let ink = (self as? JotTextView)?.ink ?? .black
        let paper = (self as? JotTextView)?.paper ?? .white
        let selection = selectedRange()
        guard selection.length > 0 else {
            insertText("$$", replacementRange: selection)
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return
        }
        let tex = (storage.string as NSString).substring(with: selection)
        guard !tex.contains("$") else { return }
        let spec = MathSpec(tex: tex, display: false)
        let run = Attributed.mathRun(spec, ink: ink, paper: paper)
        guard shouldChangeText(in: selection, replacementString: run.string) else { return }
        storage.replaceCharacters(in: selection, with: run)
        didChangeText()
        setSelectedRange(NSRange(location: selection.location + run.length, length: 0))
    }

    /// Adds the style where it is missing, removes it where it is not.
    func jotToggle(_ style: InlineStyle) {
        guard let storage = textStorage else { return }
        let ink = (self as? JotTextView)?.ink ?? .black
        let selection = selectedRange()

        func current(at index: Int) -> InlineStyle {
            InlineStyle(rawValue:
                storage.attribute(Attributed.styleKey, at: index, effectiveRange: nil) as? Int ?? 0)
        }

        guard selection.length > 0 else {
            // Nothing selected: arm the style for whatever is typed next, the
            // way every other editor treats ⌘B on an empty selection.
            var pending = InlineStyle(rawValue: typingAttributes[Attributed.styleKey] as? Int ?? 0)
            pending.formSymmetricDifference(style)
            typingAttributes = Attributed.attributes(style: pending, ink: ink)
            return
        }

        var everywhere = true
        for i in selection.location..<NSMaxRange(selection)
        where !current(at: i).contains(style) { everywhere = false; break }

        guard shouldChangeText(in: selection, replacementString: nil) else { return }
        storage.beginEditing()
        for i in selection.location..<NSMaxRange(selection) {
            // Attachments are equations; emphasising one means nothing.
            guard storage.attribute(Attributed.mathKey, at: i, effectiveRange: nil) == nil else { continue }
            var next = current(at: i)
            if everywhere { next.remove(style) } else { next.insert(style) }
            let heading = storage.attribute(Attributed.headingKey, at: i, effectiveRange: nil) as? Int ?? 0
            let link = storage.attribute(Attributed.linkKey, at: i, effectiveRange: nil) as? String
            storage.setAttributes(
                Attributed.attributes(style: next, heading: heading, link: link, ink: ink),
                range: NSRange(location: i, length: 1))
        }
        storage.endEditing()
        didChangeText()
    }
}
