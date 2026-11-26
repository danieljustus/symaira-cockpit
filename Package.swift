// swift-tools-version: 6.2
import PackageDescription

// symcockpit — the macOS GUI package. The CLI and MCP server are the Rust
// binary (crates/symcockpit) and the fan helper is the Rust symcockpit-helper;
// this package holds the app and the GUI tests on top of the local tuning package.
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
    ],
    dependencies: [
        .package(url: "https://github.com/danieljustus/symaira-corekit.git", exact: "0.27.0"),
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
