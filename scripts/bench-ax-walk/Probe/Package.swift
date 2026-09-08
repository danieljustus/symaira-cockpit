// swift-tools-version: 6.0
import PackageDescription

// Benchmark-only package. It is deliberately not part of PACKAGES in the
// Makefile or of the CI matrices: it needs a running GUI application and an
// Accessibility grant, neither of which exists on a CI runner.
let package = Package(
    name: "ax-walk-probe",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../../operate"),
    ],
    targets: [
        .executableTarget(
            name: "probe",
            dependencies: [.product(name: "SymOperateCore", package: "operate")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
