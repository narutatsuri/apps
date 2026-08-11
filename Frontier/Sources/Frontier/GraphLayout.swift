import Foundation
import CoreGraphics

/// Fruchterman–Reingold with gravity, then normalised to fit the canvas.
///
/// Deterministic: initial positions come from a hash of the paper id, not a random
/// generator, so the same library always lays out the same way. A graph that
/// rearranges itself every time you open it is one you can never learn.
///
/// The earlier version clamped positions to the canvas during the simulation. With a
/// small library `k = sqrt(area/n)` is larger than the canvas itself, so every node
/// pushed outward, hit the clamp and stuck there — the whole graph pressed flat
/// against the walls with nothing in the middle. The simulation now runs unbounded
/// and the result is scaled to fit afterwards, which is what makes the spacing
/// independent of how many papers there are.
enum ForceLayout {
    struct Node {
        let id: String
        var position: CGPoint
        var degree: Int = 0
    }

    private static func hashUnit(_ s: String, salt: UInt64) -> Double {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325 ^ salt
        for byte in s.utf8 { h = (h ^ UInt64(byte)) &* 0x1000_0000_01b3 }
        return Double(h % 10_000) / 10_000.0
    }

    static func layout(ids: [String],
                       edges: [(String, String, Double)],
                       size: CGSize,
                       iterations: Int = 400) -> [String: Node] {
        guard !ids.isEmpty else { return [:] }
        guard ids.count > 1 else {
            return [ids[0]: Node(id: ids[0],
                                 position: CGPoint(x: size.width / 2, y: size.height / 2))]
        }

        // Simulation happens in an abstract unit space; the canvas only matters at
        // the end, when the result is scaled into it.
        var pos: [String: CGPoint] = [:]
        var degree: [String: Int] = [:]
        let ring = 100.0
        for (i, id) in ids.enumerated() {
            let angle = (Double(i) / Double(ids.count)) * 2 * .pi
            let jitter = 0.75 + hashUnit(id, salt: 11) * 0.5
            pos[id] = CGPoint(x: cos(angle) * ring * jitter, y: sin(angle) * ring * jitter)
        }
        for (a, b, _) in edges {
            degree[a, default: 0] += 1
            degree[b, default: 0] += 1
        }

        let k = 90.0                       // ideal edge length in unit space
        var temperature = 60.0

        for _ in 0..<iterations {
            var disp: [String: CGPoint] = [:]

            for a in ids {
                guard let pa = pos[a] else { continue }
                var dx = 0.0, dy = 0.0
                for b in ids where a != b {
                    guard let pb = pos[b] else { continue }
                    var vx = Double(pa.x - pb.x), vy = Double(pa.y - pb.y)
                    var dist = sqrt(vx * vx + vy * vy)
                    if dist < 0.01 {
                        vx = hashUnit(a, salt: 3) - 0.5
                        vy = hashUnit(a, salt: 5) - 0.5
                        dist = 0.01
                    }
                    let force = (k * k) / dist
                    dx += (vx / dist) * force
                    dy += (vy / dist) * force
                }
                // Gravity, so disconnected papers drift back instead of escaping.
                // Without it an unconnected node feels only repulsion and leaves.
                dx -= Double(pa.x) * 0.75
                dy -= Double(pa.y) * 0.75
                disp[a] = CGPoint(x: dx, y: dy)
            }

            for (a, b, weight) in edges {
                guard let pa = pos[a], let pb = pos[b] else { continue }
                let vx = Double(pa.x - pb.x), vy = Double(pa.y - pb.y)
                let dist = max(0.01, sqrt(vx * vx + vy * vy))
                let force = (dist * dist) / k * (0.5 + weight)
                let fx = (vx / dist) * force, fy = (vy / dist) * force
                disp[a] = CGPoint(x: (disp[a]?.x ?? 0) - fx, y: (disp[a]?.y ?? 0) - fy)
                disp[b] = CGPoint(x: (disp[b]?.x ?? 0) + fx, y: (disp[b]?.y ?? 0) + fy)
            }

            for id in ids {
                guard let p = pos[id], let d = disp[id] else { continue }
                let mag = max(0.0001, sqrt(Double(d.x * d.x + d.y * d.y)))
                let step = min(mag, temperature)
                let nx = Double(p.x) + (Double(d.x) / mag) * step
                let ny = Double(p.y) + (Double(d.y) / mag) * step
                guard nx.isFinite, ny.isFinite else { continue }
                pos[id] = CGPoint(x: nx, y: ny)
            }
            temperature = max(0.05, temperature * 0.985)
        }

        return fit(pos, degree: degree, into: size)
    }

    /// Scales the settled layout into the canvas, preserving aspect so clusters keep
    /// their shape. Padding leaves room for the labels drawn beneath each node.
    private static func fit(_ pos: [String: CGPoint],
                            degree: [String: Int],
                            into size: CGSize) -> [String: Node] {
        let xs = pos.values.map { Double($0.x) }, ys = pos.values.map { Double($0.y) }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return [:] }

        let padX = 70.0, padY = 54.0
        let availableW = max(1, Double(size.width) - padX * 2)
        let availableH = max(1, Double(size.height) - padY * 2)
        let spanX = max(1e-6, maxX - minX), spanY = max(1e-6, maxY - minY)
        let scale = min(availableW / spanX, availableH / spanY)

        // Centre whatever the scale leaves over, so the graph sits in the middle
        // rather than hugging one edge.
        let usedW = spanX * scale, usedH = spanY * scale
        let offsetX = padX + (availableW - usedW) / 2
        let offsetY = padY + (availableH - usedH) / 2

        var out: [String: Node] = [:]
        for (id, p) in pos {
            let x = (Double(p.x) - minX) * scale + offsetX
            let y = (Double(p.y) - minY) * scale + offsetY
            out[id] = Node(id: id, position: CGPoint(x: x, y: y), degree: degree[id] ?? 0)
        }
        return out
    }
}
