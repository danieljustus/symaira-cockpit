// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "symaira-operate",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "SymOperateCore", targets: ["SymOperateCore"]),
        .library(name: "SymOperateMCP", targets: ["SymOperateMCP"]),
        .executable(name: "symoperate", targets: ["symoperate"]),
    ],
    dependencies: [
        .package(url: "https://github.com/danieljustus/symaira-appkit.git", exact: "0.9.1"),
    ],
    targets: [
        .target(
            name: "SymOperateCore",
            dependencies: [
                .product(name: "SymairaUpdateCheck", package: "symaira-appkit"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .target(
            name: "SymOperateMCP",
            dependencies: [
                "SymOperateCore",
                .product(name: "SymairaMCP", package: "symaira-appkit"),
            ]
        ),
        .executableTarget(
            name: "symoperate",
            dependencies: ["SymOperateCore", "SymOperateMCP"]
        ),
        .testTarget(
            name: "SymOperateCoreTests",
            dependencies: [
                "SymOperateCore",
                "SymOperateMCP",
                .product(name: "SymairaUpdateCheck", package: "symaira-appkit"),
                .product(name: "SymairaMCP", package: "symaira-appkit"),
            ]
        ),
        .testTarget(
            name: "SymOperateSmokeTests",
            dependencies: ["SymOperateCore", "SymOperateMCP"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
