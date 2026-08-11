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
Fixed in `PaperNotes/Sources/PaperNotes/Judge.swift` on 2026-08-11; a self-test
floods stderr with 200 KB and goes red if the drain is removed (checked by
removing it).

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

Added 2026-08-11: `--import <pdf-or-url> [--name …] [--plan]` (and an Import
course toolbar button) turns one whole resource — a web book, a course PDF, a
long post — into concepts chained in its own reading order, so the session
walks it end to end. A site root is asked for `/llms-full.txt` first
(rlhfbook.com serves its book that way); a page splits at its own headings; a
PDF by outline or page windows. Imported that day: the RLHF Book (198 concepts
from 20 chapters) and a policy-optimization survey (PPO→GRPO→…→SAPO, 15
concepts) — correctly chained, and cross-linked where the book builds on the
survey's GRPO. The graph is at 275 concepts, almost all unwritten.
Known limitation: a multi-page web book with no llms-full.txt imports only the
page given — use its PDF. Also fixed: title-bar double-click now zooms
(NSToolbarTitleView was swallowing it; measured with FRONTIER_ZOOMTEST=1).

At 275 concepts the graph view collapsed: draw() recomputed the whole-graph
downstream-cone BFS *per node per frame* — `--bench` measured one Canvas frame
at 2,511 ms against ~0 cached — which pinned the machine and blanked the
window. Derived data (unlocks, ready, importance rank) is now cached per
graph-change, the sidebar no longer recomputes `session` per row (Model stores
session/ready), and the graph renders level-of-detail: bottlenecks and
anything actionable in full, the tail as specks, budget rising with zoom²
("simplified — zoom in for the rest" in the legend). `--render <id|all>`
pushes any concept through the real bundled renderer headlessly — all 275
render — and the reading pane reloads itself if WebKit's content process dies.
PaperNotes' copy of the graph got the smaller matching fix (dictionary
lookups, not per-node linear scans). **The reading pane itself still does not
paint — see ACTIVE INVESTIGATION at the bottom of this file; start there.**

Open:
- **Most concepts unwritten.** The corpus is mostly empty until entries are
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

137 papers. 75 carry notes imported from the user's old `paper_summaries.html`
(recoverable from the website repo's git history at `2444ef0`, in
`~/Website/narutatsuri.github.io`). Imported notes are marked with an `Imported
verbatim` comment and use the user's own template (`## Thoughts`, `## Method`),
not the app's.

Resolved on 2026-08-11:
- **Public repo**: the user decided public is fine; it pushes.
- `Ranker.rankable` and the in-app recommendation paths exclude `archaic`;
  search keeps archived papers findable but ranks them after current work,
  labelled "(archived)".
- Non-arXiv keys exist (written as `id:` in frontmatter; ACL ids get Semantic
  Scholar metadata and Anthology links). The 9 locked-out notes were imported
  this way — 8 ACL papers plus Rivest & Sloan 1994 under the hand key
  `rivest-sloan-1994`. Four stub notes (61–90 chars) were left unimported.
- The 3 queued-and-read papers were unread (add-time `read:` stamps); the
  stamps were removed, and entering the queue now clears the date on a virgin
  note.
- The 21 `**Keywords:**` lines were moved into `tags:`.

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

- **Not committed**: `~/Developer/Jot` has a dirty working tree. Its content is
  in this mirror; its own history is stale. (`~/Developer/PaperNotes` got a
  catch-up commit on 2026-08-11; `~/Developer/Frontier` has no repo of its own —
  the mirror is its only history.)
- The user asked for a conference-deadline app (`Deadlines`) and then asked for
  it to be deleted. It is gone from disk and from this repo; the git history
  still contains it if it is ever wanted back.

---

## ACTIVE INVESTIGATION — Frontier's reading pane never paints (pick this up first)

The user's symptom: selecting a concept shows a blank pane. Reproduced,
instrumented, and half-solved on 2026-08-11; the session was cut mid-bisection.
The working tree (mirrored here) is mid-surgery and carries all the tooling.
Everything below was measured, not guessed; the screenshots and pixel counts
came from the CGWindowList + `screencapture -l<id>` technique above, scored
with a PIL "count pixels lighter than 120 in the pane region" one-liner.

### What is established

1. **The renderer is fine.** The DOM holds the full document (26,931 chars for
   `gpu-execution-model`; `FRONTIER_WEBLOG=1` logs it), `--render all` renders
   all 275 concepts headlessly, and the layout dump (`FRONTIER_DUMP=1`) puts
   the WKWebView at exactly the pane's frame, visible, alpha 1. The pane still
   paints nothing — pixel-checked flat, not dark-on-dark.
