import Foundation
import CoreGraphics

/// `--export-graph <path>` — the citation graph as data for the website.
///
/// Same nodes, same edges, same deterministic layout, same viridis-by-year and
/// sqrt-citations sizing as the graph window; the website renders the result
/// with a few dozen lines of JavaScript instead of a Canvas. What travels per
/// node beyond geometry is deliberately narrow: the title, the link, and the
/// note's "Claim, in my words" section — the summary-shaped part of a note.
/// Verdicts, confusions and appraisals are working notes and stay off the web.
enum GraphExport {
    static let canvas = CGSize(width: 1000, height: 620)

    /// A paper's one-line label, mirroring the graph window's. A paper whose
    /// metadata never arrived labels by its title's leading words rather than
    /// a bare arXiv id — "2507.14805v1.pdf" on the site read as a glitch, and
    /// thirty papers in the library have no author metadata.
    static func label(_ paper: Paper) -> String {
        let name = paper.authors.first.map { name -> String in
            name.contains(",")
                ? String(name.split(separator: ",")[0])
                : (name.split(separator: " ").last.map(String.init) ?? name)
        } ?? titleFragment(paper)
        return paper.year.map { "\(name) \($0)" } ?? name
    }

    /// The title's leading words, shaped into a label: a leading article or a
    /// literal "arXiv:…" token is skipped, trailing punctuation stripped, and
    /// a short first word ("How", "Your", "SFT") takes the next word with it —
    /// a graph dotted with "The" and "From" names nothing.
    private static func titleFragment(_ paper: Paper) -> String {
        let words = paper.title.split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ":;,.?!")) }
            .filter { !$0.isEmpty }
        var index = 0
        while index < words.count,
              ["a", "an", "the"].contains(words[index].lowercased())
              || words[index].lowercased().hasPrefix("arxiv") {
            index += 1
        }
        guard index < words.count else { return paper.arxivID }
        var fragment = words[index]
        if fragment.count < 5, index + 1 < words.count {
            fragment += " " + words[index + 1]
        }
        return fragment
    }

    static func hex(_ t: Double) -> String {
        let c = Viridis.rgb(t)
        return String(format: "#%02x%02x%02x",
                      Int(c.r * 255), Int(c.g * 255), Int(c.b * 255))
    }

    /// The whole payload, from the library. Pure and deterministic — the same
    /// papers always produce the same bytes, which is what makes both the
    /// selftest and a clean website diff possible.
    static func payload(for library: [Paper]) -> [String: Any] {
        // Archived papers are out, exactly as they are out of the graph window.
        let papers = library.filter { !$0.archaic }.sorted { $0.arxivID < $1.arxivID }
        let edges = Relations.edges(in: papers)
        let placed = ForceLayout.layout(ids: papers.map(\.arxivID),
                                        edges: edges, size: canvas)
        let maxCitations = max(1, papers.map(\.citations).max() ?? 1)
        let years = papers.compactMap(\.year)
        let (loYear, hiYear) = (years.min() ?? 2020, years.max() ?? 2026)

        let index = Dictionary(uniqueKeysWithValues:
            papers.enumerated().map { ($1.arxivID, $0) })
        var nodes: [[String: Any]] = []
        for paper in papers {
            let p = placed[paper.arxivID]?.position ?? .zero
            let t = sqrt(Double(paper.citations)) / sqrt(Double(maxCitations))
            let shade = paper.year.map {
                Double($0 - loYear) / Double(max(1, hiYear - loYear))
            } ?? 0.5
            nodes.append([
                "id": paper.arxivID,
                "label": label(paper),
                "title": paper.title.isEmpty ? paper.arxivID : paper.title,
                "url": paper.externalURL?.absoluteString ?? "",
                "x": (Double(p.x) * 10).rounded() / 10,
                "y": (Double(p.y) * 10).rounded() / 10,
                "r": ((5 + t * 11) * 10).rounded() / 10,
                "fill": hex(shade),
                "summary": paper.webSummary,
            ])
        }
        let edgeList: [[Any]] = edges.compactMap { a, b, w in
            guard let i = index[a], let j = index[b] else { return nil }
            return [i, j, (w * 1000).rounded() / 1000]
        }.sorted { ($0[0] as! Int, $0[1] as! Int) < ($1[0] as! Int, $1[1] as! Int) }
        return [
            "width": Double(canvas.width),
            "height": Double(canvas.height),
            "nodes": nodes,
            "edges": edgeList,
        ]
    }

    /// `wrap` produces a JS file assigning `window.READING_GRAPH`, so the site
    /// works when opened as a plain file too — `fetch` over `file://` does not.
    static func text(for library: [Paper], wrap: Bool) -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: payload(for: library),
            options: [.sortedKeys])) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return wrap ? "window.READING_GRAPH = \(json);\n" : json + "\n"
    }
}
