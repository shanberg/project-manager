// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "pm",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "pm", targets: ["pm"]),
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
            dependencies: ["PmLib"],
            path: "Tests/pmTests"
        ),
    ]
)
