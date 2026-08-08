import Foundation
import AppKit

/// Making a note from the terminal.
///
/// The whole premise is "I had an idea while working" — and when that happens in
/// a terminal, the fastest path is not a hotkey and a window, it is a pipe.
///
///     jot --new "check whether the rank pass is stable"
///     pbpaste | jot --new
///     git log --oneline -5 | jot --new --colour blue
enum CLI {
    @MainActor
    static func new(_ args: [String]) -> Never {
        Store.shared.bootstrap()

        var colour = StickyColour.yellow
        if let i = args.firstIndex(of: "--colour") ?? args.firstIndex(of: "--color"),
           i + 1 < args.count, let c = StickyColour(rawValue: args[i + 1].lowercased()) {
            colour = c
        }
        let words = args.enumerated().filter { i, a in
            !a.hasPrefix("--") && !(i > 0 && (args[i - 1] == "--colour" || args[i - 1] == "--color"))
        }.map(\.element)

        var text = words.joined(separator: " ")
        // Nothing on the command line means read stdin, so a pipe works. Only
        // when stdin is actually a pipe: a bare `jot --new` from a prompt should
        // make an empty sticky, not hang waiting for you to type Ctrl-D.
        if text.isEmpty, isatty(FileHandle.standardInput.fileDescriptor) == 0 {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            text = String(data: data, encoding: .utf8) ?? ""
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let sticky = Store.shared.create(colour: colour, text: text)
        Store.shared.flush(sticky.id)
        guard !text.isEmpty else {
            print("Nothing to write — pass text or pipe something in.")
            exit(1)
        }
        print("\(sticky.id)  \(sticky.title)")

        // Nudge a running app so the note appears rather than waiting for a
        // relaunch. Harmless when the app is not running.
        DistributedNotificationCenter.default().postNotificationName(
            .init("local.jot.reload"), object: sticky.id, deliverImmediately: true)
        exit(0)
    }

    @MainActor
    static func list() -> Never {
        Store.shared.bootstrap()
        let all = Store.shared.ordered
        guard !all.isEmpty else { print("No notes yet."); exit(0) }
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        for s in all {
            print(String(format: "%-8s %-13s %@",
                         (s.colour.rawValue as NSString).utf8String!,
                         (f.string(from: s.updatedAt) as NSString).utf8String!,
                         s.title))
        }
        exit(0)
    }
}
