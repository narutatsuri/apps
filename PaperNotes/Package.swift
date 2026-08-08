// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PaperNotes",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PaperNotes", path: "Sources/PaperNotes")
    ]
)
