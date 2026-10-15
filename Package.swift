// swift-tools-version: 6.2
import PackageDescription

// symcockpit — the unified entrypoint for the cockpit tool family.
// Dispatches to the tuning CLI library via a local path dependency.
let package = Package(
    name: "symcockpit",
    platforms: [
        // The whole family targets macOS 26: the GUI's docked HUD is built
        // on the Liquid Glass APIs, and a split deployment target is not
        // expressible in SwiftPM — platforms are per package, not per target.
        .macOS(.v26),
    ],
    products: [
        .executable(name: "symcockpit", targets: ["symcockpit"]),
        // The GUI: one menu-bar item plus a tune-only cockpit window.
        .executable(name: "SymCockpitApp", targets: ["SymCockpitApp"]),
    ],
    dependencies: [
        // ponytail: untagged AppKit Liquid Topography commit (PR #159). Replace with
        // `exact:` on the release tag before merge; AGENTS.md requires a tag pin.
        .package(url: "https://github.com/danieljustus/symaira-appkit.git", revision: "3b439deb365d8b75d4a18f98d72b5a1118f004db"),
        .package(path: "tuning"),
    ],
    targets: [
        .target(name: "SymCockpitVersion"),
        .executableTarget(
            name: "symcockpit",
            dependencies: [
                "SymCockpitVersion",
                .product(name: "SymCockpitCLI", package: "tuning"),
                .product(name: "SymairaUpdateCheck", package: "symaira-appkit"),
            ]
        ),
        .executableTarget(
            name: "SymCockpitApp",
            dependencies: [
                "SymCockpitVersion",
                .product(name: "SymCockpitUI", package: "tuning"),
                .product(name: "SymCockpitCore", package: "tuning"),
                .product(name: "SymairaTheme", package: "symaira-appkit"),
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
