// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "tuning",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "SymCockpitCore", targets: ["SymCockpitCore"]),
        .library(name: "SymCockpitMCP", targets: ["SymCockpitMCP"]),
        .library(name: "SymCockpitCLI", targets: ["SymCockpitCLI"]),
        // Shared pieces of the optional privileged fan helper (issue #405):
        // XPC contract, signing requirements, heartbeat watchdog. The helper
        // executable itself is a root-package target.
        .library(name: "SymCockpitHelperKit", targets: ["SymCockpitHelperKit"]),
        .executable(name: "symtune", targets: ["symtune"]),
        .executable(name: "SymCockpitMenuBarApp", targets: ["SymCockpitMenuBarApp"]),
        // The menu-bar UI as a library so symcockpit's GUI can embed the very
        // same status item, popover and preferences instead of reimplementing them.
        .library(name: "SymCockpitUI", targets: ["SymCockpitUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/danieljustus/symaira-corekit.git", exact: "0.20.0"),
        .package(path: "../history"),
    ],
    targets: [
        .target(
            name: "SymCockpitCore",
            dependencies: [
                .product(name: "SymCockpitHistory", package: "history"),
                .product(name: "SymairaKeychain", package: "symaira-corekit"),
                .product(name: "SymairaUpdateCheck", package: "symaira-corekit"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
            ]
        ),
        .target(
            name: "SymCockpitHelperKit",
            dependencies: ["SymCockpitCore"]
        ),
        .target(
            name: "SymCockpitMCP",
            dependencies: [
                "SymCockpitCore",
                .product(name: "SymairaMCP", package: "symaira-corekit"),
            ]
        ),
        .target(
            name: "SymCockpitCLI",
            dependencies: [
                "SymCockpitCore",
                "SymCockpitMCP",
                .product(name: "SymairaUpdateCheck", package: "symaira-corekit"),
                .product(name: "SymairaTheme", package: "symaira-corekit"),
            ]
        ),
        .executableTarget(
            name: "symtune",
            dependencies: [
                "SymCockpitCLI"
            ]
        ),
        .target(
            name: "SymCockpitUI",
            dependencies: [
                "SymCockpitCore",
                .product(name: "SymairaProviderKit", package: "symaira-corekit"),
                .product(name: "SymairaKeychain", package: "symaira-corekit"),
                .product(name: "SymairaUpdateCheck", package: "symaira-corekit"),
                .product(name: "SymairaTheme", package: "symaira-corekit"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "SymCockpitMenuBarApp",
            dependencies: ["SymCockpitUI"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "SymCockpitCLITests",
            dependencies: ["SymCockpitCLI"]
        ),
        .testTarget(
            name: "SymCockpitCoreTests",
            dependencies: ["SymCockpitCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "SymCockpitHelperKitTests",
            dependencies: ["SymCockpitHelperKit", "SymCockpitCore"]
        ),
        .testTarget(
            name: "SymCockpitMCPTests",
            dependencies: [
                "SymCockpitMCP",
                .product(name: "SymairaMCP", package: "symaira-corekit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
