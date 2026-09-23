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
| `Lanes/` | Lanes.app | Project progress log: one markdown column per project on a sideways-scrolling board; Jot's editor by symlink | `~/Library/Application Support/Lanes/*.md` |
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

**`build.sh` assembles into `build/X.app`, then installs to `/Applications` and
deletes the staging bundle.** The delete is not tidiness. Left in place it is a
second launchable copy with the same bundle id and the same data directory, and
it only has to be opened *once* — by Spotlight, or a double-click while looking
around the build directory — for macOS to relaunch it at every login from then
on. That happened to Jot: two processes over the same notes folder with no
cross-process coordination, both racing to register ⌃⌥Space, and after a rebuild
the survivor was the *older* build. Diagnosed from `loginwindow[173] ... Got App
URL: file:///Users/narutatsuri/Developer/Jot/build/Jot.app/`. The staging bundle
is now unregistered from LaunchServices and then deleted, in all six scripts —
unregistered first because LaunchServices notices a new `.app` the moment it
appears, so deleting alone leaves an entry pointing at a path that no longer
exists. `pkill` is `-x` by executable name everywhere too; Frontier and Jot had
it anchored to `/Applications`, which is why a rebuild never stopped the stray.

---

## How to verify GUI work without a screenshot tool

These techniques are the difference between "it should work" and "it works":

- **Screenshot a window by id.** `CGWindowListCopyWindowInfo` for the window
  number, then `screencapture -x -o -l<id>`. Captures the window even when
  something is on top of it — which is also how you prove a desktop-level window
  really is behind everything. **But bring the app to the front first if any of
  it is a web view**: an occluded WKWebView stops drawing, and the capture is
  then a perfect photograph of a bug that isn't there. See the gotcha below; it
  cost a session.
- **Render a SwiftUI view offscreen** with `ImageRenderer` and write a PNG.
- **Drive the real app.** `JOT_KEYTEST=1 open -n -a Jot` runs key-equivalent
  tests inside the shipping configuration and writes a report. A synthetic panel
  proves nothing about a SwiftUI-hosted responder chain.
- **`--list` / `--preview` style CLI commands** exist partly so the pipeline can
  be checked headlessly against live data. Frontier has `--render <id|all>`
  (every concept through the real renderer), `--seed <file> [count]` (a scratch
  list of terms into concepts; the count defaults to terms + half again, since
  asking for exactly as many concepts as terms guarantees holes),
  `--mark <id> <status> [score]` (the buttons under the reading pane, and the
  scheduler), `--test <id>` / `--retest <id>` (a concept's test, printed or
  rewritten), `--courses` (what each syllabus yields, both
  readings, exits non-zero when one is thin), `--page <url>` (the text a real
  web view gets, verbatim), `--next`, `--status` and `--bench`; Paper Notes has
  `--rank`, `--search`, `--snapshot` and friends.
- **The gated in-app checks.** `FRONTIER_WINTEST=1` asserts the window still
  fits on the screen and exits non-zero if not; `FRONTIER_CLICKTEST=1` replays a
  scripted walk through the sidebar so a pane can be photographed in every
  state; `FRONTIER_WEBLOG=1` narrates the renderer; `FRONTIER_ZOOMTEST=1` covers
  title-bar double-click; `PN_SELECT=<id>` opens Paper Notes onto a paper.

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

**A window screenshot of an app that is not in front proves nothing.** This one
cost a whole session. `screencapture -l<id>` of an occluded window returns the
window at its correct size, in its correct place, with nothing drawn in the
WKWebView — pixel-identical to the compositing bug that was being hunted.
Bring the app to the front before capturing: `osascript -e 'tell application
"System Events" to set frontmost of first process whose name is "Frontier" to
true'`. Measured: the same build, same window, read blank 8 times out of 8
unactivated and painted 2 out of 2 activated. Probe windows created with
`orderFrontRegardless()` are never occluded, which is why every probe painted
while the real window "didn't" — the comparison that made the fault look like it
was in the content.

**Count ink, not brightness.** The pixel test in the old notes was "count pixels
lighter than 120", which assumes a light appearance; this machine is in dark
mode, where that counts zero for a perfectly painted pane. Take the modal colour
of the region as the background and count pixels that differ from it — works in
either appearance, and a flat region still reads as flat.

**`NSHostingView` will resize your window.** It publishes the SwiftUI content's
minimum size as the window's `contentMinSize`, and a `List` asks for the height
of every row it holds. Measured: `contentMinSize` 373×3522 on a 949pt screen.
The window is *born* at its saved 868pt and looks right, and then the frame
restore a second later is a resize, which AppKit clamps up to that minimum — so
the window silently grows to 3554pt with its own controls below the bottom edge
of the display. `hosting.sizingOptions = []`. The window sizes the content,
never the other way round.

**"Saved" and "edited" are different events.** Jot's `Store.save` stamped
`updatedAt` on every call, and saves happen for things that are not edits — a
window moved, a note opened, the app writing its state back at launch. The menu
sorts on that field, so after a restart every note carried the same timestamp
(measured: three of them identical to the second) and the list order became
arbitrary. Stamp the time only when the *content* changed. The same trap exists
anywhere a "last modified" field is written by a code path that also runs for
metadata.

**An offscreen helper window will not stay offscreen.** Jot lays equations out
in a 2400×1200 borderless WKWebView window parked at (-10000,-10000), and macOS
pulls windows back onto a display when the screen arrangement changes. On a
three-monitor setup that deposited it mid-screen as a flat slab of the paper
colour, borderless, with nothing to close — reported as "a big yellow screen I
can't close". Measured: `constrainFrameRect((-10000,-10000,2400,1200))` through
a *titled* window returns `(0,-251,…)`, and the stray was found at `(0,-218)`.
Position is not a hiding place — and neither is transparency. Making it
`alphaValue = 0` stopped it being *seen* (verified by parking it on screen
with `JOT_MATHWIN=0,0`: 0 of 11,520,000 pixels drawn, against 11,519,811 of
one colour before) but not being *there*. It later turned up across an
external monitor's menu-bar strip, and a window under the menu bar changes
how macOS tints it — which the user saw as the menu bar glitching.
**The fix that holds is never ordering it in at all.** The view still needs
a window, so one is built and the view added; `orderBack` is simply not
called. A window that is not in the on-screen list cannot be relocated onto
a display and composites nothing. `createPDF` draws from the render tree,
so rendering is unaffected — the three KaTeX self-tests pass unchanged, and
`measuringWindowIsInvisible` now asserts `!isVisible` first.

**An equation is a picture, not glyphs.** In Jot, `$x^2$` is a KaTeX render
captured as an image and hung on one attachment character. So anything that
works by drawing behind text does not reach it — a `.backgroundColor` set on the
attachment is correct, present, and invisible, because the image is opaque and
painted with the paper colour. Whatever you want behind an equation has to be
passed to the renderer as its background. Same reason a font trait cannot bold
one. Checked by counting pixels, after the attribute route looked right and
wasn't.

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
lookups, not per-node linear scans).

