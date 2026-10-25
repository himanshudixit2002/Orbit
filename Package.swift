// swift-tools-version: 6.2
import PackageDescription

// Orbit: one app to control this Mac's customisations (window tiling, glow borders,
// menu bar, Caps Lock keys, Downloads sorter, themes, modes, cleanup).
//
//   OrbitCore      pure logic: settings, palettes, config generators, parsers, commands
//   OrbitShared    the snapshot the widgets read: all the system access the sandboxed extension has
//   OrbitPlatform  the only code that touches the system: processes, files, preferences, probes
//   OrbitUI        SwiftUI design system, pages, guided setup, menu bar panel
//
// The app itself (Sources/Orbit) is built by Orbit.xcodeproj with Scripts/build.sh: it needs Xcode
// for App Intents and the widget extension. This package holds everything that can be built and
// tested from a shell.
let package = Package(
    name: "Orbit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "OrbitUI", targets: ["OrbitUI"]),
        // What the sandboxed widget extension may use: the pure core and the shared snapshot.
        .library(name: "OrbitShared", targets: ["OrbitShared"])
    ],
    targets: [
        .target(name: "OrbitCore", path: "Sources/OrbitCore"),
        .target(name: "OrbitShared", dependencies: ["OrbitCore"], path: "Sources/OrbitShared"),
        .target(name: "OrbitPlatform", dependencies: ["OrbitCore"], path: "Sources/OrbitPlatform"),
        .target(
            name: "OrbitUI",
            dependencies: ["OrbitCore", "OrbitShared", "OrbitPlatform"],
            path: "Sources/OrbitUI",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "OrbitCoreTests",
            dependencies: ["OrbitCore"],
            path: "Tests/OrbitCoreTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "OrbitPlatformTests",
            dependencies: ["OrbitPlatform"],
            path: "Tests/OrbitPlatformTests"
        ),
        .testTarget(
            name: "OrbitUITests",
            dependencies: ["OrbitUI", "OrbitShared"],
            path: "Tests/OrbitUITests"
        )
    ]
)
