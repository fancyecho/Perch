// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Perch",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Perch", targets: ["Perch"]),
        // Loaded into /usr/bin/perl at runtime to read Now Playing (see NowPlayingService).
        .library(name: "PerchMediaHelper", type: .dynamic, targets: ["PerchMediaHelper"]),
    ],
    targets: [
        .executableTarget(
            name: "Perch",
            dependencies: ["PerchLine"],
            path: "Sources/Perch",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        // The screenshot line, adapted from Tendedero (MIT, see its LICENSE). Kept in its own Swift 5
        // module, as written, rather than reworked for Perch's strict concurrency.
        .target(
            name: "PerchLine",
            path: "Sources/PerchLine",
            exclude: ["LICENSE"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "PerchMediaHelper",
            path: "Sources/PerchMediaHelper",
            linkerSettings: [.linkedFramework("Foundation")]
        ),
        .testTarget(
            name: "PerchTests",
            dependencies: ["Perch"],
            path: "Tests/PerchTests",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
