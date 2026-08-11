import Foundation
import PDFKit

/// One resource the reader wants to learn end to end — a course PDF, a web book,
/// a long blog post — reduced to named sections of plain text that the tutor can
/// turn into concepts.
///
/// Three ways in, tried in order of how clean the text comes out:
///
/// 1. A site root is first asked for `/llms-full.txt` — the convention by which
///    sites publish their whole content as one Markdown file for exactly this
///    use. rlhfbook.com serves its entire book this way, already split into
///    chapters by `#` headings, with none of the scraping noise below.
/// 2. A specific page is fetched and split at its own headings — whichever of
///    h1/h2/h3 the page actually uses for its sections, decided by counting
///    rather than assuming, because one post puts its methods under h3 and the
///    next under h2.
/// 3. A PDF is split by its outline where it has one, and by fixed page windows
///    where it does not.
enum Resource {
    struct Section: Equatable {
        var title: String
        var text: String
    }

    struct Loaded {
        var name: String
        var origin: String        // what was asked for, kept for provenance
        var sections: [Section]
    }

    // MARK: - Entry

    static func load(_ spec: String, nameOverride: String? = nil) -> Loaded? {
        if spec.hasPrefix("http://") || spec.hasPrefix("https://") {
            guard let url = URL(string: spec) else { return nil }
            return web(url, nameOverride: nameOverride)
        }
        let url = URL(fileURLWithPath: (spec as NSString).expandingTildeInPath)
        guard url.pathExtension.lowercased() == "pdf",
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return pdf(url, nameOverride: nameOverride)
    }

    // MARK: - Web

    private static func web(_ url: URL, nameOverride: String?) -> Loaded? {
        // A site root gets the llms-full.txt shortcut; a specific page was asked
        // for as a page, and gets read as one even when the site has the file.
        let isRoot = url.path.isEmpty || url.path == "/"
        if isRoot, let full = fetch(url.appendingPathComponent("llms-full.txt")),
           full.count > 10_000, full.contains("\n# ") || full.hasPrefix("# ") {
            var sections = markdownSections(full, heading: "# ")
            if sections.count < 3 { sections = markdownSections(full, heading: "## ") }
            let name = nameOverride
                ?? sections.first.map { $0.title.replacingOccurrences(of: " Full Text", with: "") }
                ?? url.host ?? "resource"
            // The first "section" of such files is usually a cover sheet; keep it
            // only if it carries real prose.
            if let first = sections.first, first.text.count < 400 { sections.removeFirst() }
            return Loaded(name: name, origin: url.absoluteString, sections: sections)
        }

        guard let html = fetch(url) else { return nil }
        // "Post title | site name" is two facts; the resource is the first one.
        let name = nameOverride
            ?? pageTitle(html)?.components(separatedBy: " | ").first?
                .trimmingCharacters(in: .whitespaces)
            ?? url.host ?? "resource"
        let sections = htmlSections(html)
        guard !sections.isEmpty else { return nil }
        return Loaded(name: name, origin: url.absoluteString, sections: sections)
    }

