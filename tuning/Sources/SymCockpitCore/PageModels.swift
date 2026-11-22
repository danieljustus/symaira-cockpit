import Foundation
import Observation

// Models of the window's pages that read through the agent and own no hardware:
// the write history and the display profiles. Presentation state only; the agent
// answers, and a failed read is a state with its message, never an empty list.

/// Where a page's data stands: the four states every page that loads must show.
public enum LoadState<Value: Equatable & Sendable>: Equatable, Sendable {
    case idle
    case loading
    case failed(String)
    case loaded(Value)

    public var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }
}

// MARK: - History

/// One recorded write (`history`): what was asked, what was applied, how it ended.
public struct HistoryEntry: Equatable, Sendable, Identifiable {
    public let id: Int
    public let action: String
    /// `success`, or the word the writer recorded for a failure.
    public let result: String
    public let date: Date
    public let requestedValue: Double?
    public let clampedValue: Double?
    public let appliedValue: Double?
    public let errorReason: String?

    public var isSuccess: Bool { result == "success" }
}

private struct HistoryRecord: Decodable {
    let action: String
    let result: String
    let timestamp: Double
    let requestedValue: Double?
    let clampedValue: Double?
    let appliedValue: Double?
    let errorReason: String?
}

/// The write history of this Mac as the agent reports it, newest first.
@MainActor
@Observable
public final class HistoryModel {
    public private(set) var state: LoadState<[HistoryEntry]> = .idle
    @ObservationIgnored private let session: AgentSession
    @ObservationIgnored private let limit: Int

    public init(session: AgentSession, limit: Int = 200) {
        self.session = session
        self.limit = limit
    }

    public func load() async {
        state = .loading
        switch await session.perform("history", params: ["limit": .number(Double(limit))]) {
        case .done(let output):
            do {
                let records = try AgentDecoding.decode([HistoryRecord].self, from: output)
                // The agent sends the newest `limit` records, oldest first.
                state = .loaded(records.enumerated().reversed().map { offset, record in
                    HistoryEntry(
                        id: offset, action: record.action, result: record.result,
                        date: Date(timeIntervalSinceReferenceDate: record.timestamp),
                        requestedValue: record.requestedValue, clampedValue: record.clampedValue,
                        appliedValue: record.appliedValue,
                        errorReason: record.errorReason.map(SecretRedactor.redact)
                    )
                })
            } catch {
                state = .failed("The history could not be read: \(error.localizedDescription)")
            }
        case .failed(let message, _):
            state = .failed(SecretRedactor.redact(message))
        case .needsConfirmation:
            state = .failed("The Cockpit agent asked for a confirmation to read the history.")
        }
    }
}

// MARK: - Display profiles

/// Saved display settings (brightness, dim, warmth) by name: list, apply, save, delete.
@MainActor
@Observable
public final class ProfilesModel {
    public private(set) var state: LoadState<[TuneProfile]> = .idle
    /// Why the last apply, save or delete failed; cleared by the next one.
    public private(set) var failure: String?
    /// What the last apply, save or delete did, in words.
    public private(set) var notice: String?
    public private(set) var isBusy = false

    @ObservationIgnored private let session: AgentSession
    @ObservationIgnored private let didChangeDisplay: @MainActor () -> Void

    /// `didChangeDisplay` runs after a profile was applied, so the sliders re-read.
    public init(session: AgentSession, didChangeDisplay: @escaping @MainActor () -> Void = {}) {
        self.session = session
        self.didChangeDisplay = didChangeDisplay
    }

    public func load() async {
        if state.value == nil { state = .loading }
        switch await session.perform("profile.list") {
        case .done(let output):
            do {
                let profiles = try AgentDecoding.decode([TuneProfile].self, from: output["profiles"] ?? .null)
                state = .loaded(profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            } catch {
                state = .failed("The profiles could not be read: \(error.localizedDescription)")
            }
        case .failed(let message, _):
            state = .failed(SecretRedactor.redact(message))
        case .needsConfirmation:
            state = .failed("The Cockpit agent asked for a confirmation to list the profiles.")
        }
    }

    /// Applies the profile's brightness, dim and warmth.
    public func apply(_ name: String) async {
        if await run("profile.load", name: name, done: "Applied “\(name)”.") { didChangeDisplay() }
    }

    /// Saves what the display shows now under `name` (replacing a profile of that name).
    public func save(_ name: String) async {
        guard TuneProfile.isValidProfileName(name) else {
            failure = "A profile name may only contain letters, digits, hyphens and underscores."
            notice = nil
            return
        }
        if await run("profile.save", name: name, done: "Saved “\(name)”.") { await load() }
    }

    public func delete(_ name: String) async {
        if await run("profile.delete", name: name, done: "Deleted “\(name)”.") { await load() }
    }

    private func run(_ command: String, name: String, done: String) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        failure = nil
        notice = nil
        switch await session.perform(command, params: ["name": .string(name)]) {
        case .done:
            notice = done
            return true
        case .failed(let message, _):
            failure = SecretRedactor.redact(message)
        case .needsConfirmation:
            failure = "The Cockpit agent asked for a confirmation; nothing was changed."
        }
        return false
    }
}
