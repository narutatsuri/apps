import CoreGraphics

/// The pan/drag state machine, kept out of the SwiftUI gesture so it can be tested.
///
/// The bug this exists to prevent: the gesture recorded the pan origin on *every*
/// change rather than once at the start. Because `DragGesture.translation` is
/// cumulative from where the drag began, re-baselining each frame made the pan grow
/// quadratically — the graph accelerated away off-screen. The simulation was innocent;
/// every physics test passed while this was broken.
struct ViewportGesture {
    enum Mode: Equatable {
        case idle
        case panning
        case moving(String)          // dragging a specific node
    }

    private(set) var mode: Mode = .idle
    /// Pan at the moment the gesture began — captured exactly once.
    private(set) var origin: CGSize = .zero

    /// Call on every change. `hit` is only consulted on the first call.
    mutating func began(hit: String?, currentPan: CGSize) {
        guard mode == .idle else { return }      // the guard that was missing
        origin = currentPan
        mode = hit.map { Mode.moving($0) } ?? .panning
    }

    /// Resulting pan for a cumulative translation. Anchored to `origin`, so repeated
    /// calls with the same translation are idempotent.
    func pan(for translation: CGSize) -> CGSize {
        CGSize(width: origin.width + translation.width,
               height: origin.height + translation.height)
    }

    var draggedNode: String? {
        if case .moving(let id) = mode { return id }
        return nil
    }

    var isPanning: Bool { mode == .panning }

    mutating func ended() {
        mode = .idle
    }
}
