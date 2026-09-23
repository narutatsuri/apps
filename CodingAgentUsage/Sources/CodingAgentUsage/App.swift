import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything touches the network.
        if CommandLine.arguments.contains("--selftest") { SelfTest.run() }
        // Poll from launch, not from first open, so the status-bar number is live
        // even when the panel has never been shown.
        MainActor.assumeIsolated { UsageStore.shared.start() }
        // CAU_DUMP=1 — what the running app found and what the bar would say,
        // then exit. The bar's text cannot be read from outside the process.
        if ProcessInfo.processInfo.environment["CAU_DUMP"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                MainActor.assumeIsolated {
                    let store = UsageStore.shared
                    print("accounts: \(store.codex.map { "\($0.account.title) [\($0.account.tag)] \($0.snapshot.subtitle ?? "?")" })")
                    for slot in store.codex {
                        print("  \(slot.account.tag): plan=\(slot.snapshot.plan ?? "-") meters=\(slot.snapshot.meters.map { "\($0.label) \(Int($0.percent))%" }) error=\(slot.snapshot.error ?? "none")")
                    }
                    print("bar: \(store.menuBarLabel)")
                    exit(0)
                }
            }
        }
    }
}

@main
struct CodingAgentUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = UsageStore.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                Text(store.menuBarLabel)
                    .font(.system(size: 12).monospacedDigit())
            }
        }
        // .window is what makes it a panel anchored under the icon rather than a
        // dropdown menu or a free-floating window.
        .menuBarExtraStyle(.window)
    }
}
