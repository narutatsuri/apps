import AppKit

/// The inline styles a run of text can carry. A set, because text can be bold
/// and struck through at once.
struct InlineStyle: OptionSet, Hashable {
    let rawValue: Int
    static let bold = InlineStyle(rawValue: 1 << 0)
    static let italic = InlineStyle(rawValue: 1 << 1)
    static let code = InlineStyle(rawValue: 1 << 2)
    static let highlight = InlineStyle(rawValue: 1 << 3)
    static let strikethrough = InlineStyle(rawValue: 1 << 4)
    /// A fenced block. Looks like code, but writes no markers on the way out:
    /// its ``` fences were never taken out of the text to begin with.
    static let fenced = InlineStyle(rawValue: 1 << 5)
}

/// An equation in the text. Carries whether KaTeX has caught up yet, so a
/// later pass can fill in the ones still showing their source.
final class MathAttachment: NSTextAttachment {
    var isTypeset = false
}

/// A piece of maths standing in for the `$…$` that produced it.
final class MathSpec: NSObject {
    let tex: String
    let display: Bool
    init(tex: String, display: Bool) { self.tex = tex; self.display = display }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? MathSpec else { return false }
        return tex == other.tex && display == other.display
    }
    override var hash: Int { tex.hashValue ^ (display ? 1 : 0) }
}

/// Markdown in, styled text out, and back again without loss.
///
/// This is the whole trick behind markers that vanish. The text view holds
/// styled text with no `**` in it; the note on disk holds `**bold**`. Neither
/// side is the poor relation: the file stays something you can grep and pipe,
/// and the editor stays something you can read.
///
/// Both directions are pure functions over strings, so the round-trip can be
/// tested exhaustively without a window — which matters, because the failure
/// mode of a lossy serialiser is that it quietly eats what you wrote.
@MainActor
enum Attributed {
    static let styleKey = NSAttributedString.Key("jot.style")
    static let headingKey = NSAttributedString.Key("jot.heading")
    static let linkKey = NSAttributedString.Key("jot.link")
    static let mathKey = NSAttributedString.Key("jot.math")

    static let baseSize: CGFloat = 13
    static var base: NSFont { .monospacedSystemFont(ofSize: baseSize, weight: .regular) }

    // MARK: - Markdown → styled text

    /// The semantics of every character of `markdown`, one entry per UTF-16
    /// unit. Markers are flagged rather than removed here so the caller can
    /// drop them in one pass.
    private struct Semantics {
        var isMarker: [Bool]
        var style: [InlineStyle]
        var heading: [Int]
        var link: [String?]
        var math: [MathSpec?]
        var bullet: [Bool]
        var quote: [Bool]
    }

    private static func semantics(of markdown: String) -> Semantics {
        let ns = markdown as NSString
        let n = ns.length
        var out = Semantics(isMarker: .init(repeating: false, count: n),
                            style: .init(repeating: [], count: n),
                            heading: .init(repeating: 0, count: n),
                            link: .init(repeating: nil, count: n),
                            math: .init(repeating: nil, count: n),
                            bullet: .init(repeating: false, count: n),
                            quote: .init(repeating: false, count: n))

        for span in Highlighter.styles(in: markdown) {
            let r = span.range
            guard r.location >= 0, NSMaxRange(r) <= n else { continue }
            let indices = r.location..<NSMaxRange(r)
            switch span.kind {
            case .marker: for i in indices { out.isMarker[i] = true }
            case .bold: for i in indices { out.style[i].insert(.bold) }
            case .italic: for i in indices { out.style[i].insert(.italic) }
            case .code: for i in indices { out.style[i].insert(.code) }
            case .codeBlock: for i in indices { out.style[i].insert(.fenced) }
            case .highlight: for i in indices { out.style[i].insert(.highlight) }
            case .strikethrough: for i in indices { out.style[i].insert(.strikethrough) }
            case .heading(let level): for i in indices { out.heading[i] = level }
            case .link(let url): for i in indices { out.link[i] = url }
            case .listBullet: for i in indices { out.bullet[i] = true }
            case .quote: for i in indices { out.quote[i] = true }
            case .math(let display):
                let spec = MathSpec(tex: ns.substring(with: r), display: display)
                for i in indices { out.math[i] = spec }
            }
        }
        return out
    }

