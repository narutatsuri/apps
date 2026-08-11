// Copied verbatim from Paper Notes. The force simulation knows nothing
// about papers or concepts — it is ids, edges and masses — so both apps
// use it unchanged. Copied rather than shared because each app has to
// build standalone from a clone; a fix here should be applied there too.

import Foundation
import CoreGraphics
import Observation

/// A live force simulation — the graph keeps moving rather than being solved once.
///
/// Bodies carry velocity and mass, so they have momentum: flick one and it drifts and
/// settles, and a heavily-cited paper (a bigger, heavier node) is shoved around less
/// by its neighbours than a small one. `ForceLayout` still computes the opening
/// arrangement, because starting from a settled state avoids the scramble you would
/// otherwise watch every time the window opens.
@MainActor
@Observable
final class GraphSim {
    struct Body {
        var position: CGPoint
        var velocity: CGPoint = .zero
        /// Heavier nodes resist being pushed. Derived from citation count, so the
        /// papers that anchor a field also anchor the picture.
        var mass: Double = 1
    }

    private(set) var bodies: [String: Body] = [:]
    private var edges: [(String, String, Double)] = []

    /// d3-style cooling: high alpha means large steps. Interaction reheats it, so the
    /// graph responds to a drag and then settles instead of jittering forever.
    private(set) var alpha: Double = 1.0
    private let alphaDecay = 0.015
    private let alphaMin = 0.0025
    private let damping = 0.72

    var dragging: String?
    /// Where the dragged node is being held, in graph coordinates.
    var dragTarget: CGPoint = .zero
    /// Beyond this radius from the centre a strong restoring force takes over, so a
    /// hard drag cannot fling the graph off into space. A soft boundary rather than a
    /// clamp — clamping is what made an earlier version stick flat against the walls.
    private var boundsRadius: Double = 400

    var isSettled: Bool { alpha <= alphaMin && dragging == nil }

    func load(ids: [String], edges: [(String, String, Double)],
              masses: [String: Double], size: CGSize) {
        let seeded = ForceLayout.layout(ids: ids, edges: edges, size: size)
        self.edges = edges
        boundsRadius = Double(min(size.width, size.height)) * 0.62
        var next: [String: Body] = [:]
        for id in ids {
            let p = seeded[id]?.position ?? CGPoint(x: size.width / 2, y: size.height / 2)
            // Keep momentum across a reload so resizing doesn't teleport everything.
            next[id] = Body(position: bodies[id]?.position ?? p,
                            velocity: bodies[id]?.velocity ?? .zero,
                            mass: max(1, masses[id] ?? 1))
        }
        bodies = next
        reheat(0.9)
    }

    func reheat(_ to: Double = 0.55) {
        alpha = max(alpha, to)
    }

    func nudge(_ id: String, by delta: CGPoint) {
        guard var b = bodies[id] else { return }
        b.velocity.x += delta.x
        b.velocity.y += delta.y
        bodies[id] = b
        reheat()
    }

