// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "WebAttentionHarness",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "WebKitPrivates", path: "Sources/WebKitPrivates"),
        .executableTarget(name: "Harness", dependencies: ["WebKitPrivates"], path: "Sources/Harness",
                          linkerSettings: [.linkedFramework("WebKit")]),
    ]
)
