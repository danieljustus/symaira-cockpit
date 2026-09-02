// swift-tools-version: 6.0
import PackageDescription

// symcockpit — the unified entrypoint for the cockpit tool family.
// Dispatches to tune/operate/scope CLI libraries via local path dependencies.
let package = Package(
    name: "symcockpit",
    platforms: [
        // operate targets macOS 15 (ScreenCaptureKit APIs); the dispatcher
        // inherits the highest of its dependencies.
        .macOS(.v15),
    ],
    products: [
        .executable(name: "symcockpit", targets: ["symcockpit"]),
        // The GUI: one menu-bar item plus a cockpit window over all three
        // families. Ships alongside the CLI, not instead of it.
        .executable(name: "SymCockpitApp", targets: ["SymCockpitApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/danieljustus/symaira-appkit.git", exact: "0.14.0"),
        .package(path: "tune"),
        .package(path: "operate"),
        .package(path: "scope"),
    ],
    targets: [
        .target(name: "SymCockpitVersion"),
        .executableTarget(
            name: "symcockpit",
            dependencies: [
                "SymCockpitVersion",
                .product(name: "SymTuneCLI", package: "tune"),
                .product(name: "SymOperateCLI", package: "operate"),
                .product(name: "SymScopeCLI", package: "scope"),
                .product(name: "SymScopeCore", package: "scope"),
                .product(name: "SymairaUpdateCheck", package: "symaira-appkit"),
            ]
        ),
        .executableTarget(
            name: "SymCockpitApp",
            dependencies: [
                "SymCockpitVersion",
                .product(name: "SymTuneUI", package: "tune"),
                .product(name: "SymTuneCore", package: "tune"),
                .product(name: "SymScopeCore", package: "scope"),
                .product(name: "SymOperateCore", package: "operate"),
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
                .product(name: "SymTuneCore", package: "tune"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