    /// The page's own sections, split at whichever heading level the page
    /// actually organises itself by.
    static func htmlSections(_ rawHTML: String) -> [Section] {
        var html = rawHTML
        for pattern in ["<script[^>]*>[\\s\\S]*?</script>",
                        "<style[^>]*>[\\s\\S]*?</style>",
                        "<nav[^>]*>[\\s\\S]*?</nav>",
                        "<header[^>]*>[\\s\\S]*?</header>",
                        "<footer[^>]*>[\\s\\S]*?</footer>"] {
            html = html.replacingOccurrences(of: pattern, with: " ",
                                             options: [.regularExpression, .caseInsensitive])
        }

        // Which level carries the structure? The one used most, provided it is
        // used at least three times — one h1 and one h2 is a title and a
        // references box, not an organisation.
        var chosen: Int?
        for level in [2, 3, 1] {
            if headings(in: html, level: level).count >= 3 { chosen = level; break }
        }

        guard let level = chosen else {
            let text = plainText(html)
            return text.count > 200 ? [Section(title: pageTitle(rawHTML) ?? "Page", text: text)] : []
        }

        // Mark the chosen headings before stripping tags, so the split points
        // survive into the plain text.
        let marker = "\u{1}SECTION\u{1}"
        let re = try! NSRegularExpression(
            pattern: "<h\(level)[^>]*>([\\s\\S]*?)</h\(level)>",
            options: .caseInsensitive)
        let marked = re.stringByReplacingMatches(
            in: html, range: NSRange(html.startIndex..., in: html),
            withTemplate: "\n\(marker)$1\(marker)\n")

        var sections: [Section] = []
        let parts = plainText(marked).components(separatedBy: marker)
        // parts alternate: preamble, title, body, title, body …
        var i = 1
        while i + 1 <= parts.count - 1 {
            // Blog headings often end in a self-anchor rendered as "#"; that is
            // chrome, not title.
            let title = parts[i].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "# \u{00a0}"))
            let body = parts[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, body.count > 120 {
                sections.append(Section(title: title, text: body))
            }
            i += 2
        }
        return sections
    }

    private static func headings(in html: String, level: Int) -> [String] {
        let re = try! NSRegularExpression(pattern: "<h\(level)[^>]*>([\\s\\S]*?)</h\(level)>",
                                          options: .caseInsensitive)
        let range = NSRange(html.startIndex..., in: html)
        return re.matches(in: html, range: range).compactMap {
            Range($0.range(at: 1), in: html).map { plainText(String(html[$0])) }
        }
    }

    static func pageTitle(_ html: String) -> String? {
        let re = try! NSRegularExpression(pattern: "<title[^>]*>([\\s\\S]*?)</title>",
                                          options: .caseInsensitive)
        let range = NSRange(html.startIndex..., in: html)
        guard let m = re.firstMatch(in: html, range: range),
              let r = Range(m.range(at: 1), in: html) else { return nil }
        let t = plainText(String(html[r]))
        return t.isEmpty ? nil : t
    }

    /// Tags out, entities unescaped, whitespace collapsed — but line structure
    /// kept, because the digester reads this and paragraph breaks carry meaning.
    static func plainText(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<br[^>]*>", with: "\n",
                                          options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</p>|</div>|</li>|</tr>",
                                   with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, char) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                               "&#39;": "'", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–"] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        let lines = s.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits concatenated Markdown at top-level headings — outside code fences,
    /// because a Python comment in a fenced block starts with `# ` too, and the
    /// RLHF book's training-code listings are full of them.
    static func markdownSections(_ text: String, heading: String = "# ") -> [Section] {
        var sections: [Section] = []
        var title = ""
        var body: [String] = []
        var inFence = false

        func close() {
            let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty || !text.isEmpty {
                sections.append(Section(title: title.isEmpty ? "Preamble" : title, text: text))
            }
        }
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
            if !inFence, line.hasPrefix(heading),
               !line.hasPrefix(heading + "#") {   // "# " must not also claim "## "
                close()
                title = String(line.dropFirst(heading.count)).trimmingCharacters(in: .whitespaces)
                body = []
            } else {
                body.append(line)
            }
        }
        close()
        // Nothing before the first heading worth keeping? Drop the empty shell.
        return sections.filter { !$0.text.isEmpty || !$0.title.isEmpty }
    }

    // MARK: - PDF

    private static func pdf(_ url: URL, nameOverride: String?) -> Loaded? {
        guard let doc = PDFDocument(url: url) else { return nil }
        let name = nameOverride
            ?? (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            ?? url.deletingPathExtension().lastPathComponent

        // The outline is the author's own chapter list; use it when it exists.
        var bounds: [(title: String, page: Int)] = []
        if let root = doc.outlineRoot {
            for i in 0..<root.numberOfChildren {
                guard let child = root.child(at: i), let dest = child.destination,
                      let page = dest.page else { continue }
                bounds.append((child.label ?? "Chapter \(i + 1)", doc.index(for: page)))
            }
        }
        var sections: [Section] = []
        if bounds.count >= 3 {
            for (i, b) in bounds.enumerated() {
                let end = i + 1 < bounds.count ? bounds[i + 1].page : doc.pageCount
                let text = pageText(doc, from: b.page, to: end)
                if text.count > 200 { sections.append(Section(title: b.title, text: text)) }
            }
        } else {
            // No usable outline: fixed windows, titled by page range so the
            // provenance of every concept still names somewhere to look.
            let window = 12
            var start = 0
            while start < doc.pageCount {
                let end = min(start + window, doc.pageCount)
                let text = pageText(doc, from: start, to: end)
                if text.count > 200 {
                    sections.append(Section(title: "Pages \(start + 1)–\(end)", text: text))
                }
                start = end
            }
        }
        guard !sections.isEmpty else { return nil }
        return Loaded(name: name, origin: url.path, sections: sections)
    }

    private static func pageText(_ doc: PDFDocument, from: Int, to: Int) -> String {
        var out = ""
        for i in from..<to { out += (doc.page(at: i)?.string ?? "") + "\n" }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Batching

    /// Groups sections into tutor-sized calls. Adjacent small sections share a
    /// call; a section too big for one call is split at paragraph boundaries.
    /// One call per chapter of a twenty-chapter book is twenty minutes of model
    /// time; one call per *paragraph* would be a day.
    static func batches(_ sections: [Section], cap: Int = 26_000) -> [[Section]] {
        var split: [Section] = []
        for s in sections {
            if s.text.count <= cap { split.append(s); continue }
            var part = 1
            var current = ""
            for para in s.text.components(separatedBy: "\n\n") {
                if current.count + para.count > cap, !current.isEmpty {
                    split.append(Section(title: "\(s.title) (part \(part))", text: current))
                    part += 1
                    current = ""
                }
                current += (current.isEmpty ? "" : "\n\n") + para
            }
            if !current.isEmpty {
                split.append(Section(title: part == 1 ? s.title : "\(s.title) (part \(part))",
                                     text: current))
            }
        }
        var out: [[Section]] = []
        var batch: [Section] = []
        var size = 0
        for s in split {
            if size + s.text.count > cap, !batch.isEmpty {
                out.append(batch); batch = []; size = 0
            }
            batch.append(s)
            size += s.text.count
        }
        if !batch.isEmpty { out.append(batch) }
        return out
    }

    // MARK: - Fetch

    private static func fetch(_ url: URL) -> String? {
        var request = URLRequest(url: url, timeoutInterval: 40)
        request.setValue("Mozilla/5.0 (Macintosh) Frontier/1.0", forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        var body: String?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                body = data.flatMap { String(data: $0, encoding: .utf8) }
            }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + 45) == .success else { return nil }
        return body
    }
}
