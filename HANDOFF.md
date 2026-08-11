# Handoff

Written for whoever picks this up next. It covers what exists, the conventions
these apps share, the things that cost hours to find, and what is still open.

The user is a CS PhD student (Princeton PLI, Arora lab) working on empirical LLM
safety — reasoning-model robustness, misalignment under benign inputs,
self-improvement, chain-of-thought monitorability. Strong maths and theory
background. Two working preferences show up repeatedly and are worth honouring:
**measure rather than assert** (they will ask how you know), and **say the null
result** — a fix you could not verify should be reported as unverified, not as
done.

---

## The apps

| Folder | Installs as | What it is | Data |
|---|---|---|---|
| `CodingAgentUsage/` | Coding Agent Usage.app | Claude + Codex usage against plan limits, menu bar | — |
| `Frontier/` | Frontier.app | Curriculum graph for learning ML systems/hardware; daily session | `~/Library/Application Support/Frontier/concepts/*.md` |
| `Jot/` | Jot.app | Markdown sticky notes, ⌃⌥Space; markers vanish as you type, KaTeX maths | `~/Library/Application Support/Jot/*.md` |
| `PaperNotes/` | Paper Notes.app | arXiv reading notes, Claude grading/appraisal/recommendations, citation graph | `~/Library/Application Support/Paper Notes/` (git repo) |
| `Pomodoro/` | Pomodoro.app | Timer with full-screen break overlay | `~/Library/Application Support/Pomodoro` |
| `VoiceBridge/` | VoiceBridge.app | Double-tap Control to dictate into iTerm2 | `~/Library/Application Support/VoiceBridge` |

`~/Developer/<App>` are the working copies. This repo is a mirror, checked out at
`~/Developer/apps`; `./sync.sh` copies the sources in, `./install.sh` builds and
installs.

---

## Conventions

**No Xcode on this machine** — Command Line Tools only. Every app is an SPM
package plus a hand-assembled `.app`; `xcodebuild` does not exist and neither do
`.xcodeproj` files. `swift-tools-version: 5.9` is pinned deliberately: 6.0's
strict concurrency fights the `@MainActor` singletons these use.

**Data never lives in the bundle.** `build.sh` does `rm -rf /Applications/X.app`
on every rebuild, and writing into a signed bundle breaks its signature. Data
goes in `~/Library/Application Support/<App>`. This was learned by nearly
shipping it the other way.

**Every app has `--selftest`** that exits non-zero on failure. GUIs cannot be
checked by looking at a transcript, so logic that would fail silently — file
round-trips, orderings, timezone maths — is tested instead. Prefer a test that
*can fail*: after writing one, revert the fix and confirm it goes red. Two tests
in this repo passed with the fix reverted and had to be rewritten.

**Signing** uses a fixed identity, `"VoiceBridge Local Signing"`, so TCC grants
survive rebuilds. Ad-hoc signing changes the cdhash every build and macOS forgets
the Accessibility permission each time.

---

## How to verify GUI work without a screenshot tool

These techniques are the difference between "it should work" and "it works":

- **Screenshot a window by id.** `CGWindowListCopyWindowInfo` for the window
  number, then `screencapture -x -o -l<id>`. Captures the window even when
  something is on top of it — which is also how you prove a desktop-level window
  really is behind everything.
- **Render a SwiftUI view offscreen** with `ImageRenderer` and write a PNG.
- **Drive the real app.** `JOT_KEYTEST=1 open -n -a Jot` runs key-equivalent
  tests inside the shipping configuration and writes a report. A synthetic panel
  proves nothing about a SwiftUI-hosted responder chain.
- **`--list` / `--preview` style CLI commands** exist partly so the pipeline can
  be checked headlessly against live data.

---

## Gotchas, with the symptom that led to each

**`claude -p` hangs for 20+ minutes unless tools are disabled.**
Symptom: a short prompt answers in 3s, a structured one never returns. Cause: the
CLI decides to use Bash/Read and those never return in a nested session. Fix:
`--disallowedTools "WebSearch,WebFetch,Bash,Read,Write,Edit,Glob,Grep,Task"`.
Same prompt then answered in 70s. See `Frontier/Sources/Frontier/Tutor.swift`.

**Draining only stdout deadlocks the child.** A pipe nobody reads holds 64 KB and
then blocks the writer forever. Drain stdout *and* stderr, each on its own queue.
`PaperNotes/Sources/PaperNotes/Judge.swift` still has this latent bug — worth
fixing before it bites.

**`~/Documents` and `~/Desktop` are TCC-blocked** for the shell and for the Read
tool. Route through Finder: `osascript -e 'tell application "Finder" to duplicate
(POSIX file "…") to (POSIX file "…")'`. Finder has full-disk access.

**An `LSUIElement` app still needs `NSApp.mainMenu`.** ⌘C/⌘V/⌘X/⌘Z/⌘A are
dispatched by walking the main menu; with no menu they silently do nothing even
though `NSTextView` implements `copy:`. The menu is never displayed.

**`WKWebView.takeSnapshot` returns a correctly-sized blank image** for a view
that is not on screen. It passes every check except looking at it. Use
`createPDF`, which draws from the render tree and is vector.

