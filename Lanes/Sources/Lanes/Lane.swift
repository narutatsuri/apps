import Foundation

/// One thread of a project: a markdown file inside the project's folder.
struct Thread: Identifiable, Equatable {
    let id: String
    var title: String
    var text: String = ""
    var rendered: Bool = false
    var width: CGFloat = Lane.defaultWidth
}

/// One project's column.
///
/// Unsplit, it is a single markdown file named after it. Split into threads,
/// it is a folder of them — `<Title>/<Thread>.md` — shown as sub-columns side
/// by side under one header. The title *is* the filename either way, so the
/// lanes folder reads the way the board does. The id is separate and
/// stable, so renaming never tears a column down and rebuilds it.
struct Lane: Identifiable, Equatable {
    let id: String
    var title: String
    var text: String = ""
    /// Left in rendered view rather than the editor. Per lane: a project you
    /// are reporting on wants rendering; one you are thinking in does not.
    var rendered: Bool = false
    /// Column width in points. Every lane starts at the default; dragging a
    /// lane's right edge sets its own, so a project with more to say can
    /// take more room without the whole board changing.
    var width: CGFloat = Lane.defaultWidth
    /// The project's threads. Only a split project (a folder) has any; the
    /// folder's own writing lives in `text` (above the threads) and
    /// `belowText` (below them).
    var threads: [Thread] = []
    var isSplit: Bool = false
    /// Split only: the project's writing under the thread row — the place for
    /// what the threads add up to.
    var belowText: String = ""
    var belowRendered: Bool = false

    /// Height of the project's own note areas above and below the threads.
    /// Fixed, so the thread row keeps a predictable share of the column.
    static let aboveHeight: CGFloat = 150
    static let belowHeight: CGFloat = 130

    static let defaultWidth: CGFloat = 380
    /// Narrow enough to be a sliver you can still read a title in, wide
    /// enough to be a page — and never so wide that a column swallows the
    /// window and the board stops being a board.
    static func clampWidth(_ width: CGFloat) -> CGFloat { min(1200, max(240, width)) }

    /// Widths rescaled so they sum to `total`, each still clamped: dragging a
    /// project's edge shrinks or grows all its threads in proportion, rather
    /// than only the last one.
    static func scaled(_ widths: [CGFloat], toTotal total: CGFloat) -> [CGFloat] {
        let current = widths.reduce(0, +)
        guard current > 0 else { return widths }
        return widths.map { clampWidth($0 * total / current) }
    }
}
