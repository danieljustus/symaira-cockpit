// swift-tools-version: 6.2
import PackageDescription

// symcockpit — the macOS GUI package. The CLI and MCP server are the Rust
// binary (crates/symcockpit); this package holds the app, the fan helper and
// the GUI tests on top of the local tuning package.
let package = Package(
    name: "symcockpit",
    platforms: [
        // The whole family targets macOS 26: the GUI's docked HUD is built
        // on the Liquid Glass APIs, and a split deployment target is not
        // expressible in SwiftPM — platforms are per package, not per target.
        .macOS(.v26),
    ],
    products: [
        // The GUI: one menu-bar item plus a tune-only cockpit window.
        .executable(name: "SymCockpitApp", targets: ["SymCockpitApp"]),
        // The optional privileged fan helper (issue #405), embedded in the app
        // bundle and registered through SMAppService. Never installed on its own.
        .executable(name: "SymCockpitFanHelper", targets: ["SymCockpitFanHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/danieljustus/symaira-corekit.git", exact: "0.23.1"),
        .package(path: "tuning"),
    ],
    targets: [
        .target(name: "SymCockpitVersion"),
        .executableTarget(
            name: "SymCockpitApp",
            dependencies: [
                "SymCockpitVersion",
                .product(name: "SymCockpitUI", package: "tuning"),
                .product(name: "SymCockpitCore", package: "tuning"),
                .product(name: "SymairaTheme", package: "symaira-corekit"),
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "SymCockpitFanHelper",
            dependencies: [
                .product(name: "SymCockpitHelperKit", package: "tuning"),
                .product(name: "SymCockpitCore", package: "tuning"),
            ],
            // Embedded into the app bundle by scripts/build-app.sh, not a SwiftPM resource.
            exclude: ["com.symaira.symtune-helper.plist"]
        ),
        .testTarget(
            name: "SymCockpitE2ETests",
            dependencies: [
                .product(name: "SymCockpitCore", package: "tuning"),
                .product(name: "SymCockpitUI", package: "tuning"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