    /// Styled text with every marker taken out.
    static func make(from markdown: String, ink: NSColor, paper: NSColor) -> NSMutableAttributedString {
        let ns = markdown as NSString
        let n = ns.length
        let sem = semantics(of: markdown)
        let out = NSMutableAttributedString()

        var i = 0
        while i < n {
            if sem.isMarker[i] { i += 1; continue }

            // Maths collapses to a single character carrying the TeX, so the
            // caret steps over an equation the way it steps over a letter.
            if let spec = sem.math[i] {
                var j = i
                while j < n, sem.math[j] === spec { j += 1 }
                out.append(mathRun(spec, ink: ink, paper: paper))
                i = j
                continue
            }

            var j = i
            while j < n, !sem.isMarker[j], sem.math[j] == nil,
                  sem.style[j] == sem.style[i], sem.heading[j] == sem.heading[i],
                  sem.link[j] == sem.link[i], sem.bullet[j] == sem.bullet[i],
                  sem.quote[j] == sem.quote[i] { j += 1 }

            let piece = NSMutableAttributedString(
                string: ns.substring(with: NSRange(location: i, length: j - i)),
                attributes: attributes(style: sem.style[i], heading: sem.heading[i],
                                       link: sem.link[i], bullet: sem.bullet[i],
                                       quote: sem.quote[i], ink: ink))
            out.append(piece)
            i = j
        }
        return out
    }

    /// One attachment character standing in for an equation.
    static func mathRun(_ spec: MathSpec, ink: NSColor, paper: NSColor) -> NSAttributedString {
        let attachment = MathAttachment()
        let rendered = MathRenderer.shared.rendering(tex: spec.tex, display: spec.display,
                                                     size: baseSize, ink: ink, paper: paper)
        apply(rendered, to: attachment, spec: spec, ink: ink)
        let out = NSMutableAttributedString(attachment: attachment)
        out.addAttributes([mathKey: spec, .foregroundColor: ink], range: NSRange(location: 0, length: out.length))
        return out
    }

