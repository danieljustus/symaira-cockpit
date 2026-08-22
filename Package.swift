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
    ],
    dependencies: [
        .package(url: "https://github.com/danieljustus/symaira-appkit.git", exact: "0.10.0"),
        .package(path: "tune"),
        .package(path: "operate"),
        .package(path: "scope"),
    ],
    targets: [
        .executableTarget(
            name: "symcockpit",
            dependencies: [
                .product(name: "SymTuneCLI", package: "tune"),
                .product(name: "SymOperateCLI", package: "operate"),
                .product(name: "SymScopeCLI", package: "scope"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
