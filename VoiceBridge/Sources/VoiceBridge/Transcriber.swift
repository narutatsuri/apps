import Foundation

enum Transcriber {
    static func transcribe(_ wav: URL) throws -> String {
        guard let cli = Config.whisperCLI else {
            throw VBError.message("whisper-cli not found — run: brew install whisper-cpp")
        }
        guard FileManager.default.fileExists(atPath: Config.modelURL.path) else {
            throw VBError.message("Model missing at \(Config.modelURL.path)")
        }

        let p = Process()
        p.executableURL = cli
        p.arguments = [
            "-m", Config.modelURL.path,
            "-f", wav.path,
            "-nt",                                   // no timestamps
            "-np",                                   // no progress output
            "--prompt", Config.vocabularyPrompt()    // the fix for proper nouns
        ]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        guard p.terminationStatus == 0 else {
            let msg = (String(data: errData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw VBError.message(msg.isEmpty ? "whisper failed (\(p.terminationStatus))"
                                             : String(msg.suffix(180)))
        }
        return polish(String(data: data, encoding: .utf8) ?? "")
    }

    /// Two cleanups: drop whisper's non-speech markers, then apply the user's
    /// replacement rules for terms the vocabulary prompt still gets wrong.
    static func polish(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\n", with: " ")
        s = s.replacingOccurrences(of: #"\[[A-Z_ ]+\]"#, with: "",
                                   options: .regularExpression)
        for (from, to) in Config.replacements() {
            let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: from) + #"\b"#
            s = s.replacingOccurrences(of: pattern, with: to,
                                       options: [.regularExpression, .caseInsensitive])
        }
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

