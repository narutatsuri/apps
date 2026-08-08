import Foundation

/// People whose work is worth reading on sight.
///
/// A second, independent source of recommendations. The citation-based one can only
/// suggest what your existing papers already point at, so it is structurally blind
/// to anything published after them — exactly the papers most worth knowing about.
/// Following authors covers that gap: it finds work that nothing in your library
/// cites yet, because it did not exist when your library was written.
///
/// Plain text in the notes repo, so the list is versioned with the notes and
/// editable in any editor without the app running.
enum TrustedAuthors {
    static var fileURL: URL { Library.root.appendingPathComponent("trusted-authors.txt") }
    static var dismissedURL: URL { Library.root.appendingPathComponent("not-interested.txt") }

    private static let defaults = """
    # Authors whose new work you want to hear about.
    #
    # One full name per line, as it appears on arXiv. Matched against the paper's
    # complete author list, not just the first few, so it finds papers where they
    # are the last author too.
    #
    # These feed the "What to Read Next" window alongside the papers your library
    # keeps citing. Nothing here is downloaded automatically.

    Owain Evans

    # Add more below. Lines starting with # are ignored.
    """

    static func bootstrap() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? defaults.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    static func names() -> [String] {
        let raw = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? defaults
        return raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    // MARK: - Not interested

    /// Ids you have waved away. Without this the same suggestions come back every
    /// time, and a recommender that cannot take no for an answer stops being read.
    static func dismissed() -> Set<String> {
        let raw = (try? String(contentsOf: dismissedURL, encoding: .utf8)) ?? ""
        return Set(raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { PDFRefs.normalise(String($0.split(separator: " ").first ?? "")) }
            .filter { !$0.isEmpty })
    }

    /// Appends rather than rewrites, and keeps the title alongside the id so the
    /// file stays readable months later.
    static func dismiss(_ arxivID: String, title: String) {
        let id = PDFRefs.normalise(arxivID)
        guard !id.isEmpty, !dismissed().contains(id) else { return }
        var text = (try? String(contentsOf: dismissedURL, encoding: .utf8))
            ?? "# Papers you have waved away. Delete a line to see it suggested again.\n\n"
        if !text.hasSuffix("\n") { text += "\n" }
        text += "\(id)  \(title.replacingOccurrences(of: "\n", with: " "))\n"
        try? text.write(to: dismissedURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Matching

    /// Fold to something two spellings of the same person agree on: case, accents
    /// and punctuation all vary between arXiv listings of the same author.
    static func fold(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: #"[^a-z ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    /// True when `authors` really contains `name`. arXiv's author search is a text
    /// query, so it returns papers by other people with similar names — searching
    /// for one author and trusting the result would file a stranger's paper under
    /// someone you follow.
    static func matches(name: String, in authors: [String]) -> Bool {
        let want = fold(name)
        guard !want.isEmpty else { return false }
        let wantParts = want.split(separator: " ")
        guard let surname = wantParts.last else { return false }
        for author in authors {
            let got = fold(author)
            if got == want { return true }
            // "J. Steinhardt" against "Jacob Steinhardt": surname must match and
            // every given name must agree at least on its initial.
            let gotParts = got.split(separator: " ")
            guard gotParts.last == surname, gotParts.count == wantParts.count else { continue }
            let initialsAgree = zip(gotParts.dropLast(), wantParts.dropLast()).allSatisfy {
                $0.first == $1.first
            }
            if initialsAgree { return true }
        }
        return false
    }

    // MARK: - Fetching

    struct Paper {
        let arxivID: String
        let title: String
        let authors: [String]
        let year: Int?
        let published: Date?
    }

    /// Recent arXiv papers by one author, newest first.
    static func recent(by name: String, limit: Int = 20) async -> [Paper] {
        let quoted = "au:\"\(name)\""
        guard let encoded = quoted.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://export.arxiv.org/api/query?search_query=\(encoded)"
                            + "&sortBy=submittedDate&sortOrder=descending&max_results=\(limit)")
        else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let xml = String(data: data, encoding: .utf8) else { return [] }
        return parse(xml).filter { matches(name: name, in: $0.authors) }
    }

    /// Split out so the entry parsing can be tested without a network call.
    static func parse(_ xml: String) -> [Paper] {
        var out: [Paper] = []
        var rest = Substring(xml)
        while let open = rest.range(of: "<entry>"), let close = rest.range(of: "</entry>") {
            let entry = rest[open.upperBound..<close.lowerBound]
            rest = rest[close.upperBound...]

            guard let idRange = entry.range(of: "arxiv.org/abs/") else { continue }
            let idTail = entry[idRange.upperBound...].prefix { $0.isNumber || $0 == "." }
            let id = PDFRefs.normalise(String(idTail))
            guard !id.isEmpty else { continue }

            let title = field(entry, "title")?
                .split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
            var authors: [String] = []
            var scan = entry
            while let a = scan.range(of: "<name>"), let b = scan.range(of: "</name>") {
                authors.append(String(scan[a.upperBound..<b.lowerBound]))
                scan = scan[b.upperBound...]
            }
            let stamp = field(entry, "published")
            let year = stamp.flatMap { Int($0.prefix(4)) }
            out.append(Paper(arxivID: id, title: title, authors: authors,
                             year: year, published: stamp.flatMap(iso.date(from:))))
        }
        return out
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func field(_ s: Substring, _ tag: String) -> String? {
        guard let a = s.range(of: "<\(tag)>"),
              let b = s.range(of: "</\(tag)>", range: a.upperBound..<s.endIndex) else { return nil }
        return String(s[a.upperBound..<b.lowerBound])
    }
}
