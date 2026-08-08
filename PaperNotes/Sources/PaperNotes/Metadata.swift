import Foundation

/// Title, authors and year from **arXiv**; citation counts from OpenAlex.
///
/// OpenAlex was the sole source and it is not reliable for preprints. Two failures
/// found in one batch of eight: `2501.12948` (DeepSeek-R1) did not resolve at all,
/// and `2402.03300` came back as "BioXP-0.5B: Explainable Medical-AI" when it is
/// actually DeepSeekMath — a different paper entirely. arXiv's own API is
/// authoritative for arXiv ids and got both right.
///
/// OpenAlex is still used for `cited_by_count`, which arXiv does not publish and
/// which it reports correctly even where its metadata is wrong.
enum Metadata {
    struct Result {
        var title: String
        var authors: [String]
        var year: Int?
        var venue: String
        var citations: Int
        /// The submission date. The recommender orders by recency, so a missing
        /// date is not cosmetic — it silently pushes a paper down the list.
        var published: Date?
    }

    static func fetch(arxivID: String) async -> Result? {
        let id = PDFRefs.normalise(arxivID)
        async let arxiv = fetchArxiv(id)
        async let counted = fetchCitationCount(id)
        guard var result = await arxiv else {
            // arXiv failed; fall back rather than lose the paper entirely.
            return await fetchOpenAlex(id)
        }
        result.citations = await counted
        return result
    }

    // MARK: - arXiv (authoritative for identity)

    /// arXiv answers a burst of back-to-back queries with non-200s. Fetching six
    /// candidates in a tight loop left three of them with no title at all, while the
    /// same six ids all resolved from the command line moments later — so the ids
    /// were fine and the pace was not. Requests are spaced, and a failure is retried
    /// once rather than costing the paper its identity.
    private actor Pace {
        static let shared = Pace()
        private var next = Date.distantPast

        func wait(_ gap: TimeInterval = 1.2) async {
            let now = Date()
            let start = max(now, next)
            next = start.addingTimeInterval(gap)
            let delay = start.timeIntervalSince(now)
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        }
    }

    private static func fetchArxiv(_ id: String) async -> Result? {
        if let first = await requestArxiv(id) { return first }
        await Pace.shared.wait(2.5)
        return await requestArxiv(id)
    }

    private static func requestArxiv(_ id: String) async -> Result? {
        await Pace.shared.wait()
        guard let url = URL(string: "https://export.arxiv.org/api/query?id_list=\(id)") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let xml = String(data: data, encoding: .utf8),
              let entry = between(xml, "<entry>", "</entry>") else { return nil }

        guard let rawTitle = between(entry, "<title>", "</title>") else { return nil }
        let title = rawTitle.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // arXiv reports a bad or throttled query as a 200 whose single entry is
        // titled "Error" — accepting that would file the paper under that name.
        guard !title.isEmpty, title != "Error" else { return nil }

        var authors: [String] = []
        var rest = Substring(entry)
        while let open = rest.range(of: "<name>"), let close = rest.range(of: "</name>") {
            authors.append(String(rest[open.upperBound..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        let stampText = between(entry, "<published>", "</published>")
        let year = stampText.flatMap { Int($0.prefix(4)) }
        return Result(title: decode(title), authors: Array(authors.prefix(12)),
                      year: year, venue: "arXiv", citations: 0,
                      published: stampText.flatMap(iso.date(from:)))
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func between(_ s: String, _ open: String, _ close: String) -> String? {
        guard let a = s.range(of: open), let b = s.range(of: close, range: a.upperBound..<s.endIndex)
        else { return nil }
        return String(s[a.upperBound..<b.lowerBound])
    }

    private static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    /// Last resort when a PDF carries no arXiv id anywhere: search OpenAlex by
    /// title and recover the id from the DOI. Anthropic-formatted PDFs in particular
    /// omit the arXiv banner — MacDiarmid 2025 was on arXiv as 2511.18397 the whole
    /// time and would otherwise have been skipped forever.
    static func arxivID(forTitle title: String) async -> String? {
        let query = title.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "&", with: "")
        guard let url = URL(string:
            "https://api.openalex.org/works?filter=title.search:\(query)&per-page=3&select=title,doi")
        else { return nil }
        var req = URLRequest(url: url)
        req.setValue("PaperNotes (local research tool)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }

        for work in results {
            guard let doi = work["doi"] as? String,
                  doi.lowercased().contains("arxiv") else { continue }
            // "https://doi.org/10.48550/arxiv.2511.18397"
            let re = try! NSRegularExpression(pattern: #"([0-9]{4}\.[0-9]{4,5})"#)
            let r = NSRange(doi.startIndex..., in: doi)
            if let m = re.firstMatch(in: doi, range: r), let rr = Range(m.range(at: 1), in: doi) {
                return String(doi[rr])
            }
        }
        return nil
    }

    // MARK: - OpenAlex (citation counts, and a fallback)

    private static func openAlex(_ id: String) async -> [String: Any]? {
        guard let url = URL(string:
            "https://api.openalex.org/works/https://doi.org/10.48550/arXiv.\(id)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("PaperNotes (local research tool)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func fetchCitationCount(_ id: String) async -> Int {
        (await openAlex(id))?["cited_by_count"] as? Int ?? 0
    }

    private static func fetchOpenAlex(_ id: String) async -> Result? {
        guard let json = await openAlex(id), let title = json["title"] as? String else { return nil }
        let authors: [String] = (json["authorships"] as? [[String: Any]] ?? []).compactMap {
            ($0["author"] as? [String: Any])?["display_name"] as? String
        }
        let venue = ((json["primary_location"] as? [String: Any])?["source"] as? [String: Any])?["display_name"] as? String
        return Result(title: title, authors: Array(authors.prefix(12)),
                      year: json["publication_year"] as? Int,
                      venue: venue ?? "arXiv",
                      citations: json["cited_by_count"] as? Int ?? 0,
                      published: (json["publication_date"] as? String)
                          .flatMap(SemanticScholar.day))
    }
}