Resolved 2026-08-11 (later session):
- **The reading pane paints.** There was no second poisoner. The clean-born
  AppKit window was the whole fix; the previous session's "ContentView is
  blank" bisection was reading occluded windows (see the gotcha above).
  Verified on the shipping build: 6 launches by both paths (direct exec and
  `open -a`), and a scripted walk across written, unwritten and imported
  concepts, every one with a fully rendered pane. All the hunt scaffolding is
  gone — `FRONTIER_BARE`, `WebProbe.swift`, `LayoutDump.swift`, the
  `FRONTIER_OVERLAY`/`INJECT`/`OPAQUE` probes — and `ConceptPreview` is back to
  one representable rather than two, re-verified after the simplification.
- **Spaced revisit was built**, then superseded the next day by the test —
  see below. What survives from it: `dueOn`, the two-band `ready` that sorts
  not-yet-due concepts below everything else, `carryOverPerSession = 1`, the
  **Coming back** sidebar section, and the rule that a concept marked before any
  of this existed has no `due:` and counts as due. What went: the 1/3/7/16/35
  ladder driven by how many times a button had been pressed.
- **The window no longer grows off the screen.** See the `NSHostingView` gotcha.
  `FRONTIER_WINTEST=1` is a gated check for it — it exits non-zero if the window
  or its `contentMinSize` outgrows the display. Verified red without the fix.
- The unwritten-concept blurb was pinned at 150pt and cut its rationale off
  mid-sentence; it now sizes to what it rendered (the renderer reports its own
  height back), capped at 460pt.

Added 2026-08-12 — **each entry has a test, and the test drives the schedule.**
This replaces "Still learning" outright. That button said "not yet" and grew the
gap whether or not you were learning anything, because pressing a button is not
evidence about what you know; a score is.

- **Written by the same call that writes the entry** — one prompt, one button.
  Six questions: four multiple-choice, two written. The prompt asks for
  distractors that are the answer you get by applying the right idea in the
  wrong place, and for written questions that want a derivation rather than a
  definition. What came back for `gpu-execution-model` is worth reading as a
  calibration of what the prompt gets you.
- **One format, not two.** What the model is told to emit is exactly what the
  file stores: `###` for the stem, `- [x]` for the answer, a blockquote for the
  mark scheme. So a bad question is fixed by editing the note, and there is no
  wire format to drift from a storage format. `Concept.questions(fromMarkdown:)`
  both ways; a multiple-choice question with nothing ticked is dropped, because
  marking every attempt wrong is worse than not asking.
- **Marking**: multiple choice locally and instantly; the written pair goes to
  the model in one call. A grader that does not answer marks the written
  questions at half rather than zero — a silent zero would reschedule the
  concept for tomorrow on the *model's* failure, not yours.
- **The interval follows the score**: ≥0.9 multiplies by 2.6, 0.75–0.9 by 1.7,
  0.5–0.75 holds, below 0.5 resets to tomorrow whatever the history. Capped at
  60 days. A top score never marks a concept known — one good morning is not
  being finished, and that stays the user's call.
- **The test renders in the web view**, at the end of the entry, so questions
  full of arithmetic typeset through the same KaTeX path. Answers come back
  through a `WKScriptMessageHandler` rather than being pulled out with
  `evaluateJavaScript`, because the page knows when it is finished and Swift
  would have to guess. `FRONTIER_WEBLOG=1` reports the test's rendered length —
  "the call did not throw" and "there are questions on the page" are different
  claims, and 4,310 chars is the second one.
- `--test <id>` prints a stored test, `--retest <id>` writes a fresh one for an
  entry that predates this, `--mark <id> learning <score>` drives the scheduler
  from the command line.

Open:
- **Most concepts unwritten.** 1 of 287 has an entry. Each takes ~70s of model
  time, so this is a decision about spend, not a bug. Entries written from now
  on come with their test.
- **The marking round-trip is not verified end to end.** The arithmetic, the
  parsing, the grader's reply format and the rendering are each tested; actually
  clicking a radio button and pressing "Mark my answers" needs assistive access
  this process does not have. Worth doing by hand once.
- Syllabus scraping: **the diagnosis in the previous handoff was wrong**, and
  the numbers are worth reading before touching this again. It was recorded as
  "JS-heavy pages contribute 32–39 lines against CS336's 130". Measured with
  `--courses`, which prints both readings per course:

  | course | served HTML | rendered | used |
  |---|---|---|---|
  | MIT 6.5940 | 100 | 63 | 100 |
  | Stanford CS149 | 62 | 59 | 62 |
  | CMU 15-418/618 | 53 | 37 | 53 |
  | CMU 10-414/714 | 39 | 35 | 39 |
  | Stanford CS336 | 130 | 106 | 130 |
  | CMU 15-442/642 | 33 | 34 | 34 |

  Rendering the page in a real web view — the obvious fix, and the one that was
  planned — wins on **one** of six. What was actually wrong: CS336 had gone from
  130 lines to *zero* because `stanford-cs336.github.io` now redirects to
  cleartext `http://cs336.stanford.edu`, which ATS refuses, so the biggest
  contributor was silently contributing nothing; and CMU 15-442 was pointed at a
  landing page that never had a syllabus on it, rather than `/schedule`. Both
  fixed. `Courses.topics` now takes both readings and keeps the longer, so
  neither path can make things worse and a page that changes shape repairs
  itself. `PageReader` is kept for the drift towards script-built schedules, and
  because `--page <url>` is what distinguished "did not render" from "rendered,
  then thrown away by the line filter" — but it was not the fix.
- The three still-thin courses (15-418, 10-414, 15-442, at 53/39/34) are thin
  because their schedule pages are terse, not because of how they are read.
  `--courses` exits non-zero while any course is under 60 lines.
- The graph engine (`GraphSim`, `GraphLayout`, `Viewport`) is **copied** from
  Paper Notes, not shared — each app must build standalone from a clone. A fix in
  one needs applying to the other.
- **"N prerequisites not yet in the graph" mostly did not mean what it said.**
  `--grow` was run against the 10 loose ends and filled *none* of them, adding
  12 concepts and 16 fresh loose ends — a treadmill. The reason: the model
  writes `requires:` by inventing an id from a title, so `gpu-execution-model`
  gets referred to as `gpu-execution-model-sms-warps-occupancy`,
  `arithmetic-intensity-and-roofline` as `arithmetic-intensity-roofline`,
  `cache-coherence-snooping-and-false-sharing` as `cache-coherence`. They were
  not concepts the curriculum lacked; they were edges pointing a few words wide
  of concepts it already had. And because `Frontier.ready` deliberately treats
  an unknown prerequisite as non-blocking, each one was not a broken edge but a
  **silently deleted** one — so concepts were being offered before their
  prerequisites were known. Repairing the 25 mistyped edges took "ready to
  learn" from 13 down to 6, which is the graph telling the truth for the first
  time. `Frontier.resolve` does the matching (only when one id's words contain
  the other's, or ¾ of the shorter is shared, and only when exactly one concept
  fits — two candidates means no link); `Store.add` applies it to incoming
  concepts so expansions stop accumulating breakage; `--relink` prints the
  repairs and changes nothing, `--relink --apply` writes them, and it refuses to
  apply anything that would close a cycle. Eleven self-tests.