2. **The process is fine.** Bare `NSWindow` probes in the same running app all
   paint: plain, with the `drawsBackground=false` KVC, with a unified toolbar
   plus `.fullSizeContentView`, and with `NSHostingView(ConceptPreview)`
   (`FRONTIER_WEBPROBE=1` opens all of them).
3. **The SwiftUI `Window` scene's window composites no web content at all** —
   SwiftUI-hosted, AppKit-injected (`FRONTIER_INJECT=1`), or overlaid
   (`FRONTIER_OVERLAY=1`). All blank. The app now builds its window in AppKit
   instead (`AppDelegate.makeWindow`), toolbar replaced by an in-content bar.
4. **Root cause, window half — CONFIRMED by single-variable bisection:** a
   window whose frame changes between creation and its first compositor commit
   never composites out-of-process layers again on this macOS (Darwin 25.5.0).
   `win.center()` → blank; `win.setFrameAutosaveName(…)` (it restores, i.e.
   moves) → blank; the identical construction without them → paints; the same
   move applied 1 s later → still paints. `makeKeyAndOrderFront`,
   `isReleasedWhenClosed`, every styleMask flag including `.miniaturizable` —
   all innocent. This is why the SwiftUI scene window fails: scenes restore
   their saved frame at launch. `makeWindow` now computes the starting rect by
   hand (parsing `NSWindow Frame FrontierMain` from defaults) so the window is
   *born* at its final frame, and arms `setFrameAutosaveName` at +1 s.
5. **There is a second poisoner inside ContentView, not yet identified.** With
   the clean-born window: bare `ConceptPreview` as the window's content paints;
   the full `ContentView` is blank. Already eliminated *in the clean window*:
   `NavigationSplitView` (swapped for a hand-rolled HStack — still blank) and
   the materials (`.listStyle(.sidebar)`, `.background(.bar)` — still blank).
   Not yet eliminated: the segmented pickers (prime suspect — they carry the
   LiftPortal/`CAPortalLayer` glass machinery seen in the layer dump), the
   `List` itself, the control-bar buttons, and the shared modifiers
   (`.sheet`/`.alert`/`.overlay`/`.onAppear`).

### The next step, ready to run

`ContentView` has a bisection switch already wired: `FRONTIER_BARE=1` renders
the pane alone under the shared modifiers, `=2` adds the control bar (segmented
picker), `=3` adds the sidebar `List`. Build, install, then for each level:
launch with the env var, find the window id, screenshot, count light pixels.
L1 blank → the shared modifiers; L2 blank → the control bar; L3 blank → the
List. Then delete the guilty part's effect (e.g. replace the segmented picker
with plain buttons) and re-verify. Afterwards **strip the scaffolding**: the
`FRONTIER_BARE` switch, `WebProbe.swift`, `LayoutDump.swift`, and the probe
paragraphs in `AppDelegate` can all go once the pane paints; `ZoomDiagnose`
(zoom regression) and `ClickDiagnose`/`FRONTIER_WEBLOG` are worth keeping.

### Also in flight / worth knowing

- `ConceptPreview` is currently double-hosted (`NSHostingView<WebPane>` inside
  the representable) with a `FillContainer` that sizes the web view in
  `layout()`, plus WebKit process-death recovery. The double-hosting was
  adopted mid-hunt and is probably unnecessary once the real poisoner is out —
  simplify back to one representable and re-verify.
- The current installed build still shows the blank pane (unchanged from the
  user's complaint); sidebar, Courses, graph, import and zoom all work.
- **PaperNotes probably has the same disease** — same WKWebView-in-scene-window
  pattern, unverified because its preview needs a selected paper. Check by
  opening a note; if blank, the same clean-birth AppKit window treatment (or
  whatever the content-level fix turns out to be) applies there.
- If the hunt stalls, the robust fallback is the gotchas list's own advice:
  render in the offscreen web view (which provably works) → `createPDF` →
  display in a `PDFView` — in-process drawing, no remote layers. Remember the
  KaTeX lazy-font gotcha if going this route.
- A fix, once found, deserves a red-then-green check: the pixel-count loop
  makes that cheap.

---

## One thing about working with this user

They notice when a claim is not backed. Several times in the session that
produced this file, a "fix" was reported that had not been verified, and each
time they caught it. The habit that worked: state what was measured, state what
was not, and when something is a guess, say it is a guess.
