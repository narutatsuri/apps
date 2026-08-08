import Foundation

/// Reads ~/.codex/auth.json — the credential the Codex CLI maintains — and calls the
/// endpoint that backs the usage view.
enum CodexClient {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let authPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/auth.json")

    static func credentials() throws -> (token: String, accountID: String) {
        guard let data = try? Data(contentsOf: authPath) else {
            throw UsageError.message("No ~/.codex/auth.json — run `codex login`.")
        }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = root["tokens"] as? [String: Any],
            let token = tokens["access_token"] as? String
        else {
            throw UsageError.message("Unexpected credential format.")
        }
        return (token, tokens["account_id"] as? String ?? "")
    }

    static func fetch() async -> ProviderSnapshot {
        var snap = ProviderSnapshot()
        do {
            let (token, account) = try credentials()
            var req = URLRequest(url: usageURL)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if !account.isEmpty { req.setValue(account, forHTTPHeaderField: "chatgpt-account-id") }
            req.timeoutInterval = 15

            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 401 || code == 403 {
                throw UsageError.message("Token expired — run `codex` once to refresh it.")
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
