# Coding Agent Usage

Menu bar app showing live Claude and Codex usage against plan limits, so you don't
need the Claude app and the Codex usage page open in two windows.

Built 2026-07-30.

## Build & install

```sh
./build.sh          # compiles, renders icon, installs to /Applications, launches
```

Requires only Command Line Tools — there is no Xcode on this machine, and no
`.xcodeproj`. `swift-tools-version` is pinned to 5.9 deliberately: 6.0 turns on
strict concurrency, which fights the `@MainActor @Observable` singletons here.

## Where the data comes from

Both products expose a live usage endpoint that credentials already on this Mac can
call. This is the whole basis of the app:

| | Endpoint | Auth |
|---|---|---|
| Claude | `GET https://api.anthropic.com/api/oauth/usage` | keychain item `Claude Code-credentials`, plus header `anthropic-beta: oauth-2025-04-20` |
| Codex | `GET https://chatgpt.com/backend-api/wham/usage` | `~/.codex/auth.json`, plus header `chatgpt-account-id` |

Rejected alternatives, for the record: `~/.claude.json → cachedUsageUtilization` has
the right shape but only refreshes while Claude Code runs (it was 12 days stale when
checked), and Codex's `state_5.sqlite` has raw `tokens_used` per thread but nothing
that maps to a plan percentage.

## Files

| File | Role |
|---|---|
| `ClaudeClient.swift` | keychain read + Anthropic endpoint, parses the `limits[]` array |
| `CodexClient.swift` | `auth.json` read + ChatGPT endpoint |
| `UsageStore.swift` | polling schedule, per-provider backoff, last-good retention |
| `PopoverView.swift` | the panel |
| `Model.swift` | `Meter`/`ProviderSnapshot`, severity thresholds |
| `Tools/MakeIcon.swift` | renders `AppIcon.iconset` via Core Graphics; no asset catalog |

## Maintenance notes

**These endpoints are undocumented.** They are what the products use internally, not
a published API, so they can change without notice. If the panel goes blank, verify
by hand before touching the code:

```sh
TOK=$(security find-generic-password -s "Claude Code-credentials" -w \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('claudeAiOauth',d)['accessToken'])")
curl -s -D - -H "Authorization: Bearer $TOK" -H "anthropic-beta: oauth-2025-04-20" \
  https://api.anthropic.com/api/oauth/usage
```

**Do not lower the poll interval.** 60s got the account rate-limited (40×200 and
6×429 in 18 minutes) — the endpoint is shared with Claude Code itself, which polls it
too. It is now 300s in the background plus a refresh when the panel opens, which is
when freshness actually matters. `UsageStore.baseInterval`.

**Token refresh is delegated to the CLIs.** The app re-reads the credential on every
poll, so running `claude` or `codex` refreshes it. On 401 the panel says so rather
than failing silently. Claude's access token lasts roughly 8 hours.

**A failed refresh keeps the last good values** and marks them stale. Preserve that
behaviour if you rewrite `UsageStore.apply` — blanking the panel on a transient 429
is worse than showing numbers a few minutes old.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `Rate limited — backing off` | expected under heavy Claude Code use; values shown are the last good ones |
| `Token expired — run 'claude' once` | access token aged out; running either CLI refreshes it |
| Keychain prompt on launch | approve once with *Always Allow*; the app shells out to `/usr/bin/security` rather than calling `SecItemCopyMatching` precisely so this survives rebuilds |
| `Error registering app with intents framework` in logs | benign; every ad-hoc-signed SwiftUI app emits it |
