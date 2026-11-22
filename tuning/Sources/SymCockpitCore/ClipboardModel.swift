import Foundation
import Observation

// The Clipboard page's model. The history is for the human only: it is read through the
// agent's own methods (`clipboard.list/read/copy/delete/settings/configure`, docs/agent-protocol.md),
// which have no CLI path and no MCP tool. Pause, resume and clear are register commands. The model
// owns no capture and no storage; every value comes from the agent, a failed read is a state.
// Content is held only while the page is visible and dropped when it is hidden.

public struct ClipboardSettings: Equatable, Sendable {
    public var enabled: Bool
    public var paused: Bool
    public var excludedApps: [String]
    public var maxItems: Int
    public var maxAgeSeconds: Int

    public var isCapturing: Bool { enabled && !paused }
    public var maxAgeDays: Int { max(1, maxAgeSeconds / 86_400) }

    init?(json: AgentJSON) {
        guard let enabled = json["enabled"]?.boolValue, let paused = json["paused"]?.boolValue else { return nil }
        self.enabled = enabled
        self.paused = paused
        self.excludedApps = (json["excluded_apps"]?.arrayValue ?? []).compactMap(\.stringValue)
        self.maxItems = json["max_items"]?.intValue ?? 0
        self.maxAgeSeconds = json["max_age_secs"]?.intValue ?? 0
    }
}

/// One history entry as the list gives it: metadata only, no content and no source.
public struct ClipboardItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let date: Date
    /// `text` or `image`; another word is shown as it came.
    public let kind: String
    public let size: Int

    public var isText: Bool { kind == "text" }
    public var isImage: Bool { kind == "image" }
}

/// One entry opened (`clipboard.read`): the source app and the decrypted content.
public struct ClipboardDetail: Equatable, Sendable {
    public let id: String
    public let source: String?
    public let text: String?
    public let png: Data?
}

public struct ClipboardSnapshot: Equatable, Sendable {
    public let settings: ClipboardSettings
    public let items: [ClipboardItem]
    /// The capture service's own error (a pasteboard it could not read, a key it could not open).
    public let serviceError: String?
}

@MainActor
@Observable
public final class ClipboardModel {
    public private(set) var state: LoadState<ClipboardSnapshot> = .idle
    public private(set) var details: [String: ClipboardDetail] = [:]
    /// Entries that could not be opened (gone, or the key was refused), by id.
    public private(set) var detailFailures: [String: String] = [:]
    /// Why the last change failed; cleared by the next one.
    public private(set) var failure: String?
    public private(set) var notice: String?
    public private(set) var isBusy = false

    @ObservationIgnored private let session: AgentSession
    @ObservationIgnored private let limit: Int
    @ObservationIgnored private var token: UUID?
    @ObservationIgnored private var lastStatus: AgentJSON?
    @ObservationIgnored private var loadRequest: UUID?
    @ObservationIgnored private var detailRequest: UUID?
    @ObservationIgnored private let owner = "clipboard-\(UUID())"

    public init(session: AgentSession, limit: Int = 200) {
        self.session = session
        self.limit = limit
    }

    public func clearMessages() {
        failure = nil
        notice = nil
    }

    /// The agent hosts the history. A plain `serve` process or an older agent does not.
    public var isOffered: Bool {
        ["clipboard.list", "clipboard.settings", "clipboard.configure"].allSatisfy(session.offers(method:))
    }

    public var canCopyBack: Bool { session.offers(method: "clipboard.copy") }
    public var canDelete: Bool { session.offers(method: "clipboard.delete") }
    public var canReadContent: Bool { session.offers(method: "clipboard.read") }

    // MARK: Visibility

    /// Samples the cheap `clipboard.status` while the page is on screen, so a new copy shows
    /// without a refresh. Hidden: nothing is subscribed and the opened content is dropped.
    public func setVisible(_ visible: Bool) {
        if visible {
            guard token == nil else { return }
            lastStatus = nil
            token = session.subscribe("clipboard.status", visibleMs: 2000) { [weak self] event in
                Task { @MainActor in await self?.receive(event) }
            }
        } else {
            if let token { session.unsubscribe(token) }
            token = nil
            clearDetail()
        }
        session.setVisible(visible, owner: owner)
    }

