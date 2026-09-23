import Foundation

/// The cadence decisions, which are invisible until the server starts refusing.
///
/// This app had no tests at all, and the thing it got wrong was arithmetic about
/// time: how often to ask, how long to wait after a refusal, and whether opening
/// a window should cost a request. None of that shows up in a screenshot, and
/// all of it is a pure function of a date. Run with --selftest.
enum SelfTest {
    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        var fails = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { fails += 1 }
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // --- routine cadence
        //
        // The complaint that started this: rate limits, constantly. Two
        // providers on the old five-minute cycle is 24 requests an hour before
        // anyone opens the panel.
        check("the routine cadence is quarter-hourly, not five-minutely",
              Schedule.routine == 900,
              "utilization percentages move over hours; \(Int(Schedule.routine))s")
        check("that is at most 8 routine requests an hour for both providers",
              2 * 3600 / Schedule.routine <= 8,
              "got \(Int(2 * 3600 / Schedule.routine))")

        let earliest = Schedule.nextRoutine(after: now, jitter: -1)
        let latest = Schedule.nextRoutine(after: now, jitter: 1)
        check("routine checks are spread rather than exact",
              earliest < latest,
              "in step, both providers fire together and every cycle is a burst")
        check("the spread is a fifth either way",
              abs(earliest.timeIntervalSince(now) - 720) < 0.001
              && abs(latest.timeIntervalSince(now) - 1080) < 0.001,
              "got \(Int(earliest.timeIntervalSince(now)))s … "
            + "\(Int(latest.timeIntervalSince(now)))s")
        check("and never lands before the interval's lower bound",
              Schedule.nextRoutine(after: now, jitter: -99).timeIntervalSince(now) >= 720,
              "a jitter value out of range must not collapse the gap")

        // --- opening the panel
        //
        // Looking at a usage meter is the thing you do often. It used to cost a
        // request nearly every time, which made the panel its own worst enemy.
        // Three minutes, not one: at exactly the old threshold this test passes
        // either way and proves nothing. It has to sit between the two values.
        check("opening the panel does not refetch numbers from three minutes ago",
              !Schedule.shouldRefreshOnOpen(fetchedAt: now.addingTimeInterval(-180),
                                            failures: 0, now: now),
              "this was the main source of traffic")
        check("but does when they are genuinely old",
              Schedule.shouldRefreshOnOpen(fetchedAt: now.addingTimeInterval(-1200),
                                           failures: 0, now: now))
        check("and does when there are no numbers yet",
              Schedule.shouldRefreshOnOpen(fetchedAt: nil, failures: 0, now: now))
        check("opening the panel never jumps an active backoff",
              !Schedule.shouldRefreshOnOpen(fetchedAt: now.addingTimeInterval(-9999),
                                            failures: 1, now: now),
              "jumping our own backoff because a window appeared is what turned "
            + "one 429 into a run of them")

        // --- backing off
        check("the first failure waits a minute",
              Schedule.backoff(failures: 1, retryAfter: nil) == 60)
        check("and each one after that doubles",
              Schedule.backoff(failures: 2, retryAfter: nil) == 120
              && Schedule.backoff(failures: 3, retryAfter: nil) == 240)
        check("but never past half an hour",
              Schedule.backoff(failures: 99, retryAfter: nil) == Schedule.maxBackoff,
              "got \(Int(Schedule.backoff(failures: 99, retryAfter: nil)))s")
        check("a usable Retry-After wins",
              Schedule.backoff(failures: 1, retryAfter: 300) == 300)
        check("an unusable one is ignored",
              Schedule.backoff(failures: 1, retryAfter: 0) == 60,
              "this endpoint answers 429 with retry-after: 0, which is not a hint")

        // --- the refresh button
        check("the button acts when it has not just acted",
              Schedule.manualCooldownRemaining(lastManual: now.addingTimeInterval(-60),
                                               now: now) == 0)
        check("a second press inside the cooldown reports how long is left",
              Schedule.manualCooldownRemaining(lastManual: now.addingTimeInterval(-4),
                                               now: now) == 6,
              "a button with no visible consequence reads as broken, which is "
            + "exactly how this one read")
        check("the cooldown is short enough to not feel broken",
              Schedule.manualCooldown <= 10,
              "got \(Int(Schedule.manualCooldown))s")

        // --- more than one Codex login
        //
        // `codex login` replaces the one credential in ~/.codex — which is how
        // the personal account overwrote the business one. CODEX_HOME gives
        // each account a home of its own; the app has to find them all.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cau-selftest-\(getpid())")
        for name in [".codex", ".codex-personal", ".codex-empty", ".codexfake", "notes"] {
            try? FileManager.default.createDirectory(
                at: tmp.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for name in [".codex", ".codex-personal", ".codexfake"] {
            try? "{}".write(to: tmp.appendingPathComponent(name).appendingPathComponent("auth.json"),
                            atomically: true, encoding: .utf8)
        }
        let found = CodexAccount.discover(in: tmp)
        check("every home with a login is found, and nothing else",
              found.map(\.home.lastPathComponent) == [".codex", ".codex-personal"],
              "got \(found.map(\.home.lastPathComponent)) — a home with no auth.json "
            + "is not a login, and .codexfake is not a CODEX_HOME naming")
        check("the default home comes first", found.first?.isDefault == true)
        check("the default is just 'Codex'", found.first?.title == "Codex")
        check("the others say which", found.last?.title == "Codex · personal")
        check("status-bar tags stay short and distinct",
              found.map(\.tag) == ["X", "Xp"], "got \(found.map(\.tag))")
        check("the refresh hint names the right home",
              found.last?.refreshCommand == "CODEX_HOME=~/.codex-personal codex",
              "the CLI only refreshes the home it is run against")
        try? FileManager.default.removeItem(at: tmp)

        // The email out of an id_token, so two "Codex" sections can be told
        // apart. A synthetic token: header.payload.signature, base64url.
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let fake = b64url("{\"alg\":\"none\"}") + "."
            + b64url("{\"email\":\"someone@example.com\",\"sub\":\"x\"}") + ".sig"
        check("the login's email is read from the token",
              CodexAccount.email(inIDToken: fake) == "someone@example.com",
              "got \(CodexAccount.email(inIDToken: fake) ?? "nil") — base64url, "
            + "with the padding the encoder stripped")
        check("garbage is not an email", CodexAccount.email(inIDToken: "nope") == nil)

        check("the status bar shows one part per login",
              UsageStore.label([("C", 12), ("X", 40.4), ("Xp", nil)]) == "C 12%  X 40%  Xp –",
              "got '\(UsageStore.label([("C", 12), ("X", 40.4), ("Xp", nil)]))'")

        print(fails == 0 ? "\nALL PASS" : "\n\(fails) FAILURE(S)")
        exit(fails == 0 ? 0 : 1)
    }
}
