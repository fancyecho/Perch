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
            path: "Sources/Perch",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
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
