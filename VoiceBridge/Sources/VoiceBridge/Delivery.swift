import AppKit
import ApplicationServices

enum DeliveryTarget: String, CaseIterable {
    /// Type into whatever has keyboard focus, wherever the cursor is. Matches how
    /// Dictation behaves, and is the default.
    case focused
    /// Always the current iTerm2 session, regardless of what is frontmost. Useful
    /// for dictating into a terminal while reading something else — but it will
    /// happily type into a terminal you are not looking at.
    case iterm
}

enum Delivery {
    static func send(_ text: String, submit: Bool) throws {
        switch Prefs.target {
        case .focused: try sendToFocusedApp(text, submit: submit)
        case .iterm: try sendToITerm(text, submit: submit)
        }
    }

    /// Where the frontmost app's name can be read, for the HUD confirmation.
    static var frontmostAppName: String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "the focused app"
    }

    // MARK: - Focused app (default)

    /// Synthesises keyboard input into whatever currently has focus. Uses the
    /// Accessibility grant the hotkey already requires, so this needs no additional
    /// permission.
    static func sendToFocusedApp(_ text: String, submit: Bool) throws {
        guard AXIsProcessTrusted() else {
            throw VBError.message("Accessibility permission is needed to type into the focused app.")
        }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw VBError.message("Could not create an event source.")
        }

        // Let the modifier taps that triggered us fully settle before typing.
        usleep(60_000)

        for piece in chunks(text, utf16Limit: 16) {
            var buffer = Array(piece.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw VBError.message("Could not synthesise keyboard input.")
            }
            // Clear modifier state explicitly: a still-held Control would otherwise
            // turn the synthetic characters into control codes.
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
            usleep(2_000)
        }

        if submit { postReturn(source) }
    }

    private static func postReturn(_ source: CGEventSource) {
        let returnKey: CGKeyCode = 36
        for isDown in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: isDown)
            else { continue }
            e.flags = []
            e.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// A single event carries only a limited run of UTF-16 units reliably, so long
    /// transcripts are split. Chunking by Character never splits a surrogate pair.
    private static func chunks(_ text: String, utf16Limit: Int) -> [String] {
        var out: [String] = []
        var current = ""
        var units = 0
        for ch in text {
            current.append(ch)
            units += ch.utf16.count
            if units >= utf16Limit {
                out.append(current)
                current = ""
                units = 0
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: - iTerm2 (opt-in)

    /// iTerm2's own scripting command, documented as "send text as though it was
    /// typed". Needs Automation permission rather than Accessibility, and targets
    /// iTerm2 whether or not it is frontmost.
    static func sendToITerm(_ text: String, submit: Bool) throws {
        let script = """
        on run argv
          tell application "iTerm2"
            tell current window
              tell current session
                write text (item 1 of argv) newline \(submit ? "yes" : "no")
              end tell
            end tell
          end tell
        end run
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicebridge-send.applescript")
        try script.write(to: url, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // The transcript travels via argv, so quotes and backslashes inside it
        // need no escaping.
        p.arguments = [url.path, text]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()

        try p.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        guard p.terminationStatus == 0 else {
            var msg = (String(data: errData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if msg.contains("-1743") || msg.lowercased().contains("not allowed") {
                msg = "Allow VoiceBridge to control iTerm2 in System Settings › Privacy & Security › Automation."
            } else if msg.contains("-1728") {
                msg = "No iTerm2 window is open."
            }
            throw VBError.message(msg.isEmpty ? "osascript failed (\(p.terminationStatus))" : msg)
        }
    }
}
