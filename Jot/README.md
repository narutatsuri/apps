# Jot

Markdown scratch notes that float over whatever you are working in.

    ⌃⌥Space   new note, focused, ready to type
    ⌃⌥S       show every note, or hide them all

Notes live in `~/Library/Application Support/Jot` as plain markdown, one file
each — where macOS keeps an app's data, rather than as a folder in your home
directory. The menu bar icon opens it. Grep them, edit one in
vim, pipe things into them; the app is a way of looking at that folder, not a
container the notes are trapped inside.

## From the terminal

    jot --new "check whether the rank pass is stable"
    pbpaste | jot --new
    git log --oneline -5 | jot --new --colour blue
    jot --list

## In a note

    ⌘B / ⌘I          bold, italic
    ⌘⇧H              highlight
    ⌘E               inline code
    ⌘⇧X              strikethrough
    ⌘1…⌘6            colour
    ⌘R               render the markdown / back to editing
    ⌘⌫               delete (moved to .trash inside that folder, not gone)

Emphasis writes markdown *into the text* — `**bold**` is stored as `**bold**`
and drawn bold as you type. That is the difference from the built-in Stickies
app, where formatting is state attached to each note, so every note drifts into
its own font and nothing survives being moved between them. Here formatting is a
function of the text, so every note looks the same and a note is still a file.
