import SwiftUI
import Observation

@MainActor
@Observable
final class UsageStore {
    static let shared = UsageStore()

    var claude = ProviderSnapshot()
    /// One per Codex home found on disk, each scheduled on its own so one
    /// account being rate-limited never stalls another.
    var codex: [CodexSlot] = []
    var isRefreshing = false

    struct CodexSlot: Identifiable {
        let account: CodexAccount
        var snapshot = ProviderSnapshot()
        var failures = 0
        var next = Date.distantPast
        var id: String { account.id }
    }
    /// Bumped on a slow timer purely so relative "resets in" labels stay honest.
    var tick = 0

    var launchAtLogin = LoginItem.isEnabled
    var loginError: String?

    /// Every cadence decision lives in `Schedule`, so it can be checked without
    /// a network. See `--selftest`.

    /// Set when the refresh button was pressed and could not act yet, so the
    /// press has a visible consequence either way.
    var manualNote: String?

    private var pollTask: Task<Void, Never>?
    private var lastManual = Date.distantPast
    // Scheduled independently: Claude being rate-limited must not stall Codex.
    private var claudeNext = Date.distantPast
    private var claudeFailures = 0

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

    /// Panel opened. Only worth a request if the numbers are genuinely old, and
    /// never while a provider is backing off — jumping our own backoff because a
    /// window appeared is what turned one 429 into a run of them.
    func refreshOnOpen() async {
        let now = Date()
        if Schedule.shouldRefreshOnOpen(fetchedAt: claude.fetchedAt,
                                        failures: claudeFailures, now: now) {
            claudeNext = .distantPast
        }
        for i in codex.indices
        where Schedule.shouldRefreshOnOpen(fetchedAt: codex[i].snapshot.fetchedAt,
                                           failures: codex[i].failures, now: now) {
            codex[i].next = .distantPast
        }
        await pollDue()
    }

    /// The refresh button.
    ///
    /// This is the one thing allowed past our own backoff: the user is saying
    /// the numbers matter right now. It works because the routine cadence above
    /// no longer spends the budget — the old five-minute cycle plus a fetch on
    /// almost every panel open is what left nothing for the press that mattered.
    ///
    /// A short cooldown still guards against a click-storm, but it says so
    /// rather than doing nothing: a button with no visible consequence reads as
    /// broken, which is precisely how this one read.
    func manualRefresh() async {
        let now = Date()
        let waiting = Schedule.manualCooldownRemaining(lastManual: lastManual, now: now)
        guard waiting <= 0 else {
            manualNote = "Just checked — again in \(Int(waiting.rounded(.up)))s"
            return
        }
        manualNote = nil
        lastManual = now
        claudeNext = .distantPast
        for i in codex.indices { codex[i].next = .distantPast }
        await pollDue()
        // Say what happened. A press that comes back to the same screen with the
        // same numbers is the complaint this whole change exists to answer.
        let failed = ([claude.error] + codex.map(\.snapshot.error)).compactMap { $0 }
        manualNote = failed.isEmpty ? nil : failed.joined(separator: " · ")
    }

    /// Homes come and go — a `CODEX_HOME=… codex login` while the app is up
    /// should appear without a relaunch — so the list is re-read on every
    /// poll, keeping the schedule of any account that is still there.
    private func syncAccounts() {
        let found = CodexAccount.discover()
        codex = found.map { account in
            codex.first { $0.account == account } ?? CodexSlot(account: account)
        }
    }

    private func pollDue() async {
        syncAccounts()
        let now = Date()
        let wantClaude = now >= claudeNext
        let dueCodex = codex.indices.filter { now >= codex[$0].next }
        guard wantClaude || !dueCodex.isEmpty else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        // Everything due, at once — the accounts are independent logins and
        // there is no reason for the second to wait on the first.
        async let claudeFresh: ProviderSnapshot? = wantClaude ? ClaudeClient.fetch() : nil
        let codexFresh: [(Int, ProviderSnapshot)] = await withTaskGroup(
            of: (Int, ProviderSnapshot).self
        ) { group in
            for i in dueCodex {
                let account = codex[i].account
                group.addTask { (i, await CodexClient.fetch(account)) }
            }
            var out: [(Int, ProviderSnapshot)] = []
            for await pair in group { out.append(pair) }
            return out
        }
        if let cs = await claudeFresh {
            apply(cs, to: &claude, failures: &claudeFailures, next: &claudeNext)
        }
        for (i, fresh) in codexFresh where i < codex.count {
            // Through a local: three inout paths into one observed array
            // element is an aliasing error, and the compiler is right.
            var slot = codex[i]
            apply(fresh, to: &slot.snapshot, failures: &slot.failures, next: &slot.next)
            codex[i] = slot
        }
    }

    private func apply(_ fresh: ProviderSnapshot, to current: inout ProviderSnapshot,
                       failures: inout Int, next: inout Date) {
        if fresh.error == nil {
            current = fresh
            failures = 0
            next = Schedule.nextRoutine(after: Date())
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
        next = Date().addingTimeInterval(
            Schedule.backoff(failures: failures, retryAfter: fresh.retryAfter))
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
        Self.label([("C", claude.headline?.percent)]
                   + codex.map { ($0.account.tag, $0.snapshot.headline?.percent) })
    }

    /// "C 12%  X 40%  Xp 5%" — one part per login, a dash where there is no
    /// number yet. Pure, so the composition can be checked without a network.
    nonisolated static func label(_ parts: [(tag: String, percent: Double?)]) -> String {
        parts.map { tag, pct in
            guard let pct else { return "\(tag) –" }
            return "\(tag) \(Int(pct.rounded()))%"
        }.joined(separator: "  ")
    }

    var worstSeverity: Severity {
        let all = claude.meters + codex.flatMap(\.snapshot.meters)
        let peak = all.map(\.percent).max() ?? 0
        return Severity(percent: peak)
    }
}
