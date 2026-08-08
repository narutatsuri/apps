import AppKit

/// The markdown parser: what is a marker, what is content, and what the content
/// means.
///
/// The file on disk stays plain markdown — `**bold**` is stored as `**bold**`,
/// so a note can be grepped, piped, and opened in any editor. What you see is
/// the text with the markers taken out and the styling put on. That is the
/// distinction the built-in Stickies app misses: there, formatting is state
/// attached to each note, so every note ends up looking different and nothing
/// can be moved between them. Here formatting is a function of the markdown, so
/// every note looks the same and the styling can never drift out of sync with
/// what any other tool would show.
///
/// This half is pure and range-based so it can be checked without a window: a
/// parser that puts the emphasis on the wrong span is invisible in a screenshot
/// and obvious in a test.
enum Highlighter {
    struct Style: Equatable {
        var range: NSRange
        var kind: Kind
    }

    enum Kind: Equatable {
        case heading(level: Int)
        case bold
        case italic
        case highlight
        case code
        /// A ``` fence. Keeps its fences in the text, unlike every other
        /// construct: they are the only thing marking where the block ends, and
        /// a block whose end is invisible is one you cannot type your way out of.
        case codeBlock
        case strikethrough
        /// `$x+y=1$` and `$$…$$`. The content is TeX, handed to KaTeX.
        case math(display: Bool)
        case link(url: String)
        /// The `**`, `==`, `$` and `#` themselves. Deleted from what you see.
        case marker
        case listBullet
        case quote
    }

    /// What a pattern is allowed to do to, and suffer from, its neighbours.
    private enum Role {
        /// Claims its range: nothing else may style inside it. Code and maths,
        /// where the markup is the content.
        case verbatim
        /// Line-level shape. Survives inside a verbatim span — a heading that
        /// happens to contain `$x$` is still a heading.
        case structural
        /// Suppressed inside a verbatim span: the `*` in `$a^*$` is a
        /// superscript, and the `**` in `` `a**b` `` is two literal asterisks.
        case inline
    }

    private typealias Build = (NSTextCheckingResult, NSString) -> [Style]

    /// One regular expression per construct, compiled once.
    ///
    /// Ordered verbatim first so the claimed ranges are known before any inline
    /// pattern is asked whether it falls inside one, and longer markers before
    /// their prefixes so `***a***` is not read as `**` followed by a stray `*`.
    private static let patterns: [(NSRegularExpression, Role, Build)] = {
        func re(_ p: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
            try! NSRegularExpression(pattern: p, options: options)
        }
        /// Marker, content, marker — the shape of every paired construct.
        func delimited(_ m: NSTextCheckingResult, _ width: Int, _ kinds: [Kind]) -> [Style] {
            [Style(range: NSRange(location: m.range.location, length: width), kind: .marker)]
                + kinds.map { Style(range: m.range(at: 1), kind: $0) }
                + [Style(range: NSRange(location: m.range.upperBound - width, length: width),
                         kind: .marker)]
        }
        return [
            (re(#"```[\s\S]*?```"#), .verbatim, { m, _ in
                [Style(range: m.range, kind: .codeBlock)]
            }),
            (re(#"`([^`\n]+)`"#), .verbatim, { m, _ in delimited(m, 1, [.code]) }),
            // Display maths before inline, or $$x$$ reads as two empty spans.
            (re(#"\$\$([\s\S]+?)\$\$"#), .verbatim, { m, _ in
                delimited(m, 2, [.math(display: true)])
            }),
            // The currency guard: "$5 and $7" is money, "$x+y=1$" is maths.
            (re(#"\$(?!\s)([^$\n]+?)(?<!\s)\$"#), .verbatim, { m, _ in
                delimited(m, 1, [.math(display: false)])
            }),
            // The marker swallows the trailing space too, so a stripped heading
            // does not start with one.
            // (.+) not (.*): the hashes only come out once there is something
            // for the heading level to live on. Otherwise typing "# " deletes
            // the hash, and the heading is gone before a word of it is written.
            (re(#"^(#{1,6}[ \t]+)(.+)$"#, [.anchorsMatchLines]), .structural, { m, s in
                let level = s.substring(with: m.range(at: 1))
                    .filter { $0 == "#" }.count
                return [Style(range: m.range(at: 1), kind: .marker),
                        Style(range: m.range(at: 2), kind: .heading(level: level))]
            }),
            (re(#"==([^=\n]+)=="#), .inline, { m, _ in delimited(m, 2, [.highlight]) }),
            // Bold-italic first: **bold** would otherwise eat the inner stars
            // and leave the outer ones stranded.
            (re(#"\*\*\*([^*\n]+)\*\*\*"#), .inline, { m, _ in
                delimited(m, 3, [.bold, .italic])
            }),
            (re(#"\*\*([^*\n]+)\*\*"#), .inline, { m, _ in delimited(m, 2, [.bold]) }),
            (re(#"(?<!\*)\*(?!\*)([^*\n]+)\*(?!\*)"#), .inline, { m, _ in
                delimited(m, 1, [.italic])
            }),
            (re(#"~~([^~\n]+)~~"#), .inline, { m, _ in delimited(m, 2, [.strikethrough]) }),
            (re(#"\[([^\]\n]+)\]\(([^)\n]+)\)"#), .inline, { m, s in
                let text = m.range(at: 1)
                return [Style(range: NSRange(location: m.range.location, length: 1), kind: .marker),
                        Style(range: text, kind: .link(url: s.substring(with: m.range(at: 2)))),
                        Style(range: NSRange(location: text.upperBound,
                                             length: m.range.upperBound - text.upperBound),
                              kind: .marker)]
            }),
            // Bullets and quote marks are left in the text: they read as what
            // they are, and taking them out would mean owning list indentation.
            (re(#"^[ \t]*([-*+]|\d+\.)[ \t]"#, [.anchorsMatchLines]), .structural, { m, _ in
                [Style(range: m.range(at: 1), kind: .listBullet)]
            }),
            (re(#"^[ \t]*>[ \t]?.*$"#, [.anchorsMatchLines]), .structural, { m, _ in
                [Style(range: m.range, kind: .quote)]
            }),
        ]
    }()

    /// Every span in `text`, markers included so a caller can drop them.
    static func styles(in text: String) -> [Style] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var verbatim: [Style] = []
        var claimed: [NSRange] = []
        var rest: [Style] = []

        for (regex, role, build) in patterns {
            for match in regex.matches(in: text, range: full) {
                let built = build(match, ns).filter { $0.range.length > 0 }
                switch role {
                case .verbatim:
                    // A $ inside a code fence is the fence's business.
                    guard !overlaps(match.range, claimed) else { continue }
                    claimed.append(match.range)
                    verbatim.append(contentsOf: built)
                case .structural:
                    rest.append(contentsOf: built)
                case .inline:
                    guard !overlaps(match.range, claimed) else { continue }
                    rest.append(contentsOf: built)
                }
            }
        }
        return rest + verbatim
    }

    private static func overlaps(_ range: NSRange, _ ranges: [NSRange]) -> Bool {
        ranges.contains { NSIntersectionRange($0, range).length > 0 }
    }
}
