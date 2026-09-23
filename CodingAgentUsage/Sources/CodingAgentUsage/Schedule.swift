import Foundation

/// When to ask the usage endpoints anything.
///
/// Split out from `UsageStore` and kept free of state so it can be checked
/// without a network or a menu bar. Every number here is a rate-limit decision,
/// and a rate-limit decision that is wrong is invisible until the server starts
/// refusing — at which point the app tells you it is backing off and you have no
/// way to know whether that was the server's fault or its own.
///
/// The governing fact: these are *utilization percentages*. They move over
/// hours. Nothing here is worth a request per minute.
enum Schedule {
    /// Routine cadence, per provider.
    ///
    /// Was 300s. Two providers on a five-minute cycle is 24 requests an hour
    /// before anyone opens the panel, and the panel used to add one of its own
    /// nearly every time it was opened. Fifteen minutes is 8 an hour, which
    /// leaves the budget for the refresh button — the one request the user
    /// actually asked for.
    static let routine: TimeInterval = 900

    /// Routine checks are spread rather than exact.
    ///
    /// Without this both providers fall into step and every cycle is a burst of
    /// two. A fifth either way is enough to keep them apart, and nothing here
    /// needs to happen at a precise moment.
    static let jitterFraction = 0.2

    /// Opening the panel only fetches if the numbers are older than this.
    ///
    /// Was 60s, which meant that looking at a usage meter — the thing you do
    /// often, and the whole point of it being in the menu bar — was itself the
    /// main source of traffic. Ten minutes shows you what was last measured and
    /// says how old it is; the refresh button is there when that is not enough.
    static let openFreshness: TimeInterval = 600

    /// The shortest gap between two manual refreshes.
    static let manualCooldown: TimeInterval = 10

    static let minBackoff: TimeInterval = 60
    static let maxBackoff: TimeInterval = 1800

    /// When to next check a provider that just answered.
    static func nextRoutine(after now: Date,
                            jitter: Double = .random(in: -1 ... 1)) -> Date {
        let spread = routine * jitterFraction * max(-1, min(1, jitter))
        return now.addingTimeInterval(routine + spread)
    }

    /// How long to wait after a failure.
    ///
    /// Doubling from a minute, capped at half an hour. The server's own
    /// `Retry-After` wins when it is usable — this endpoint answers 429 with
    /// `retry-after: 0`, which is not, so most of the time this is all there is.
    static func backoff(failures: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter, retryAfter > 0 {
            return min(max(retryAfter, minBackoff), maxBackoff)
        }
        let doubled = minBackoff * pow(2, Double(max(0, failures - 1)))
        return min(max(doubled, minBackoff), maxBackoff)
    }

    /// Whether opening the panel should cost a request.
    ///
    /// Never while a provider is backing off: jumping our own backoff because a
    /// window appeared is what turned one 429 into a run of them.
    static func shouldRefreshOnOpen(fetchedAt: Date?, failures: Int, now: Date) -> Bool {
        guard failures == 0 else { return false }
        guard let fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) > openFreshness
    }

    /// Seconds left before the refresh button will do anything, or zero.
    ///
    /// Returned rather than swallowed. A button that silently does nothing is
    /// indistinguishable from a broken one, and that is exactly how it read.
    static func manualCooldownRemaining(lastManual: Date, now: Date) -> TimeInterval {
        max(0, manualCooldown - now.timeIntervalSince(lastManual))
    }
}
