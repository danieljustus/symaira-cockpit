#if DEBUG
import SwiftUI
import SymTuneCore
import SymairaTheme

/// The real passive Cockpit components, without the app's hardware lifecycle.
/// All values are labelled fixtures; interactions change local view state only.
/// The production workspace surrounds passive components. Fan, activity and
/// HUD model behavior still need the running app, not invented preview values.
struct CockpitDesignPreview: View {
    var showsReadings = true

    @State private var brightness = 0.62
    @State private var beyondNormal = 0.0
    @State private var warmth = 0.2
    @State private var keepAwake = false
    @State private var preventDisplaySleep = false
    @State private var durationIndex = 0
    @State private var showsPreviewPreferences = false
    @State private var fanProfile: FanProfile = .system

    var body: some View {
        CockpitWorkspaceView(version: TuneVersion.current, openPreferences: openPreviewPreferences) {
            VStack(alignment: .leading, spacing: SymairaSpacing.large) {
                VStack(alignment: .leading, spacing: SymairaSpacing.small) {
                    Text("This Mac")
                        .symairaText(.title, respectsForeground: false)
                        .foregroundStyle(SymairaTheme.textPrimary)
                    Label("PREVIEW · Beispieldaten · Keine Hardwarezugriffe", systemImage: "eye")
                        .symairaText(.caption, respectsForeground: false)
                        .foregroundStyle(SymairaTheme.goldSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .id(TuneWorkspaceAnchor.overview)

                SystemStatusCard(
                    battery: showsReadings ? Self.battery : nil,
                    sensors: showsReadings ? Self.sensors : nil
                )

                VStack(alignment: .leading, spacing: SymairaSpacing.medium) {
                    sectionLabel("Display")
                    displayControls
                    DisplaysCard(displays: showsReadings ? Self.displays : [])
                }
                .id(TuneWorkspaceAnchor.display)

                VStack(alignment: .leading, spacing: SymairaSpacing.medium) {
                    sectionLabel("Power & cooling")
                    VStack(alignment: .leading, spacing: SymairaSpacing.small) {
                        FanProfileSliderRow(profile: fanProfile, onCommit: selectPreviewFanProfile)
                        Text(fanProfile.summary)
                            .symairaText(.caption, respectsForeground: false)
                            .foregroundStyle(SymairaTheme.textSecondary)
                        Text("PREVIEW · Profile selection only · No fan writes")
                            .symairaText(.caption, respectsForeground: false)
                            .foregroundStyle(SymairaTheme.goldSecondary)
                    }
                    .cardStyle()
                    KeepAwakeCard(
                        active: keepAwake,
                        preventDisplaySleep: $preventDisplaySleep,
                        durationIndex: $durationIndex,
                        remaining: nil,
                        isInteractive: true,
                        presets: [("Indefinite", nil), ("15 min", 900), ("1 hour", 3600)],
                        onToggle: { keepAwake.toggle() }
                    )
                }
                .id(TuneWorkspaceAnchor.power)

                previewOnlySection("Activity", anchor: .activity)
                previewOnlySection("Menu bar & HUD", anchor: .readout)

                Text("Komponentenvorschau, nicht das vollständige Cockpit-Fenster. Regler und Schalter wirken nur hier.")
                    .symairaText(.caption, respectsForeground: false)
                    .foregroundStyle(SymairaTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("Design preview", isPresented: $showsPreviewPreferences) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Preferences are available in the running app. This preview writes no settings.")
        }
    }

    private func openPreviewPreferences() {
        showsPreviewPreferences = true
    }

    private func selectPreviewFanProfile(_ profile: FanProfile) {
        fanProfile = profile
    }

    private func previewOnlySection(_ title: String, anchor: TuneWorkspaceAnchor) -> some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            sectionLabel(title)
            Text("Available in the running app. No live model is started by this preview.")
                .symairaText(.callout, respectsForeground: false)
                .foregroundStyle(SymairaTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(anchor)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .symairaText(.heading, respectsForeground: false)
            .foregroundStyle(SymairaTheme.textPrimary)
    }

    /// Reuse the production slider rows, but commit only to preview-local state.
    private var displayControls: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.xLarge) {
            TuneSliderRow(
                title: "Screen Brightness", systemImage: "sun.max.fill",
                value: brightness, range: 0...1, onCommit: { brightness = $0 }
            )
            CenterAnchoredSliderRow(
                title: "Beyond Normal", systemImage: "circle.lefthalf.filled",
                position: beyondNormal, minimumLabel: "Darker", maximumLabel: "Brighter",
                onCommit: { beyondNormal = $0 }
            )
            TuneSliderRow(
                title: "Color Warmth", systemImage: "thermometer.sun.fill",
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

    // These public models have no public memberwise initializer. Decode fixed,
    // checked fixtures rather than widening production API for a design tool.
    private static let sensors = try! JSONDecoder().decode(SensorReport.self, from: Data(#"""
    {
        "thermalPressure": "nominal", "smcSupported": true,
        "temperatures": [{"key": "DEMO", "label": "CPU", "celsius": 48.5}],
        "fans": [{"index": 0, "label": "Demo fan", "rpm": 1800, "minRpm": 1200, "maxRpm": 6000}],
        "notes": ["Design fixture, not a hardware reading"]
    }
    """#.utf8))

    private static let displays = try! JSONDecoder().decode([DisplayInfo].self, from: Data(#"""
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
    """#.utf8))
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