- 12 loose ends remain and these do look genuinely undefined — `data-parallelism-zero-fsdp`,
  `autograd-internals-checkpointing`, `large-scale-optimization-in-practice` and
  the like. `--grow` is the right tool for *those*; expect it to add its own
  crop, now repaired on the way in rather than left dangling.

### Coding Agent Usage

Menu bar, Claude + Codex utilization against plan limits. **Gained `--selftest`
on 2026-08-15** — it had none, and what it got wrong was arithmetic about time,
which is invisible until the server starts refusing.

The rate-limit complaint and what was behind it:
- Routine cadence was 300s per provider — 24 requests an hour before anyone
  opened the panel. Now 900s, with ±20% jitter so the two providers do not fall
  into step and turn every cycle into a burst of two.
- **Opening the panel refetched anything older than 60s.** Looking at a usage
  meter is the thing you do often, so the panel was its own main source of
  traffic. Now 600s: it shows what was last measured and says how old it is.
- The refresh button silently did nothing inside its cooldown, which is
  indistinguishable from broken — and that was the actual complaint. It now
  reports how long is left, and reports the error when a press does fail.
- All of it lives in `Schedule.swift` as pure functions of a `Date`, so
  `--selftest` can check it without a network. 18 tests; four reverted in turn
  and confirmed red. The first attempt at the panel-open test used exactly the
  old 60s threshold and passed either way — the value has to sit *between* the
  old and new ones to discriminate.

**Two Codex accounts (2026-08-28).** The user added a personal Codex
subscription; `codex login` replaced the business credential in `~/.codex`
(measured: the file's mtime and the id_token's email both flipped). The fix is
the CLI's own `CODEX_HOME`: one directory per login, `~/.codex` the default and
`~/.codex-<name>` the rest. `CodexAccount.discover()` re-reads the list on every
poll so a new login appears without a relaunch; each account is its own
`CodexSlot` with its own backoff; the panel labels each section with the email
out of the id_token; the bar shows `X` for the default and `X<initial>` for
the others. Verified live with `CAU_DUMP=1`. Facts that shaped it:
`codex login status` does *not* refresh a token (measured: `last_refresh`
unchanged), only running `codex` against that home does; the access token
lasts ten days; the id_token one hour. The "token expired" message names the
exact command for the home in question. Routine traffic is 4 requests an hour
per login, so three logins is 12 — still under the old two-login figure of 24.

Then, the same afternoon, the user decided the business account is not worth
keeping: **one Codex login, personal, in `~/.codex`**; `~/.codex-personal` was
deleted. The multi-home code stays — it is inert with one home, costs nothing,
and is tested — but nothing currently exercises it. Two lessons from the
detour, both paid for: `codex login` deletes the existing credential and
revokes it *server-side* the moment it starts, so an interrupted login leaves
no login at all; and copying an `auth.json` to a second home does not preserve
that login, because the copy is the same token and dies with the original. A
second account has to be logged in fresh under its own `CODEX_HOME`.

Worth being straight about: if the server is refusing, no client change makes a
request succeed. What these changes buy is that the budget is no longer spent on
polling nobody asked for, so a manual press is nearly always available.

### Paper Notes

Added 2026-09-10 — **scoped recommendations** (`Recommender.Scope`:
library / project(name) / paper(id)). The Next window header gains a scope
picker (whole library + each project; a paper scope appears when a sidebar
row's "What to read after this…" opened the window). `scoped(_:to:)` pure:
library keeps the archaic filter, explicit scopes skip it (deliberate — a
question about that paper); project matching reuses Projects.papers;
paper matching normalises ids. Scoped runs: seeds = the scope itself
(arXiv-shaped keys only — web entries have no registry), authors feed
skipped, fresh-arXiv vocabulary built from the scope, cited-bar via
`minimumCiting(for:count:)` (3 library / 2 project≥4 / 1 small), judge
weighs against the scope. Scope is session-only (a scope surviving relaunch
reads as the recommender gone strange). Pure parts selftest'd + red-checked
(raw-id comparison reddens the normalisation test); the live scoped network
run is the user's click — not machine-verified.

Changed 2026-09-10 — **the website graph now fetches from the paper-notes
repo**, not a data file committed to the site. `reading-graph.json` lives at
the notes repo root; `AppModel.pushIfEnabled` regenerates it before any push
that carries changes and commits it only when the bytes moved (deterministic
export → quiet cycles are free; the hook is inside the `unpushed > 0` guard
so the 120s timer never pays the layout cost idle). The site's
reading-graph.js fetches it from raw.githubusercontent.com/narutatsuri/
paper-notes/main/ (public repo, `access-control-allow-origin: *` — measured;
CDN caches ~5 min). The site's data/reading-graph-data.js is deleted; on
fetch failure the page shows a one-line note instead of a graph. The
`window.READING_GRAPH` script-tag path is gone from the page (module exports
for the Node harness remain; harness now reads the notes repo's JSON, and
its filled/hollow check was made structural after hard-coded counts went
stale within a day — the library grows daily). Privacy note: the notes repo
is public and auto-pushed, so the full notes were already public; the JSON
is a strict subset. Untested by machine: the push hook firing on a real
timer cycle — its halves (export determinism, commit-only-when-changed) are
tested; watch the next `graph: refresh` commit appear after a note edit.

Added 2026-09-10 — **blog posts / web pages as entries** (WebIngest.swift).
Any non-arXiv http(s) URL in the add sheet (or `--add-url`; `--peek-url` is
the no-write diagnostic) becomes a hand-keyed entry: key = host label +
URL slug ≤6 words (deterministic → idempotent adds), title/authors/date from
the page, venue = host, new `url:` + `published:` frontmatter (written only
when set — old files byte-identical; `published` feeds the (year, month) sort
tuple; `url` wins in externalURL, labeled by host). ForumMagnum sites
(lesswrong.com, alignmentforum.org, forum.effectivealtruism.org) go through
their public GraphQL API — the HTML route gets a Vercel bot checkpoint,
measured — parsing title/postedAt/user+coauthors; everything else via
JSON-LD → OpenGraph → meta tags → <title> (both attribute orders, entity
unescape, ISO/plain dates), nothing invented when undeclared (Anthropic news
page: title only, "none found" for author/date — correct). Parsers pure +
selftest'd against the captured LW API reply and fixtures; red-checked
(reversed-attr pattern, postedAt parse). Live-verified both paths via
--peek-url; the example post ingested for real (lesswrong-astra-and-fable-
still-hack-on, Dean Valentine, published 2026-09-08). Site graph re-exported:
the post is a hollow clickable "Valentine 2026" node.

Fixed 2026-09-09 — **27 papers were keyed "<id>.pdf"** (dragged-in PDFs named
by id: `normalise` passed the un-arXiv-shaped string through untouched, so no
metadata fetch, no arXiv link, no citation-edge matches — surfaced when the
label fallback printed "AI Alignment" as an author). `normalise` now strips a
trailing ".pdf"; `--repair-ids` (testable core `repairCore(fetchMetadata:)`)
re-keyed 26, fetched metadata for 29, idempotent, one batch commit; the 27th
was a true duplicate of 2605.31328, merged by hand (project tag + newer PDF
revision into the metadata-rich entry) and committed. Library now has zero
.pdf keys and zero author-less papers. Site data re-exported: 122 nodes / 711
edges, all labels "Surname Year", every arXiv node clickable. Tooltips now
format summaries — summaryHTML() (escaped; "- " lines → real <ul>, blank
lines → paragraphs, $…$ left for MathJax; typeset per node-change, content
rebuilt only when the hovered node changes) — with single-dollar inlineMath
enabled in misc.html's MathJax config, and tip-body switched from line-clamp
to a 300px height cap (clamp misbehaves over block children). Node harness:
20 checks incl. formatting over the real summaries.

Changed 2026-09-09 — **the template is now `## Summary` + `## Questions/
Comments`** (user request; five notes were already hand-written in this shape).
Existing files untouched — the change is only `Paper.template`, and both
templates keep parsing. Everything keyed on headings was retaught:
`webSummary` prefers the Summary section, then the old claim section, then
whole prose for free-form notes; a templated note without its summary exports
NOTHING — the old rule was quietly carrying the hand-written notes' whole
prose (candid Questions/Comments included, one under `verdict: garbage`)
into the committed-but-unpushed site data, and the audit of the re-export
caught it. `Paper.questions` now reads Questions/Comments and the old
confusion section alike, so the grader answers both. Also: graph labels for
the ~30 papers with no author metadata now come from the title's leading
words (skip articles/arXiv: tokens, pair short first words) instead of a bare
id — shared by GraphView and GraphExport. Website same day: wheel zoom is
⌘/Ctrl-gated with a hint overlay (plain scroll scrolls the page; trackpad
pinch = ctrl+wheel still zooms), touch only engages on a node-drag or pinch
(one finger on empty space scrolls the page, touch-action: pan-y), two-finger
pan. All selftest'd (red-checked: Summary branch and questions merge each
redden their tests); site data re-exported and diff-audited node by node —
119 summaries byte-identical, the 4 changes each explained (stray "-" gone
hollow, questions trimmed, interim user edits). Committed to the site repo
(91a6c5f), not pushed.

