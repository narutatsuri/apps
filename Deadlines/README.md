# Deadlines

A countdown to the conference deadlines you care about, pinned to the desktop.

Sits above the wallpaper and below every ordinary window, on all Spaces, and
ignores the mouse entirely — clicks pass straight through to the desktop. It is
furniture, not an app you switch to. There is no Dock tile; the menu bar icon
holds the controls and shows the next deadline.

## Not a widget, and why

macOS widgets are app **extensions**: a `.appex` bundle with an
`NSExtensionPointIdentifier`, embedded in a containing app, signed and
registered with PlugInKit. Producing and registering one is Xcode's build
system's job, and there is no Xcode on this machine — only Command Line Tools.
(`WidgetKit.framework` *is* in the CLT SDK, so the code would compile; it is the
bundle and its registration that are out of reach.)

A desktop-level window occupies the same place on screen, needs no gallery, no
container app and no signing dance, and can be edited with a text file.

## What it tracks

`~/deadlines/conferences.txt`, one per line:

```
NeurIPS
ICML
ICLR
COLM

My Workshop | 2026-11-14 23:59 UTC-8 | abstract
Some CFP    | 2026-12-01 AoE
```

A bare name is looked up automatically. Dates come from
[`ccfddl/ccf-deadlines`](https://github.com/ccfddl/ccf-deadlines), which is
maintained by people who actually submit to these venues — so a deadline that
slips gets fixed without you noticing. Anything else you write yourself.

The file is watched, so an edit takes effect without relaunching. Fetched dates
are cached beside it, so the panel is right offline and on the first frame.

**TMLR and JMLR are deliberately absent.** They are rolling-submission journals
with no deadline; there is nothing to count down to, and a countdown to one
would be fiction.

## Timezones, which is where this kind of thing lies to you

Most ML conferences use **Anywhere on Earth** — UTC-12, the last place on the
planet where it is still that date. Treating AoE as UTC is a twelve-hour error
in the direction that loses papers, so every deadline is stored as an absolute
instant, shown in your local time, and labelled with the zone it came from.
`Zone.offset` refuses a label it does not recognise rather than guessing: a
deadline in the wrong zone is worse than a deadline not shown.

## A conference with nothing upcoming

It says so, rather than vanishing. In August 2026 the 2026 rounds of NeurIPS,
ICML and COLM have all passed and the 2027 dates are not out — so those rows
read `next round TBA`. A missing row would read as "nothing to do", which is a
different and much worse claim.

## Running it

```sh
./build.sh                       # build, install to /Applications, launch
Deadlines --list                 # the same standings, in the terminal
Deadlines --selftest             # 40 logic checks; exits non-zero on failure
Deadlines --preview out.png      # render the panel to a PNG
```

`--list` and `--preview` exist because a window pinned to the desktop cannot be
read back in a transcript. They are how the whole pipeline — file, fetch, parse,
timezone, ordering — gets checked against live data.

The menu bar icon offers the corner it sits in, a manual refresh, and the file.
