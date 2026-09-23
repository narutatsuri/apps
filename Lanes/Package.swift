// swift-tools-version: 5.9
import PackageDescription

// 5.9 deliberately, as in Jot: 6.0's strict concurrency fights @MainActor
// singletons that AppKit callbacks reach into, and this app is one process,
// one main thread.
let package = Package(
    name: "Lanes",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Lanes", path: "Sources/Lanes")]
)
