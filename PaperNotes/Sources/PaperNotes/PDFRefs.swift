import Foundation
import PDFKit

/// Pulls the citation graph out of the PDFs themselves.
///
/// This exists because the free citation APIs are unusable for the papers actually
/// being read: OpenAlex returns reference lists for older published work but **zero**
/// references for recent arXiv preprints, and Semantic Scholar rate-limits
/// unauthenticated callers. Measured across 82 AI-safety PDFs, local extraction found
/// a median of 19 references per paper with no paper yielding zero.
enum PDFRefs {
    /// Every common way an arXiv id appears in a bibliography. Matching only the
    /// literal "arXiv:" form finds a small fraction — many papers cite by URL.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?:arXiv[:\s]*|arxiv\.org/(?:abs|pdf)/)([0-9]{4}\.[0-9]{4,5})"#,
        options: .caseInsensitive)

    /// arXiv ids cited by the PDF at `url`, excluding the paper's own id.
    static func references(in url: URL, excluding own: String? = nil) -> [String] {
        guard let doc = PDFDocument(url: url), let text = doc.string else { return [] }
        return references(inText: text, excluding: own)
    }

    static func references(inText text: String, excluding own: String? = nil) -> [String] {
        var found = Set<String>()
        let range = NSRange(text.startIndex..., in: text)
        pattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let r = Range(match.range(at: 1), in: text) else { return }
            found.insert(String(text[r]))
        }
        if let own { found.remove(normalise(own)) }
        return found.sorted()
    }

    /// "2510.23966v2" and "arXiv:2510.23966" both mean the same node in the graph.
    static func normalise(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "arXiv:", with: "", options: .caseInsensitive)
        guard let dot = trimmed.firstIndex(of: ".") else { return trimmed }
        let tail = trimmed[trimmed.index(after: dot)...]
        let digits = tail.prefix { $0.isNumber }
        return String(trimmed[..<dot]) + "." + digits
    }

    /// Recovers an arXiv id from a filename, which is how the existing PDF piles are
    /// organised — either a trailing `__2510.23966` or a bare `2510.23966v2`.
    static func idFromFilename(_ name: String) -> String? {
        let re = try! NSRegularExpression(pattern: #"([0-9]{4}\.[0-9]{4,5})"#)
        let range = NSRange(name.startIndex..., in: name)
        guard let m = re.firstMatch(in: name, range: range),
              let r = Range(m.range(at: 1), in: name) else { return nil }
        return String(name[r])
    }

    /// First `pages` pages as plain text, for feeding a judge.
    static func text(of url: URL, pages: Int) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        var out = ""
        for i in 0..<min(pages, doc.pageCount) {
            out += (doc.page(at: i)?.string ?? "") + "\n"
        }
        return out
    }

    /// The paper's *own* arXiv id, read from the stamp arXiv prints down the left
    /// margin of page one — "arXiv:2510.23966v1 [cs.LG] 27 Oct 2025".
    ///
    /// Needed because a sensibly-organised library names files "Author Year - Title",
    /// not by identifier: of 60 PDFs in ~/Papers not one carried an id in its
    /// filename, while 59 carried it in the banner.
    static func ownID(in url: URL) -> String? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0)?.string else { return nil }
        let range = NSRange(page.startIndex..., in: page)
        // The banner form first — it is unambiguous. A bare match could pick up a
        // reference that happens to appear on page one.
        let banner = try! NSRegularExpression(
            pattern: #"arXiv[:\s]*([0-9]{4}\.[0-9]{4,5})(v[0-9]+)?\s*\[[a-zA-Z.\-]+\]"#)
        if let m = banner.firstMatch(in: page, range: range),
           let r = Range(m.range(at: 1), in: page) { return String(page[r]) }
        if let m = pattern.firstMatch(in: page, range: range),
           let r = Range(m.range(at: 1), in: page) { return String(page[r]) }
        return nil
    }

    /// Title from the PDF's own metadata, or the largest text on page one as a
    /// fallback. Only a hint — the metadata lookup is authoritative.
    static func guessTitle(in url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        if let t = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
           t.count > 8 { return t }
        guard let first = doc.page(at: 0)?.string else { return nil }
        return first.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.count > 12 && $0.count < 200 }
    }
}
