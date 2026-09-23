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

/// A picture standing in for the `![alt](path)` that produced it.
final class ImageSpec: NSObject {
    let alt: String
    let path: String
    init(alt: String, path: String) { self.alt = alt; self.path = path }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ImageSpec else { return false }
        return alt == other.alt && path == other.path
    }
    override var hash: Int { alt.hashValue ^ path.hashValue }
}

/// An image in the text. It sizes itself at layout time to the column it is
/// in — as wide as the text, less a margin either side, aspect kept, never
/// scaled up — so a picture fits whatever column holds it and re-fits when
/// that column is dragged wider or narrower.
final class ImageAttachment: NSTextAttachment {
    /// The file's own size; nil for the stand-in drawn for a missing file,
    /// which keeps whatever bounds it was given.
    var naturalSize: NSSize?

    override func attachmentBounds(for textContainer: NSTextContainer?,
                                   proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint,
                                   characterIndex charIndex: Int) -> CGRect {
        guard let natural = naturalSize, natural.width > 0 else { return bounds }
        let padding = textContainer?.lineFragmentPadding ?? 5
        let columnWidth = textContainer?.size.width ?? lineFrag.width
        let available = columnWidth - 2 * padding - 2 * Attributed.imageMargin
        let width = min(natural.width, max(40, available))
        let height = width * natural.height / natural.width
        return CGRect(x: 0, y: -2, width: floor(width), height: floor(height))
    }
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
    static let imageKey = NSAttributedString.Key("jot.image")