    /// One integration step. Fixed timestep — a variable one makes the springs
    /// explode whenever a frame is late.
    func step(centre: CGPoint) {
        guard !bodies.isEmpty else { return }
        if alpha > alphaMin {
            alpha -= (alpha - alphaMin) * alphaDecay
            // Snap once it is close enough. Exponential decay approaches the floor
            // asymptotically and never reaches it, so without this `isSettled` is
            // never true and the 60 Hz ticker runs forever on a motionless graph.
            if alpha - alphaMin < 1e-4 { alpha = alphaMin }
        }

        let ids = Array(bodies.keys)
        let k = 105.0
        var force: [String: CGPoint] = [:]

        for a in ids {
            guard let ba = bodies[a] else { continue }
            var fx = 0.0, fy = 0.0
            for b in ids where a != b {
                guard let bb = bodies[b] else { continue }
                var vx = Double(ba.position.x - bb.position.x)
                var vy = Double(ba.position.y - bb.position.y)
                var d2 = vx * vx + vy * vy
                if d2 < 0.5 {
                    // Deterministic nudge rather than a random one, so a reload
                    // reproduces the same picture.
                    vx = Double(a.hashValue % 17) - 8
                    vy = Double(a.hashValue % 13) - 6
                    d2 = max(0.5, vx * vx + vy * vy)
                }
                let d = sqrt(d2)
                // Repulsion scaled by the other body's mass: big papers push harder.
                let rep = (k * k) * bb.mass / d2
                fx += (vx / d) * rep
                fy += (vy / d) * rep
            }
            // Gentle pull to centre keeps unconnected papers from wandering off.
            fx += Double(centre.x - ba.position.x) * 0.9
            fy += Double(centre.y - ba.position.y) * 0.9

            force[a] = CGPoint(x: fx, y: fy)
        }

        for (a, b, weight) in edges {
            guard let ba = bodies[a], let bb = bodies[b] else { continue }
            let vx = Double(ba.position.x - bb.position.x)
            let vy = Double(ba.position.y - bb.position.y)
            let d = max(1, sqrt(vx * vx + vy * vy))

            // Distance carries meaning: the rest length shortens as the relation
            // strengthens, so a direct citation sits close and a weak topical
            // resemblance sits far. Previously every spring had the same rest length
            // and only the stiffness varied, which left distance saying nothing.
            let rest = k * (1.65 - min(1, weight))
            // Clamped so a node dragged across the canvas cannot apply unbounded
            // force to its neighbours.
            let stretch = min(900, max(-900, (d - rest))) * (0.5 + weight * 0.6)
            let fx = (vx / d) * stretch, fy = (vy / d) * stretch
            force[a] = CGPoint(x: (force[a]?.x ?? 0) - fx, y: (force[a]?.y ?? 0) - fy)
            force[b] = CGPoint(x: (force[b]?.x ?? 0) + fx, y: (force[b]?.y ?? 0) + fy)
        }

        for id in ids {
            guard var body = bodies[id] else { continue }
            if id == dragging {
                // A held node follows the cursor exactly, and its velocity records
                // the motion so releasing it throws the node.
                let dx = dragTarget.x - body.position.x
                let dy = dragTarget.y - body.position.y
                // Capped: a quick flick would otherwise hand the node a huge velocity
                // that it keeps on release, launching it and dragging its neighbours
                // along behind it.
                var vx = dx * 0.5, vy = dy * 0.5
                let speed = hypot(vx, vy)
                if speed > 14 { vx *= 14 / speed; vy *= 14 / speed }
                body.velocity = CGPoint(x: vx, y: vy)
                body.position = dragTarget
                bodies[id] = body
                continue
            }
            let f = force[id] ?? .zero
            let scale = alpha / body.mass
            body.velocity.x = (body.velocity.x + CGFloat(Double(f.x) * scale * 0.0016)) * CGFloat(damping)
            body.velocity.y = (body.velocity.y + CGFloat(Double(f.y) * scale * 0.0016)) * CGFloat(damping)
            // Clamp so a stiff spring can never fling a node off the canvas.
            let speed = hypot(body.velocity.x, body.velocity.y)
            if speed > 26 {
                body.velocity.x *= 26 / speed
                body.velocity.y *= 26 / speed
            }
            body.position.x += body.velocity.x
            body.position.y += body.velocity.y

            // Containment, applied to position and deliberately *not* scaled by
            // alpha. As a force it was useless: alpha decays to 0.0025 after a drag,
            // which left the restoring pull at ~0.07 pt/frame — far too weak to bring
            // anything back, so a hard drag parked the graph 1664pt off a 600pt
            // canvas and left it there. A positional correction always works.
            let ox = Double(body.position.x - centre.x), oy = Double(body.position.y - centre.y)
            let dist = sqrt(ox * ox + oy * oy)
            if dist > boundsRadius {
                let excess = dist - boundsRadius
                let correction = excess * 0.08
                body.position.x -= CGFloat((ox / dist) * correction)
                body.position.y -= CGFloat((oy / dist) * correction)
                // Kill the outward component so it stops pushing against the edge.
                let outward = (Double(body.velocity.x) * ox + Double(body.velocity.y) * oy) / dist
                if outward > 0 {
                    body.velocity.x -= CGFloat((ox / dist) * outward)
                    body.velocity.y -= CGFloat((oy / dist) * outward)
                }
            }

            guard body.position.x.isFinite, body.position.y.isFinite else { continue }
            bodies[id] = body
        }
    }

    func position(_ id: String) -> CGPoint? { bodies[id]?.position }
}
