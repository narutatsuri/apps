import Foundation

/// What to read next, in order.
///
/// The positions are kept dense and 1-based at all times — every mutation
/// renumbers. A queue that leaves gaps (1, 2, 5) still *sorts* correctly, so the
/// bug hides until something reads a position as a count and reports "3 of 5".
///
/// Pure on purpose: the whole risk in a reading queue is the arithmetic, and
/// arithmetic that only runs behind a button press is arithmetic nobody checks.
enum ReadingQueue {
    /// The queued papers, in reading order.
    static func ordered(_ papers: [Paper]) -> [Paper] {
        papers.filter(\.isQueued).sorted { $0.queuePosition < $1.queuePosition }
    }

    /// Where each paper should end up after `ids` are added at the given end.
    /// Returns only the papers whose position actually changes, so a caller
    /// writing to disk touches the minimum number of files.
    ///
    /// Adding something already queued moves it rather than duplicating it —
    /// "read this next" on a paper already third in line is a reorder request,
    /// not a no-op and not a second entry.
    static func adding(_ ids: [String], to papers: [Paper], atFront: Bool) -> [Paper] {
        let wanted = ids.map(PDFRefs.normalise).filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return [] }

        let byID = Dictionary(uniqueKeysWithValues:
            papers.map { (PDFRefs.normalise($0.arxivID), $0) })
        // Preserve the caller's order for the newcomers, dropping ids that
        // aren't in the library and any repeats within the same request.
        var seen = Set<String>()
        let incoming = wanted.filter { byID[$0] != nil && seen.insert($0).inserted }
        guard !incoming.isEmpty else { return [] }

        let incomingSet = Set(incoming)
        let existing = ordered(papers)
            .map { PDFRefs.normalise($0.arxivID) }
            .filter { !incomingSet.contains($0) }

        let order = atFront ? incoming + existing : existing + incoming
        return renumber(order, in: papers)
    }

    /// Positions after `ids` leave the queue.
    static func removing(_ ids: [String], from papers: [Paper]) -> [Paper] {
        let drop = Set(ids.map(PDFRefs.normalise))
        var changed: [Paper] = []
        for var paper in papers where paper.isQueued
            && drop.contains(PDFRefs.normalise(paper.arxivID)) {
            paper.queuePosition = -1
            changed.append(paper)
        }
        guard !changed.isEmpty else { return [] }
        let remaining = ordered(papers)
            .map { PDFRefs.normalise($0.arxivID) }
            .filter { !drop.contains($0) }
        return changed + renumber(remaining, in: papers)
    }

    /// Assigns 1…n over `order` and returns only the papers that moved.
    private static func renumber(_ order: [String], in papers: [Paper]) -> [Paper] {
        let byID = Dictionary(uniqueKeysWithValues:
            papers.map { (PDFRefs.normalise($0.arxivID), $0) })
        var changed: [Paper] = []
        for (i, id) in order.enumerated() {
            guard var paper = byID[id] else { continue }
            let position = i + 1
            guard paper.queuePosition != position else { continue }
            paper.queuePosition = position
            changed.append(paper)
        }
        return changed
    }
}
