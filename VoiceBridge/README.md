# VoiceBridge

Double-tap **Control**, speak, double-tap again. The transcript is typed into
whatever holds keyboard focus — so in an SSH terminal it lands in the remote tmux
pane running Claude Code, and in an editor it lands at the cursor.

Built 2026-07-30. No menu bar icon, no Dock tile; it behaves like Dictation.

## The problem it solves

Claude Code runs on `della-pli`, which has no microphone, so voice input has to happen
locally and only *text* crosses the wire. macOS Dictation can do that — it types into
the focused terminal — but it mangles technical vocabulary, most notably rendering
`tmux` as `TX`.

Measured, on *"open a new tmux pane and run sbatch on della-pli"*:

| | Output |
|---|---|
| macOS Dictation | `TX` ✗ |
| whisper alone | `Open a new Tmux pane and run Spatch on Dellaplee.` |
| \+ vocabulary priming | `open a new tmux pane and run spatch on della-pli` |
| \+ fix-up rules | `open a new tmux pane and run sbatch on della-pli` ✓ |

Hence three layers, all of which are load-bearing.

## Build & install

```sh
brew install whisper-cpp     # provides whisper-cli
./build.sh                   # downloads the model if absent, installs, launches
```

The model (`ggml-small.en.bin`, 465 MB) lives in
`~/Library/Application Support/VoiceBridge/`, never in the repo.

## Signing — why it is not ad-hoc

Ad-hoc signing (`codesign --sign -`) gives a designated requirement of a bare
`cdhash H"…"` of the binary, so **every rebuild invalidated the Accessibility
grant** — and the row in System Settings kept displaying as *enabled* while the app
silently received no key events, which made it look like a permissions bug rather
than a signing one. That cost a long detour on 2026-07-30.

The app is now signed with a fixed self-signed certificate, so the requirement is

```
identifier "local.voicebridge" and certificate root = H"76253e91…"
```

The hash is the *certificate*, not the binary. Verified by building twice: the
cdhash changed (`5533…` → `9355…`) while the requirement stayed identical.
**Rebuilds no longer require re-granting.**

```sh
./Tools/make-signing-identity.sh    # once per machine; build.sh picks it up
```

The certificate deliberately is **not** added to the trust store — `codesign`
accepts an untrusted self-signed identity, and skipping trust settings avoids
a password prompt. `CSSMERR_TP_NOT_TRUSTED` beside it in
`security find-identity` is expected. macOS will ask once for permission to let
`codesign` use the key; choose *Always Allow*.

`build.sh` falls back to ad-hoc with a warning if the identity is missing. If you
ever do land back in the stale-row state, the escape is
`tccutil reset Accessibility local.voicebridge`, then re-grant.

## Files

| File | Role |
|---|---|
| `DoubleTapMonitor.swift` | double-tap detection; `process(flags:at:)` is deliberately free of `NSEvent` so it can be unit-tested |
| `Recorder.swift` | `AVAudioRecorder` straight to 16 kHz mono PCM — what whisper wants, no resampling |
| `Transcriber.swift` | `whisper-cli` invocation, `--prompt` priming, fix-up rules |
| `Delivery.swift` | keystroke synthesis into the focused app, plus the iTerm2 fallback |
| `HUD.swift` | the floating indicator; non-activating so it never steals focus |
| `VoiceStore.swift` | coordinator |
| `Config.swift` | paths and the on-disk defaults |

## Configuration

Plain text, re-read on **every** transcription — edit and the next utterance uses it,
no rebuild:

- `~/.config/voicebridge/vocabulary.txt` — terms fed to whisper as context. This is
  what turns `dellaplee` into `della-pli`. Add project jargon here first.
- `~/.config/voicebridge/replacements.txt` — literal `wrong => right` fix-ups,
  case-insensitive and whole-word, for whatever priming still misses.

Fix a recurring mis-transcription by adding it to `vocabulary.txt`; if it persists,
add a rule to `replacements.txt`.

### The vocabulary has a budget — spend it on the right words

whisper truncates its initial prompt near **224 tokens** and drops the overflow
*silently*, so a list that grows forever quietly stops working. `--status` reports the
estimate:

```
vocabulary:            ~136 tokens of 224
```

**Only list words whisper gets wrong.** Ordinary English it already handles —
`checkpoint`, `dataset`, `attention`, `benchmark` — costs budget and buys nothing.
Measured: trimming exactly those from a 208-token list took it to 136 with *identical*
output on the test set. Proper nouns and odd tokens are what priming is for.

