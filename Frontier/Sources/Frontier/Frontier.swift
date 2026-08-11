import Foundation

/// What you are ready to learn next.
///
/// The whole app turns on this. A glossary tells you what a word means; a
/// curriculum tells you which word to look up today, and that is a function of
/// what you already know. A concept is *ready* when everything it rests on is
/// known — so the order emerges from the graph instead of from someone's idea
/// of a syllabus, and it re-plans itself every time you learn something.
enum Frontier {
    /// Concepts whose prerequisites are all known, and which you have not
    /// finished. In order: what to open this morning.
    static func ready(_ concepts: [Concept], now: Date = Date()) -> [Concept] {
        let known = Set(concepts.filter(\.isKnown).map(\.id))
        let present = Set(concepts.map(\.id))

        let eligible = concepts.filter { c in
            guard !c.isKnown else { return false }
            // A prerequisite that is not in the library at all cannot block
            // anything — otherwise a typo in one file silently freezes a whole
            // branch of the graph, and nothing on screen says why.
            return c.requires.allSatisfy { known.contains($0) || !present.contains($0) }
        }
        let scores = unlocks(concepts)
        return eligible.sorted {
            let l = score($0, unlocks: scores[$0.id] ?? 0, now: now)
            let r = score($1, unlocks: scores[$1.id] ?? 0, now: now)
            return l == r ? $0.title < $1.title : l > r
        }
    }

    /// How many concepts each one unblocks, counting the whole downstream cone
    /// rather than only direct dependants.
    ///
    /// This is what makes the ordering feel deliberate: a bottleneck everything
    /// rests on outranks a leaf, so the foundations get taught first without
    /// anyone hand-ordering them.
    static func unlocks(_ concepts: [Concept]) -> [String: Int] {
        var dependants: [String: [String]] = [:]
        for c in concepts {
            for r in c.requires { dependants[r, default: []].append(c.id) }
        }
        var out: [String: Int] = [:]
        for c in concepts {
            var seen: Set<String> = []
            var stack = dependants[c.id] ?? []
            while let next = stack.popLast() {
                // A cycle in the graph is a mistake, not a reason to hang.
                guard seen.insert(next).inserted else { continue }
                stack.append(contentsOf: dependants[next] ?? [])
            }
            out[c.id] = seen.count
        }
        return out
    }

    /// Higher is sooner.
    ///
    /// Three pulls, deliberately weighted. What unlocks the most comes first,
    /// because learning a bottleneck is worth more than learning a leaf.
    /// Something already started outranks something untouched, so sessions
    /// finish what they begin. And anything dated is news, which is worth
    /// knowing while it is still news and worth little once it is not.
    static func score(_ c: Concept, unlocks: Int, now: Date) -> Double {
        var total = Double(unlocks) * 2.0
        if c.status == .learning { total += 12 }
        if let dated = c.dated {
            let days = now.timeIntervalSince(dated) / 86_400
            // Full weight for a fortnight, then fading over the next two months.
            total += days < 14 ? 20 : max(0, 20 - (days - 14) / 3)
        }
        // A concept nobody depends on and nothing dates is still worth doing;
        // it just waits its turn.
        return total
    }

    /// Prerequisites that no file defines. These are the graph's loose ends —
    /// worth surfacing, since each one is a concept the curriculum wants and
    /// does not have.
    static func missing(_ concepts: [Concept]) -> [String] {
        let present = Set(concepts.map(\.id))
        var out: Set<String> = []
        for c in concepts {
            for r in c.requires where !present.contains(r) { out.insert(r) }
        }
        return out.sorted()
    }

    /// Cycles, which are always an authoring mistake: A cannot require B if B
    /// requires A. Returned rather than tolerated, because a cycle makes both
    /// concepts permanently unreachable and the app would simply never suggest
    /// them.
    static func cycles(_ concepts: [Concept]) -> [[String]] {
        let byID = Dictionary(uniqueKeysWithValues: concepts.map { ($0.id, $0) })
        var colour: [String: Int] = [:]           // 0 unvisited, 1 on stack, 2 done
        var found: [[String]] = []
        var path: [String] = []

        func walk(_ id: String) {
            colour[id] = 1
            path.append(id)
            for next in byID[id]?.requires ?? [] {
                guard byID[next] != nil else { continue }
                if colour[next] == 1, let start = path.firstIndex(of: next) {
                    found.append(Array(path[start...]))
                } else if colour[next] != 2 {
                    walk(next)
                }
            }
            path.removeLast()
            colour[id] = 2
        }
        for c in concepts where colour[c.id] != 2 { walk(c.id) }
        return found
    }

    /// A day's session: the top of the frontier, spread across areas.
    ///
    /// Spread on purpose — three concepts from the same corner of the graph is
    /// a lecture, and this is meant to be fifteen minutes that leaves you
    /// better placed in more than one direction.
    static func session(_ concepts: [Concept], size: Int = 3, now: Date = Date()) -> [Concept] {
        var out: [Concept] = []
        var used: Set<Concept.Area> = []
        let queue = ready(concepts, now: now)
        for c in queue where !used.contains(c.area) {
            out.append(c)
            used.insert(c.area)
            if out.count == size { return out }
        }
        // Fewer areas than slots: fill the rest in frontier order.
        for c in queue where !out.contains(where: { $0.id == c.id }) {
            out.append(c)
            if out.count == size { break }
        }
        return out
    }
}
