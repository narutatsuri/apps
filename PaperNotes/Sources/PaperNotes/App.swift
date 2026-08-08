import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Registers the "Add to Paper Notes" entry that appears under a PDF's
        // right-click → Services menu in Finder.
        NSApp.servicesProvider = ServiceProvider()
        NSUpdateDynamicServices()
        if ProcessInfo.processInfo.environment["PN_DUMP"] == "1" { Diagnose.scheduleDump() }
        if ProcessInfo.processInfo.environment["PN_WINDOWS"] == "1" { Diagnose.scheduleWindowDump() }
    }

    /// Finder's "Open With → Paper Notes", and files opened via `open -a`.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { AppModel.shared.ingest(fileURL: url) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The notes window specifically — not "the first window that can become
    /// main", which was the bug. Graph and What-to-Read-Next can both become
    /// main, so with either of them open a Dock click raised one of those and
    /// reported the reopen as handled, and the notes window never came forward.
    static func mainWindow() -> NSWindow? {
        // SwiftUI stamps the scene id into the window identifier.
        if let byID = NSApp.windows.first(where: {
            $0.identifier?.rawValue.contains(WindowID.main) == true
        }) { return byID }
        // Fall back to the title, and exclude the two auxiliary scenes by name
        // rather than trusting ordering.
        return NSApp.windows.first {
            $0.canBecomeMain && $0.title != "Citation Graph" && $0.title != "What to Read Next"
        }
    }

    /// Returning `true` means "handled — skip the default", and the default is
    /// SwiftUI restoring a closed scene. So only claim to have handled it when a
    /// window was actually brought forward; otherwise fall through and let
    /// SwiftUI re-create the scene, which NSWindow APIs cannot do.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let window = Self.mainWindow() else { return false }
        // A minimised window ignores makeKeyAndOrderFront. Returning true after
        // that call left the app looking dead on a Dock click, which is the other
        // half of "sometimes it doesn't appear".
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

/// Target for the Services menu entry declared in Info.plist.
final class ServiceProvider: NSObject {
    @objc func addToPaperNotes(_ pasteboard: NSPasteboard,
                               userData: String?,
                               error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        MainActor.assumeIsolated {
            for url in urls where url.pathExtension.lowercased() == "pdf" {
                AppModel.shared.ingest(fileURL: url)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@main
struct PaperNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    init() {
        let args = CommandLine.arguments
        if args.contains("--selftest") { MainActor.assumeIsolated { SelfTest.run() } }
        if args.contains("--refresh") { Importer.refresh() }
        if args.contains("--adopt-pdfs") { Importer.adoptPDFs() }
        if let i = args.firstIndex(of: "--recommend") {
            Commands.recommend(Array(args[(i + 1)...]))
        }
        if args.contains("--rank") {
            Commands.rank([])
        }
        if let i = args.firstIndex(of: "--search") {
            Commands.search(Array(args[(i + 1)...]))
        }
        if let i = args.firstIndex(of: "--queue") {
            Commands.queue(Array(args[(i + 1)...]))
        }
        if let i = args.firstIndex(of: "--appraise") {
            Commands.appraise(Array(args[(i + 1)...]))
        }
        if let i = args.firstIndex(of: "--meta") {
            Commands.meta(Array(args[(i + 1)...]))
        }
        if let i = args.firstIndex(of: "--grade") {
            Commands.grade(Array(args[(i + 1)...]))
        }
        if let i = args.firstIndex(of: "--import") {
            Importer.run(Array(args[(i + 1)...]))
        }
        if let i = args.firstIndex(of: "--snapshot") {
            MainActor.assumeIsolated { Snapshot.run(Array(args[(i + 1)...])) }
        }
    }

    var body: some Scene {
        // Window, not WindowGroup: a WindowGroup is a multi-window scene, so every
        // file opened from Finder spawned another copy of the app's window.
        Window("Paper Notes", id: WindowID.main) {
            ContentView(model: model)
        }
        .defaultSize(width: 1120, height: 700)

        // Its own window on purpose: with three displays, the graph earns a screen
        // of its own next to the PDF and the notes.
        Window("Citation Graph", id: WindowID.graph) {
            GraphView(model: model)
                .frame(minWidth: 520, minHeight: 420)
        }
        .defaultSize(width: 900, height: 680)

        // Also its own window: choosing what to read next is a separate act from
        // writing about what you just read, and it takes a minute to populate.
        Window("What to Read Next", id: WindowID.recommend) {
            RecommendationsView(model: model)
        }
        .defaultSize(width: 640, height: 560)

        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Paper…") { model.showingAdd = true }
                    .keyboardShortcut("n", modifiers: .command)
                Divider()
                Button("Open PDF for Reading") {
                    if let d = model.draft { model.startReading(d) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.draft?.pdfPath.isEmpty ?? true)
                Button("Move Window to Next Display") { Reading.moveNotesToNextScreen() }
                    .keyboardShortcut("d", modifiers: [.command, .control])
                Divider()
                GraphCommand()
                RecommendCommand()
                Button("Edit Trusted Authors…") { model.editTrustedAuthors() }
                Toggle("Appraise New Papers with Claude", isOn: Binding(
                    get: { Prefs.autoAppraise },
                    set: { Prefs.autoAppraise = $0 }))
                Button("Rank Library by Interest") { model.rankLibrary() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(model.isRanking)
                Button("Grade My Note") { model.gradeCurrentNote() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(!(model.draft?.isSubstantive ?? false))
                Divider()
                Button("Push Now") { model.pushIfEnabled() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }
}
