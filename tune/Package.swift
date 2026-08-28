// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "symaira-tune",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "SymTuneCore", targets: ["SymTuneCore"]),
        .library(name: "SymTuneMCP", targets: ["SymTuneMCP"]),
        .library(name: "SymTuneCLI", targets: ["SymTuneCLI"]),
        .executable(name: "symtune", targets: ["symtune"]),
        .executable(name: "SymTuneApp", targets: ["SymTuneApp"]),
        // The menu-bar UI as a library so symcockpit's GUI can embed the very
        // same status item, popover and preferences instead of reimplementing them.
        .library(name: "SymTuneUI", targets: ["SymTuneUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/danieljustus/symaira-appkit.git", exact: "0.14.0"),
        .package(path: "../history"),
    ],
    targets: [
        .target(
            name: "SymTuneCore",
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
            name: "SymTuneMCP",
            dependencies: [
                "SymTuneCore",
                .product(name: "SymairaMCP", package: "symaira-appkit"),
            ]
        ),
        .target(
            name: "SymTuneCLI",
            dependencies: [
                "SymTuneCore",
                "SymTuneMCP",
                .product(name: "SymairaUpdateCheck", package: "symaira-appkit"),
                .product(name: "SymairaTheme", package: "symaira-appkit"),
            ]
        ),
        .executableTarget(
            name: "symtune",
            dependencies: [
                "SymTuneCLI"
            ]
        ),
        .target(
            name: "SymTuneUI",
            dependencies: [
                "SymTuneCore",
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
            name: "SymTuneApp",
            dependencies: ["SymTuneUI"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "SymTuneCoreTests",
            dependencies: ["SymTuneCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "SymTuneMCPTests",
            dependencies: [
                "SymTuneMCP",
                .product(name: "SymairaMCP", package: "symaira-appkit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
