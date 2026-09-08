// swift-tools-version: 6.0
import PackageDescription

// Standalone probe: does a CGEventTap actually swallow F1/F2 on this Mac,
// and can we draw a HUD that passes for the native one?
// Deliberately not wired into the symcockpit package graph — it is a spike.
let package = Package(
    name: "BrightnessHUDProbe",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "BrightnessHUDProbe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
