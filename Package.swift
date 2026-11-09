// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodeCaps",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodeCaps", targets: ["CodeCaps"]),
        .library(name: "QuotaCore", targets: ["QuotaCore"]),
    ],
    dependencies: [
        // In-app auto-update from signed releases CI publishes on every merge
        // to main.  See docs/AUTO-UPDATE.md.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
        // Crash reporting and telemetry for the codecaps Sentry project
        // (org simple-with-us).  Pinned to the fleet-wide sentry-cocoa major.
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.32.0"),
    ],
    targets: [
        .target(name: "QuotaCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(
            name: "CodeCaps",
            dependencies: [
                "QuotaCore",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Sentry", package: "sentry-cocoa"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "QuotaCoreTests", dependencies: ["QuotaCore"]),
        // The iOS widget parse path, compiled straight from the iOS sources
        // (mirrored into the test build at build time, so there is no
        // committed copy to drift) because the companion builds via
        // xcodebuild, not SPM: without this target the code feeding every
        // widget pixel had no CI.
        .executableTarget(name: "WidgetParseMirrorTool"),
        .plugin(name: "WidgetParseMirrorGen", capability: .buildTool(), dependencies: ["WidgetParseMirrorTool"]),
        .testTarget(name: "WidgetParseTests", plugins: ["WidgetParseMirrorGen"]),
        .testTarget(name: "CodeCapsTests", dependencies: ["CodeCaps"]),
    ]
)
