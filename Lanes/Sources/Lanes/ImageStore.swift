import AppKit
import Foundation
import UniformTypeIdentifiers

/// Pictures dropped into a lane.
///
/// The file is copied into `_assets/` beside the lanes (underscored: the
/// store's own, visible, exported with the folder) and the lane gets an
/// ordinary markdown image link, written relative to the lane's own file so
/// any markdown viewer given the folder shows it. Inside the app the link is
/// resolved by its file name against `_assets/`, so a lane that later moves
/// into a project folder still shows its pictures.
@MainActor
enum ImageStore {
    static var assets: URL { LaneStore.root.appendingPathComponent("_assets") }

    /// Points the shared editor at this store. Called once at launch.
    static func install() {
        Attributed.imageResolver = { resolve($0) }
    }

    /// Copies the file in and returns the link to insert. `depth` is how
    /// many folders down the lane's file lives: 0 for `<Title>.md`, 1 for a
    /// thread or a project's own areas.
    static func adopt(_ source: URL, depth: Int) -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(at: assets, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let stem = LaneStore.sanitise(source.deletingPathExtension().lastPathComponent)
            .replacingOccurrences(of: " ", with: "-")
        let stamp = Self.stampFormatter.string(from: Date())
        var name = "\(stem)-\(stamp).\(ext)"
        var n = 2
        while fm.fileExists(atPath: assets.appendingPathComponent(name).path) {
            name = "\(stem)-\(stamp)-\(n).\(ext)"
            n += 1
        }
        do { try fm.copyItem(at: source, to: assets.appendingPathComponent(name)) } catch { return nil }
        let prefix = String(repeating: "../", count: max(0, depth))
        return "![\(stem)](\(prefix)_assets/\(name))"
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = .current
        return f
    }()

    /// The file a link points at: an absolute path as it is; otherwise the
    /// name looked up in `_assets/`, then the path relative to the lanes
    /// folder.
    static func locate(_ path: String) -> URL? {
        let fm = FileManager.default
        if path.hasPrefix("/"), fm.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        let name = (path as NSString).lastPathComponent
        let inAssets = assets.appendingPathComponent(name)
        if fm.fileExists(atPath: inAssets.path) { return inAssets }
        let relative = LaneStore.root.appendingPathComponent(path)
        return fm.fileExists(atPath: relative.path) ? relative : nil
    }

    static func resolve(_ path: String) -> NSImage? {
        locate(path).flatMap { NSImage(contentsOf: $0) }
    }

    private static var inlineCache: [String: String] = [:]

    /// The markdown with every image link's file inlined as a data URI, for
    /// the rendered view: the web view may only read the app's own bundle,
    /// so a file path in an `<img>` would show nothing.
    static func inlined(_ markdown: String) -> String {
        let pattern = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(([^)\n]+)\)"#)
        let ns = markdown as NSString
        var out = ""
        var cursor = 0
        for m in pattern.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let alt = ns.substring(with: m.range(at: 1))
            let path = ns.substring(with: m.range(at: 2))
            out += "![\(alt)](\(dataURI(for: path) ?? path))"
            cursor = NSMaxRange(m.range)
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func dataURI(for path: String) -> String? {
        guard let url = locate(path) else { return nil }
        let stamp = ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970).map { String(Int($0)) } ?? ""
        let key = url.path + "@" + stamp
        if let cached = inlineCache[key] { return cached }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
        let uri = "data:\(mime);base64," + data.base64EncodedString()
        inlineCache[key] = uri
        return uri
    }
}
