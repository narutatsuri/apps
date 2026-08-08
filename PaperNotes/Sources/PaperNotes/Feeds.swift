import Foundation

/// A paper from somewhere other than your own bibliographies.
struct FeedPaper {
    var arxivID: String
    var title: String
    var authors: [String] = []
    var abstract: String = ""
    var published: Date?
    var citations: Int = 0
}

/// Semantic Scholar's recommendation endpoint: "papers like these".
///
/// The third retrieval mode. Measured on this library, 51 of 64 papers were
/// unreachable by the two that existed — a paper only turns up in your
/// bibliographies if something you already have cites it, and only turns up
/// under a followed author if you happen to follow one of them. Neither can find
/// adjacent new work, which is most of what actually gets read.
///
/// No account, no key, no rate-limit headers to negotiate.
enum SemanticScholar {
    static func recommendations(seedIDs: [String], limit: Int = 60) async -> [FeedPaper] {
        let seeds = seedIDs.map(PDFRefs.normalise).filter { !$0.isEmpty }
        guard !seeds.isEmpty else { return [] }
        guard let url = URL(string: "https://api.semanticscholar.org/recommendations/v1/papers"
            + "?fields=title,abstract,publicationDate,externalIds,citationCount,authors"
            + "&limit=\(limit)") else { return [] }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("PaperNotes (local research tool)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 40
        // Cap the seed list: the endpoint weighs every seed, and a whole library
        // of seeds returns the average of your interests rather than the sharp
        // end of them.
        let body: [String: Any] = [
            "positivePaperIds": seeds.prefix(20).map { "arXiv:\($0)" },
            "negativePaperIds": [],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["recommendedPapers"] as? [[String: Any]] else { return [] }

        return list.compactMap { p in
            guard let ext = p["externalIds"] as? [String: Any],
                  let arxiv = ext["ArXiv"] as? String else { return nil }
            let authors = (p["authors"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
            return FeedPaper(arxivID: PDFRefs.normalise(arxiv),
                             title: (p["title"] as? String) ?? "",
                             authors: Array(authors.prefix(12)),
                             abstract: (p["abstract"] as? String) ?? "",
                             published: (p["publicationDate"] as? String).flatMap(day),
                             citations: (p["citationCount"] as? Int) ?? 0)
        }
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func day(_ s: String) -> Date? { dayFormat.date(from: s) }
}

/// New arXiv submissions in the categories this library lives in.
///
/// The only source that can reach a paper posted this week. Everything else
/// needs the world to have noticed the paper first — a citation from something
/// you own, or a recommendation engine that has indexed it.
enum ArxivFeed {
    static var categoriesURL: URL {
        Library.root.appendingPathComponent("arxiv-categories.txt")
    }

    private static let defaults = """
    # arXiv categories to watch for brand-new papers, one per line.
    #
    # Everything posted to these in the last few weeks is fetched and scored
    # against your library's own vocabulary; only the closest handful reach the
    # judge. Widening this costs a little time, not accuracy — the scoring is
    # what decides relevance.

    cs.LG
    cs.CL
    cs.AI
    cs.CR
    stat.ML
    """

    static func bootstrap() {
        if !FileManager.default.fileExists(atPath: categoriesURL.path) {
            try? defaults.write(to: categoriesURL, atomically: true, encoding: .utf8)
        }
    }

    static func categories() -> [String] {
        let raw = (try? String(contentsOf: categoriesURL, encoding: .utf8)) ?? defaults
        return raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmm"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Feeds are cached on disk for a few hours.
    ///
    /// A scan of five categories is a couple of thousand papers and a minute of
    /// paging, and arXiv posts once a day — refetching that every time the
    /// window opens spends a minute to learn nothing. Refresh forces it.
    enum Cache {
        static let lifetime: TimeInterval = 6 * 3600

        static var directory: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/PaperNotes/feeds")
        }

        static func url(_ key: String) -> URL {
            directory.appendingPathComponent("\(key).json")
        }

        static func load(_ key: String) -> [FeedPaper]? {
            let u = url(key)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
                  let modified = attrs[.modificationDate] as? Date,
                  Date().timeIntervalSince(modified) < lifetime,
                  let data = try? Data(contentsOf: u),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { return nil }
            return rows.compactMap { r in
                guard let id = r["id"] as? String else { return nil }
                return FeedPaper(arxivID: id,
                                 title: (r["title"] as? String) ?? "",
                                 authors: (r["authors"] as? [String]) ?? [],
                                 abstract: (r["abstract"] as? String) ?? "",
                                 published: (r["published"] as? Double).map(Date.init(timeIntervalSince1970:)))
            }
        }

        static func save(_ key: String, _ papers: [FeedPaper]) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let rows: [[String: Any]] = papers.map {
                var r: [String: Any] = ["id": $0.arxivID, "title": $0.title,
                                        "authors": $0.authors, "abstract": $0.abstract]
                if let d = $0.published { r["published"] = d.timeIntervalSince1970 }
                return r
            }
            guard let data = try? JSONSerialization.data(withJSONObject: rows) else { return }
            try? data.write(to: url(key))
        }

        static func clear() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Everything submitted to `category` in the last `days`, newest first.
    ///
    /// Paged, because a busy week in cs.LG is several hundred papers and arXiv
    /// caps a single response. Stops early when a page comes back short.
    static func recent(category: String, days: Int, cap: Int = 400,
                       useCache: Bool = true) async -> [FeedPaper] {
        let key = "\(category)-\(days)d"
        if useCache, let hit = Cache.load(key) { return hit }
        let now = Date()
        let from = stamp.string(from: now.addingTimeInterval(-Double(days) * 86_400))
        let to = stamp.string(from: now.addingTimeInterval(86_400))
        var out: [FeedPaper] = []
        let page = 100

        while out.count < cap {
            let query = "cat:\(category) AND submittedDate:[\(from) TO \(to)]"
            guard let encoded = query.addingPercentEncoding(
                    withAllowedCharacters: .alphanumerics),
                  let url = URL(string: "https://export.arxiv.org/api/query?search_query=\(encoded)"
                    + "&sortBy=submittedDate&sortOrder=descending"
                    + "&start=\(out.count)&max_results=\(page)") else { break }
            var req = URLRequest(url: url)
            req.timeoutInterval = 40
            guard let (data, response) = try? await URLSession.shared.data(for: req),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let xml = String(data: data, encoding: .utf8) else { break }

            let batch = parse(xml)
            out.append(contentsOf: batch)
            if batch.count < page { break }
            if out.count >= cap { break }
            // arXiv asks for a pause between calls, and a paging loop is exactly
            // the thing it asks it for.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        Cache.save(key, out)
        return out
    }

    /// Split out so the entry parsing is testable without a network call.
    static func parse(_ xml: String) -> [FeedPaper] {
        var out: [FeedPaper] = []
        var rest = Substring(xml)
        while let open = rest.range(of: "<entry>"), let close = rest.range(of: "</entry>") {
            let entry = rest[open.upperBound..<close.lowerBound]
            rest = rest[close.upperBound...]

            guard let idRange = entry.range(of: "arxiv.org/abs/") else { continue }
            let id = PDFRefs.normalise(String(
                entry[idRange.upperBound...].prefix { $0.isNumber || $0 == "." }))
            guard !id.isEmpty else { continue }

            func field(_ tag: String) -> String? {
                guard let a = entry.range(of: "<\(tag)>"),
                      let b = entry.range(of: "</\(tag)>", range: a.upperBound..<entry.endIndex)
                else { return nil }
                return String(entry[a.upperBound..<b.lowerBound])
            }
            func flat(_ s: String?) -> String {
                (s ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }

            var authors: [String] = []
            var scan = entry
            while let a = scan.range(of: "<name>"), let b = scan.range(of: "</name>") {
                authors.append(String(scan[a.upperBound..<b.lowerBound]))
                scan = scan[b.upperBound...]
            }

            out.append(FeedPaper(arxivID: id,
                                 title: flat(field("title")),
                                 authors: Array(authors.prefix(12)),
                                 abstract: flat(field("summary")),
                                 published: field("published").flatMap(iso.date(from:))))
        }
        return out
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
