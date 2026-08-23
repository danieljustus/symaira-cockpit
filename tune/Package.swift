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
    ],
    dependencies: [
        .package(url: "https://github.com/danieljustus/symaira-appkit.git", exact: "0.10.0"),
    ],
    targets: [
        .target(
            name: "SymTuneCore",
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
        .executableTarget(
            name: "SymTuneApp",
            dependencies: [
                "SymTuneCore",
                .product(name: "SymairaUpdateCheck", package: "symaira-appkit"),
                .product(name: "SymairaTheme", package: "symaira-appkit"),
            ],
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
