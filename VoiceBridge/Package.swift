// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceBridge",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "VoiceBridge", path: "Sources/VoiceBridge")
    ]
)
