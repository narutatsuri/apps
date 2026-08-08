import Foundation
import CoreGraphics

/// The colours a sticky can be.
///
/// Six, not a picker. A palette you can hold in your head is what makes colour a
/// usable index — "the yellow one" only means something while there are few
/// enough colours to name.
enum StickyColour: String, CaseIterable, Codable {
    case yellow, blue, green, pink, purple, grey

    var label: String { rawValue.capitalized }

    /// Paper colour, and the ink that stays readable on it. Both are given
    /// explicitly rather than derived, because a computed contrast colour goes
    /// wrong on exactly the shades you would pick for a sticky.
    var paper: (light: UInt32, dark: UInt32) {
        switch self {
        case .yellow: return (0xFFF3B0, 0x4A4324)
        case .blue:   return (0xCFE6FF, 0x24384A)
        case .green:  return (0xCFF3D8, 0x24462F)
        case .pink:   return (0xFFD6E0, 0x4A2A33)
        case .purple: return (0xE4D9FF, 0x352A4A)
        case .grey:   return (0xE8E8E4, 0x35352F)
        }
    }
}

/// One sticky note.
///
/// A markdown file with a little frontmatter, the same shape Paper Notes uses:
/// the file is the truth, so a sticky is greppable, editable in any editor, and
/// survives the app being deleted. The frontmatter carries only what the file
/// cannot imply — colour, where the window sat, whether it floats.
struct Sticky: Identifiable, Equatable {
    var id: String
    var text: String = ""
    var colour: StickyColour = .yellow
    /// Screen position and size. Restored so a sticky comes back where you left
    /// it, which is most of what makes a sticky feel like an object.
    var frame: CGRect?
    /// Floats above other windows. On by default: a note you cannot see while
    /// working in the terminal is a note you will not write.
    var floats: Bool = true
    /// Rendered rather than raw. Per sticky, because a checklist wants rendering
    /// and a paste buffer does not.
    var rendered: Bool = false
    /// Was this on screen when you last quit?
    ///
    /// Explicit rather than inferred from "does it have a saved frame", which is
    /// what this was first: a note made from the terminal has never had a
    /// window, so it had no frame, so it never reappeared. It showed up in
    /// `--list` and in the menu and nowhere else, which is the worst kind of
    /// missing — the data is fine and you think the app lost it.
    var isOpen: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// A sticky with nothing in it is not worth keeping — the store deletes
    /// these rather than leaving empty files around after a scratch buffer.
    var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The first non-empty line, for the menu bar list. Markdown heading marks
    /// and list bullets are stripped: "# Ideas" should read as "Ideas".
    var title: String {
        for raw in text.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            while let first = line.first, "#>-*+".contains(first) {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            // A line of only punctuation ("---", "***") is a rule, not a title.
            guard !line.isEmpty else { continue }
            return String(line.prefix(60))
        }
        return "Empty sticky"
    }

    /// Counts stickies made in this process, so two made in the same second
    /// cannot collide however unlucky the random half is.
    private static var sequence: UInt8 = 0

    static func newID() -> String {
        // Sortable by creation, and unique on both axes it can collide along.
        // Random alone was not enough: 16 bits of it is a 1-in-4 chance of a
        // repeat across 200 stickies in the same second, by the birthday bound,
        // and a repeat means one note silently overwrites another. The counter
        // rules out collisions within a process; the random half rules them out
        // between processes, since the CLI and the app both make stickies.
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = .current
        sequence &+= 1
        return String(format: "%@-%02x%04x", f.string(from: Date()),
                      Int(sequence), Int(UInt16.random(in: 0...0xFFFF)))
    }
}

// MARK: - File round-trip

extension Sticky {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    var markdown: String {
        var out = "---\n"
        out += "id: \(id)\n"
        out += "colour: \(colour.rawValue)\n"
        if let f = frame {
            out += "frame: \(Int(f.origin.x)),\(Int(f.origin.y)),\(Int(f.width)),\(Int(f.height))\n"
        }
        out += "floats: \(floats)\n"
        out += "open: \(isOpen)\n"
        if rendered { out += "rendered: true\n" }
        out += "created: \(Self.iso.string(from: createdAt))\n"
        out += "updated: \(Self.iso.string(from: updatedAt))\n"
        out += "---\n\n"
        out += text.hasSuffix("\n") ? text : text + "\n"
        return out
    }

    /// Parses our own dialect. A file with no frontmatter at all is still a
    /// sticky — dropping a plain .md into the folder should work, and losing
    /// someone's text because a header was missing would be unforgivable.
    init?(markdown raw: String, id fallbackID: String) {
        var front: [String: String] = [:]
        var body = raw

        if raw.hasPrefix("---") {
            let lines = raw.components(separatedBy: "\n")
            if let close = lines.dropFirst().firstIndex(of: "---") {
                for line in lines[1..<close] {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let key = String(line[line.startIndex..<colon])
                        .trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty { front[key] = value }
                }
                body = lines[(close + 1)...].joined(separator: "\n")
            }
        }

        self.id = front["id"] ?? fallbackID
        self.text = body.trimmingCharacters(in: .newlines)
        self.colour = StickyColour(rawValue: front["colour"] ?? "") ?? .yellow
        self.floats = (front["floats"] ?? "true") != "false"
        self.rendered = (front["rendered"] ?? "") == "true"
        // Absent means yes: a hand-written .md dropped into the folder should
        // show up, and so should every note made before this field existed.
        self.isOpen = (front["open"] ?? "true") != "false"
        self.createdAt = front["created"].flatMap(Self.iso.date(from:)) ?? Date()
        self.updatedAt = front["updated"].flatMap(Self.iso.date(from:)) ?? self.createdAt
        self.frame = Self.parseFrame(front["frame"])
    }

    static func parseFrame(_ s: String?) -> CGRect? {
        guard let parts = s?.split(separator: ","), parts.count == 4 else { return nil }
        let n = parts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard n.count == 4, n[2] > 40, n[3] > 40 else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }
}
