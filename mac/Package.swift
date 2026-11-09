// swift-tools-version: 6.2
// The desktop app: a SwiftUI/AppKit front-end for the same engine as the TUI (src/serve.ts,
// compiled to `running-core` and shipped inside the app bundle). Built by scripts/build-app.ts.
import PackageDescription

let package = Package(
    name: "Running",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Running",
            path: "Sources/Running",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RunningTests",
            dependencies: ["Running"],
            path: "Tests/RunningTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
