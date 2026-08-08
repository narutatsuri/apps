# apps

Six small macOS apps, kept here so they survive this machine and can be rebuilt
anywhere. Each lives in its own folder, is a self-contained Swift Package with
its own `build.sh` and its own README, and installs to `/Applications`.

| Folder | Installs as | What it does | Its data lives in |
|---|---|---|---|
| `CodingAgentUsage/` | Coding Agent Usage.app | Live Claude and Codex usage against plan limits, in the menu bar | — |
| `Deadlines/` | Deadlines.app | Countdown to conference deadlines, pinned to the desktop below your windows | `~/deadlines/conferences.txt` |
| `Jot/` | Jot.app | Markdown sticky notes. ⌃⌥Space for a new one; markers disappear as you type them and equations typeset | `~/jot/*.md` |
| `PaperNotes/` | Paper Notes.app | arXiv reading notes, with Claude grading the notes, appraising papers on the interest of the idea, and recommending new ones | `~/paper-notes/` |
| `Pomodoro/` | Pomodoro.app | Pomodoro timer with a full-screen break overlay | — |
| `VoiceBridge/` | VoiceBridge.app | Double-tap Control to dictate into the current iTerm2 session, and so into remote tmux over SSH | `~/Library/Application Support/VoiceBridge` |

Notes and papers are deliberately **not** in this repo — the apps keep their data
in the home directory, in plain files, so backing up the code and backing up the
writing are separate decisions.

## Building on a fresh machine

```sh
git clone https://github.com/narutatsuri/apps.git
cd apps
./install.sh              # all six
./install.sh Jot          # or just one
```

Requirements: macOS and the Command Line Tools (`xcode-select --install`). Swift
5.9 or later. **Xcode itself is not needed and never was** — see below.

## How these are built, and why it looks unusual

There is no Xcode on the machine these were written on, only Command Line Tools.
So each app is an SPM package plus a hand-assembled `.app` bundle rather than an
`.xcodeproj`:

- `swift-tools-version: 5.9`, pinned deliberately. 6.0 turns on strict
  concurrency, which fights the `@MainActor @Observable` singletons these use.
- `build.sh` runs `swift build -c release`, creates `Contents/MacOS` and
  `Contents/Resources`, writes `Info.plist`, renders the icon with a small
  `Tools/MakeIcon.swift`, and copies the result into `/Applications`.
- `build/` and `.build/` are generated and are not committed. Nothing in this
  repo is a build artifact except `Pomodoro/reference/`, which holds the only
  surviving copy of a 2025 binary whose source was lost.

Two apps need one-time permission grants that a rebuild must not invalidate:

- **VoiceBridge** signs with a fixed self-signed identity created by
  `VoiceBridge/Tools/make-signing-identity.sh`. Ad-hoc signing produces a new
  code hash every build, which makes macOS forget the Accessibility grant every
  build. It also downloads a ~465 MB whisper model on first run, into Application
  Support — never into the repo.
- **Jot** and **CodingAgentUsage** are `LSUIElement` menu-bar apps, so they show
  no Dock icon and no menu bar. Jot still builds an `NSMenu` and never displays
  it, because on macOS ⌘C and ⌘V are dispatched *through* the main menu; without
  one, copy and paste silently do nothing.

## Testing

Every app has a `--selftest` flag that runs its logic checks and exits non-zero
on failure, deliberately, because a GUI cannot be checked by looking at it in a
transcript:

```sh
"/Applications/Jot.app/Contents/MacOS/Jot" --selftest
```

Jot additionally has `JOT_KEYTEST=1`, which drives the real app — real windows,
real key equivalents, real KaTeX — and writes a report:

```sh
open -n -a Jot --env JOT_KEYTEST=1 --env JOT_KEYTEST_OUT=/tmp/jot-keytest.txt
```

## Keeping this repo current

The working copies live in `~/Developer/<App>`; this repo is a mirror. To refresh
it after changing an app:

```sh
./sync.sh                 # copies ~/Developer/* in, minus build output
git add -A && git commit -m "..." && git push
```

## A note on widgets

None of these are WidgetKit widgets. A widget is an app extension — a `.appex`
with an `NSExtensionPointIdentifier`, embedded in a containing app, signed and
registered with PlugInKit — and producing one is Xcode`s build system`s job.
`Deadlines` gets the same effect with a desktop-level window instead.
