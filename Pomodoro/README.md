# Pomodoro

Menu bar Pomodoro timer with a full-screen break overlay.

Rewritten 2026-07-30 from the compiled 2025 binary, whose source no longer existed
anywhere on this Mac.

## Build & install

```sh
./build.sh          # compiles, installs to /Applications, launches
```

Bundle identifier is deliberately still `com.pomodoro.app`, so the existing settings
at `~/Library/Preferences/com.pomodoro.app.plist` carry over untouched. The icons are
the original artwork, copied out of `reference/`.

## Why it was rewritten

The original had no source. Its architecture was recovered from Swift metadata in the
binary (`TimerManager`, `OverlayWindowController`, `Settings`, `SettingRow`, and the
`timerDidTick` / `timerDidStartBreak` / `timerDidEndBreak` delegate methods), which
survives compilation.

The reported bug was "the timer is wrong". The binary showed why: it called
`NSTimer.scheduledTimerWithTimeInterval:repeats:block:` and contained **zero**
references to `Date`, `timeIntervalSince`, `ContinuousClock`, `SuspendingClock`, or
`DispatchTime`. With no wall-clock anchor it could only have been decrementing a
counter per tick, which fails three ways:

1. **Sleep.** `NSTimer` does not fire while the Mac is asleep, so the counter stops.
   A 25-minute session with a 40-minute nap in the middle finishes 40 minutes late.
2. **Menu tracking.** `scheduledTimer` installs into `.default` run loop mode only.
   While any menu is open the loop runs in `.eventTracking` and the timer stops.
3. **Drift.** Timer delivery is best-effort and macOS coalesces timers for power, so
   every tick lands slightly late and the error accumulates.

## The core invariant — do not break this

`TimerManager` derives everything from an absolute `deadline: Date`. A tick that never
arrives cannot lose time; it only delays a redraw, and the next tick self-corrects.

**Never reintroduce a decremented seconds counter.** If you need to change the timer,
keep `remaining` computed as `deadline.timeIntervalSinceNow`. `frozenRemaining` holds
the interval across a pause, and `resume()` re-anchors to `now`.

Supporting details that also matter: the ticker is added with
`RunLoop.main.add(t, forMode: .common)`, not `scheduledTimer`, and
`NSWorkspace.didWakeNotification` re-syncs the display immediately on wake.

Verified with a self-test that blocks the main thread — guaranteeing zero ticks fire,
exactly as sleep does — and confirms ~3.00s still elapses. The old design would have
reported 0.00s.

## Files

| File | Role |
|---|---|
| `TimerManager.swift` | the wall-clock engine and phase transitions |
| `SessionLog.swift` | append-only interval log, hour bucketing, day summaries |
| `WorkDetector.swift` | frontmost-app + idle watching; `decide()` is pure so it can be tested |
| `NudgePanel.swift` | the floating "Starting work?" ask |
| `DayReportView.swift` | the per-hour breakdown window |
| `Overlay.swift` | break overlay: one window per screen, draws over fullscreen apps |
| `PanelView.swift` | menu bar panel: controls, cycle dots, sliders |
| `Settings.swift` | UserDefaults, keys unchanged from the original |
| `reference/` | **the original 2025 binary — the only copy that exists** |

## Break on demand

Breaks are no longer only on the timer's terms:

- **During focus** — "Break now" ends the focus session and starts the break early.
- **During a break** — "Skip break" in the panel, or "Skip to Focus" on the overlay.

Two decisions worth knowing, because they are judgement calls rather than
consequences of anything:

- **An early break still advances the cycle.** You ended the focus session, so it
  counts toward the next long break. The rule is predictable and easy to reason
  about; the log records the true duration either way, so nothing is distorted.
- **Paused time is not work.** `pause()` closes the interval and `resume()` opens a
  fresh one, so a session paused for lunch does not bank an hour of "focus".

## Noticing when you start working

Forgetting to start the timer is the main way a Pomodoro app fails you, so the app
watches for it. Two permission-free primitives do all the work:
`NSWorkspace.frontmostApplication` for which app is in front, and
`CGEventSource.secondsSinceLastEventType` for how long since a keypress. Nothing
reads window contents or keystrokes — only *which* app is frontmost and *whether*
input happened.

When a work app has held focus for **30 seconds** and the timer is idle, you get a
small floating ask — "Starting work?" — with **Start focus** / **Not now**. It is a
non-activating panel, so answering never pulls focus out of the editor the question
is about, and it gives up on its own after 25 seconds.

Three modes, in the panel under "When I start working":

| Mode | Behaviour |
|---|---|
| **Ask me** *(default)* | offers to start; you decide |
| Start automatically | no prompt |
| Off | nothing is watched |

### The rules, and why they are these rules

- **30 seconds of sustained focus**, not the moment an app comes forward — otherwise
  alt-tabbing past Cursor would trigger a session.
- **Sitting in the editor untouched does not count.** If there has been no input for
  longer than the dwell time, you are looking at the screen, not working.
- **Switching apps mid-session does not stop it.** Reading documentation in a browser
  is work. Only *absence of input* ends a session, which is why start and stop use
  different signals.
