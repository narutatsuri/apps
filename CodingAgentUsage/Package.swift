// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodingAgentUsage",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "CodingAgentUsage", path: "Sources/CodingAgentUsage")
    ]
)
