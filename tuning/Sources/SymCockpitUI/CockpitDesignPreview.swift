#if DEBUG
import SwiftUI
import SymCockpitCore
import SymairaTheme

/// The real passive Cockpit components, without the app's hardware lifecycle.
/// All values are labelled fixtures; interactions change local view state only.
/// The production workspace surrounds passive components. Fan, activity and
/// HUD model behavior still need the running app, not invented preview values.
public struct CockpitDesignPreview: View {
    var showsReadings = true
    @State private var appearance: CockpitAppearancePreferences

    public init(showsReadings: Bool = true, appearance: CockpitAppearance = .system) {
        self.showsReadings = showsReadings
        _appearance = State(initialValue: CockpitAppearancePreferences(defaults: nil, initialValue: appearance))
    }

    @State private var brightness = 0.62
    @State private var beyondNormal = 0.0
    @State private var warmth = 0.2
    @State private var keepAwake = false
    @State private var preventDisplaySleep = false
    @State private var durationIndex = 0
    @State private var showsPreviewPreferences = false
    @State private var fanProfile: FanProfile = .system

    public var body: some View {
        CockpitWorkspaceView(
            version: TuneVersion.current, openPreferences: openPreviewPreferences, appearance: appearance
        ) { destination in
            SymairaPage(title: destination.title, subtitle: destination.subtitle, maxWidth: CockpitLayout.pageWidth) {
                VStack(alignment: .leading, spacing: SymairaSpacing.large) {
                    Label("PREVIEW · Beispieldaten · Keine Hardwarezugriffe", symairaIcon: .visible, iconSize: 14)
                        .symairaText(.caption, respectsForeground: false)
                        .foregroundStyle(SymairaTokens.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .cockpitProtected()
                    content(for: destination)
                    Text("Komponentenvorschau, nicht das vollständige Cockpit-Fenster. Regler und Schalter wirken nur hier.")
                        .symairaText(.caption, respectsForeground: false)
                        .foregroundStyle(SymairaTokens.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .cockpitProtected()
                }
            }
        }
        .alert("Design preview", isPresented: $showsPreviewPreferences) {
            Button("Dismiss", role: .cancel) { }
        } message: {
            Text("Preferences are available in the running app. This preview writes no settings.")
        }
    }

    @ViewBuilder
    private func content(for destination: CockpitDestination) -> some View {
        switch destination {
        case .overview:
            SystemStatusCard(
                battery: showsReadings ? Self.battery : nil,
                sensors: showsReadings ? Self.sensors : nil
            )
            SensorsCard(sensors: showsReadings ? Self.sensors : nil)
        case .display:
            displayControls
            KeepAwakeCard(
                active: keepAwake,
                preventDisplaySleep: $preventDisplaySleep,
                durationIndex: $durationIndex,
                remaining: nil,
                isInteractive: true,
                presets: [("Indefinite", nil), ("15 min", 900), ("1 hour", 3600)],
                onToggle: { keepAwake.toggle() }
            )
            DisplaysCard(displays: showsReadings ? Self.displays : [])
        case .powerFans:
            BatteryCard(battery: showsReadings ? Self.battery : nil)
            VStack(alignment: .leading, spacing: SymairaSpacing.small) {
                FanProfileSliderRow(profile: fanProfile, onCommit: selectPreviewFanProfile)
                Text(fanProfile.summary)
                    .symairaText(.caption, respectsForeground: false)
                    .foregroundStyle(SymairaTokens.ink2)
                Text("PREVIEW · Profile selection only · No fan writes")
                    .symairaText(.caption, respectsForeground: false)
                    .foregroundStyle(SymairaTokens.ink)
            }
            .cardStyle()
        case .storage:
            StorageVolumesCard(volumes: showsReadings ? Self.volumes : nil)
        default:
            Text("Available in the running app. No live model is started by this preview.")
                .symairaText(.callout, respectsForeground: false)
                .foregroundStyle(SymairaTokens.ink2)
                .cockpitProtected()
        }
    }

    private func openPreviewPreferences() {
        showsPreviewPreferences = true
    }

    private func selectPreviewFanProfile(_ profile: FanProfile) {
        fanProfile = profile
    }

    /// Reuse the production slider rows, but commit only to preview-local state.
    private var displayControls: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.xLarge) {
            TuneSliderRow(
                title: "Screen Brightness", icon: .lightMode,
                value: brightness, range: 0...1, onCommit: { brightness = $0 }
            )
            CenterAnchoredSliderRow(
                title: "Beyond Normal", icon: .appearance,
                position: beyondNormal, minimumLabel: "Darker", maximumLabel: "Brighter",
                onCommit: { beyondNormal = $0 }
            )
            TuneSliderRow(
                title: "Color Warmth", icon: .temperature,
                value: warmth, range: 0...1, onCommit: { warmth = $0 }
            )
        }
        .cardStyle()
    }