    /// How an image path becomes a picture. The default takes the path as it
    /// is; an app whose notes keep images somewhere of their own (Lanes keeps
    /// them in `_assets/`) installs a resolver that knows where to look.
    static var imageResolver: (String) -> NSImage? = { NSImage(contentsOfFile: $0) }
    /// Breathing room either side of a picture, inside the column's own inset.
    nonisolated static let imageMargin: CGFloat = 8

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
        var image: [ImageSpec?]
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
                            image: .init(repeating: nil, count: n),
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
            case .image(let alt, let path):
                let spec = ImageSpec(alt: alt, path: path)
                for i in indices { out.image[i] = spec }
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
                // The enclosing emphasis travels with the equation. Without it a
                // highlight that wraps one has a hole where the maths is, and —
                // worse — the markdown written back out breaks the run in two.
                out.append(mathRun(spec, style: sem.style[i], ink: ink, paper: paper))
                i = j
                continue
            }

            // So does a picture: one character, the image itself.
            if let spec = sem.image[i] {
                var j = i
                while j < n, sem.image[j] === spec { j += 1 }
                out.append(imageRun(spec, style: sem.style[i], ink: ink))
                i = j
                continue
            }

            var j = i
            while j < n, !sem.isMarker[j], sem.math[j] == nil, sem.image[j] == nil,
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
    static func mathRun(_ spec: MathSpec, style: InlineStyle = [],
                        ink: NSColor, paper: NSColor) -> NSAttributedString {
        let attachment = MathAttachment()
        let rendered = MathRenderer.shared.rendering(tex: spec.tex, display: spec.display,
                                                     size: baseSize, ink: ink,
                                                     paper: mathPaper(style: style, paper: paper))
        apply(rendered, to: attachment, spec: spec, ink: ink)
        let out = NSMutableAttributedString(attachment: attachment)
        var attrs: [NSAttributedString.Key: Any] = [mathKey: spec, .foregroundColor: ink]
        attrs.merge(mathAttributes(style: style)) { _, new in new }
        out.addAttributes(attrs, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// One attachment character standing in for a picture: the file, scaled to
    /// fit the column, or — when the path leads nowhere — its alt text and
    /// path drawn in place, so a missing file reads as missing rather than as
    /// nothing having been there.
    static func imageRun(_ spec: ImageSpec, style: InlineStyle = [], ink: NSColor) -> NSAttributedString {
        let attachment = ImageAttachment()
        if let image = imageResolver(spec.path), image.size.width > 0 {
            attachment.image = image
            attachment.naturalSize = image.size
            // The real bounds come from the column at layout time; these are
            // for anywhere that never lays out.
            attachment.bounds = NSRect(x: 0, y: -2, width: image.size.width, height: image.size.height)
        } else {
            let label = NSAttributedString(
                string: "⚠︎ " + (spec.alt.isEmpty ? spec.path : "\(spec.alt) (\(spec.path))"),
                attributes: [.font: NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask),
                             .foregroundColor: ink.withAlphaComponent(0.55)])
            let size = label.size()
            let image = NSImage(size: NSSize(width: ceil(size.width), height: ceil(size.height)))
            image.lockFocus()
            label.draw(at: .zero)
            image.unlockFocus()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -3, width: image.size.width, height: image.size.height)
        }
        let out = NSMutableAttributedString(attachment: attachment)
        var attrs: [NSAttributedString.Key: Any] = [imageKey: spec, .foregroundColor: ink]
        attrs.merge(mathAttributes(style: style)) { _, new in new }
        out.addAttributes(attrs, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// The colour an equation is drawn *against*.
    ///
    /// An equation is not glyphs, it is a picture: KaTeX renders it in a web
    /// view over an opaque background and the result is captured as an image.
    /// So a `.backgroundColor` behind the attachment is painted over by the
    /// image itself — a highlight that wrapped an equation came out with a
    /// rectangular hole where the maths was. Pixel-checked; it is not a thing
    /// you can reason your way to from the attribute being set correctly. The
    /// highlight therefore has to go into the render, not behind it.
    static func mathPaper(style: InlineStyle, paper: NSColor) -> NSColor {
        guard style.contains(.highlight) else { return paper }
        return composite(Theme.highlightTint, over: paper)
    }

    /// A translucent colour flattened onto an opaque one. The renderer wants a
    /// solid background, and the highlight tint is deliberately see-through.
    private static func composite(_ top: NSColor, over base: NSColor) -> NSColor {
        guard let t = top.usingColorSpace(.sRGB), let b = base.usingColorSpace(.sRGB) else {
            return base
        }
        let a = t.alphaComponent
        return NSColor(srgbRed: t.redComponent * a + b.redComponent * (1 - a),
                       green: t.greenComponent * a + b.greenComponent * (1 - a),
                       blue: t.blueComponent * a + b.blueComponent * (1 - a),
                       alpha: 1)
    }

    /// What an emphasis means when it lands on an equation.
    ///
    /// The style key is always carried, whether or not it changes how the
    /// equation looks, because it is what `markdown(from:)` reads to put the
    /// markers back — an equation inside `==…==` that forgot it was highlighted
    /// would be written out as two highlights with a bare `$x$` between them.
    ///
    /// Only the attributes that mean something on a pre-rendered image are
    /// applied: a background tint sits behind it, a strikethrough draws across
    /// it. Bold and italic are deliberately not — the glyphs come from KaTeX as
    /// a picture, and a font trait cannot reach inside one. `**$x$**` therefore
    /// round-trips exactly and emboldens the words around the equation, and the
    /// equation itself stays upright. Doing better means asking KaTeX for it.
    static func mathAttributes(style: InlineStyle) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [:]
        if !style.isEmpty { attrs[styleKey] = style.rawValue }
        if style.contains(.highlight) { attrs[.backgroundColor] = Theme.highlightTint }
        if style.contains(.strikethrough) {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
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

    /// Marker nesting order, outermost first. One list, so the writer opens and
    /// closes in an order the parser can read back.
    private static let nesting: [(style: InlineStyle, marker: String)] =
        [(.highlight, "=="), (.bold, "**"), (.italic, "*"),
         (.strikethrough, "~~"), (.code, "`")]

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
        func image(_ at: Int) -> ImageSpec? {
            attributed.attribute(imageKey, at: at, effectiveRange: nil) as? ImageSpec
        }

        // Markers are opened and closed as the style *changes*, rather than
        // wrapped around every run. Wrapping each run separately doubled the
        // markers wherever emphasis nested: `==a **b** c==` was written back as
        // `==a ====**b**==== c==`, because the middle run carried both styles
        // and re-opened the highlight it was already inside. That is a lossy
        // round-trip in a notes app — the file on disk is rewritten into
        // something you did not type — and it applied to any nesting at all,
        // including a link inside a highlight.
        //
        // Runs are also grouped *across* equations, so an emphasis spanning one
        // gets a single pair of markers instead of breaking in two around it.
        var open: [(style: InlineStyle, marker: String)] = []

        func closeDown(to keep: Int) {
            while open.count > keep { out += open.removeLast().marker }
        }

        while i < end {
            let runStyle = style(i)
            let runLink = link(i)
            var j = i
            while j < end, style(j) == runStyle, link(j) == runLink { j += 1 }

            // Keep the open markers this run is still inside; close the rest,
            // innermost first, so they nest properly.
            var keep = 0
            while keep < open.count, runStyle.contains(open[keep].style) { keep += 1 }
            closeDown(to: keep)
            for entry in nesting
            where runStyle.contains(entry.style) && !open.contains(where: { $0.style == entry.style }) {
                out += entry.marker
                open.append(entry)
            }

            var text = ""
            var k = i
            while k < j {
                if let spec = math(k) {
                    let fence = spec.display ? "$$" : "$"
                    text += fence + spec.tex + fence
                    k += 1
                } else if let spec = image(k) {
                    text += "![" + spec.alt + "](" + spec.path + ")"
                    k += 1
                } else {
                    var m = k
                    while m < j, math(m) == nil, image(m) == nil { m += 1 }
                    text += ns.substring(with: NSRange(location: k, length: m - k))
                    k = m
                }
            }

            out += runLink.map { "[" + text + "](" + $0 + ")" } ?? text
            i = j
        }
        closeDown(to: 0)
        return out
    }
}
