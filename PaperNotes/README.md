# Paper Notes

Reading notes for papers, with a citation graph as the spine. Notes are markdown in
a git repo you own (`~/paper-notes` → `github.com/narutatsuri/paper-notes`); the app
is a lens over those files, never their owner.

Built 2026-08-04.

## Why this shape

The problem was not capture. Capture had already been built three times:

- **Zotero** — 306 papers, 49 notes, then abandoned. Items added per month:
  `2025-12: 179 → 2026-01: 51 → 02: 38 → 03: 12 → 04: 26 → nothing after 13 April.`
- **Obsidian** — a vault registered in December, dormant.
- An **AI summary pipeline** — a careful rubric (GOLD/SOLID/MIXED/THIN/GARBAGE,
  "if a value is not in the paper write *not reported*") that produced 80 summaries
  for 88 papers, and works.

306 captured papers, and still "I forget I even read it." **What was missing was
anything that brings a paper back.** So the design centres on the relation graph: a
reason to return, which grows as you read. Capture tools decay because nothing there
ever gets denser.

The summaries stay useful for triage — deciding what to read. They are deliberately
not the note.

## The citation graph, and why it comes from PDFs

A connectedpapers-style graph needs reference lists. The free APIs do not have them
for the papers actually being read:

| Paper | OpenAlex `referenced_works` |
|---|---|
| GPT-3 (2020) | 127 |
| Geometry of Truth (2023) | **0** |
| `2412.04984` (Dec 2024) | **0** |
| `2510.23966` (Oct 2025) | **0** |

Reference lists exist only for older published work; every recent arXiv preprint
returns nothing. Semantic Scholar *does* index preprint references but rate-limits
unauthenticated callers (`429`).

So references are extracted from the PDFs, via PDFKit, with no dependency and no API.
Measured over 82 AI-safety PDFs: **median 19 references per paper, zero papers
yielding none, 1,911 edges total.**

One trap worth recording: matching only the literal `arXiv:` form finds a small
fraction of citations, because many papers cite by URL. The pattern must also accept
`arxiv.org/abs/…` and `arxiv.org/pdf/…`. That single fix took median references from
1 to 19.

OpenAlex is still used, but **for metadata only** — title, authors, year, venue —
which it returns reliably even when references are empty.

## Edges

| Kind | Meaning | Weight |
|---|---|---|
| `cites` / `citedBy` | one paper's bibliography contains the other | 1.0 |
| `coupling` | shared references — the connectedpapers signal | 0.7 × saturating |
| `topical` | title term overlap, minus field-wide stopwords | 0.3 × saturating |

Coupling saturates at 12 shared references rather than scaling linearly: 40 shared
refs is not four times more meaningful than 10, it mostly means both bibliographies
are long. Each pair of papers yields one relation — the strongest reason wins — so
the panel reads as a list of papers, not a list of reasons.

## The reading loop

1. Download a PDF.
2. In Finder, right-click → **Services → Add to Paper Notes** (or *Open With → Paper
   Notes*, or drop it on the window). All three land in `AppModel.ingest`.
3. The PDF opens in Preview, references are pulled from it, metadata from OpenAlex,
   and the notes window moves to a display Preview isn't using.
4. Write. The right pane renders as you type.

`LSHandlerRank` is `Alternate` on purpose — Preview stays the default PDF handler,
because reading happens there and this app only wants the file.

With **three displays** attached, no automatic arrangement is right, so
`placeNotesAwayFrom` only moves the window when it would otherwise share a screen
with Preview. It finds Preview's screen through `CGWindowListCopyWindowInfo`, which
needs no Accessibility permission. `⌃⌘D` moves the window on manually.

## The note

Edited as **one markdown document** with the prompts as headings, not as separate
fields. Five text boxes cannot host LaTeX or a live preview, and "just drop down
notes" is not a form. The file format is unchanged either way — the headings are
still parsed for the section text.

Markdown and math render live in the right pane: **marked** for markdown, **KaTeX**
for `$…$`, `$$…$$`, `\(…\)` and `\[…\]`. Both are bundled into the app (536 KB
including fonts) rather than loaded from a CDN, so the preview works offline.

One trap: math is extracted and stashed *before* markdown runs. Left to itself,
marked mangles TeX — `a_b` becomes emphasis and `\\` disappears. The round-trip test
covers exactly this, asserting a body containing `\epsilon_{\text{miss}}` and a
display block survives byte-identically.

Five prompts, chosen because a summary structurally cannot answer them for you:
the claim **in your own words**, what evidence actually convinced you, what would
have to be true for it to be wrong, **what you did not understand**, and free
connections. The fourth is the one worth having — confusion is where the next paper
comes from — and it is the field no summarizer will ever write.

Verdicts reuse the GOLD/SOLID/MIXED/THIN/GARBAGE scale from the existing summary
rubric, so the two systems share a vocabulary instead of inventing a second scale.

## Files

| File | Role |
|---|---|
| `Paper.swift` | the model and its markdown round-trip |
| `PDFRefs.swift` | citation extraction via PDFKit; id normalisation |
| `Relations.swift` | edge kinds, scoring, whole-library graph |
| `Library.swift` | the git working tree, plus a thin git CLI wrapper |
| `Metadata.swift` | OpenAlex lookup — metadata only, deliberately not references |
| `MarkdownPreview.swift` | WKWebView preview; bundled KaTeX + marked |
| `Reading.swift` | opens the PDF, keeps the two windows on different displays |
| `GraphLayout.swift` | Fruchterman–Reingold, pure and deterministic |
| `GraphView.swift` | the Canvas graph window (⌘G) |
| `Importer.swift` | `--import`, headless cataloguing |
| `SelfTest.swift` | `--selftest` |

