import Foundation

/// Reads the same OAuth credential Claude Code stores in the login keychain and
/// calls the endpoint that backs `/usage`.
enum ClaudeClient {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let keychainService = "Claude Code-credentials"

    /// Shell out to /usr/bin/security rather than SecItemCopyMatching: the keychain
    /// ACL is keyed to the requesting binary, and `security` is a stable system path,
    /// so the one-time "Always Allow" survives every rebuild of this app.
    static func accessToken() throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        guard p.terminationStatus == 0, !data.isEmpty else {
            throw UsageError.message("Keychain access denied — approve the prompt, or log in with `claude`.")
        }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root as [String: Any]?,
            let token = oauth["accessToken"] as? String
        else {
            throw UsageError.message("Unexpected credential format.")
        }
        return token
    }

    static func fetch() async -> ProviderSnapshot {
        var snap = ProviderSnapshot()
        do {
            let token = try accessToken()
            var req = URLRequest(url: usageURL)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.timeoutInterval = 15

            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 401 {
                throw UsageError.message("Token expired — run `claude` once to refresh it.")
            }
            if code == 429 {
                snap.retryAfter = HTTPHint.retryAfter(http)
                throw UsageError.message("Rate limited — backing off.")
            }
            guard code == 200 else { throw UsageError.message("HTTP \(code)") }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw UsageError.message("Bad response.")
            }

            snap.meters = parseMeters(json)
            snap.fetchedAt = Date()

            if let extra = json["extra_usage"] as? [String: Any],
               extra["is_enabled"] as? Bool == true,
               let util = extra["utilization"] as? Double {
                snap.note = "Extra usage \(Fmt.pct(util))"
            }
        } catch let e as UsageError {
            snap.error = e.text
        } catch {
            snap.error = error.localizedDescription
        }
        return snap
    }

    /// `limits[]` is the general form — it carries per-model weekly windows that the
    /// flat five_hour/seven_day fields don't. Fall back to the flat fields if absent.
    private static func parseMeters(_ json: [String: Any]) -> [Meter] {
        if let limits = json["limits"] as? [[String: Any]], !limits.isEmpty {
            return limits.compactMap { l in
                guard let pct = l["percent"] as? Double else { return nil }
                let kind = l["kind"] as? String ?? "limit"
                var label: String
                switch kind {
                case "session": label = "Session · 5h"
                case "weekly_all": label = "Weekly · all models"
                case "weekly_scoped":
                    let model = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                    label = "Weekly · \(model ?? "scoped")"
                default: label = kind.replacingOccurrences(of: "_", with: " ").capitalized
                }
                return Meter(
                    id: "claude.\(kind).\(label)",
                    label: label,
                    percent: pct,
                    resetsAt: date(l["resets_at"]),
                    isActive: l["is_active"] as? Bool ?? false
                )
            }
        }

        var out: [Meter] = []
        for (key, label) in [("five_hour", "Session · 5h"), ("seven_day", "Weekly · all models")] {
            if let w = json[key] as? [String: Any], let pct = w["utilization"] as? Double {
                out.append(Meter(id: "claude.\(key)", label: label, percent: pct,
                                 resetsAt: date(w["resets_at"]), isActive: key == "five_hour"))
            }
        }
        return out
    }

    private static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

struct UsageError: Error {
    let text: String
    static func message(_ s: String) -> UsageError { UsageError(text: s) }
}
