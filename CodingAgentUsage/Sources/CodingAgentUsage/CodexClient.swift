import Foundation

/// One Codex login: a `CODEX_HOME` directory holding an `auth.json`.
///
/// The CLI keeps exactly one login per home, and `codex login` replaces it —
/// which is how a second account logged in "on this machine" overwrote the
/// first. `CODEX_HOME=~/.codex-personal codex login` writes to a home of its
/// own instead, so two accounts coexist as two directories, and the app shows
/// each. `~/.codex` is the default home; anything `~/.codex-<name>` is another.
struct CodexAccount: Identifiable, Equatable {
    let home: URL
    var id: String { home.path }

    /// "" for `~/.codex`, "personal" for `~/.codex-personal`.
    var suffix: String {
        let name = home.lastPathComponent
        return name.hasPrefix(".codex-") ? String(name.dropFirst(".codex-".count)) : ""
    }
    var isDefault: Bool { suffix.isEmpty }
    var title: String { isDefault ? "Codex" : "Codex · \(suffix)" }
    /// Status-bar tag: `X` for the default, `Xp` for `.codex-personal`.
    var tag: String { isDefault ? "X" : "X" + suffix.prefix(1).lowercased() }
    /// The command that refreshes this home's token — the CLI only refreshes
    /// the home it is run against.
    var refreshCommand: String {
        isDefault ? "codex" : "CODEX_HOME=~/\(home.lastPathComponent) codex"
    }
    var authPath: URL { home.appendingPathComponent("auth.json") }

    /// Every home with a login, default first, the rest by name.
    static func discover(
        in userHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [CodexAccount] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: userHome.path)) ?? []
        return names
            .filter { $0 == ".codex" || $0.hasPrefix(".codex-") }
            .map { CodexAccount(home: userHome.appendingPathComponent($0)) }
            .filter { FileManager.default.fileExists(atPath: $0.authPath.path) }
            .sorted { a, b in
                if a.isDefault != b.isDefault { return a.isDefault }
                return a.suffix < b.suffix
            }
    }

    /// Who this login is, from the id_token's claims — enough to tell two
    /// "Codex" sections apart without printing anything secret.
    static func email(inIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return claims["email"] as? String
    }
}

/// Reads a home's auth.json — the credential the Codex CLI maintains — and calls
/// the endpoint that backs the usage view.
enum CodexClient {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static func credentials(for account: CodexAccount) throws
        -> (token: String, accountID: String, email: String?) {
        guard let data = try? Data(contentsOf: account.authPath) else {
            throw UsageError.message("No \(account.authPath.path) — run `\(account.refreshCommand) login`.")
        }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = root["tokens"] as? [String: Any],
            let token = tokens["access_token"] as? String
        else {
            throw UsageError.message("Unexpected credential format.")
        }
        return (token, tokens["account_id"] as? String ?? "",
                (tokens["id_token"] as? String).flatMap(CodexAccount.email(inIDToken:)))
    }

    static func fetch(_ account: CodexAccount) async -> ProviderSnapshot {
        var snap = ProviderSnapshot()
        do {
            let (token, accountID, email) = try credentials(for: account)
            snap.subtitle = email
            var req = URLRequest(url: usageURL)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if !accountID.isEmpty { req.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id") }
            req.timeoutInterval = 15

            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 401 || code == 403 {
                // Only the CLI refreshes a token, and only for the home it is
                // run against; `codex login status` does not (measured).
                throw UsageError.message("Token expired — run `\(account.refreshCommand)` once to refresh it.")
            }
            if code == 429 {
                snap.retryAfter = HTTPHint.retryAfter(http)
                throw UsageError.message("Rate limited — backing off.")
            }
            guard code == 200 else { throw UsageError.message("HTTP \(code)") }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw UsageError.message("Bad response.")
            }

            snap.plan = (json["plan_type"] as? String)?.capitalized
            snap.fetchedAt = Date()

            if let rl = json["rate_limit"] as? [String: Any] {
                for (key, fallback) in [("primary_window", "Primary"), ("secondary_window", "Secondary")] {
                    guard let w = rl[key] as? [String: Any],
                          let pct = w["used_percent"] as? Double else { continue }
                    snap.meters.append(Meter(
                        id: "codex.\(key)",
                        label: windowLabel(w["limit_window_seconds"] as? Double) ?? fallback,
                        percent: pct,
                        resetsAt: (w["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) },
                        isActive: key == "primary_window"
                    ))
                }
            }

            if let c = json["credits"] as? [String: Any] {
                if c["unlimited"] as? Bool == true {
                    snap.note = "Unlimited credits"
                } else if let bal = c["balance"] as? Double, c["has_credits"] as? Bool == true {
                    snap.note = "Credits balance \(Int(bal))"
                }
            }
        } catch let e as UsageError {
            snap.error = e.text
        } catch {
            snap.error = error.localizedDescription
        }
        return snap
    }

    private static func windowLabel(_ seconds: Double?) -> String? {
        guard let s = seconds else { return nil }
        switch Int(s) {
        case 604800: return "Weekly"
        case 86400: return "Daily"
        case 18000: return "Session · 5h"
        case 3600: return "Hourly"
        default:
            let h = Int(s) / 3600
            return h >= 24 ? "Rolling · \(h / 24)d" : "Rolling · \(h)h"
        }
    }
}
