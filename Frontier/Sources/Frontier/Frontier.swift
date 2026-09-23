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
        func rank(_ a: Concept, _ b: Concept) -> Bool {
            let l = score(a, unlocks: scores[a.id] ?? 0, now: now)
            let r = score(b, unlocks: scores[b.id] ?? 0, now: now)
            return l == r ? a.title < b.title : l > r
        }
        // Two bands, not one score with a penalty folded in. A concept waiting
        // for its next revisit has to sort below *everything* else, and with
        // 275 concepts the unlocks term alone reaches into the hundreds — any
        // constant penalty big enough today is a guess that breaks as the graph
        // grows. Partitioning says exactly what is meant. Deferred concepts stay
        // in the list rather than disappearing from it: the sidebar is also how
        // you find something again on a day you feel like it.
        let (deferred, running) = eligible.partitioned { $0.isDeferred(at: now) }
        return running.sorted(by: rank) + deferred.sorted(by: rank)
    }

    /// The gap before a concept comes back, given how its test went.
    ///
    /// There *is* something to fit against now. The old ladder — 1, 3, 7, 16,
    /// 35 days by how many times you had pressed a button — expanded whether or
    /// not you were learning anything, because pressing "still learning" is not
    /// evidence about what you know. A score is. So the interval multiplies
    /// when you do well and collapses when you do not:
    ///
    /// - **≥ 0.9** — you know it. Multiply hard; the gap is where the value is.
    /// - **0.75–0.9** — solid with gaps. Grow, but less.
    /// - **0.5–0.75** — shaky. Ask again after the same gap, not a longer one.
    /// - **< 0.5** — you do not have it. Back to tomorrow, whatever the history.
    ///
    /// A first pass has no interval to multiply, so it starts from one day.
    /// Capped at sixty: past two months a concept you have not retained wants a
    /// different entry, not a longer wait. A very good score never marks a
    /// concept known — one good morning is not the same as being finished, and
    /// that is the user's call to make.
    static let maximumIntervalDays = 60

    static func nextInterval(afterScore score: Double, previous: Int) -> Int {
        let base = max(previous, 1)
        let next: Double
        switch score {
        case 0.9...:      next = Double(base) * 2.6
        case 0.75..<0.9:  next = Double(base) * 1.7
        case 0.5..<0.75:  next = Double(base)
        default:          return 1
        }
        return min(maximumIntervalDays, max(1, Int(next.rounded())))
    }

    /// When a concept should next come up, and the interval that produced it.
    static func nextDue(for c: Concept, score: Double, now: Date = Date())
        -> (due: Date, interval: Int) {
        let interval = nextInterval(afterScore: score, previous: c.intervalDays)
        return (now.addingTimeInterval(Double(interval) * 86_400), interval)
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
        // Something started and now due outranks something untouched, so
        // sessions finish what they begin. Something started and *not* due has
        // already been sorted out of the running by `ready`; the bonus would be
        // meaningless there, so it is not applied.
        if c.status == .learning, !c.isDeferred(at: now) { total += 12 }
        if let dated = c.dated {
            let days = now.timeIntervalSince(dated) / 86_400
            // Full weight for a fortnight, then fading over the next two months.
            total += days < 14 ? 20 : max(0, 20 - (days - 14) / 3)
        }
        // A concept nobody depends on and nothing dates is still worth doing;
        // it just waits its turn.
        return total
    }

    /// A prerequisite id that nothing defines, matched to the concept it plainly
    /// meant.
    ///
    /// Most "missing prerequisites" are not missing. The model writes
    /// `requires:` by inventing an id from a title, so a concept filed as
    /// `gpu-execution-model` is referred to as
    /// `gpu-execution-model-sms-warps-occupancy`, and `arithmetic-intensity-and-
    /// roofline` as `arithmetic-intensity-roofline`. Measured on this graph: of
    /// 10 loose ends, none were concepts the curriculum lacked — they were edges
    /// pointing a few words wide of concepts it already had. That matters beyond
    /// tidiness, because `ready` deliberately treats an unknown prerequisite as
    /// non-blocking: a mistyped edge is not a broken link, it is a *silently
    /// deleted* one, and the concept it guarded becomes ready before it should.
    ///
    /// Deliberately timid. It links only when one id's words contain the
    /// other's, or when three-quarters of the shorter one is shared, and only
    /// when exactly one concept fits — two candidates means no link. A missing
    /// edge is visible in `--status`; a wrong edge teaches the wrong order.
    static func resolve(_ wanted: String, among ids: [String]) -> String? {
        if ids.contains(wanted) { return wanted }
        let want = words(wanted)
        guard want.count >= 2 else { return nil }
        let fits = ids.filter { id in
            let have = words(id)
            let shared = want.intersection(have).count
            guard shared >= 2 else { return false }
            if want.isSubset(of: have) || have.isSubset(of: want) { return true }
            return shared >= 3
                && Double(shared) >= 0.75 * Double(min(want.count, have.count))
        }
        return fits.count == 1 ? fits[0] : nil
    }

    /// An id as a set of meaningful words. The joining words are dropped so
    /// `arithmetic-intensity-and-roofline` and `arithmetic-intensity-roofline`
    /// are the same three words rather than a near miss.
    private static let joiners: Set<String> = ["and", "or", "the", "a", "an",
                                               "of", "in", "for", "to", "with"]

    private static func words(_ id: String) -> Set<String> {
        Set(id.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !joiners.contains($0) })
    }

    /// Every concept with its prerequisites pointed at concepts that exist, and
    /// a list of what was re-pointed so the repair can be read before it is run.
    static func relinked(_ concepts: [Concept])
        -> (concepts: [Concept], repairs: [(concept: String, from: String, to: String)]) {
        let ids = concepts.map(\.id)
        let present = Set(ids)
        var out: [Concept] = []
        var repairs: [(concept: String, from: String, to: String)] = []
        for var c in concepts {
            c.requires = c.requires.map { req in
                guard !present.contains(req),
                      let fixed = resolve(req, among: ids), fixed != c.id else { return req }
                repairs.append((c.id, req, fixed))
                return fixed
            }
            // A repair can point two prerequisites at the same concept.
            var seen: Set<String> = []
            c.requires = c.requires.filter { seen.insert($0).inserted }
            out.append(c)
        }
        return (out, repairs)
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
    /// How many carried-over concepts a single session may contain.
    ///
    /// One. A morning made of three things you already failed to learn is not a
    /// session, it is the same session again — and three at once is how a
    /// backlog becomes a reason to stop opening the app.
    static let carryOverPerSession = 1

    static func session(_ concepts: [Concept], size: Int = 3, now: Date = Date()) -> [Concept] {
        var out: [Concept] = []
        var used: Set<Concept.Area> = []
        var carried = 0

        // Deferred concepts are at the tail of `ready` so they stay findable;
        // a session is a recommendation, so they are simply not in it.
        let queue = ready(concepts, now: now).filter { !$0.isDeferred(at: now) }

        func take(_ c: Concept) -> Bool {
            if c.status == .learning {
                guard carried < carryOverPerSession else { return false }
                carried += 1
            }
            out.append(c)
            return true
        }

        for c in queue where !used.contains(c.area) {
            if take(c) {
                used.insert(c.area)
                if out.count == size { return out }
            }
        }
        // Fewer areas than slots: fill the rest in frontier order.
        for c in queue where !out.contains(where: { $0.id == c.id }) {
            if take(c), out.count == size { break }
        }
        return out
    }
}

extension Concept {
    /// Marked "still learning" and not yet back round.
    ///
    /// A concept marked before scheduling existed has no date and is treated as
    /// due — which is exactly what it was, every single morning.
    func isDeferred(at now: Date) -> Bool {
        guard status == .learning, let dueOn else { return false }
        return dueOn > now
    }

    /// Plain-language "when does this come back", for the one place the schedule
    /// is visible. A scheduler you cannot see is indistinguishable from a
    /// concept that quietly vanished.
    func revisitDescription(at now: Date = Date()) -> String? {
        guard status == .learning, let dueOn else { return nil }
        let days = Int((dueOn.timeIntervalSince(now) / 86_400).rounded(.up))
        if days <= 0 { return "due now" }
        if days == 1 { return "back tomorrow" }
        return "back in \(days) days"
    }
}

extension Array {
    /// (matching, rest) — one pass, and it reads as what it is at the call site.
    func partitioned(by belongs: (Element) -> Bool) -> ([Element], [Element]) {
        var yes: [Element] = [], no: [Element] = []
        for e in self { if belongs(e) { yes.append(e) } else { no.append(e) } }
        return (yes, no)
    }
}
