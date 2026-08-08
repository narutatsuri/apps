// swift-tools-version: 5.9
import PackageDescription

// 5.9 deliberately: 6.0's strict concurrency fights @MainActor singletons that
// AppKit callbacks reach into, and this app is one process, one main thread.
let package = Package(
    name: "Deadlines",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Deadlines", path: "Sources/Deadlines")]
)