Fixed 2026-09-06 — **notes autosave; the template-reset data loss is closed**.
The draft lived only in memory and ⌘S was the only write path: clicking a
different paper replaced the draft (note resets to template), and any
background `refresh()` — appraisal landing, star, tag, queue — reloaded the
draft from disk over live typing. It cost the user a real note (unsaved text is
unrecoverable; anything ever ⌘S'd survives in the repo's git history). Now:
`noteEdited()` debounces a 1s `flushDraft()`; `select()` flushes before
replacing (commit on switching papers, plain write on same-id reloads);
`applicationWillTerminate` flushes; autosave writes skip the commit
(`Library.save(commit:)`) so history stays clean. `flushDraft` merges only
body+verdict onto a fresh disk read — writing the whole draft was measured
undoing a queue change that landed after the draft loaded. Tested end-to-end in
`--selftest` against a private temp library: `PN_LIBROOT` env override on
`Library.root` (getenv, set by the selftest itself before first touch), so
probes drive the real select/flush path with zero writes or commits to the real
repo — verified clean after runs. Red-checked both ways: flush removed → 4
probes fail; merge replaced by whole-draft write → stale-fields probe fails.

Removed 2026-09-06 (user request) — **in-app Claude appraisal**: no auto pass
on add (`Prefs.autoAppraise` gone), no header appraisal row, no "Ask Claude if
it's worth reading", sidebar badge shows the user's verdict only (was
`effectiveVerdict` falling back to Claude's). Kept deliberately: `appraisal_*`
frontmatter round-trip (150 files carry them; stripping would churn every
file), the "Most interesting" sort reading stored ranks, and the explicit CLI
`--appraise` / `--rank` for batch passes. The appraisal landing mid-typing was
also the likeliest trigger of the data loss above.

Added 2026-09-08 — **the reading graph on the website**. `--export-graph
<path>` (GraphExport.swift) emits the graph-window's graph — archived out,
Relations edges, deterministic ForceLayout, viridis/sqrt-citations styling — as
`window.READING_GRAPH = <json>` for narutatsuri.github.io (files:
`data/reading-graph-data.js`, `assets/reading-graph.js`, a Misc. section
between TA Experience and Writeups, tooltip CSS). Hover shows
`Paper.webSummary`; hollow circle = no summary. webSummary rule (measured, not
guessed): claim section if written; whole prose for free-form notes (79 are
the old site's imported summaries — template detection keys on the literal
"## Claim, in my words" heading, because "contains ##" withheld 26 imported
summaries that use their own headings); templated notes without a claim export
nothing — confusions/evidence/verdicts stay off the web. Real export:
123 nodes, 39 filled, 716 edges; two runs byte-identical. Verified by Swift
selftests (red-checked: body-instead-of-claim reddens 2) plus a Node harness
driving the real data file through the renderer's exported pure functions
(scratchpad graph-site-test.js — scratchpad is ephemeral; recreate from this
description if needed). Longest summary is 6.4k chars → tooltip clamps at 16
lines (CSS line-clamp). Website changes left UNCOMMITTED for the user to
review and push — pushing publishes the summaries.

Rewritten same day after "holy shit that's ugly / nothing can be seen": the
static SVG became a **canvas port of the app's GraphSim** — constants line for
line (k=105, damping 0.72, alpha floor 0.0025, drag caps 14/26, soft bounds
0.62·min(w,h) with positional correction), dark #17181c surface, app radii
(7–26, mass=r/8 recovered from the export's 5–16 scale), viridis fills, hollow
ring = no summary, labels collision-claimed by citation order, hover dimming,
cursor-anchored wheel zoom, node dragging with throw, pinch on touch,
double-click reset. Export positions seed the sim so the page opens settled.
Section header is just "Paper Notes", no explanation text (user request).
Verified: Node harness runs the real sim 800 steps — settles at the alpha
floor, all bodies finite/in bounds/still, drag semantics exact; a settled
frame rendered to SVG→PNG (qlmanage) and inspected by eye — legible, looks
like the app. DOM events remain the user's eyeball check.

Fixed 2026-09-06 — **the window can be narrow now**. The floor was 980pt of
explicit `minWidth` plus three genuine width demands stacked behind it: the
editor split's rigid `frame(width: 520)` slab, the fixed-size verdict picker
bidding its full width into the window minimum, and the sidebar's frame floor.
Now: explicit floor 480; the split watches its real width
(`onGeometryChange`) and the left pane yields, keeping the right pane ≥120 so
the divider handle never leaves the window; the verdict and project rows report
no minimum and clip at the right edge instead; the sidebar uses
`navigationSplitViewColumnWidth(min: 190)`. Measured by the new gated
`PN_WINTEST=1` probe: contentMinSize 980→480, and after a programmatic shrink
to 500pt the editor text view (151pt) and preview web view (61pt) both survive
inside the window. Red-checked: with the 980 floor restored, setFrame(500) is
actively re-inflated back to 980 and the probe fails. The probe's 700pt
threshold sits between old and new so it cannot pass vacuously. A paper can carry `project: <name>` in its
frontmatter (only when set — untagged notes stay byte-identical); `projects.txt`
at the library root maps names to one of eight palette colours, hand-editable
and versioned like `trusted-authors.txt`. Sidebar rows show a dot, the header
shows a chip under the title, and the chip/context-menu assign, clear, or
create (small sheet, least-used colour preselected). A tag whose project left
the registry renders grey rather than vanishing. 2026-09-19: **Manage Projects…** sheet (bottom of every project menu, shown
once a project exists) — recolour by clicking a swatch (`AppModel.recolour`,
case-insensitive name match, writes projects.txt + commits) and delete
(`deleteProject`: untags its papers via `assign(project: nil)` in one batch
commit, removes the registry line, commits; the alert states the count from
`papers(inProject:)`). Untag-on-delete is deliberate: a hand edit to
projects.txt leaves grey orphan dots, an in-app delete cleans up. Tested
through AppModel in the temp library; red-checked (dropping the untag
reddens "untagged, not deleted"). Added later the same day: a
sidebar filter (under the sort picker, only shown once projects exist) —
all / one project / "No project"; pure `Projects.papers(_:matching:)`, tested;
its first red-check caught a redundant `isEmpty` branch (`compare` against ""
already matches only untagged papers), which was then deleted. Search and the
queue deliberately stay unfiltered. Verified: parse/serialise and
round-trip in `--selftest` (red-checked); `--snapshot <png> 700 200 chip`
renders the header offscreen and counts chip-fill pixels (889; red-checked via
an untagged probe). Header height grew by exactly 24 pt on all 150 papers —
uniform, so no new instability; the pre-existing 32 pt spread from 1-vs-2-line
titles is unchanged and still reported UNSTABLE by `--snapshot x 1200 0`.
Gotcha for pixel probes: compare `NSBitmapImageRep.colorAt` components raw —
converting through `.usingColorSpace(.sRGB)` re-applies a profile and turned
848 byte-exact pixels into zero matches.

137 papers. 75 carry notes imported from the user's old `paper_summaries.html`
(recoverable from the website repo's git history at `2444ef0`, in
`~/Website/narutatsuri.github.io`). Imported notes are marked with an `Imported
verbatim` comment and use the user's own template (`## Thoughts`, `## Method`),
not the app's.

**It does not have Frontier's blank-pane disease** — checked 2026-08-11 with a
paper actually open, which is the only way the question means anything: with
nothing selected the app shows its empty state and a broken preview and a
working one look identical. `PN_SELECT=<id>` was added for this and opens
straight onto a paper. The KaTeX preview column renders in full.

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

### Lanes

New 2026-09-15 — **Lanes** (~/Developer/Lanes, /Applications/Lanes.app,
bundle id local.lanes, regular Dock app). A project progress log: one
fixed-width (380pt) column per project on a horizontally scrolling canvas,
"+ New lane" column at the right (⌘N appends and scrolls to it). Each lane is
`~/Library/Application Support/Lanes/<Title>.md` with NO frontmatter — the
title is the filename, so the folder reads like the board and a lane copies
straight into a report; `lanes.json` beside them carries order + rendered
flags; deleted lanes go to `.trash`; a `.md` dropped into the folder becomes
a lane on reload. Rename = edit the title + return (sanitised: `/` `:` → `-`;
clashes numbered case-insensitively; file moved, id stable). ⋯ menu: move
left/right, show in Finder, delete (confirmed). Eye/pencil toggles Jot's
rendered view (marked + KaTeX). **The editor stack is Jot's by symlink**:
Sources/Lanes/Shared/{Editor,Attributed,Highlighter,Math,Theme,
MarkdownPreview,Sticky}.swift → ../../../../Jot/Sources/Jot/ — one source of
truth, SwiftPM compiles through the links (verified), rsync -a in sync.sh
preserves them and they resolve inside the apps mirror too. build.sh copies
../Jot/Resources/web for KaTeX. Menu.swift is Lanes' own (Jot's is
app-specific) with the identical Format section (jotBold… selectors).
Autosave: 0.6s debounce, write looks the lane up at fire time so a rename
mid-debounce lands under the new name; flush on window close and quit; a
blank lane keeps its file (a project column, not a scratch buffer). Paper is
StickyColour.grey under Jot's Theme; ⌘⇧D dark mode. NSHostingView
sizingOptions = [] (Frontier lesson). Verified: 22 selftests in a private
LANES_ROOT temp folder (round-trip, debounce firing via RunLoop, titles as
filenames, order/rendered persistence, dropped files, trash, Jot parser
present; red-checked: removing the debounce dispatch reddens exactly the
autosave test), and LANES_WINTEST=1 reads the live view tree: 4-lane fixture
→ 1664pt canvas > 1180pt window, 4 JotTextViews each 670/720pt tall. Not
machine-verified: trackpad horizontal scrolling over a column's own vertical
text view (AppKit should forward the unhandled axis; the user's swipe will
say), and the Format shortcuts reaching the focused column (same responder
path as Jot). Repo initialised, nothing committed — the user's call.

Same day — **per-lane widths by dragging**: `ResizeHandle` (9pt grab strip,
1pt drawn line) between lanes; drag resizes the lane on its left, live width
held in board state during the drag and committed once via
`LaneStore.setWidth` on release; double-click resets to `Lane.defaultWidth`
(380); `Lane.clampWidth` 240–1200; the index writes `width` only when
non-default. Selftests: default, clamp, index minimality, relaunch survival
(red-checked: dropping the width from the index reddens the survival test);
LANES_WINTEST now checks the canvas is the *sum* of lane widths and that
each on-screen column matches its lane's width (fixture [380,560,380,300] →
exact). Icon redrawn: three pastel cards (Jot's yellow/blue/green) with
header bands and text lines on a dark gradient ground — viewed at 512px
before shipping.

Same day — **"never loses its info" hardening** (user: "that would be
catastrophic"). The debounce is gone: `LaneStore.update` writes the file
synchronously and atomically before returning — tested as "on disk before
update() even returns", red-checked (removing the write reddens it).
`read()` returns nil for a file that is not UTF-8 text and `reload` skips it
with a printed note instead of showing an empty lane — the Paper Notes
failure mode where a failed read masquerades as emptiness and the first
keystroke overwrites real content; tested with a non-UTF8 `Binary.md` left
byte-intact. `.history/<Title>-<stamp>.md` keeps the previous on-disk
version before an overwrite, at most once per `historyInterval` (600s,
settable — the test sets 0) per lane, never for empty files. Delete still
moves to `.trash`. Remaining loss surfaces, stated: an external editor
writing the same file while the app has the lane open will be overwritten
by the app's next keystroke in that lane (the app is the writer); and the
column views are non-lazy so no stale-state re-creation path exists today —
if the board ever goes lazy, re-audit.

Same day — **threads (sub-columns)** per the user's choices: folder per
project, horizontal sub-columns inline under one spanning project header;
the split default is "existing text becomes thread `Main`" (they said "IDK
what is best" — rename is one click). Model: `Lane.threads: [Thread]`,
`isSplit` ⇔ folder `<Title>/` of `<Thread>.md`; the index entry carries
`threads: [Entry]?` exactly when split (`file` is "Title" not "Title.md").
Store: `addThread` (splits first — moveItem, never copy; red-checked: a copy
reddens "the single file moved"), `updateThread` (synchronous write +
per-thread history), `renameThread`/`moveThread`/`setThreadWidth`/
`setThreadRendered`, `deleteThread` (refuses the last one), `unsplit`
(one thread left → back to `<Title>.md`, folder removed), lane
`rename`/`delete` handle folders (trash keeps the folder), `reload`
reconciles folders (hand-dropped folder → split project; empty folder
ignored; dot-dirs are the store's). Board: `NoteColumn<Extra>` is the one
note view (lane or thread; differs only in callbacks and ⋯ items),
`ProjectColumn` = header + HStack of NoteColumns with ResizeHandles,
`liveWidth` keyed by lane-or-thread id, `commitWidth` routes to the right
setter. Probe now flattens lanes into columns (thread widths) and checks
on-screen widths per column: fixture [300 | 380,520 | 380] exact. 40
selftests.

Same day — **project text above and below the threads**, and the drag fix.
The "Main" thread is gone: splitting moves `<Title>.md` → `<Title>/_above.md`
(the project's words stay above the threads), and `_below.md` is a second
area under the thread row — `Lane.text`/`rendered` = above,
`belowText`/`belowRendered` = below; index entries carry `belowRendered`;
underscored files are never threads; a hand-made folder without them is an
empty area, not a missing project. Fixed heights `Lane.aboveHeight` 150 /
`belowHeight` 130 (`NotePane`: title-less editor with a corner render
toggle). Any thread can be deleted now; deleting the last one auto-folds
the project back to a single file when below is empty (red-checked:
removing the fold reddens its test), otherwise the folder stays with zero
threads (placeholder "Add a thread" in the row, project keeps
defaultWidth+9) and ⋯ offers Merge Back, which joins above + "\n\n" +
below. **Drag jiggle**: `DragGesture(coordinateSpace: .global)` — the
handle moved with the column it resized, so in its own space every tick
shifted the ruler under the finger; global space is fixed for the drag's
duration. Probe classifies note areas by their known heights (a ratio
threshold failed: threads landed at exactly half the window) and checks
lanes tall / threads = window − areas − chrome: fixture heights
[670, 360, 360, 670] ✓, areas [150, 130] ✓. 44 selftests. Not
machine-verified: that the jiggle is actually gone under a hand — the
diagnosis is confident, the feel is the user's.

Same day — **separators, project edge, proportional shrink.** User: "the
line to the right seems to be gone" for a split project, and "remove the
little spacing between the top bar and the vertical lines". Added
`LANES_SNAPSHOT=<png>` (WindowCheck.scheduleSnapshot: contentView
`cacheDisplay` → PNG; no screen-recording permission; web views do not
paint, editors/headers/lines do) and LOOKED: the project had no full-height
edge line (its only line was the thread row's trailing handle, spanning the
row only), and every separator sat in a 9pt transparent grab strip, so
header bands had a notch either side of every line. Fix: `ResizeHandle` is
now a real 1pt line in layout with the 9pt grab zone as an `.overlay` +
`.zIndex(1)` (SwiftUI hit-tests overlays beyond bounds; zIndex keeps it
above the neighbour column); ProjectColumn draws handles only *between*
threads; the board places a full-height handle at the project's edge, and
that handle scales all threads together — `Lane.scaled(_:toTotal:)` (pure,
clamped per thread; red-checked) → `LaneStore.setThreadWidths` (one index
write); `liveWidths: [String: CGFloat]` replaces the single live tuple.
Zero-thread project width = defaultWidth (no phantom +9). Snapshot after:
full-height edge, continuous bands, inner line confined to the thread row.
Probe still exact ([300 | 380,520 | 380]); 47 selftests.

2026-09-22 — **"titles got lost and are now Untitled."** Diagnosed from
evidence, not the code first: `.history/` snapshots are named by the title
at snapshot time, and every snapshot of the affected lanes back to their
creation (Sep 16/17/19) was already "Untitled…" — the names had *never*
reached disk. Cause: both title fields (ProjectColumn header, NoteColumn
header) committed a rename only in `.onSubmit` (Return); typing a name and
clicking away kept the field showing it while the file stayed Untitled.md,
until a relaunch/column rebuild showed the truth. Fix: `@FocusState`
`editingTitle` on both fields; commit on `.onChange(of: editingTitle)` →
false, on `.onChange(of: title)` while unfocused (measured: the SwiftUI
binding delivers the final text *after* focus has left, so the focus
handler alone still read the old name and the first fix failed its own
probe), and on `.onDisappear`; a failed rename now reverts the field to the
model title instead of showing a fiction. New live probe
`LANES_RENAMETEST=1` (fixture lane "Alpha"): makes the NSTextField first
responder, types via the field editor, `makeFirstResponder(nil)` — the
click-away — then checks store + disk; red-checked: Return-only code fails
all three checks. Content was never at risk (files intact; the user must
retype the names). The lone "Main.md" thread in the Untitled 2 project is
from the pre-`_above` split design and is harmless.

2026-09-21 — **images by drag and drop**, shown in both modes. The
construct lives in Jot's shared editor stack (so Jot has it too):
`Highlighter.Kind.image(alt:path:)` from `![alt](path)`, a *verbatim*
pattern placed with the maths ones so the link pattern cannot read the
inside as a link; `Attributed` gets `ImageSpec` (Equatable, like MathSpec),
`imageKey`, `imageRun` (one attachment character), serialisation back to
`![alt](path)`, `imageResolver` (static hook: default = the path as given;
Lanes installs one) and `imageMargin`. **Fit-to-column**: `ImageAttachment`
overrides `attachmentBounds(for:proposedLineFragment:…)` — width =
container width − 2×lineFragmentPadding − 2×8, aspect kept, never above
natural size (a small icon is not blown up), re-queried on every layout so
a dragged column re-fits; the override is nonisolated, hence
`imageMargin` is a `nonisolated static let`. Missing file → alt+path
drawn in place (⚠︎), like the maths placeholder. `stylingMatches` compares
imageKey. **Drop**: `JotTextView.imageDropHandler: ((URL) -> String?)?`
(nil = default AppKit behaviour, so Jot is unchanged);
draggingEntered/Updated answer .copy for image files
(`urlReadingContentsConformToTypes: [UTType.image]`),
performDragOperation inserts the returned links at
`characterIndexForInsertion` via insertText — the ordinary typed-text
path, so undo/binding/collapse all apply. `MarkdownEditor.onImageDrop`
forwards it. **Lanes** `ImageStore`: `_assets/` (store-owned, visible),
`adopt(url, depth:)` copies to `<stem>-<stamp>[-n].<ext>` and returns the
link with `../` per folder depth (lane 0, thread/areas 1); `locate` tries
absolute → `_assets/<basename>` → root-relative, so split/unsplit never
breaks display in-app (export depth is right at write time; a later move
is the documented limitation); `inlined(markdown)` swaps each link's path
for a data URI (mtime-keyed cache) because the shared WKWebView may only
read the bundle directory — marked renders `![](data:…)` unchanged. Verified:
Jot 199 selftests (image kinds, 4 byte-identical round-trips incl. inside
==…== and **…**, attachment placeholder, fit 600×300→354×177 in a 380
container and no upscale at 1000; red-checked: `return bounds` first
reddens both fit tests); Lanes 62 (adopt/depth/no-collision/resolve-by-
name/fit 234×117 in 260/round-trip/inline data URI); LANES_SNAPSHOT of an
800×400 PNG in a 300pt and a 620pt lane — looked at: fitted, margins,
aspect. Not machine-verified: the actual drag gesture (AppKit drop
plumbing) and the rendered (web) view showing the inlined image — the web
view does not paint in the offscreen snapshot.

2026-09-16 — **the vault** (user: hide a column/thread but preserve it —
"deleting the accumulated thread is too wasteful"). `_vault/` inside the
lanes folder: underscore-prefixed so the store treats it as its own (reload
now skips top-level `_*` as well as `.*`; uniqueTitle ignores them),
visible so it can be browsed/exported. `vault(laneID)` moves the file or
whole folder to `_vault/<Title>[.md]` (numbered on clash via
`uniqueName`), drops it from the index; `vaultThread` moves the thread to
`_vault/<Project>/<Thread>.md` and reuses the last-thread fold rule;
`vaulted()` lists entries ("Title" / "Title/"), sorted by bare name — the
first cut sorted with the marker on and "Big 2/" beat "Big/" (space <
slash), caught by the test; `restore(name)` moves it back under a unique
title and appends a lane (folder → folderLane). Menus: ⋯ "Vault" / "Vault
Project" / "Vault Thread"; File → "Restore from Vault ▸" is an NSMenu with
AppDelegate as NSMenuDelegate, rebuilt in `menuNeedsUpdate` from the vault
each time it opens ("Nothing in the vault" when empty); "Open Vault
Folder". Red-checked: vault copying instead of moving reddens its test. 55
selftests. Not machine-verified: the dynamic submenu populating on open
(NSMenuDelegate path — standard, but the user's click).

### Jot

Markers vanish as you type: the buffer holds styled text, the file holds
`**bold**`. `Attributed` converts both ways; the round-trip is tested
exhaustively because a lossy serialiser eats what was written.

Added 2026-09-06 — **never-delete flag**. A lock button in the bar (⌘L) marks a
sticky important: `important: true` in the frontmatter. While on, the trash
button is absent, ⌘⌫ is inert, and — the actual guarantee — `Store.delete()`
refuses and the blank-note auto-bin writes the file instead of trashing it, so
no caller can delete it. The field is written only when true, so every
pre-existing file still round-trips byte-identically. All four guards are
red-checked in the selftest; the one thing not machine-verifiable is the SwiftUI
button actually disappearing on screen (same GUI limit as always).

Open:
- **⌘Z reverts the whole typing burst**, not just the marker collapse.
  breakUndoCoalescing, explicit grouping and deferring past the event were all
  tried; none separates them. Documented in `Editor.swift`.
- **There is no way to colour text, by design** — `Theme.ink` is fixed (black on
  light paper, `#F2F0EA` in dark) because "a note is a physical object here, and
  its ink does not change when the OS switches to dark". What is colourable: the
  paper, ⌘1–⌘6 over six shades, and a highlighted run via ⌘⇧H, which writes
  `==…==` into the file. If coloured text is ever wanted, the question to settle
  first is how it is *stored*: this app's whole premise is that formatting is a
  function of the text, so it needs a marker syntax (`==` is already a
  non-standard extension, so that door is open) rather than attributes attached
  to a range — which is precisely the Stickies behaviour the README rejects.

Fixed 2026-08-11 — **emphasis around an equation**. `==energy $x^2$ here==` used
to produce no highlight at all and leave its `==` on screen as literal text. It
turned out to be four separate faults stacked, which is why it looked like a
flat "you cannot do that" rather than a bug:

1. `Highlighter` rejected an inline span that *overlapped* a verbatim one. Maths
   claims its range so nothing styles inside it — right, the `*` in `$a^*$` is a
   superscript — but an emphasis that merely *wraps* an equation also overlaps
   it, so the whole span was discarded. Now it is rejected only when it straddles
   one (`==a $b== c$` still goes).
2. The highlight pattern was `==([^=\n]+)==`, forbidding `=` in the content. That
   was there to stop `==a== and ==b==` reading as one span, but it also meant no
   highlight could contain an equals sign — so `==a = b==` failed too, with
   nothing to do with maths. Lazy matching handles the run-on case instead.
3. `Attributed.make` short-circuited on maths and never read the style, so the
   equation carried no highlight and the markdown written back out broke into
   two highlights around a bare `$x^2$`.
4. `jotToggle` deliberately skipped attachments — "you cannot embolden a
   picture" — but the style is also what says where the markers go, so ⌘⇧H
   dragged across an equation produced `==energy ==$x^2$== here==` in the file.

And a fifth found while verifying, unrelated to maths and **pre-existing**:
`inlineMarkdown` wrapped every run in its whole style set, so any nesting
doubled the outer markers — `==a **b** c==` was written back as
`==a ====**b**==== c==`, and likewise for a link inside a highlight. Markers are
now opened and closed as the style changes. That one was corrupting files on
save and nothing caught it; the round-trip corpus now covers nesting.

**The part that could not be reasoned out.** Setting `.backgroundColor` on the
attachment looked correct and was not: an equation is a KaTeX render captured as
an *opaque image painted with the paper colour*, so it covers any background
drawn behind it, and the highlight came out with a rectangular hole in it.
Pixel-checked — modal colour behind the equation was the bare paper (53,53,48).
The highlight has to go *into* the render, so `Attributed.mathPaper` flattens the
tint onto the paper and hands that to the renderer, and `fillMath` and
`jotToggle` both use it or a re-render brings the hole back. After: (111,101,62)
against a predicted (114,102,56).

Fixed 2026-08-21 — three typing reports, each reproduced headlessly by driving
a real NSTextView through the real Coordinator before touching anything:

- **The second letter of every heading came out unstyled.** When `# T`
  collapses, the collapse moves the caret while its re-entry guard is up, which
  swallows the selection callback that refreshes `typingAttributes` — so the
  next keystroke inserts with the stale plain ones. Two-part fix, deliberately
  redundant: the collapse now refreshes typing attributes explicitly
  (prevention), and its early-out compares *styling* rather than just the
  string (repair) — "Ti" round-trips to "Ti" whether or not the `i` knows it
  is in a heading, so a string comparison could never see the damage. Reverting
  either half alone stays green because the other heals it; the red-check has
  to revert both.
- **A collapsed heading could never be reformatted.** Once `## Title` is
  styled the hashes are gone from the buffer, so a typed `#` became literal
  text (`## #Title` in the file) and the level was stuck. First fix made `#`
  increment the level by one; the user corrected the semantics the same day:
  **the marker you type is the level you mean, absolutely** — `# ` makes it a
  title whatever it was, `### ` jumps straight to h3, and down works as well
  as up. Implemented in the collapse (`Coordinator.relevel`): the gesture
  serialises as old-marker-then-typed-marker (`## # Title`) and the old one
  gives way. The trailing space is the trigger, same as every marker, so a
  heading whose text starts with `#1` stays literal — and a *file* containing
  `## # Title` still round-trips byte-identical, because the rewrite lives in
  the editor's collapse, not in the file format (pinned in the corpus).
  The way *out* is ⌫ at the very start of a heading line: the marker collapsed
  so there is nothing visible to delete, and that press deletes the title-ness
  — only the next one merges lines. `Coordinator.removeHeading`, same
  round-trip shape as the collapse; ⌫ everywhere else is untouched, tested.
- **⌃⌫ deleted everything before the cursor.** Now deletes the previous word,
  same as ⌥⌫. One `keyDown` intercept on keycode 51 + control.

Fixed 2026-08-11 — **the uncloseable slab**. See the offscreen-helper-window
gotcha. `MathRenderer`'s measuring window is now transparent, mouse-transparent,
out of Exposé and ⌘-tab, and declines the frame constraint; `JOT_MATHWIN=<x>,<y>`
parks it somewhere visible so the claim can be photographed. The
`constrainFrameRect` override is kept but is **not** the proven fix — a
borderless window is not constrained by the direct call, and whether AppKit
routes its own repositioning through that method could not be shown either way.
`alphaValue = 0` is what actually holds.

Added 2026-08-12:
- **Notes snap to each other's size when resized.** `Snap.swift` — pure
  arithmetic over rectangles, because a live drag cannot be photographed
  mid-resize. Two kinds of snap are weighed together and the nearest wins: the
  neighbour's own width/height (what makes a column of notes read as a column)
  and the moving edge landing on a neighbour's edge. Only during a live resize,
  so restoring a saved frame at launch is not silently rewritten; only against
  notes on the same display; never below `minSize`. The anchor — which corner
  the drag is pinned to — is read once from the pointer when the drag starts,
  because read per-step it flips as the pointer crosses the midline. Thirteen
  tests. **The arithmetic is tested; the live drag is not** — driving a real
  resize needs assistive access this process does not have.
- **`~a~` strikes out**, as well as `~~a~~`. Two guards do the work: `(?<!~)…(?!~)`
  keeps it out of the inside of `~~a~~` (the trick the single `*` uses against
  `**`), and refusing whitespace just inside the tildes stops
  "~/Developer and ~/Documents" striking out everything between two home
  directories (the trick the `$` pattern uses against "$5 and $7"). Both
  spellings are written back as `~~`, which is a normalisation and is tested as
  one rather than left to be discovered.
- **The menu bar has "Show All Stickies" and "Hide All Stickies" as two items.**
  It was one item that renamed itself, so the moment a single note was on screen
  it read "Hide All" and there was no way to bring the others back — which is
  the one thing that menu is for. Hide All is greyed rather than removed when
  nothing is showing. Checked by building the menu and reading it, since the app
  is LSUIElement and driving a status item needs assistive access.

Still true: **bold and italic do not reach the glyphs.** `**$x$**` round-trips
exactly and emboldens the words around it, and the equation stays upright,
because a font trait cannot reach inside a picture. Doing better means asking
KaTeX for it.
- `.trash` was swept on 2026-08-11: 40 development fixtures deleted ("say
  **this**" ×20, "a real note with **content**" ×8, "note text pasted" ×6,
  "# Math test" ×3, "## TEst" ×2), 9 kept, 196 KB → 36 KB. The 9 are not junk
  and should stay: four snapshots of "check whether the rank pass is stable
  across runs", four of a note about a tmux/Codex annoyance, and one that says
  "keep this". Worth knowing if this ever gets swept again — the previous note
  here called all 49 test files, and it was wrong.

---

## Things deliberately not done

- **Not committed**: `~/Developer/Jot` has a dirty working tree. Its content is
  in this mirror; its own history is stale. (`~/Developer/PaperNotes` got a
  catch-up commit on 2026-08-11; `~/Developer/Frontier` has no repo of its own —
  the mirror is its only history.)
  Jot alone had no `.gitignore`, so `build/` (52 files) and `.build/` (273) were
  tracked — which is a way for the duplicate-app problem to come back, since a
  `git checkout` would restore a launchable `build/Jot.app`. It now has the same
  `.gitignore` as the others, and `git rm -r --cached build .build` is **staged
  but not committed**: 325 deletions sitting in the index. Committing is the one
  step left, and it is the user's call.
- A screen-shading app (`Veil` — menu-bar toggle, per-display ScreenCaptureKit
  brightness measurement driving a click-through black overlay) was built on
  2026-08-15 and deleted at the user's request six days later: it did not work
  for them. Gone from disk, from /Applications, from the build scripts, and from
  TCC; unlike Deadlines it was never committed, so there is no history to
  recover it from. If the idea ever comes back, the parts that were measured and
  worked: per-display capture at 5fps costs 0.48ms/frame; a window must be
  created *before* the content snapshot that builds its own exclusion list, or
  the veil measures its own dimming; and the envelope has to be stepped by a
  timer because ScreenCaptureKit stops delivering frames when the screen goes
  static.
- The user asked for a conference-deadline app (`Deadlines`) and then asked for
  it to be deleted. It is gone from disk and from this repo; the git history
  still contains it if it is ever wanted back.

---

## How the blank-pane hunt actually ended

Kept because the *shape* of the mistake is worth more than the fix, and because
anyone reading the git history will find a session's worth of confident,
carefully-measured, wrong conclusions.

The symptom was real: the reading pane showed nothing. One real cause was found
and fixed — a window whose frame changes between creation and its first
compositor commit never composites out-of-process layers again on this macOS
(Darwin 25.5.0), which is why `win.center()` and `setFrameAutosaveName` are both
avoided at birth in `AppDelegate.makeWindow`. That fix worked.

Everything after it — "there is a second poisoner inside ContentView",
the `NavigationSplitView` and materials being eliminated, the `FRONTIER_BARE`
bisection ladder — was chasing a measurement artifact. The captures were taken
of a window sitting behind the terminal, and an occluded WKWebView does not
draw. The probe windows all used `orderFrontRegardless()` and so were never
occluded; the real window used `makeKeyAndOrderFront` on an unactivated app and
always was. So every probe painted, the real pane never did, and the difference
looked like it was in the content. It was in which window was in front.

What would have caught it sooner: the probes and the subject were not launched
the same way. When a control and a treatment differ in the thing being measured,
check that they do not also differ in how they are observed. The single-variable
test that settled it took two minutes once it was asked — same build, same
window, activate or don't: 8/8 blank, 2/2 painted.

Also worth keeping: the pixel-count check reported a perfectly-painted pane as
blank, because the threshold assumed a light appearance and the machine is in
dark mode. A measurement instrument that can only fail in one direction will
eventually tell you what you already believe.

The same shape turned up again the same day, in the syllabus work: the recorded
diagnosis was "JS-heavy pages scrape thin", the planned fix was to render them
in a web view, and the fix was built before the premise was measured. Rendering
turned out to help one page in six. What was actually wrong was a URL that had
started redirecting to cleartext http, and another pointed at a landing page.
Both were visible in thirty seconds of `curl -w '%{url_effective}'`. Measure the
premise, not just the result.

---

## One thing about working with this user

They notice when a claim is not backed. Several times in the session that
produced this file, a "fix" was reported that had not been verified, and each
time they caught it. The habit that worked: state what was measured, state what
was not, and when something is a guess, say it is a guess.
