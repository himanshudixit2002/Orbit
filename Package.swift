// swift-tools-version: 6.2
import PackageDescription

// Orbit: one app to control this Mac's customisations (window tiling, glow borders,
// menu bar, Caps Lock keys, Downloads sorter, themes, modes, cleanup).
//
//   OrbitCore      pure logic: settings, palettes, config generators, parsers, commands
//   OrbitPlatform  the only code that touches the system: processes, files, preferences, probes
//   OrbitUI        SwiftUI design system, pages, guided setup, menu bar panel
//   Orbit          the app entry point, bundled into Orbit.app by Scripts/build.sh
let package = Package(
    name: "Orbit",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Orbit", targets: ["Orbit"])
    ],
    targets: [
        .target(name: "OrbitCore", path: "Sources/OrbitCore"),
        .target(name: "OrbitPlatform", dependencies: ["OrbitCore"], path: "Sources/OrbitPlatform"),
        .target(
            name: "OrbitUI",
            dependencies: ["OrbitCore", "OrbitPlatform"],
            path: "Sources/OrbitUI",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .executableTarget(
            name: "Orbit",
            dependencies: ["OrbitUI"],
            path: "Sources/Orbit",
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
            dependencies: ["OrbitUI"],
            path: "Tests/OrbitUITests"
        )
    ]
)