    private static let battery = BatteryReport(
        present: true, charging: false, externalConnected: false,
        currentCapacityPercent: 76, cycleCount: 42,
        designCapacityMah: 6000, maxCapacityMah: 5820, healthPercent: 97,
        temperatureCelsius: 29, chargeLimitSupported: false,
        notes: ["Design fixture, not a hardware reading"]
    )

    private static let volumes: [StorageVolumeReport] = [
        StorageVolumeReport(
            name: "Demo Macintosh HD", mountPath: "/", isInternal: true, isLocal: true,
            space: DiskReport(capacityBytes: 512_000_000_000, usedBytes: 256_000_000_000, freeBytes: 256_000_000_000)
        ),
        StorageVolumeReport(
            name: "Demo External SSD", mountPath: "/Volumes/Demo External SSD", isInternal: false, isLocal: true,
            space: DiskReport(capacityBytes: 1_000_000_000_000, usedBytes: 750_000_000_000, freeBytes: 250_000_000_000)
        ),
        StorageVolumeReport(name: "Demo Unavailable", mountPath: "/Volumes/Demo Unavailable", isReadOnly: true)
    ]

    // These public models have no public memberwise initializer. Decode fixed,
    // validated fixtures rather than widening production API for a design tool.
    private static func decodeFixture<Model: Decodable>(_ type: Model.Type, json: String) -> Model {
        do {
            return try JSONDecoder().decode(type, from: Data(json.utf8))
        } catch {
            preconditionFailure("Invalid Cockpit design fixture for \(type): \(error)")
        }
    }

    private static let sensors = decodeFixture(SensorReport.self, json: #"""
    {
        "thermalPressure": "nominal", "smcSupported": true,
        "temperatures": [{"key": "DEMO", "label": "CPU", "celsius": 48.5}],
        "fans": [{"index": 0, "label": "Demo fan", "rpm": 1800, "minRpm": 1200, "maxRpm": 6000}],
        "notes": ["Design fixture, not a hardware reading"]
    }
    """#)

    private static let displays = decodeFixture([DisplayInfo].self, json: #"""
    [
        {
            "name": "Demo Built-in Display", "displayID": 1, "isBuiltin": true,
            "maxEDRHeadroom": 1.5, "potentialEDRHeadroom": 2.0,
            "edrCapable": true, "backingScaleFactor": 2.0
        },
        {
            "name": "Demo External Display", "displayID": 2, "isBuiltin": false,
            "maxEDRHeadroom": 1.0, "potentialEDRHeadroom": 1.0,
            "edrCapable": false, "backingScaleFactor": 2.0
        }
    ]
    """#)
}

#Preview("Cockpit · Breit", traits: .fixedLayout(width: 1080, height: 760)) {
    CockpitDesignPreview()
}

#Preview("Cockpit · Kompakt", traits: .fixedLayout(width: 620, height: 740)) {
    CockpitDesignPreview()
}

#Preview("Cockpit · Ohne Messwerte", traits: .fixedLayout(width: 1080, height: 760)) {
    CockpitDesignPreview(showsReadings: false)
}
#endif
