import Foundation

/// Blog posts and web pages as library entries.
///
/// A post is a hand-keyed paper: the key comes from the URL's slug, the page
/// itself supplies title, authors and publication date, and the URL is stored
/// in the frontmatter so the entry links back to its source. LessWrong, the
/// Alignment Forum and the EA Forum run the same codebase behind a bot wall
/// that serves curl a checkpoint page — their public GraphQL API is the front
/// door, so those go through it; everything else is read from the HTML's
/// structured metadata (JSON-LD, OpenGraph, meta tags), which is what the
/// sites themselves publish for exactly this purpose.
enum WebIngest {
    struct Result: Equatable {
        var title = ""
        var authors: [String] = []
        var published: Date?
    }

    /// A URL the add path should treat as a web page: http(s), and not arXiv —
    /// arXiv URLs already resolve to real paper keys with references and PDFs,
    /// and quietly downgrading one to a web entry would be a worse ingestion.
    static func ingestableURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("http://")
                || trimmed.lowercased().hasPrefix("https://"),
              let url = URL(string: trimmed),
              let host = url.host?.lowercased(),
              !host.hasSuffix("arxiv.org") else { return nil }
        return url
    }

    /// The entry's key: the host's first label plus the URL's slug, at most
    /// six words — "lesswrong-astra-and-fable-still-hack-on". Deterministic,
    /// so adding the same post twice finds the existing entry instead of
    /// forking it.
    static func key(for url: URL) -> String {
        let host = (url.host ?? "web").lowercased()
            .replacingOccurrences(of: "www.", with: "")
            .split(separator: ".").first.map(String.init) ?? "web"
        // The slug is the hyphenated path component, usually last; a random
        // document id ("munJKF7iWMsWJLAH2") has no hyphens and is skipped.
        let slug = url.pathComponents.reversed().first {
            $0.contains("-") && $0.rangeOfCharacter(from: .letters) != nil
        } ?? url.pathComponents.last(where: { $0 != "/" }) ?? "post"
        let cleaned = slug.lowercased()
            .map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        let words = String(cleaned).split(separator: "-").prefix(6)
        guard !words.isEmpty else { return host + "-post" }
        return host + "-" + words.joined(separator: "-")
    }

    // MARK: - Fetching

    static func fetch(_ url: URL) async -> Result? {
        if let postID = forumMagnumPostID(url),
           let viaAPI = await fetchForumMagnum(url: url, postID: postID) {
            return viaAPI
        }
        guard let html = await fetchHTML(url) else { return nil }
        let parsed = metadata(fromHTML: html)
        return parsed.title.isEmpty ? nil : parsed
    }

    /// The post id out of a ForumMagnum URL: /posts/<id>/<slug>.
    static func forumMagnumPostID(_ url: URL) -> String? {
        let hosts = ["lesswrong.com", "alignmentforum.org", "forum.effectivealtruism.org"]
        guard let host = url.host?.lowercased(),
              hosts.contains(where: { host.hasSuffix($0) }) else { return nil }
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: "posts"), i + 1 < parts.count else { return nil }
        return parts[i + 1]
    }

    private static func fetchForumMagnum(url: URL, postID: String) async -> Result? {
        guard let host = url.host,
              let endpoint = URL(string: "https://\(host)/graphql") else { return nil }
        let query = "{ post(input: {selector: {_id: \"\(postID)\"}}) { result "
            + "{ title postedAt user { displayName } coauthors { displayName } } } }"
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("PaperNotes/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return parseForumMagnum(data)
    }

    /// Split from the fetch so the selftest can drive it with a captured reply.
    static func parseForumMagnum(_ data: Data) -> Result? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let post = ((root["data"] as? [String: Any])?["post"]
                          as? [String: Any])?["result"] as? [String: Any],
              let title = post["title"] as? String, !title.isEmpty else { return nil }
        var authors: [String] = []
        if let name = (post["user"] as? [String: Any])?["displayName"] as? String {
            authors.append(name)
        }
        for co in post["coauthors"] as? [[String: Any]] ?? [] {
            if let name = co["displayName"] as? String { authors.append(name) }
        }
        return Result(title: title.trimmingCharacters(in: .whitespaces),
                      authors: authors,
                      published: (post["postedAt"] as? String).flatMap(parseDate))
    }

    private static func fetchHTML(_ url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        // A browser-shaped agent: plenty of blogs serve real pages to browsers
        // and interstitials to bare library agents.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) PaperNotes/1.0",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Generic HTML metadata

    /// What the page says about itself, most structured source first:
    /// JSON-LD article data, then OpenGraph, then plain meta tags, then the
    /// title element. Pure, so the selftest can feed it captured pages.
    static func metadata(fromHTML html: String) -> Result {
        var out = Result()

        if let article = jsonLDArticle(in: html) {
            out.title = (article["headline"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out.authors = jsonLDAuthors(article["author"])
            for key in ["datePublished", "dateCreated"] where out.published == nil {
                out.published = (article[key] as? String).flatMap(parseDate)
            }
        }
        if out.title.isEmpty, let og = metaContent(html, keys: ["og:title", "twitter:title"]) {
            out.title = og
        }
        if out.title.isEmpty, let bare = firstMatch(in: html,
                pattern: "<title[^>]*>([^<]*)</title>") {
            out.title = bare.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        out.title = unescape(out.title)

        if out.authors.isEmpty,
           let name = metaContent(html, keys: ["author", "article:author", "parsely-author"]),
           !name.lowercased().hasPrefix("http") {   // article:author may be a profile URL
            out.authors = name.split(separator: ",")
                .map { unescape($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
        }

        if out.published == nil {
            out.published = metaContent(html, keys:
                ["article:published_time", "date", "parsely-pub-date", "dc.date"])
                .flatMap(parseDate)
        }
        if out.published == nil,
           let t = firstMatch(in: html, pattern: "<time[^>]*datetime=[\"']([^\"']+)[\"']") {
            out.published = parseDate(t)
        }
        return out
    }

    private static func jsonLDArticle(in html: String) -> [String: Any]? {
        let pattern = "<script[^>]*type=[\"']application/ld\\+json[\"'][^>]*>(.*?)</script>"
        guard let re = try? NSRegularExpression(pattern: pattern,
                options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        for m in re.matches(in: html, range: range) {
            guard let r = Range(m.range(at: 1), in: html),
                  let data = String(html[r]).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            // A block can be one object, an array, or an @graph.
            var candidates: [[String: Any]] = []
            if let one = json as? [String: Any] {
                candidates = [one] + (one["@graph"] as? [[String: Any]] ?? [])
            } else if let many = json as? [[String: Any]] {
                candidates = many
            }
            let articleTypes = ["Article", "BlogPosting", "NewsArticle", "ScholarlyArticle"]
            for c in candidates {
                let type = c["@type"] as? String ?? ""
                if articleTypes.contains(type) || c["headline"] != nil { return c }
            }
        }
        return nil
    }

    private static func jsonLDAuthors(_ value: Any?) -> [String] {
        func name(_ any: Any?) -> String? {
            if let s = any as? String { return s }
            if let d = any as? [String: Any] { return d["name"] as? String }
            return nil
        }
        let raw: [String]
        if let list = value as? [Any] {
            raw = list.compactMap(name)
        } else {
            raw = [name(value)].compactMap { $0 }
        }
        return raw.map { unescape($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    /// `<meta property|name="key" content="…">`, either attribute order.
    static func metaContent(_ html: String, keys: [String]) -> String? {
        for key in keys {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let forward = "<meta[^>]*(?:property|name)=[\"']\(escaped)[\"'][^>]*"
                + "content=[\"']([^\"']*)[\"']"
            let reversed = "<meta[^>]*content=[\"']([^\"']*)[\"'][^>]*"
                + "(?:property|name)=[\"']\(escaped)[\"']"
            for pattern in [forward, reversed] {
                if let hit = firstMatch(in: html, pattern: pattern), !hit.isEmpty {
                    return unescape(hit)
                }
            }
        }
        return nil
    }

    private static func firstMatch(in html: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let m = re.firstMatch(in: html, range: range),
              let r = Range(m.range(at: 1), in: html) else { return nil }
        return String(html[r])
    }

    /// ISO 8601 with or without time, or a bare yyyy-MM-dd.
    static func parseDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in
            [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            iso.formatOptions = options
            if let d = iso.date(from: s) { return d }
        }
        let plain = DateFormatter()
        plain.dateFormat = "yyyy-MM-dd"
        plain.timeZone = .current
        return plain.date(from: String(s.prefix(10)))
    }

    /// The handful of entities that actually appear in titles.
    static func unescape(_ s: String) -> String {
        var out = s
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                               ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"),
                               ("&nbsp;", " "), ("&#8217;", "'"), ("&#8216;", "'"),
                               ("&#8220;", "\u{201C}"), ("&#8221;", "\u{201D}")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out
    }
}
