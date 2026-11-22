import Foundation
import Observation

// The model of the Audio & MIDI page. It reads the agent's `audio.devices`, `midi.devices`
// and `audio.mixer.status` (subscribable topics, sampled only while the page is on screen)
// and acts through `audio.default.set`, `audio.volume.set`, `audio.mute.set`,
// `audio.app-volume.set` (reversible: they run at once) and `audio.format.set`,
// `audio.aggregate.create` (risky: a plan the shared confirmation applies). It owns no audio
// object. A failed read is a state with the agent's message, never an empty list.

// MARK: - Shapes of the agent's answers

public enum AudioDirection: String, Sendable, CaseIterable {
    case input, output

    public var title: String { self == .input ? "Input" : "Output" }
}

public struct AudioStreamFormat: Decodable, Equatable, Sendable {
    public let rate: Double
    public let bits: Int
    public let channels: Int
}

public struct AudioScopeState: Decodable, Equatable, Sendable {
    public let channels: Int
    public let volume: Double?
    public let volumeSettable: Bool
    public let muted: Bool?
    public let muteSettable: Bool
    public let format: AudioStreamFormat?
}

public struct SampleRateRange: Decodable, Equatable, Sendable {
    public let min: Double
    public let max: Double
}

public struct AudioDevice: Decodable, Equatable, Sendable, Identifiable {
    public let uid: String
    public let name: String
    public let manufacturer: String?
    /// `builtin`, `usb`, `bluetooth`, … or the four-character code.
    public let transport: String
    /// `physical`, `aggregate` or `virtual`.
    public let kind: String
    public let online: Bool
    public let defaultInput: Bool
    public let defaultOutput: Bool
    public let input: AudioScopeState
    public let output: AudioScopeState
    public let sampleRate: Double?
    public let sampleRates: [SampleRateRange]?
    public let members: [String]?

    public var id: String { uid }
    public var isAggregate: Bool { kind == "aggregate" }

    public func scope(_ direction: AudioDirection) -> AudioScopeState {
        direction == .input ? input : output
    }

    /// The side `audio.format.set` changes: the output when the device has one.
    public var formatDirection: AudioDirection { output.channels > 0 ? .output : .input }

    public func isDefault(_ direction: AudioDirection) -> Bool {
        direction == .input ? defaultInput : defaultOutput
    }

    /// An online device that has streams in `direction`.
    public func offers(_ direction: AudioDirection) -> Bool {
        online && scope(direction).channels > 0
    }

    private static let commonRates: [Double] = [
        8000, 11025, 16000, 22050, 32000, 44100, 48000, 88200, 96000, 176_400, 192_000,
    ]

    /// Common rates and range endpoints, limited to what the agent reports.
    public static func selectableRates(in ranges: [SampleRateRange], reported: [Double]) -> [Double] {
        let endpoints = ranges.flatMap { [$0.min, $0.max] }
        let available = (commonRates + reported).filter { hz in ranges.contains { hz >= $0.min && hz <= $0.max } }
        return Set(endpoints + available).filter { $0.isFinite && $0 > 0 }.sorted()
    }
}

public struct AudioFormatOptions: Decodable, Equatable, Sendable {
    public struct Scope: Decodable, Equatable, Sendable {
        public let format: AudioStreamFormat?
        public let formats: [AudioStreamFormat]
    }

    public let uid: String
    public let sampleRate: Double?
    public let sampleRates: [SampleRateRange]
    public let input: Scope
    public let output: Scope

    public func formats(for direction: AudioDirection) -> [AudioStreamFormat] {
        (direction == .input ? input : output).formats
    }
}

public struct AudioDeviceList: Decodable, Equatable, Sendable {
    public let devices: [AudioDevice]
    public let defaultInputUid: String?
    public let defaultOutputUid: String?

    public func devices(for direction: AudioDirection) -> [AudioDevice] {
        devices.filter { $0.offers(direction) }
    }

    /// What an aggregate can be made of: online, not itself an aggregate.
    public var aggregateCandidates: [AudioDevice] {
        devices.filter { $0.online && !$0.isAggregate }
    }
}

public struct MixerProcess: Decodable, Equatable, Sendable {
    public let pid: Int
    public let bundleId: String?
    public let runningOutput: Bool
}

public struct MixerManagedApp: Decodable, Equatable, Sendable {
    public let pid: Int
    public let volume: Double
    public let muted: Bool
    /// `active`, `pending`, `passthrough` or `failed`.
    public let state: String
    public let detail: String?
}

public struct MixerStatus: Decodable, Equatable, Sendable {
    public let supported: Bool
    public let mixerRunning: Bool
    public let managed: [MixerManagedApp]?
    public let audioProcesses: [MixerProcess]
}

