import SwiftUI
import Observation

@MainActor
@Observable
final class UsageStore {
    static let shared = UsageStore()

    var claude = ProviderSnapshot()
    var codex = ProviderSnapshot()
    var isRefreshing = false
    /// Bumped on a slow timer purely so relative "resets in" labels stay honest.
    var tick = 0

    var launchAtLogin = LoginItem.isEnabled
    var loginError: String?

    /// Background cadence. The original 60s was enough to get rate-limited on its
    /// own, and utilization percentages don't move nearly fast enough to justify it.
    static let baseInterval: TimeInterval = 300
    /// Opening the panel refreshes only if the data is older than this.
    static let openFreshness: TimeInterval = 60
    static let maxBackoff: TimeInterval = 1800
    private static let manualCooldown: TimeInterval = 15

    private var pollTask: Task<Void, Never>?
    private var lastManual = Date.distantPast
    // Scheduled independently: Claude being rate-limited must not stall Codex.
    private var claudeNext = Date.distantPast
    private var codexNext = Date.distantPast
    private var claudeFailures = 0
    private var codexFailures = 0

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollDue()
                try? await Task.sleep(for: .seconds(15))
                self?.tick += 1
            }
        }
    }

    /// Panel opened: bypass the background cadence for anything stale, but never
    /// jump an active backoff — that is what got us rate-limited to begin with.
    func refreshOnOpen() async {
        let now = Date()
        if claudeFailures == 0, claude.fetchedAt.map({ now.timeIntervalSince($0) > Self.openFreshness }) ?? true {
            claudeNext = .distantPast
        }
        if codexFailures == 0, codex.fetchedAt.map({ now.timeIntervalSince($0) > Self.openFreshness }) ?? true {
            codexNext = .distantPast
        }
        await pollDue()
    }

    /// Explicit user request. Overrides backoff, but rate-limited so a frustrated
    /// click-storm can't dig the hole deeper.
    func manualRefresh() async {
        guard Date().timeIntervalSince(lastManual) > Self.manualCooldown else { return }
        lastManual = Date()
        claudeNext = .distantPast
        codexNext = .distantPast
        await pollDue()
    }

    private func pollDue() async {
        let now = Date()
        let wantClaude = now >= claudeNext
        let wantCodex = now >= codexNext
        guard wantClaude || wantCodex else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        if wantClaude && wantCodex {
            async let c = ClaudeClient.fetch()
            async let x = CodexClient.fetch()
            let (cs, xs) = await (c, x)
            apply(cs, to: &claude, failures: &claudeFailures, next: &claudeNext)
            apply(xs, to: &codex, failures: &codexFailures, next: &codexNext)
        } else if wantClaude {
            apply(await ClaudeClient.fetch(), to: &claude, failures: &claudeFailures, next: &claudeNext)
        } else {
            apply(await CodexClient.fetch(), to: &codex, failures: &codexFailures, next: &codexNext)
        }
    }

    private func apply(_ fresh: ProviderSnapshot, to current: inout ProviderSnapshot,
                       failures: inout Int, next: inout Date) {
        if fresh.error == nil {
            current = fresh
            failures = 0
            next = Date().addingTimeInterval(Self.baseInterval)
            return
        }

        failures += 1
        if current.meters.isEmpty {
            current = fresh          // never had good data — the error is all we can show
        } else {
            // Keep the last good numbers on screen. A transient 429 blanking the whole
            // panel is worse than showing values that are a few minutes old.
            current.error = fresh.error
            current.isStale = true
        }
        let backoff = fresh.retryAfter ?? min(60 * pow(2, Double(failures)), Self.maxBackoff)
        next = Date().addingTimeInterval(min(max(backoff, 30), Self.maxBackoff))
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            try LoginItem.set(on)
            loginError = nil
        } catch {
            loginError = LoginItem.isBlockedByUser
                ? "Allow it in System Settings › General › Login Items."
                : error.localizedDescription
        }
        // Trust the service's own status, not the requested value — the user can have
        // it disabled at the system level.
        launchAtLogin = LoginItem.isEnabled
    }

    /// Compact status-bar text. Each provider contributes the window nearest its
    /// ceiling; stale numbers still beat a dash.
    var menuBarLabel: String {
        func part(_ tag: String, _ snap: ProviderSnapshot) -> String {
            guard let h = snap.headline else { return "\(tag) –" }
            return "\(tag) \(Int(h.percent.rounded()))%"
        }
        return "\(part("C", claude))  \(part("X", codex))"
    }

    var worstSeverity: Severity {
        let all = claude.meters + codex.meters
        let peak = all.map(\.percent).max() ?? 0
        return Severity(percent: peak)
    }
}
