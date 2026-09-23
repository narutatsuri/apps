import CoreGraphics
import Foundation

/// Making two notes the same width without measuring them.
///
/// Stickies get stacked — one above another, down the side of a screen — and
/// the thing that makes a stack look deliberate rather than dumped is that the
/// edges line up. Doing that by hand means dragging until it looks right, which
/// it never quite does. So a resize that comes close to another note's width
/// takes that width exactly, and an edge that comes close to another note's edge
/// lands on it.
///
/// Pure arithmetic over rectangles, deliberately: a live resize cannot be
/// screenshotted mid-drag, and "the window snapped" is a claim about numbers.
enum Snap {
    /// How near counts as near. Eight points is about a window border's width —
    /// close enough that you meant it, far enough that a deliberate 12pt
    /// difference survives.
    static let threshold: CGFloat = 8

    /// Which corner the drag is pinned to. Resizing moves two edges at most; the
    /// other two stay where they are, and snapping has to know which is which or
    /// it computes a width that pulls the wrong edge.
    struct Anchor {
        var fixedMinX: Bool
        var fixedMinY: Bool

        /// Inferred from where the pointer went down: grab the right-hand side
        /// and the left edge is what stays put.
        static func from(mouse: CGPoint, in frame: CGRect) -> Anchor {
            Anchor(fixedMinX: mouse.x > frame.midX, fixedMinY: mouse.y > frame.midY)
        }
    }

    /// The size to use instead of `proposed`.
    ///
    /// Two kinds of snap are considered together and the nearest wins, so a note
    /// being dragged past a neighbour's edge does not jump to matching its width
    /// when the edge was what you were aiming at:
    ///
    /// - **matching size** — the neighbour's own width or height, which is what
    ///   makes a column of notes read as a column;
    /// - **aligned edge** — the moving edge landing on a neighbour's edge.
    ///
    /// `minimum` is respected: a snap that would make the note smaller than it
    /// is allowed to be is not a snap, it is a bug that eats the note's content.
    static func resize(from current: CGRect, to proposed: CGSize,
                       anchor: Anchor, others: [CGRect],
                       minimum: CGSize = .zero,
                       within threshold: CGFloat = threshold) -> CGSize {
        CGSize(
            width: snap(proposed.width,
                        movingEdge: anchor.fixedMinX ? current.minX + proposed.width
                                                     : current.maxX - proposed.width,
                        toEdges: others.flatMap { [$0.minX, $0.maxX] },
                        matching: others.map(\.width),
                        fixedEdge: anchor.fixedMinX ? current.minX : current.maxX,
                        growsWithEdge: anchor.fixedMinX,
                        minimum: minimum.width, within: threshold),
            height: snap(proposed.height,
                         movingEdge: anchor.fixedMinY ? current.minY + proposed.height
                                                      : current.maxY - proposed.height,
                         toEdges: others.flatMap { [$0.minY, $0.maxY] },
                         matching: others.map(\.height),
                         fixedEdge: anchor.fixedMinY ? current.minY : current.maxY,
                         growsWithEdge: anchor.fixedMinY,
                         minimum: minimum.height, within: threshold))
    }

    /// One axis of the above. Kept separate because width and height are the
    /// same problem twice and the sign conventions are easy to get backwards.
    private static func snap(_ proposed: CGFloat, movingEdge: CGFloat,
                             toEdges edges: [CGFloat], matching sizes: [CGFloat],
                             fixedEdge: CGFloat, growsWithEdge: Bool,
                             minimum: CGFloat, within threshold: CGFloat) -> CGFloat {
        // Every candidate expressed as a size, with how far it is from what was
        // asked for, so the nearest can win regardless of which kind it is.
        var best: (size: CGFloat, distance: CGFloat)?
        func offer(_ size: CGFloat) {
            guard size >= minimum else { return }
            let distance = abs(size - proposed)
            guard distance <= threshold else { return }
            if best == nil || distance < best!.distance { best = (size, distance) }
        }
        for size in sizes { offer(size) }
        for edge in edges {
            offer(growsWithEdge ? edge - fixedEdge : fixedEdge - edge)
        }
        return best?.size ?? proposed
    }
}
