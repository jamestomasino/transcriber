// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Transcriber",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TranscriberCore", targets: ["TranscriberCore"]),
        .executable(name: "Transcriber", targets: ["TranscriberApp"])
    ],
    targets: [
        // Pure, AppKit-free core: model, engine, view model. (Persistence,
        // processors, retention added in later phases.)
        .target(
            name: "TranscriberCore",
            path: "Sources/Core"
        ),
        .target(name: "CWhisper", path: "Sources/CWhisper", publicHeadersPath: "include"),
        // The SwiftUI/AppKit shell (window + menu bar).
        .executableTarget(
            name: "TranscriberApp",
            dependencies: ["TranscriberCore", "CWhisper"],
            path: "Sources/App"
        ),
        // The assertion-based test harness.
        .executableTarget(
            name: "TranscriberTests",
            dependencies: ["TranscriberCore"],
            path: "Tests"
        )
    ]
)