/// One app of the mixer: the processes of a bundle id (or a lone process), with the
/// volume the agent holds for it, or 100 % when it holds none.
public struct MixerApp: Equatable, Sendable, Identifiable {
    public let id: String
    /// What `audio.app-volume.set` takes as `app`: the bundle id, or the process id.
    public let target: String
    public let name: String
    public let isPlaying: Bool
    public let volume: Double
    public let muted: Bool
    public let state: String?
    public let detail: String?
    /// `true` once the agent holds a setting for it.
    public let isManaged: Bool
}

extension MixerStatus {
    public func apps() -> [MixerApp] {
        let groups = Dictionary(grouping: audioProcesses) { $0.bundleId ?? "pid:\($0.pid)" }
        let held = Dictionary(uniqueKeysWithValues: (managed ?? []).map { ($0.pid, $0) })
        return groups.map { key, processes in
            let pids = processes.map(\.pid).sorted()
            let settings = pids.compactMap { held[$0] }
            let first = processes[0]
            return MixerApp(
                id: key,
                target: first.bundleId ?? String(first.pid),
                name: first.bundleId ?? "Process \(first.pid)",
                isPlaying: processes.contains { $0.runningOutput },
                volume: settings.first?.volume ?? 1,
                muted: settings.first?.muted ?? false,
                state: settings.first { $0.state == "failed" || $0.state == "pending" }?.state
                    ?? settings.first?.state,
                detail: settings.compactMap(\.detail).first.map(SecretRedactor.redact),
                isManaged: !settings.isEmpty
            )
        }
        .sorted {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

public struct MidiEndpoint: Decodable, Equatable, Sendable {
    public let uniqueId: Int
    public let name: String
    public let offline: Bool
    public let present: Bool
}

public struct MidiEntity: Decodable, Equatable, Sendable {
    public let uniqueId: Int
    public let name: String
    public let sources: [MidiEndpoint]
    public let destinations: [MidiEndpoint]
}

public struct MidiDevice: Decodable, Equatable, Sendable, Identifiable {
    public let uniqueId: Int
    public let name: String
    public let manufacturer: String?
    public let model: String?
    public let offline: Bool
    public let present: Bool
    public let entities: [MidiEntity]

    public var id: Int { uniqueId }
    public var inputs: Int { entities.reduce(0) { $0 + $1.sources.count } }
    public var outputs: Int { entities.reduce(0) { $0 + $1.destinations.count } }
}

public struct MidiList: Decodable, Equatable, Sendable {
    public let devices: [MidiDevice]
    public let standaloneSources: [MidiEndpoint]
    public let standaloneDestinations: [MidiEndpoint]

    public var isEmpty: Bool { devices.isEmpty && standaloneSources.isEmpty && standaloneDestinations.isEmpty }
}

/// Passive information from the agent's status and the last explicit mixer action.
public enum AudioCaptureAccess: Equatable, Sendable {
    /// The mixer reports that this Mac does not offer per-app volume.
    case unsupported
    case unknown
    case activeCapture
    case denied(String)
}

/// A recorded plan and what the page tells the person who reviews it.
@MainActor
public struct DevicePlan {
    public let confirmation: PlanConfirmationModel
    public let summary: String
    public let confirmTitle: String
    /// True until the plan was sent: what it concerns stays locked while it is open.
    public var isOpen: Bool { confirmation.report == nil }
}

/// A reversible write that the agent answered with a report that is not `confirmed`:
/// the device did not show the new value afterwards.
func unconfirmedProblem(_ output: AgentJSON) -> String? {
    guard let outcome = output["outcome"]?.stringValue, outcome != "confirmed" else { return nil }
    let detail = output["detail"]?.stringValue.map { " \($0)" } ?? ""
    switch outcome {
    case "skipped_changed": return "The device changed while the request was on its way, so nothing was done.\(detail)"
    default: return "The device did not show the new value afterwards.\(detail)"
    }
}

// MARK: - Model

@MainActor
@Observable
public final class AudioMIDIModel {
    public private(set) var devices: LoadState<AudioDeviceList> = .idle
    public private(set) var midi: LoadState<MidiList> = .idle
    public private(set) var mixer: LoadState<MixerStatus> = .idle
    public private(set) var pending: DevicePlan?
    /// Why the last action failed; cleared by the next one.
    public private(set) var failure: String?
    public private(set) var notice: String?
    public private(set) var isPlanning = false
    public private(set) var isActing = false
    public private(set) var isRefreshing = false
    private var captureProblem: String?

    @ObservationIgnored private let session: AgentSession
    @ObservationIgnored private var tokens: [UUID] = []
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var generation = 0
    private static let owner = "audio-midi"
    /// A HAL snapshot is cheap; two seconds keep the sliders in step with the keyboard keys.
    private static let interval = 2000

    public init(session: AgentSession) {
        self.session = session
    }

    // MARK: Derived

    public var mixerApps: [MixerApp] { mixer.value?.apps() ?? [] }
    public var controlsLocked: Bool { isActing || isPlanning || isRefreshing || pending?.isOpen == true }

    public var captureAccess: AudioCaptureAccess {
        if mixer.value?.supported == false { return .unsupported }
        if mixer.value?.managed?.contains(where: { $0.state == "active" }) == true { return .activeCapture }
        if let captureProblem { return .denied(captureProblem) }
        return .unknown
    }

    // MARK: Lifecycle

    /// Samples while the page is on screen, nothing otherwise (Q04).
    public func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        generation += 1
        let generation = generation
        if visible {
            devices = .loading
            midi = .loading
            mixer = .loading
            for command in ["audio.devices", "midi.devices", "audio.mixer.status"] {
                tokens.append(session.subscribe(command, visibleMs: Self.interval) { [weak self] event in
                    Task { @MainActor in
                        guard let self, self.generation == generation else { return }
                        self.receive(event)
                    }
                })
            }
        } else {
            tokens.forEach(session.unsubscribe)
            tokens = []
            // A reading that is no longer sampled is not shown.
            devices = .idle
            midi = .idle
            mixer = .idle
            notice = nil
            pending = nil
        }
        session.setVisible(visible, owner: Self.owner)
    }

    func receive(_ event: AgentEvent) {
        guard isVisible else { return }
        switch event.payload {
        case .result(let json):
            switch event.command {
            case "audio.devices": devices = decode(AudioDeviceList.self, json, what: "The audio devices")
            case "midi.devices": midi = decode(MidiList.self, json, what: "The MIDI devices")
            case "audio.mixer.status": mixer = decode(MixerStatus.self, json, what: "The app mixer")
            default: break
            }
        case .error(let error):
            let message = SecretRedactor.redact(error.message)
            switch event.command {
            case "audio.devices": devices = .failed(message)
            case "midi.devices": midi = .failed(message)
            case "audio.mixer.status": mixer = .failed(message)
            default: break
            }
        }
    }

    private func decode<T: Decodable & Equatable & Sendable>(_ type: T.Type, _ json: AgentJSON, what: String) -> LoadState<T> {
        do {
            return .loaded(try AgentDecoding.decode(type, from: json))
        } catch {
            return .failed("\(what) could not be read: \(error.localizedDescription)")
        }
    }

    /// Reads all three now, for manual refresh and retry.
    public func refresh() async {
        guard isVisible, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let generation = generation
        if devices.value == nil { devices = .loading }
        if midi.value == nil { midi = .loading }
        if mixer.value == nil { mixer = .loading }
        async let list = read(AudioDeviceList.self, "audio.devices", "The audio devices")
        async let midiList = read(MidiList.self, "midi.devices", "The MIDI devices")
        async let status = read(MixerStatus.self, "audio.mixer.status", "The app mixer")
        let (newDevices, newMidi, newMixer) = await (list, midiList, status)
        guard self.generation == generation else { return }
        devices = newDevices
        midi = newMidi
        mixer = newMixer
    }

    private func read<T: Decodable & Equatable & Sendable>(
        _ type: T.Type, _ command: String, _ what: String, params: [String: AgentJSON] = [:]
    ) async -> LoadState<T> {
        switch await session.perform(command, params: params) {
        case .done(let output): return decode(type, output, what: what)
        case .failed(let message, _): return .failed(SecretRedactor.redact(message))
        case .needsConfirmation: return .failed("The Cockpit agent asked for a confirmation to read this.")
        }
    }

    // MARK: Reversible actions

    public func setDefault(_ direction: AudioDirection, device: AudioDevice) async {
        guard device.offers(direction) else { return }
        await run(
            "audio.default.set",
            ["direction": .string(direction.rawValue), "uid": .string(device.uid)],
            done: "“\(device.name)” is now the default \(direction.rawValue) device."
        )
    }

    public func setVolume(_ value: Double, device: AudioDevice, direction: AudioDirection) async {
        guard value.isFinite, device.offers(direction), device.scope(direction).volumeSettable else { return }
        await run("audio.volume.set", [
            "uid": .string(device.uid), "value": .number(min(max(value, 0), 1)),
            "direction": .string(direction.rawValue),
        ], done: nil)
    }

    public func setMuted(_ muted: Bool, device: AudioDevice, direction: AudioDirection) async {
        guard device.offers(direction), device.scope(direction).muteSettable else { return }
        await run("audio.mute.set", [
            "uid": .string(device.uid), "muted": .bool(muted), "direction": .string(direction.rawValue),
        ], done: nil)
    }

    /// A non-identity setting can start the mixer and ask for audio recording permission.
    public func setAppVolume(_ value: Double, muted: Bool, app: MixerApp) async {
        guard value.isFinite, mixer.value?.supported == true, mixer.value?.mixerRunning == true else { return }
        await run("audio.app-volume.set", [
            "app": .string(app.target), "volume": .number(min(max(value, 0), 1)), "muted": .bool(muted),
        ], done: nil, isCapture: true)
    }

    private func run(_ command: String, _ params: [String: AgentJSON], done: String?, isCapture: Bool = false) async {
        guard isVisible, !controlsLocked else { return }
        isActing = true
        defer { isActing = false }
        failure = nil
        notice = nil
        switch await session.perform(command, params: params) {
        case .done(let output):
            if isCapture {
                let results = output["apps"]?.arrayValue ?? []
                if results.contains(where: { $0["state"]?.stringValue == "active" }) {
                    captureProblem = nil
                }
                if let failed = results.first(where: { $0["state"]?.stringValue == "failed" }) {
                    failure = failed["detail"]?.stringValue.map(SecretRedactor.redact)
                        ?? "The mixer could not apply the app setting."
                }
            } else {
                failure = unconfirmedProblem(output)
            }
            if failure == nil { notice = done }
            await refresh()
        case .failed(let message, let exitClass):
            let text = SecretRedactor.redact(message)
            failure = text
            if isCapture, exitClass == "permission" { captureProblem = text }
        case .needsConfirmation:
            failure = "The Cockpit agent asked for a confirmation; nothing was changed."
        }
    }

    // MARK: Plans (risky)

    public func loadFormats(for device: AudioDevice) async -> LoadState<AudioFormatOptions> {
        guard isVisible else { return .idle }
        return await read(
            AudioFormatOptions.self, "audio.format.get", "The audio formats", params: ["uid": .string(device.uid)]
        )
    }

    public func requestFormat(_ rate: Double, bits: Int?, device: AudioDevice) async {
        guard device.online, rate.isFinite, rate > 0 else { return }
        var params: [String: AgentJSON] = ["uid": .string(device.uid), "rate": .number(rate)]
        if let bits { params["bits"] = .number(Double(bits)) }
        let format = Self.hertz(rate) + (bits.map { ", \($0)-bit" } ?? "")
        await requestPlan(
            "audio.format.set", params,
            summary: "Set “\(device.name)” to \(format).", confirmTitle: "Apply Audio Format"
        )
    }

    public func requestAggregate(name: String, members: [String], main: String?, multiOutput: Bool) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Self.aggregateProblem(name: trimmed, memberCount: Set(members).count) {
            failure = problem
            return
        }
        guard members.count == Set(members).count, main.map({ members.contains($0) }) ?? true else {
            failure = "Choose distinct members and a clock source from those members."
            return
        }
        var params: [String: AgentJSON] = [
            "name": .string(trimmed), "members": .array(members.map(AgentJSON.string)),
            "multi_output": .bool(multiOutput),
        ]
        if let main { params["main"] = .string(main) }
        let kind = multiOutput ? "multi-output" : "aggregate"
        await requestPlan(
            "audio.aggregate.create", params,
            summary: "Create the \(kind) device “\(trimmed)” from \(members.count) devices.",
            confirmTitle: "Create Aggregate Device"
        )
    }

    /// The name must be 1 to 64 characters and at least two devices must be chosen.
    public static func aggregateProblem(name: String, memberCount: Int) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.count > 64 { return "Give the device a name of 1 to 64 characters." }
        if memberCount < 2 { return "Choose at least two devices." }
        return nil
    }

    private func requestPlan(
        _ command: String, _ params: [String: AgentJSON], summary: String, confirmTitle: String
    ) async {
        guard isVisible, !controlsLocked else { return }
        failure = nil
        notice = nil
        pending = nil
        isPlanning = true
        defer { isPlanning = false }
        switch await session.plan(command, params: params) {
        case .needsConfirmation(let plan):
            guard isVisible else { return }
            let confirmation = PlanConfirmationModel(plan: plan, session: session)
            confirmation.onFinished = { [weak self, weak confirmation] report in
                guard let self, let confirmation, self.pending?.confirmation === confirmation else { return }
                if report.isConfirmed { Task { await self.refresh() } }
            }
            pending = DevicePlan(confirmation: confirmation, summary: summary, confirmTitle: confirmTitle)
        case .done:
            failure = "The agent returned an unexpected result for the plan request."
            await refresh()
        case .failed(let message, _):
            failure = SecretRedactor.redact(message)
        }
    }

    public func dismissPending() {
        pending = nil
    }

    public nonisolated static func hertz(_ rate: Double) -> String {
        rate >= 1000
            ? String(format: "%g kHz", rate / 1000)
            : String(format: "%g Hz", rate)
    }
}