- **Going away pauses silently** — there is nobody there to answer a prompt, and it
  keeps the logged minutes honest. Coming back *does* ask ("Back at it?"), because
  otherwise the timer sits paused while you carry on working. See below for what
  "away" means.
- **Declining snoozes for 15 minutes**, and pressing Stop by hand suppresses
  auto-start for 10. Without that, stopping a session while sitting in Cursor would
  just start another one moments later.

### What "away" means — and what it is not

**No camera, no microphone, no Bluetooth proximity, no screen reading.** Two signals,
in order of confidence:

| Signal | Meaning | Response |
|---|---|---|
| Screen locked, or display asleep | proof you left | pause immediately |
| No keyboard/mouse for *N* minutes | a guess | pause after the threshold |

The idle number comes from one call:

```swift
CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .null)
```

Seconds since the last HID event. Any keypress or mouse movement resets it to zero.
macOS hands this to any process without permission precisely because it reveals
nothing about *what* you did — only *that* input happened.

**Which is exactly why the threshold is generous.** Idle time cannot distinguish
"left the desk" from "reading a paper" or "thinking", so it defaults to **10 minutes**
and is adjustable from 2 to 60 under "Pause when idle for". It started at 3 minutes,
which interrupted reading — a short threshold punishes the parts of the work that
don't involve typing.

The lock signal is what makes that safe: proper absences get caught the instant the
screen locks, so the fuzzy signal doesn't have to be aggressive. Lock and display
sleep are tracked separately and OR'd, since waking a display does not mean the screen
was unlocked.

### Which apps count

`~/.config/pomodoro/work-apps.txt`, one per line, matched on bundle identifier or
display name, re-read on every check:

```
Cursor
com.todesktop.230313mzl4w4u92
iTerm2
com.googlecode.iterm2
Code
```

Browsers, Slack and Notion are deliberately absent. Reading docs in Chrome is work,
but *starting* a session because Chrome came forward would fire constantly.

Finer granularity — "iTerm2, but only the tmux window running Claude Code" — is
possible via iTerm2's scripting interface, but it costs an Automation permission and
a poll of session contents. Not built; app-level has been enough.

## Tracking and the day report

Every focus and break interval is appended to
`~/Library/Application Support/Pomodoro/sessions.jsonl`, one JSON object per line:

```json
{"kind":"work","start":"2026-07-30T09:00:00Z","end":"2026-07-30T09:25:00Z","endedBy":"completed","plannedMinutes":25}
```

`endedBy` is one of `completed` / `early` / `stopped` / `paused`. Intervals under 5
seconds are dropped as mis-clicks. JSONL because it is cheap to append, safe to
accumulate for years, and greppable without the app.

**"Today's breakdown"** in the panel opens a window showing focus and break minutes
per hour, as stacked bars on a shared 60-minute axis, with day-to-day navigation and
a table view. Design notes:

- An interval is **split across hour boundaries** — 09:50–10:15 contributes 10
  minutes to 09:00 and 15 to 10:00. Day selection uses an overlap test, not
  containment, so a session crossing midnight counts toward both days.
- **Idle hours inside the active span are kept.** A gap at 11:00 between work at
  10:00 and 12:00 is the point of the chart, not noise to be compressed away.
- Series colours are categorical slots 1 and 2 in fixed order (focus always blue,
  break always orange), with separate steps for dark mode. Validated at ΔE 24.7
  (protan, light) and 26.8 (protan, dark). A legend and a table view both exist, so
  identity never rests on colour alone.

## Calibration — deliberately not built

The obvious next question is "what work/break split actually suits me?", and the log
is shaped to answer it without a migration. `plannedMinutes` is recorded on every
interval specifically so historical settings never have to be guessed at, and
`endedBy` distinguishes sessions that ran their course from ones cut short.

That makes analyses like these available whenever you want them: completion rate by
configured duration, how focus-share varies by hour of day, whether long breaks are
followed by better or worse sessions. None of it is implemented — but no schema change
is needed to start.

## Self-test

`SessionLog.summarize` is pure, so the arithmetic is exercised directly rather than
through the file system:

```sh
POMO_SELFTEST=1 /Applications/Pomodoro.app/Contents/MacOS/Pomodoro
```

11 checks covering hour splitting, midnight crossing, day exclusion, work/break
separation, idle-hour retention, focus share, and the append/read round-trip (through
a temp file — it never writes to the real log). Retained rather than stripped, because
this arithmetic will be touched again if calibration gets built. Run it after changing
anything in `SessionLog`.

## Maintenance notes

**`reference/Pomodoro-original.app` is irreplaceable.** There is no Time Machine
destination configured on this Mac and no other backup. It is committed to git for
that reason. Do not delete it.

The overlay opens one window per `NSScreen` with
`[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]` and rebuilds
on `didChangeScreenParametersNotification`, so displays can be plugged and unplugged
mid-break. `OverlayWindow` overrides `canBecomeKey` because borderless windows
otherwise ignore the first click on a button.

A finished break deliberately does **not** roll straight into the next focus session —
it parks at a prompt, so a session never starts without you agreeing to it.