Worked example — model names, 2026-07-31. Baseline, with the names absent:

| spoken | whisper produced |
|---|---|
| Olmo | `Olmo` / `allmo` / `olmo` — inconsistent |
| Qwen | `Quinn`, `quen`, `quintokonizer` — never right |

Adding `Olmo, Qwen` to the Models line fixed all of them outright, no rules needed.
The `Quinn => Qwen` and `Elmo => Olmo` rules in `replacements.txt` are a safety net for
noisy audio or a crowded prompt, verified to fire when priming misses.

### Testing a vocabulary change without speaking

```sh
VoiceBridge --transcribe /path/to/clip.wav
```

Runs a `.wav` through the real pipeline — priming and replacement rules included — and
prints the result. To make a clip without a microphone:

```sh
say -v Samantha -o /tmp/t.aiff "compare olmo two and kwen three"
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/t.aiff /tmp/t.wav
VoiceBridge --transcribe /tmp/t.wav
```

Synthesised speech is not a substitute for your own voice, but it is a fast way to
check whether a term is being primed at all.

## Commands

With no menu bar item, these replace what would have been menu commands:

```sh
/Applications/VoiceBridge.app/Contents/MacOS/VoiceBridge --status
/Applications/VoiceBridge.app/Contents/MacOS/VoiceBridge --selftest
/Applications/VoiceBridge.app/Contents/MacOS/VoiceBridge --target focused
/Applications/VoiceBridge.app/Contents/MacOS/VoiceBridge --target iterm
/Applications/VoiceBridge.app/Contents/MacOS/VoiceBridge --transcribe clip.wav
/Applications/VoiceBridge.app/Contents/MacOS/VoiceBridge --enable-login-item
/Applications/VoiceBridge.app/Contents/MacOS/VoiceBridge --disable-login-item
pkill -x VoiceBridge
```

**Known wart:** the `accessibility trusted:` line printed by `--status` is unreliable.
Run from a shell, macOS attributes the TCC check to the responsible process — iTerm2 —
not to VoiceBridge, so it reports `false` regardless of what is actually granted.
**Trust the HUD instead**: "Ready — double-tap Control" on launch means the monitor is
running. Fixing it properly means having the GUI process write its own status file for
`--status` to read. That was deferred while deploying a change cost an Accessibility
re-grant — **that reason no longer applies** now signing is stable, so it is simply
outstanding work.

## Maintenance notes

**The built-in Dictation shortcut must stay off** (System Settings › Keyboard ›
Dictation › Shortcut → Off). If both are bound to double-tap Control, Dictation grabs
the microphone first and VoiceBridge records silence.

**Delivery has two modes**, in `Delivery.swift`:

| `--target` | Behaviour |
|---|---|
| `focused` *(default)* | synthesises keystrokes into whatever holds keyboard focus, wherever the cursor is — the same model as Dictation |
| `iterm` | always the current iTerm2 session, regardless of what is frontmost |

`iterm` was the original default and it was wrong: dictating while typing in VS Code
on another display silently delivered the text into a terminal instead. Focus-following
is what people actually expect. `iterm` survives as an opt-in for the genuine case it
serves — dictating into a terminal while reading something else — but it will happily
type into a window you are not looking at.

`focused` posts `CGEvent`s with `keyboardSetUnicodeString`, which needs Accessibility —
already required for the hotkey, so no extra permission. Two details that matter:
event flags are cleared explicitly (a still-held Control would otherwise turn the text
into control codes), and long transcripts are chunked, because a single event carries
only a short run of UTF-16 units reliably. Chunking iterates `Character`s so surrogate
pairs are never split.

The HUD confirmation names the destination — "→ Visual Studio Code · <text>" — which is
the quickest way to notice text going somewhere unexpected.

**Chord rejection matters.** Typing `⌃C` must never start a recording.
`DoubleTapMonitor` tracks a `wasChord` flag set by a `keyDown` monitor. Covered by
`--selftest`; run it after touching that state machine.

**Never lose a transcript.** If delivery fails, the text goes to the clipboard and the
HUD says so. Preserve that.

Permissions required: **Accessibility** (bare-modifier double-taps cannot use the
permission-free Carbon hotkey API), **Microphone**, and **Automation → iTerm2**.