    /// Puts a rendering — or a stand-in, while KaTeX is still working — into an
    /// attachment. Separate so the editor can swap the real image in later
    /// without rebuilding the text and losing the caret.
    static func apply(_ rendered: MathRenderer.Rendered?, to attachment: MathAttachment,
                      spec: MathSpec, ink: NSColor) {
        if let rendered {
            attachment.isTypeset = true
            attachment.image = rendered.image
            attachment.bounds = NSRect(x: 0, y: -rendered.descent,
                                       width: rendered.image.size.width,
                                       height: rendered.image.size.height)
        } else {
            // The TeX source, drawn as text, until the typeset version arrives.
            // Better than a blank: a slow render should not look like data loss.
            let placeholder = NSAttributedString(string: spec.tex, attributes: [
                .font: NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask),
                .foregroundColor: ink.withAlphaComponent(0.55),
            ])
            let size = placeholder.size()
            let image = NSImage(size: NSSize(width: ceil(size.width), height: ceil(size.height)))
            image.lockFocus()
            placeholder.draw(at: .zero)
            image.unlockFocus()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -3, width: image.size.width, height: image.size.height)
        }
    }

    /// The visual attributes for a semantic combination. One place, so the
    /// editor, the typing attributes and the tests cannot disagree.
    static func attributes(style: InlineStyle, heading: Int = 0, link: String? = nil,
                           bullet: Bool = false, quote: Bool = false,
                           ink: NSColor) -> [NSAttributedString.Key: Any] {
        var font = base
        if heading > 0 {
            let size: CGFloat = heading == 1 ? 18 : heading == 2 ? 16 : 14.5
            font = .monospacedSystemFont(ofSize: size, weight: .bold)
        } else if style.contains(.bold) {
            font = .monospacedSystemFont(ofSize: baseSize, weight: .bold)
        }
        if style.contains(.italic) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }

        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        if !style.isEmpty { attrs[styleKey] = style.rawValue }
        if heading > 0 { attrs[headingKey] = heading }

        if style.contains(.code) || style.contains(.fenced) {
            attrs[.backgroundColor] = Theme.codeTint
            attrs[.foregroundColor] = Theme.codeInk
        }
        if style.contains(.highlight) {
            attrs[.backgroundColor] = Theme.highlightTint
        }
        if style.contains(.strikethrough) {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link {
            attrs[linkKey] = link
            attrs[.foregroundColor] = Theme.linkInk
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if bullet {
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: baseSize, weight: .bold)
            attrs[.foregroundColor] = ink.withAlphaComponent(0.55)
        }
        if quote { attrs[.foregroundColor] = ink.withAlphaComponent(0.62) }
        return attrs
    }

    // MARK: - Styled text → markdown

    /// The markers for a style set, innermost last so they nest predictably and
    /// the parser reads back exactly what was written.
    private static func wrap(_ style: InlineStyle) -> (open: String, close: String) {
        var open = "", close = ""
        for (member, marker) in [(InlineStyle.highlight, "=="), (.bold, "**"),
                                 (.italic, "*"), (.strikethrough, "~~"), (.code, "`")]
        where style.contains(member) {
            open += marker
            close = marker + close
        }
        return (open, close)
    }

    static func markdown(from attributed: NSAttributedString) -> String {
        let ns = attributed.string as NSString
        let n = ns.length
        guard n > 0 else { return "" }

        var out = ""
        var index = 0
        while index < n {
            let line = ns.lineRange(for: NSRange(location: index, length: 0))
            var body = NSRange(location: line.location, length: line.length)
            // The newline is copied through verbatim rather than styled.
            var terminator = ""
            while body.length > 0,
                  let last = ns.substring(with: NSRange(location: NSMaxRange(body) - 1, length: 1)).first,
                  last == "\n" || last == "\r" {
                terminator = String(last) + terminator
                body.length -= 1
            }

            if body.length > 0 {
                let level = attributed.attribute(headingKey, at: body.location,
                                                 effectiveRange: nil) as? Int ?? 0
                if level > 0 { out += String(repeating: "#", count: level) + " " }
                out += inlineMarkdown(attributed, in: body)
            }
            out += terminator
            index = NSMaxRange(line)
        }
        return out
    }

    private static func inlineMarkdown(_ attributed: NSAttributedString, in range: NSRange) -> String {
        let ns = attributed.string as NSString
        var out = ""
        var i = range.location
        let end = NSMaxRange(range)

        func style(_ at: Int) -> InlineStyle {
            InlineStyle(rawValue: attributed.attribute(styleKey, at: at, effectiveRange: nil) as? Int ?? 0)
        }
        func link(_ at: Int) -> String? {
            attributed.attribute(linkKey, at: at, effectiveRange: nil) as? String
        }
        func math(_ at: Int) -> MathSpec? {
            attributed.attribute(mathKey, at: at, effectiveRange: nil) as? MathSpec
        }

        while i < end {
            if let spec = math(i) {
                let fence = spec.display ? "$$" : "$"
                out += fence + spec.tex + fence
                i += 1
                continue
            }
            var j = i
            while j < end, math(j) == nil, style(j) == style(i), link(j) == link(i) { j += 1 }

            let text = ns.substring(with: NSRange(location: i, length: j - i))
            let (open, close) = wrap(style(i))
            if let url = link(i) {
                out += open + "[" + text + "](" + url + ")" + close
            } else {
                out += open + text + close
            }
            i = j
        }
        return out
    }
}
