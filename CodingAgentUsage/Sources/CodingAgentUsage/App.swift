import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Poll from launch, not from first open, so the status-bar number is live
        // even when the panel has never been shown.
        MainActor.assumeIsolated { UsageStore.shared.start() }
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