**KaTeX loads fonts lazily**, so a capture taken too early is missing glyphs from
faces layout has not requested yet — an integral sign vanishes while the limits
render. Force-load every `KaTeX_*` family before the first render.

**One web view, one DOM.** Two concurrent renders race: the second overwrites the
first before it is captured, and the first equation ends up wearing the second
one's picture at its own measured size. Serialise renders.

**SwiftUI `Text` does not render LaTeX.** Anything with maths must go through the
KaTeX web view. A view rendered by AppKit (list rows, canvas labels) needs a
plain-text fallback that flattens `\times` to ×; see `Concept.plain`.

**An `NSViewRepresentable` inside a `ScrollView`** is asked for its size with an
unbounded proposal and falls back to a few hundred points, clipping its content.
Let the web view fill the pane and scroll itself.

**Swift regex literals choke on `{2}`.** `/^(\d{2})(\d{2})\./` fails to parse;
write the parse by hand.

**arXiv ids encode YYMM.** `2507.14805` is July 2025 — a better sort key than a
`year` field, and present even when the metadata fetch failed. Three papers with
no year sorted below a 2016 paper before this.

**Anywhere on Earth is UTC-12.** Treating AoE as UTC is a twelve-hour error in
the direction that loses papers.

**Persist all three states of a checked link** (ok / unreachable / unchecked).
Recording only failures made verified links read back as unchecked.

---

## Per-app state

### Frontier (newest, least settled)

Concepts are markdown with `requires:` edges. `Frontier.ready` returns concepts
whose prerequisites are all `known`; ordering favours bottlenecks (whole
downstream cone), then started-but-unfinished, then dated items for a fortnight.
`--seed <file>` bootstraps from a scratch list, `--syllabus` synthesises from six
real course syllabi (MIT 6.5940, Stanford CS149, CMU 15-418, CMU 10-414, Stanford
CS336, CMU 15-442), `--grow` continues those syllabi rather than inventing,
`--write <id>` generates the reference entry, `--walk <id>` generates the
walkthrough, `--verify` checks source links.

Open:
- **62 concepts, 1 written.** The corpus is mostly empty until entries are
  generated; each takes ~70s.
- **"Still learning" scores +12**, which pins a concept to the top of every
  session forever. The user wants spaced revisit (`dueOn` + scheduler) with a cap
  of one carried-over concept per session. Not built.
- Syllabus scraping reads rendered HTML, so JS-heavy pages (CMU 15-442, 10-414)
  contribute 32–39 lines against CS336's 130. Those courses are under-represented.
- The graph engine (`GraphSim`, `GraphLayout`, `Viewport`) is **copied** from
  Paper Notes, not shared — each app must build standalone from a clone. A fix in
  one needs applying to the other.
- 10 prerequisites are referenced but not defined; `--grow` fills them.

### Paper Notes

128 papers. 66 carry notes imported from the user's old files (a
`paper_summaries.txt` and a `paper_summaries.html` recovered from their website's
git history — both since deleted at their request). Imported notes are marked
with an `Imported verbatim` comment and use the user's own template (`##
Thoughts`, `## Method`), not the app's.

Open:
- **The library repo is public and auto-pushes** (`pushEnabled = 1`, on a timer).
  The user was told twice it was unpushed before this was noticed; they have been
  told, and the decision is theirs.
- `--rank`, `Vocabulary` and `Search` do not know about `archaic`, so 33 archived
  papers still compete for ranking band shares. The graph and recommender do
  filter them.
- 9 papers with real notes could not be imported: ACL Anthology work with no
  arXiv id, and the library is keyed by arXiv id. The longest is 6,470 characters
  (Rivest & Sloan). Supporting non-arXiv keys would recover them.
- 3 papers are queued *and* marked read.
- 21 imported notes open with `**Keywords:** …` which would map naturally onto
  the app's `tags:` field. Offered, not done.

### Jot

Markers vanish as you type: the buffer holds styled text, the file holds
`**bold**`. `Attributed` converts both ways; the round-trip is tested
exhaustively because a lossy serialiser eats what was written.

Open:
- **⌘Z reverts the whole typing burst**, not just the marker collapse.
  breakUndoCoalescing, explicit grouping and deferring past the event were all
  tried; none separates them. Documented in `Editor.swift`.
- `~/Library/Application Support/Jot/.trash` holds ~30 test files from
  development.

---

## Things deliberately not done

- **Not committed**: `~/Developer/Jot` and `~/Developer/PaperNotes` have dirty
  working trees. Their content is in this mirror; their own history is stale.
- **Frontier is not in the mirror yet.**
- The user asked for a conference-deadline app (`Deadlines`) and then asked for
  it to be deleted. It is gone from disk and from this repo; the git history
  still contains it if it is ever wanted back.

---

## One thing about working with this user

They notice when a claim is not backed. Several times in the session that
produced this file, a "fix" was reported that had not been verified, and each
time they caught it. The habit that worked: state what was measured, state what
was not, and when something is a guess, say it is a guess.
