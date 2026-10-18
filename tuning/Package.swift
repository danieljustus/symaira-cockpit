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
        .executable(name: "symtune", targets: ["symtune"]),
        .executable(name: "SymCockpitMenuBarApp", targets: ["SymCockpitMenuBarApp"]),
        // The menu-bar UI as a library so symcockpit's GUI can embed the very
        // same status item, popover and preferences instead of reimplementing them.
        .library(name: "SymCockpitUI", targets: ["SymCockpitUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/danieljustus/symaira-appkit.git", exact: "0.15.1"),
        .package(path: "../history"),
    ],
    targets: [
        .target(
            name: "SymCockpitCore",
            dependencies: [
                .product(name: "SymCockpitHistory", package: "history"),
                .product(name: "SymairaKeychain", package: "symaira-appkit"),
                .product(name: "SymairaUpdateCheck", package: "symaira-appkit"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
            ]
        ),
        .target(
            name: "SymCockpitMCP",
            dependencies: [
                "SymCockpitCore",
                .product(name: "SymairaMCP", package: "symaira-appkit"),
            ]
        ),
        .target(
            name: "SymCockpitCLI",
            dependencies: [
                "SymCockpitCore",
                "SymCockpitMCP",
                .product(name: "SymairaUpdateCheck", package: "symaira-appkit"),
                .product(name: "SymairaTheme", package: "symaira-appkit"),
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
                .product(name: "SymairaProviderKit", package: "symaira-appkit"),
                .product(name: "SymairaKeychain", package: "symaira-appkit"),
                .product(name: "SymairaUpdateCheck", package: "symaira-appkit"),
                .product(name: "SymairaTheme", package: "symaira-appkit"),
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
            name: "SymCockpitMCPTests",
            dependencies: [
                "SymCockpitMCP",
                .product(name: "SymairaMCP", package: "symaira-appkit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
