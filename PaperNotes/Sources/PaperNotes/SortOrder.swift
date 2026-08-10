import Foundation

/// How the sidebar is ordered. Publication date by default — the question when
/// looking at a reading list is usually "what is recent", not "what did I open last".
enum SortOrder: String, CaseIterable, Identifiable {
    case published, added, interest, queue, citations, title, unread

    var id: String { rawValue }

    var label: String {
        switch self {
        case .published: return "Publication date"
        case .added: return "Recently added"
        case .interest: return "Most interesting"
        case .queue: return "Reading queue"
        case .citations: return "Most cited"
        case .title: return "Title"
        case .unread: return "Unread first"
        }
    }

    static func apply(_ order: SortOrder, to papers: [Paper]) -> [Paper] {
        switch order {
        case .published:
            // From the arXiv id, so the order is by month and survives a paper
            // whose metadata never arrived — sorting those to the bottom put
            // 2025 papers below 2016 ones.
            return papers.sorted {
                ($0.published.year, $0.published.month, $0.arxivID)
                    > ($1.published.year, $1.published.month, $1.arxivID)
            }
        case .added:
            return papers.sorted { ($0.readOn ?? .distantPast) > ($1.readOn ?? .distantPast) }
        case .interest:
            // By the grade on the shelf — yours where you wrote one, Claude's
            // otherwise — then by recency inside each band. Ungraded papers sink,
            // because an absent grade is not a low one.
            return papers.sorted { a, b in
                // The whole-library ranking wins where it exists: it is the only
                // signal derived from comparing papers to each other.
                let ar = a.appraisalRank > 0 ? a.appraisalRank : Int.max
                let br = b.appraisalRank > 0 ? b.appraisalRank : Int.max
                if ar != br { return ar < br }
                let l = interestRank(a), r = interestRank(b)
                if l != r { return l < r }
                return (a.published.year, a.published.month) > (b.published.year, b.published.month)
            }
        case .queue:
            // Queued papers in queue order, then everything else by interest —
            // the list stays usable when the queue is short or empty.
            return papers.sorted { a, b in
                switch (a.isQueued, b.isQueued) {
                case (true, true): return a.queuePosition < b.queuePosition
                case (true, false): return true
                case (false, true): return false
                case (false, false):
                    let l = interestRank(a), r = interestRank(b)
                    return l == r ? a.published > b.published : l < r
                }
            }
        case .citations:
            return papers.sorted { $0.citations == $1.citations
                ? $0.arxivID > $1.arxivID : $0.citations > $1.citations }
        case .title:
            return papers.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .unread:
            // Starred first within each group: those are the ones worth reading next.
            return papers.sorted { a, b in
                if a.isSubstantive != b.isSubstantive { return !a.isSubstantive }
                if a.starred != b.starred { return a.starred }
                return (a.year ?? 0) > (b.year ?? 0)
            }
        }
    }

    /// `unset` ranks below every real grade rather than in the middle of the scale.
    private static func interestRank(_ p: Paper) -> Int {
        switch p.effectiveVerdict {
        case .gold: return 0
        case .solid: return 1
        case .mixed: return 2
        case .thin: return 3
        case .garbage: return 4
        case .unset: return 5
        }
    }
}