    private func receive(_ event: AgentEvent) async {
        guard token != nil, !isBusy, loadRequest == nil, case .result(let json) = event.payload else { return }
        let changed = lastStatus.map { $0 != json } ?? false
        lastStatus = json
        // ponytail: the register reports counts, not the newest ID. Read bounded metadata
        // while capturing so a new entry is visible even at the retention limit.
        if changed || json["capturing"]?.boolValue == true { await load() }
    }

    // MARK: Loading

    public func load() async {
        guard isOffered else { return }
        let request = UUID()
        loadRequest = request
        defer { if loadRequest == request { loadRequest = nil } }
        if state.value == nil { state = .loading }
        let settings: ClipboardSettings
        let settingsResult = await session.invoke("clipboard.settings")
        guard loadRequest == request else { return }
        switch settingsResult {
        case .done(let json):
            guard let parsed = ClipboardSettings(json: json) else {
                state = .failed("The clipboard settings could not be read.")
                return
            }
            settings = parsed
        case .failed(let message, _):
            state = .failed(SecretRedactor.redact(message))
            return
        case .needsConfirmation:
            state = .failed("The Cockpit agent asked for a confirmation to read the clipboard settings.")
            return
        }
        let items: [ClipboardItem]
        let listResult = await session.invoke("clipboard.list", params: ["limit": .number(Double(limit))])
        guard loadRequest == request else { return }
        switch listResult {
        case .done(let json):
            guard let entries = json["items"]?.arrayValue else {
                state = .failed("The clipboard history could not be read.")
                return
            }
            items = entries.compactMap(Self.item)
        case .failed(let message, _):
            state = .failed(SecretRedactor.redact(message))
            return
        case .needsConfirmation:
            state = .failed("The Cockpit agent asked for a confirmation to list the clipboard history.")
            return
        }
        let error = await serviceError()
        guard loadRequest == request else { return }
        state = .loaded(ClipboardSnapshot(settings: settings, items: items, serviceError: error))
    }

    private static func item(_ json: AgentJSON) -> ClipboardItem? {
        guard let id = json["id"]?.stringValue, let created = json["created_at"]?.intValue else { return nil }
        return ClipboardItem(
            id: id, date: Date(timeIntervalSince1970: TimeInterval(created)),
            kind: json["kind"]?.stringValue ?? "unknown", size: json["size"]?.intValue ?? 0
        )
    }

    /// The capture service's last error, from `services`. A failed read is no error to show:
    /// the history itself loaded.
    private func serviceError() async -> String? {
        guard session.offers(method: "services"),
              case .done(let json) = await session.invoke("services"),
              let error = json["clipboard"]?["last_error"]?.stringValue, !error.isEmpty
        else { return nil }
        return SecretRedactor.redact(error)
    }

    // MARK: Entries

    /// Opens only the selected entry. A response from an old selection cannot repopulate it.
    public func loadDetail(_ id: String) async {
        guard token != nil, canReadContent else { return }
        clearDetail()
        let request = UUID()
        detailRequest = request
        let outcome = await session.invoke("clipboard.read", params: ["id": .string(id)])
        guard detailRequest == request, !Task.isCancelled else { return }
        switch outcome {
        case .done(let json):
            details[id] = ClipboardDetail(
                id: id, source: json["source"]?.stringValue, text: json["text"]?.stringValue,
                png: json["png_base64"]?.stringValue.flatMap { Data(base64Encoded: $0) }
            )
        case .failed(let message, _):
            detailFailures[id] = SecretRedactor.redact(message)
        case .needsConfirmation:
            detailFailures[id] = "The Cockpit agent asked for a confirmation; nothing was opened."
        }
    }

    public func clearDetail() {
        detailRequest = nil
        details = [:]
        detailFailures = [:]
    }

    public func copyBack(_ id: String) async {
        _ = await run("clipboard.copy", ["id": .string(id)], flag: "copied",
                      done: "Copied back to the clipboard.", reload: false)
    }