## Git

Commit per note (instant, never fails); push on a 120-second timer (needs the
network, should not sit between you and the next thought). Auth is the `osxkeychain`
helper over HTTPS, the same path the existing website repo uses — the SSH key on this
machine is rejected by GitHub and is not involved.

**Pushing is off by default.** The notes record what you did not understand and
candid verdicts on other people's work. Publishing that is a decision to make
deliberately, so the toggle sits in the status bar and starts off.

## Self-test

```sh
"/Applications/Paper Notes.app/Contents/MacOS/PaperNotes" --selftest
```

Writes nothing. Two halves:

**Asserted** — the markdown round-trip (a lossy one would silently eat notes,
including the TeX-mangling case above), id normalisation, and the graph scoring
against *synthetic* papers with known citation relationships: a direct citation
outranks weaker signals, the reverse edge appears on the other paper, shared
references make an edge without a citation, an unrelated paper gets none, and edges
are deduplicated.

**Observed, not asserted** — reference extraction and edge density over whatever PDFs
are actually on disk.

That split exists because an earlier version asserted edge density over
`~/Downloads/ai_safety_papers`, and broke the moment those folders were reorganised —
7 unrelated PDFs legitimately produce almost no edges. It was testing the reading
pile, not the code. Density is a property of what you read; correctness is not.

## Not built yet

- **Resurfacing.** The graph is the substrate for "you read this before, and it
  connects" — currently shown at save time and in the graph, but nothing brings a
  paper back weeks later of its own accord. This is the piece that actually attacks
  forgetting.
- **Reference recall.** Extraction only matches arXiv ids. Papers cited by title or
  DOI alone are invisible to the graph, which is part of why a young library looks
  sparse.
- **Backlog import.** 88 + 37 PDFs and 306 Zotero items are untouched by design;
  the loop should prove itself on new reading first.

## The graph window

`⌘G` opens it in a window of its own — with three displays it earns a screen next to
the PDF and the notes. Nodes are papers, filled where a note exists and hollow where
the paper is only catalogued; radius grows with degree. Selecting a node dims
everything not adjacent to it, and clicking one selects that paper in the main window.

Layout is Fruchterman–Reingold, seeded from a hash of the arXiv id rather than a
random generator. That matters more than it sounds: a graph that rearranges itself
every time you open it is one you can never learn the shape of.

**A caution on reading it early.** With seven papers the graph has two edges, and that
is honest — those papers genuinely share few references. The graph earns its keep once
the library has topical density, not before. Sparse output is not a bug; it is the
library telling you what you have actually read.

## Bulk import

```sh
"/Applications/Paper Notes.app/Contents/MacOS/PaperNotes" --import ~/Downloads
```

Catalogues every PDF whose filename carries an arXiv id — same pipeline as Finder,
minus opening each one for reading. Imported papers hold no note, so they appear as
"catalogued only" until you read them.

## Seeing the layout without screen recording

Screen recording is not permitted on this machine, so `screencapture` fails and every
layout bug — the title overlapping the note, the editor pushed off the top — was
invisible to every other check. `ImageRenderer` rasterises SwiftUI offscreen and needs
no permission:

```sh
"/Applications/Paper Notes.app/Contents/MacOS/PaperNotes" --snapshot /tmp/e.png 700 460
```

**It renders `EditorPane`, not `ContentView`.** `NavigationSplitView` needs a real
window and rasterises as a prohibition glyph; so do `TextEditor`, `WKWebView`,
`Picker` and `Link`, since all are AppKit-backed. Their *frames* still render, which
is what layout debugging needs — two bugs were found this way at 620pt and 700pt: the
authors line clipped, then the verdict picker overflowing the right edge. Both came
from the six-segment picker sharing a row with the metadata; it now has its own.

**The limitation is real.** Anything caused by the `NavigationSplitView` wrapper, the
toolbar, or safe-area insets is outside what this can see.

Passing a height of `0` switches it from rendering to **measuring**: it walks every
paper in the library and prints the height the editor demands for each.

```
2512.20798  515 pt   1 relation(s)
2312.16730  474 pt   0 relation(s)     <- 41pt shorter
spread across papers: 41 pt
UNSTABLE - the pane resizes when you click a different paper
```

That is what caught the real bug. The related strip was 54pt tall for a connected
paper and one line of text for an unconnected one, so every click between the two
moved everything above it by 41pt. Both the strip and the cards inside it now have
fixed heights, and the spread is 0.

**Layout rules this app learned the hard way**, all of which cost a round-trip:

- `GeometryReader` is greedy in both axes and reports no ideal size; inside a `VStack`
  it shoves its siblings out of the frame.
- A horizontal `ScrollView` is still flexible *vertically*.
- Anything whose height depends on the selection must be given a fixed height, or the
  layout moves under the reader.
- One child of the content stack should carry `layoutPriority(1)` and no `minHeight`,
  so it absorbs the slack instead of inflating the stack.
