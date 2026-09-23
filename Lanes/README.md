# Lanes

A project progress log: every project is a column, all of them side by side
on a canvas that scrolls sideways. The point is seeing all of them at once.

Each column is a markdown file — `~/Library/Application Support/Lanes/<Title>.md`,
no frontmatter, exactly what you typed — so a lane copies straight into a
report or opens in any editor (the app menu's Open Lanes Folder gets you
there). Drop a `.md` into that folder and it is a lane on the next launch.
Column order, widths and which lanes were left in rendered view live in
`lanes.json` beside the files; deleting a lane moves its file to `.trash`.

## Nothing is lost

Every keystroke is on disk before the editor returns from it — an atomic
write, no save timer, no "unsaved changes" state to lose. Before a lane's
file is overwritten, the previous version is copied into `.history/` at most
once per ten minutes of editing, so an accidental select-all-and-type is
recoverable an hour later. A file the app cannot read as text is left
untouched and not shown, never presented as an empty lane that the first
keystroke would overwrite. Deleting a lane moves its file, never removes it.

## Threads

A project with several things going on can be split into threads: ⋯ →
**Add Thread** on any lane. The lane becomes a folder —
`Lanes/<Project>/` — and its words stay exactly where they were, *above*
the threads, as `_above.md`; a second area *below* the threads is
`_below.md`, for what the threads add up to. Both are ordinary markdown,
underscored so they are never mistaken for threads and visible so they
export with the folder. Each thread is `<Thread>.md` inside — a full note
column with its own title, render toggle and draggable width; the project's
areas above and below have render toggles of their own, tucked into the
corner. Threads can be reordered, renamed (the file moves), and deleted to
`.trash`. Delete the last thread and, if nothing is written below, the
project folds back into a single file on its own; if something is, it keeps
its folder and ⋯ offers **Merge Back Into One Lane**, which joins above and
below with a blank line between. A folder of markdown dropped into the lanes
folder by hand becomes a split project on the next launch. One level only —
threads do not nest.

## The vault

For a project that has no promise but too much in it to throw away: ⋯ →
**Vault** on a lane (or **Vault Project** / **Vault Thread** in a split
project) takes it off the board and moves its file — or its whole folder,
or the thread's file under `_vault/<Project>/` — into `_vault/` inside the
lanes folder. Nothing is rewritten, and `_vault` is visible in Finder, so
what is in it can be read, exported, or moved back by hand. **File → Restore
from Vault** lists what the vault holds and puts an entry back on the board
at the right, under a title not already in use; **Open Vault Folder** opens
it. Vaulting a project's last thread folds the project back into one file
the way deleting it would.

## Pictures

Drop an image file onto a lane or thread. It is copied into `_assets/`
beside the lanes (visible, exported with the folder) and the text gets an
ordinary markdown link — `![name](_assets/name-20260921-225936.png)`,
written relative to the file it lands in, so any markdown viewer given the
folder shows it. In the editor the link collapses into the picture itself,
fitted to the column it is in with a small margin either side, aspect kept,
never scaled up, and re-fitted when the column is dragged; the rendered view
shows it too. Inside the app a link is resolved by its file name against
`_assets/`, so a lane that later splits into a project folder keeps its
pictures. Delete the text and the file stays in `_assets/`.

## Writing

The editor is Jot's, verbatim: `Editor.swift`, `Attributed.swift`,
`Highlighter.swift`, `Math.swift`, `Theme.swift` and `MarkdownPreview.swift`
in `Sources/Lanes/Shared/` are **symlinks into `~/Developer/Jot`**, so every
fix to Jot's editor is a fix here. Same markers vanishing as you type, same
shortcuts, same maths, same render toggle (the eye/pencil button on each
column, which "compiles" the markdown with marked + KaTeX). The build copies
Jot's `Resources/web` for that.

    ⌘N              new lane (a column appended at the right, scrolled into view)
    ⌘B / ⌘I         bold, italic
    ⌘⇧H             highlight
    ⌘E              inline code
    ⌘⇧X             strikethrough
    ⌘⇧M             maths
    ⌘⇧D             dark mode
    #s + space      set a heading's level · ⌫ at its start un-titles

Drag the line on a column's right edge to make it wider or narrower
(240–1200pt); double-click the line to put it back at the default 380pt.
Widths are remembered in `lanes.json`. In a split project the lines between
threads resize one thread; the project's own right edge resizes all its
threads together, in proportion.

Rename a lane by editing its title — the name lands when you press return
*or* click away, and the file is renamed with it (`/` and `:` become `-`; a clash gets a number). The ⋯ menu moves a
lane left or right, shows its file in Finder, or deletes it.

## Self-test

    swift build && .build/debug/Lanes --selftest

Runs in a private temp folder (`LANES_ROOT`), never the real one: the file
round-trip, writes landing before `update` returns, titles as filenames (sanitising,
de-duplication, renames moving files and keeping words), order and view mode
surviving a relaunch, dropped files, deletion to `.trash`, and that Jot's
parser is compiled in. `LANES_WINTEST=1` launches the app and reads the live
view tree to confirm the board is a sideways canvas of full-height columns,
each as wide as its lane or thread says. `LANES_SNAPSHOT=<path.png>` draws
the window's content offscreen through AppKit's display cache — not a
screenshot, no permission needed — so a layout can actually be looked at.