    public func delete(_ id: String) async {
        if await run("clipboard.delete", ["id": .string(id)], flag: "deleted",
                     done: "Deleted the entry.", reload: true) {
            if details[id] != nil || detailFailures[id] != nil { clearDetail() }
        }
    }

    public func clearAll() async {
        if await runCommand("clipboard.clear", done: { json in
            let count = json["cleared"]?.intValue ?? 0
            return count == 1 ? "Deleted 1 entry." : "Deleted \(count) entries."
        }) {
            details = [:]
            detailFailures = [:]
        }
    }

    // MARK: Settings

    /// The opt-in. Off by default; the agent starts or stops the capture at once.
    public func setEnabled(_ enabled: Bool) async {
        _ = await configure(
            ["enabled": .bool(enabled)],
            done: enabled ? "Clipboard history is on. Only what you copy from now on is kept."
                : "Clipboard history is off. Saved entries stay until you delete them."
        )
    }

    public func setPaused(_ paused: Bool) async {
        _ = await runCommand(paused ? "clipboard.pause" : "clipboard.resume", done: { _ in
            paused ? "Capture is paused." : "Capture is running again."
        })
    }

    public func addExcludedApp(_ bundleID: String) async -> Bool {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidBundleID(id) else {
            failure = "A bundle identifier looks like com.example.App: letters, digits, dots and hyphens."
            notice = nil
            return false
        }
        let current = state.value?.settings.excludedApps ?? []
        guard !current.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else {
            failure = "That app is already excluded."
            notice = nil
            return false
        }
        return await configure(
            ["excluded_apps": .array((current + [id]).map(AgentJSON.string))], done: "Excluded \(id)."
        )
    }

    public func removeExcludedApp(_ bundleID: String) async {
        let current = state.value?.settings.excludedApps ?? []
        _ = await configure(
            ["excluded_apps": .array(current.filter { $0 != bundleID }.map(AgentJSON.string))],
            done: "Stopped excluding \(bundleID)."
        )
    }

    public static func isValidBundleID(_ text: String) -> Bool {
        guard text.count <= 255, text.contains("."), !text.hasPrefix("."), !text.hasSuffix(".") else { return false }
        return text.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_")
        }
    }

    // MARK: Running

    private func configure(_ patch: [String: AgentJSON], done: String) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        loadRequest = nil
        defer { isBusy = false }
        failure = nil
        notice = nil
        switch await session.invoke("clipboard.configure", params: patch) {
        case .done(let json):
            if json["state"]?.stringValue == "failed" {
                failure = SecretRedactor.redact(
                    json["last_error"]?.stringValue ?? "The clipboard capture could not start.")
            } else {
                notice = done
            }
            await load()
            return true
        case .failed(let message, _):
            failure = SecretRedactor.redact(message)
        case .needsConfirmation:
            failure = "The Cockpit agent asked for a confirmation; nothing was changed."
        }
        return false
    }

    private func run(
        _ method: String, _ params: [String: AgentJSON], flag: String, done: String, reload: Bool
    ) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        loadRequest = nil
        defer { isBusy = false }
        failure = nil
        notice = nil
        switch await session.invoke(method, params: params) {
        case .done(let result):
            if reload { await load() }
            guard result[flag]?.boolValue == true else {
                failure = "The agent did not confirm the change. The entry may no longer be available."
                return false
            }
            notice = done
            return true
        case .failed(let message, _):
            failure = SecretRedactor.redact(message)
        case .needsConfirmation:
            failure = "The Cockpit agent asked for a confirmation; nothing was changed."
        }
        return false
    }

    private func runCommand(_ command: String, done: (AgentJSON) -> String) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        loadRequest = nil
        defer { isBusy = false }
        failure = nil
        notice = nil
        switch await session.perform(command) {
        case .done(let json):
            notice = done(json)
            await load()
            return true
        case .failed(let message, _):
            failure = SecretRedactor.redact(message)
        case .needsConfirmation:
            failure = "The Cockpit agent asked for a confirmation; nothing was changed."
        }
        return false
    }
}
