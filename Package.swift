// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClaudeUsage", targets: ["ClaudeUsage"]),
    ],
    targets: [
        // Platform-independent logic: response parsing, credentials, formatting, scheduling.
        .target(name: "ClaudeUsageCore"),
        // The menu bar app itself (AppKit + SwiftUI).
        .executableTarget(
            name: "ClaudeUsage",
            dependencies: ["ClaudeUsageCore"]
        ),
        .testTarget(
            name: "ClaudeUsageCoreTests",
            dependencies: ["ClaudeUsageCore"]
        ),
    ]
)
