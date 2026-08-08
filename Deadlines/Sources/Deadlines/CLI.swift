import Foundation

/// `deadlines --list`.
///
/// The same standings the panel shows, in the terminal. Worth having for its
/// own sake, and worth more than that as a check: a desktop panel cannot be
/// read back in a transcript, so this is how the whole pipeline — file, fetch,
/// parse, timezone, ordering — gets verified against live data.
@MainActor
enum CLI {
    static func list() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        Store.shared.bootstrap()

        let semaphore = DispatchSemaphore(value: 0)
        var offline = false
        Task { @MainActor in
            let fetched = await Feed.fetch(Store.shared.tracked)
            if fetched.isEmpty { offline = true } else { Store.shared.store(fetched) }
            semaphore.signal()
        }
        // The fetch is the point of the command, so it is worth waiting for —
        // but not forever, and a stale cache still prints.
        while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        let now = Date()
        let standings = Schedule.standings(for: Store.shared.tracked,
                                           in: Store.shared.all, now: now)
        if offline { print("(offline — showing the last dates fetched)") }
        if standings.isEmpty {
            print("nothing tracked. add conferences to \(Store.list.path)")
            exit(0)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        // Padded in Swift rather than with String(format:) and %s, which takes
        // a C string and turns every em dash into mojibake.
        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
        }
        for standing in standings {
            switch standing {
            case .upcoming(let d):
                print(pad(d.title, 18) + pad(d.kind.label, 10)
                      + pad(Countdown.text(from: now, to: d.at), 11)
                      + formatter.string(from: d.at) + "  (\(d.zone))")
            case .unannounced(let conference, let lastKnown):
                print(pad(conference, 18) + pad("—", 10) + pad("—", 11)
                      + (lastKnown.map { "next round not announced (last seen \($0))" }
                         ?? "not found in the feed"))
            }
        }
        exit(0)
    }
}

import SwiftUI

@MainActor
extension CLI {
    /// `--preview <path>` renders the panel to a PNG.
    ///
    /// A window pinned to the desktop cannot be read back in a transcript, and
    /// "the tests pass" says nothing about whether the thing is legible. This
    /// draws the actual view with the actual data.
    static func preview(_ path: String) -> Never {
        Store.shared.bootstrap()
        let model = Model()

        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let fetched = await Feed.fetch(Store.shared.tracked)
            if !fetched.isEmpty { Store.shared.store(fetched) }
            model.checked = Date()
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        model.recompute()

        let renderer = ImageRenderer(content:
            PanelView(model: model)
                // Drawn on a mid grey stand-in for wallpaper: the card is
                // translucent, so rendering it on nothing would flatter it.
                .background(Color(white: 0.30)))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("could not render")
            exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
        exit(0)
    }
}
