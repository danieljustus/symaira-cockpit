// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "symaira-scope",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "SymScopeCore", targets: ["SymScopeCore"]),
        .library(name: "SymScopeMCP", targets: ["SymScopeMCP"]),
        .executable(name: "symscope", targets: ["symscope"]),
    ],
    dependencies: [
        .package(url: "https://github.com/danieljustus/symaira-appkit.git", exact: "0.10.0"),
    ],
    targets: [
        .target(
            name: "SymScopeCore",
            dependencies: []
        ),
        .target(
            name: "SymScopeMCP",
            dependencies: [
                "SymScopeCore",
                .product(name: "SymairaMCP", package: "symaira-appkit"),
            ]
        ),
        .executableTarget(
            name: "symscope",
            dependencies: [
                "SymScopeCore",
                "SymScopeMCP",
            ]
        ),
        .testTarget(
            name: "SymScopeCoreTests",
            dependencies: ["SymScopeCore"]
        ),
        .testTarget(
            name: "SymScopeMCPTests",
            dependencies: ["SymScopeMCP"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
