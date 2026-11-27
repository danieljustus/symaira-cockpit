import SwiftUI
import SymCockpitCore
import SymairaTheme

// Screen card
// 1. Destination: Audio & MIDI in the Cockpit sidebar.
// 2. Job: choose the default input and output and adjust audio levels.
// 3. Data: audio devices, MIDI and mixer snapshots from the agent while visible.
// 4. States: loading, empty, retry, capability and permission notices, shell diagnosis.
// 5. Density: stacked device, mixer, aggregate and MIDI cards.
// 6. Platform: macOS workspace. The page stores no preferences.

@MainActor
public struct AudioMIDIPage: View {
    @State private var model: AudioMIDIModel

    public init(session: AgentSession) {
        _model = State(initialValue: AudioMIDIModel(session: session))
    }

    public var body: some View {
        SymairaPage(
            title: CockpitDestination.audioMIDI.title, subtitle: CockpitDestination.audioMIDI.subtitle,
            maxWidth: CockpitLayout.pageWidth
        ) {
            Button("Refresh") { Task { await model.refresh() } }
                .symairaButtonStyle(.secondary)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isRefreshing)
        } content: {
            ScrollViewReader { scroll in
                VStack(alignment: .leading, spacing: SymairaSpacing.medium) {
                    if let failure = model.failure {
                        SymairaNotice(message: failure, tone: .critical)
                            .id("audio-action-failure")
                    }
                    if let notice = model.notice {
                        SymairaNotice(message: notice, tone: .positive)
                    }
                    if model.isPlanning {
                        ProgressView("Preparing audio plan…")
                    } else if model.isActing {
                        ProgressView("Applying audio setting…")
                    }
                    if let plan = model.pending {
                        DevicePlanReview(plan: plan, dismiss: model.dismissPending)
                            .symairaCard()
                            .id("audio-plan")
                    }
                    SymairaPageState(
                        state: model.devices.devicePageState, loading: "Loading audio devices…", retry: refresh
                    ) { list in
                        if list.devices.isEmpty {
                            SymairaPageEmpty(
                                icon: .audio, title: "No Audio Devices",
                                message: "Connect an audio device and refresh."
                            ) {
                                Button("Refresh", action: refresh).symairaButtonStyle(.secondary)
                            }
                        } else {
                            AudioDevicesCard(direction: .output, list: list, model: model)
                            AudioDevicesCard(direction: .input, list: list, model: model)
                            AudioAggregateCard(list: list, model: model)
                        }
                    }
                    AudioMixerCard(model: model, retry: refresh)
                    midiCard
                }
                .onChange(of: model.pending?.confirmation.plan.id) { _, id in
                    if id != nil { scroll.scrollTo("audio-plan", anchor: .top) }
                }
                .onChange(of: model.failure) { _, failure in
                    if failure != nil { scroll.scrollTo("audio-action-failure", anchor: .top) }
                }
            }
        }
        .onAppear { model.setVisible(true) }
        .onDisappear { model.setVisible(false) }
    }

    private func refresh() {
        Task { await model.refresh() }
    }

    private var midiCard: some View {
        SymairaPageState(state: model.midi.devicePageState, loading: "Loading MIDI devices…", retry: refresh) { list in
                        GroupBox {

                if list.isEmpty {
                    SymairaFormRow("No MIDI Devices", description: "Connect a MIDI device to see it here.")
                }
                ForEach(list.devices) { device in
                    midiDevice(device)
                }
                ForEach(list.standaloneSources, id: \.uniqueId) { endpoint in
                    midiEndpoint(endpoint, direction: "Source")
                }
                ForEach(list.standaloneDestinations, id: \.uniqueId) { endpoint in
                    midiEndpoint(endpoint, direction: "Destination")
                }
                        } label: {
                Text("MIDI")
                    .symairaText(.sectionLabel)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    private func midiDevice(_ device: MidiDevice) -> some View {
        let availability = device.offline || !device.present ? "Offline" : "Online"
        let summary = "\(availability) · \(device.inputs) inputs · \(device.outputs) outputs"
        return DisclosureGroup {
            ForEach(device.entities, id: \.uniqueId) { entity in
                SymairaFormRow(entity.name)
                ForEach(entity.sources, id: \.uniqueId) { endpoint in
                    midiEndpoint(endpoint, direction: "Source")
                }
                ForEach(entity.destinations, id: \.uniqueId) { endpoint in
                    midiEndpoint(endpoint, direction: "Destination")
                }
            }
            if device.entities.isEmpty {
                Text("The device reports no MIDI ports.").symairaText(.caption)
            }
        } label: {
            VStack(alignment: .leading, spacing: SymairaSpacing.xSmall) {
                Text(device.name).symairaText(.body)
                Text(summary).symairaText(.caption)
            }
            .padding(.vertical, SymairaSpacing.small)
        }
    }

    private func midiEndpoint(_ endpoint: MidiEndpoint, direction: String) -> some View {
        let availability = endpoint.offline || !endpoint.present ? "Offline" : "Online"
        return SymairaFormRow(endpoint.name, description: "\(direction) · \(availability)")
    }
}

extension LoadState {
    var devicePageState: SymairaPageLoadState<Value> {
        switch self {
        case .idle: .idle
        case .loading: .loading
        case .failed(let message): .failed(message)
        case .loaded(let value): .loaded(value)
        }
    }
}

@MainActor
struct DevicePlanReview: View {
    let plan: DevicePlan
    let dismiss: () -> Void

    var body: some View {
        PlanConfirmationView(
            model: plan.confirmation, summary: plan.summary, confirmTitle: plan.confirmTitle,
            applyingTitle: "Applying changes…", onClose: dismiss
        )
        .padding(.vertical, SymairaSpacing.small)
    }
}
