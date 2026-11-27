import SwiftUI
import SymCockpitCore
import SymairaTheme

// Screen card
// 1. Destination: Bluetooth & Input in the Cockpit sidebar.
// 2. Job: inspect paired and nearby devices and configure Finder Cut.
// 3. Data: paired devices on open and refresh, BLE session and Input status while visible.
// 4. States: loading, empty, bounded scan, retry, permission and capability notices, shell diagnosis.
// 5. Density: stacked paired devices, BLE explorer, log and Input cards.
// 6. Platform: macOS workspace. Finder Cut uses the agent's existing setting.

@MainActor
public struct BluetoothInputPage: View {
    @State private var bluetooth: BluetoothModel
    @State private var input: InputModel

    public init(session: AgentSession) {
        _bluetooth = State(initialValue: BluetoothModel(session: session))
        _input = State(initialValue: InputModel(session: session))
    }

    public var body: some View {
        SymairaPage(
            title: CockpitDestination.bluetoothInput.title, subtitle: CockpitDestination.bluetoothInput.subtitle,
            maxWidth: CockpitLayout.pageWidth
        ) {
            Button("Refresh", action: refresh)
                .symairaButtonStyle(.secondary)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(bluetooth.isLoadingPaired || bluetooth.radioIsBusy)
        } content: {
            ScrollViewReader { scroll in
                VStack(alignment: .leading, spacing: SymairaSpacing.medium) {
                    if let failure = bluetooth.failure {
                        SymairaNotice(message: failure, tone: .critical).id("bluetooth-action-failure")
                    }
                    if let plan = bluetooth.pending {
                        DevicePlanReview(plan: plan, dismiss: bluetooth.dismissPending)
                            .symairaCard()
                            .id("bluetooth-plan")
                    }
                    pairedCard
                    BLEExplorerCard(model: bluetooth)
                    BLEActivityCard(model: bluetooth)
                    CockpitInputCard(model: input)
                }
                .onChange(of: bluetooth.pending?.confirmation.plan.id) { _, id in
                    if id != nil { scroll.scrollTo("bluetooth-plan", anchor: .top) }
                }
                .onChange(of: bluetooth.failure) { _, failure in
                    if failure != nil { scroll.scrollTo("bluetooth-action-failure", anchor: .top) }
                }
            }
        }
        .task {
            bluetooth.setVisible(true)
            input.setVisible(true)
            await bluetooth.loadPaired()
        }
        .onDisappear {
            bluetooth.setVisible(false)
            input.setVisible(false)
        }
    }

    private func refresh() {
        Task { await bluetooth.loadPaired() }
        Task { await bluetooth.refreshSession() }
        Task { await input.refresh() }
    }

    private var pairedCard: some View {
        SymairaPageState(state: bluetooth.paired.devicePageState, loading: "Loading paired devices…", retry: {
            Task { await bluetooth.loadPaired() }
        }) { devices in
                        GroupBox {

                if devices.isEmpty {
                    SymairaFormRow("No Paired Devices", description: "Pair a device in System Settings, then refresh.") {
                        DeviceSettingsLink("Open Bluetooth Settings", pane: "com.apple.BluetoothSettings")
                    }
                }
                ForEach(devices.indices, id: \.self) { index in
                    let device = devices[index]
                    if index > 0 { SymairaFormDivider() }
                    SymairaFormRow(device.name, description: device.battery.summary) {
                        SymairaStatusLabel(
                            device.connected ? "Connected" : "Disconnected",
                            tone: device.connected ? .positive : .neutral
                        )
                    }
                }
                        } label: {
                Text("Paired Devices")
                    .symairaText(.sectionLabel)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }
}

@MainActor
struct DeviceSettingsLink: View {
    let title: String
    let pane: String
    @Environment(\.openURL) private var openURL

    init(_ title: String, pane: String) {
        self.title = title
        self.pane = pane
    }

    var body: some View {
        Button(title) {
            if let url = URL(string: "x-apple.systempreferences:\(pane)") { openURL(url) }
        }
        .symairaButtonStyle(.secondary)
    }
}
