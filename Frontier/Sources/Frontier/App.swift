import AppKit
import SwiftUI

@main
struct FrontierApp: App {
    @StateObject private var model = Model()

    init() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--selftest") { MainActor.assumeIsolated { SelfTest.run() } }
        MainActor.assumeIsolated { CLI.run(args) }
    }

    var body: some Scene {
        // Window, not WindowGroup: one curriculum, one window. A second copy
        // would be two views of the same files fighting over who saved last.
        Window("Frontier", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1040, height: 720)
    }
}
