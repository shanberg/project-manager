// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "pm",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "pm", targets: ["pm"]),
        // Exposed so native macOS front-ends (the menubar agent app) can link the domain
        // logic directly instead of shelling out to the `pm` CLI.
        .library(name: "PmLib", targets: ["PmLib"]),
    ],
    targets: [
        .executableTarget(
            name: "pm",
            dependencies: ["PmLib"],
            path: "Sources/pm"
        ),
        .target(
            name: "PmLib",
            path: "Sources/PmLib"
        ),
        .testTarget(
            name: "pmTests",
            dependencies: ["PmLib", "pm"],
            path: "Tests/pmTests"
        ),
    ]
)
