import Foundation
import Observation

// Models of the Storage page. Each one asks the agent (`storage.*`, `apps.uninstall`, `plan.confirm`)
// and keeps only what the page shows: no file is read or removed here. A cleanup, a duplicate
// removal and an uninstall are plans the agent records; the shared `PlanConfirmationModel` applies
// them after the user said so. A failed read is a state with the agent's words, never a made-up value.

// MARK: - State

/// Where one section of a page stands. Unlike ``LoadState`` it tells "this Mac cannot or may not"
/// (`unsupported`, `permission`: retrying changes nothing) from "it went wrong".
public enum SectionState<Value: Equatable & Sendable>: Equatable, Sendable {
    case idle
    case loading
    case failed(String)
    case unavailable(String)
    case loaded(Value)

    public var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    public var isLoading: Bool { self == .loading }

    /// The state a failed agent answer stands for.
    static func failure(_ message: String, exitClass: String?) -> Self {
        let text = SecretRedactor.redact(message)
        return exitClass == "unsupported" || exitClass == "permission" ? .unavailable(text) : .failed(text)
    }
}

/// One long agent job at a time. The agent answers one request after another, so a second scan
/// would only queue behind the first (and every other page with it); the page disables the other
/// triggers and says what is running instead. The agent has no way to cancel a job.
@MainActor
@Observable
public final class AgentWorkGate {
    public private(set) var running: String?

    public init() {}

    public var isBusy: Bool { running != nil }

    func begin(_ name: String) -> Bool {
        guard running == nil else { return false }
        running = name
        return true
    }

    func end() { running = nil }
}

// MARK: - Drive health

public enum HealthGrade: String, Equatable, Sendable, Decodable {
    case good, warning, critical, unknown

    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct HealthMeasurement: Decodable, Equatable, Sendable {
    public let value: Double
    public let unit: String
}

public struct DriveHealth: Decodable, Equatable, Sendable {
    public struct Access: Decodable, Equatable, Sendable {
        public let status: String
        public let stage: String?
        public let code: String?
    }

    public struct Check: Decodable, Equatable, Sendable, Identifiable {
        public let rule: String
        public let grade: HealthGrade
        public let message: String
        public var id: String { rule }
    }

    public struct Metrics: Decodable, Equatable, Sendable {
        public let temperatureCelsius: HealthMeasurement?
        public let availableSpare: HealthMeasurement?
        public let percentageUsed: HealthMeasurement?
        public let dataRead: HealthMeasurement?
        public let dataWritten: HealthMeasurement?
        public let powerOnHours: HealthMeasurement?
        public let powerCycles: HealthMeasurement?
        public let unsafeShutdowns: HealthMeasurement?
        public let mediaErrors: HealthMeasurement?
    }

    public struct Device: Decodable, Equatable, Sendable, Identifiable {
        /// `location:model`, the key `storage.health.history` takes.
        public let key: String
        public let model: String?
        public let firmware: String?
        public let location: String
        public let access: Access
        public let grade: HealthGrade
        public let checks: [Check]
        public let metrics: Metrics?
        public var id: String { key }
    }

    public let measuredAt: String
    public let overallGrade: HealthGrade
    public let devices: [Device]
}

/// One stored measurement (`storage.health.history`), newest first.
public struct HealthSample: Decodable, Equatable, Sendable, Identifiable {
    public struct Change: Decodable, Equatable, Sendable {
        public let kind: String
        public let message: String
    }

    public let measuredAt: String
    public let deviceKey: String
    public let model: String
    public let grade: HealthGrade
    public let temperatureCelsius: Double?
    public let availableSparePercent: Int
    public let percentageUsed: Int
    public let mediaErrors: Double
    /// What got worse since the next older measurement; `nil` for the oldest one.
    public let changes: [Change]?

    public var id: String { "\(deviceKey)@\(measuredAt)" }
    public var date: Date? { ISO8601DateFormatter().date(from: measuredAt) }
}

private struct HealthHistoryAnswer: Decodable { let samples: [HealthSample] }

/// SMART health per device, the rules' verdicts and the recorded history. `storage.health` through
/// the agent never records (the tool stays read-only); the history holds what `symcockpit storage
/// health` on the command line recorded.
@MainActor
@Observable
public final class StorageHealthModel {
    public private(set) var report: SectionState<DriveHealth> = .idle
    public private(set) var history: SectionState<[HealthSample]> = .idle

    @ObservationIgnored private let session: AgentSession
    @ObservationIgnored private let historyLimit: Int

    public init(session: AgentSession, historyLimit: Int = 40) {
        self.session = session
        self.historyLimit = historyLimit
    }

    public func load() async {
        guard !report.isLoading, !history.isLoading else { return }
        report = .loading
        history = .loading
        async let measured: Void = loadReport()
        async let stored: Void = loadHistory()
        _ = await (measured, stored)
    }

    private func loadReport() async {
        switch await session.perform("storage.health") {
        case .done(let output):
            do {
                report = .loaded(try AgentDecoding.decode(DriveHealth.self, from: output))
            } catch {
                report = .failed("The drive health could not be read: \(error.localizedDescription)")
            }
        case .failed(let message, let exitClass):
            report = .failure(message, exitClass: exitClass)
        case .needsConfirmation:
            report = .failed("The Cockpit agent asked for a confirmation to read the drive health.")
        }
    }

    private func loadHistory() async {
        switch await session.perform("storage.health.history", params: ["limit": .number(Double(historyLimit))]) {
        case .done(let output):
            do {
                history = .loaded(try AgentDecoding.decode(HealthHistoryAnswer.self, from: output).samples)
            } catch {
                history = .failed("The history could not be read: \(error.localizedDescription)")
            }
        case .failed(let message, let exitClass):
            history = .failure(message, exitClass: exitClass)
        case .needsConfirmation:
            history = .failed("The Cockpit agent asked for a confirmation to read the history.")
        }
    }
}

// MARK: - Space analysis

public struct SpaceNode: Equatable, Sendable, Identifiable {
    /// The path of the entry; unique in one report.
    public let id: String
    public let name: String
    public let isDirectory: Bool
    public let allocatedBytes: Int
    public let files: Int
    /// `nil` for a leaf (what `OutlineGroup` expects). The children the agent summed up instead of
    /// listing are one last row of their own.
    public let children: [SpaceNode]?
}

public struct SpaceReport: Equatable, Sendable {
    public let path: String
    public let depth: Int
    public let root: SpaceNode
    public let entriesVisited: Int
    public let truncated: Bool
    public let errorCount: Int
}

private struct SpaceAnswer: Decodable {
    struct Node: Decodable {
        struct Other: Decodable {
            let count: Int
            let allocatedBytes: Int
        }
        let name: String
        let kind: String
        let allocatedBytes: Int
        let files: Int
        let children: [Node]
        let other: Other
    }

    let path: String
    let depth: Int
    let tree: Node
    let entriesVisited: Int
    let truncated: Bool
    let errorCount: Int

    func report() -> SpaceReport {
        func convert(_ node: Node, path: String) -> SpaceNode {
            var kids = node.children.map { child in
                convert(child, path: path == "/" ? "/\(child.name)" : "\(path)/\(child.name)")
            }
            // The agent sums the children below its limit; they are shown as one row so the sizes add up.
            let others = node.other.count
            if others > 0 {
                kids.append(SpaceNode(
                    id: "\(path)\u{0}others", name: others == 1 ? "1 smaller item" : "\(others) smaller items",
                    isDirectory: false, allocatedBytes: node.other.allocatedBytes, files: others,
                    children: nil
                ))
            }
            return SpaceNode(
                id: path, name: node.name, isDirectory: node.kind == "dir",
                allocatedBytes: node.allocatedBytes, files: node.files,
                children: kids.isEmpty ? nil : kids
            )
        }
        return SpaceReport(
            path: path, depth: depth, root: convert(tree, path: path), entriesVisited: entriesVisited,
            truncated: truncated, errorCount: errorCount
        )
    }
}

/// The size tree of one folder (`storage.space`).
@MainActor
@Observable
public final class SpaceModel {
    public static let depths = Array(1...16)

    public private(set) var state: SectionState<SpaceReport> = .idle
    public private(set) var folder: String?
    public var depth = 3

    @ObservationIgnored private let session: AgentSession
    @ObservationIgnored private let gate: AgentWorkGate

    public init(session: AgentSession, gate: AgentWorkGate) {
        self.session = session
        self.gate = gate
    }

    /// Analyses `path`, or the folder chosen before when `nil` (a new depth).
    public func analyze(_ path: String? = nil) async {
        guard let target = path ?? folder, gate.begin("Space analysis") else { return }
        defer { gate.end() }
        folder = target
        state = .loading
        let outcome = await session.perform(
            "storage.space",
            params: ["path": .string(target), "depth": .number(Double(depth))],
            timeout: AgentSession.longRunning
        )
        switch outcome {
        case .done(let output):
            do {
                state = .loaded(try AgentDecoding.decode(SpaceAnswer.self, from: output).report())
            } catch {
                state = .failed("The space analysis could not be read: \(error.localizedDescription)")
            }
        case .failed(let message, let exitClass):
            state = .failure(message, exitClass: exitClass)
        case .needsConfirmation:
            state = .failed("The Cockpit agent asked for a confirmation to analyse a folder.")
        }
    }
}

// MARK: - Cleanup

public struct CleanCategory: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let reason: String
    /// Removed for good instead of moved to the Trash.
    public let permanent: Bool
    public let items: Int
    public let bytes: Int
}

/// What a cleanup scan found: the recorded plan and its summary per category.
public struct CleanScan: Equatable, Sendable {
    public let plan: AgentPlan
    public let categories: [CleanCategory]
    public let skipped: Int

    public var totalBytes: Int { categories.reduce(0) { $0 + $1.bytes } }
    public var itemCount: Int { categories.reduce(0) { $0 + $1.items } }
    public var hasPermanentRemoval: Bool { categories.contains { $0.permanent && $0.items > 0 } }
}

/// Cleanup by catalog: scan the chosen categories, show what would go, apply the plan on approval.
@MainActor
@Observable
public final class CleanModel {
    public private(set) var scan: SectionState<CleanScan> = .idle
    public private(set) var confirmation: PlanConfirmationModel?
    /// Categories switched off. The register's description says `empty_trash` is not part of the
    /// default selection; the rest are on.
    /// shortcut: that default is mirrored here, the register gives no machine-readable default; upgrade when it does.
    public private(set) var switchedOff: Set<String> = ["empty_trash"]

    @ObservationIgnored private let session: AgentSession
    @ObservationIgnored private let gate: AgentWorkGate

    public init(session: AgentSession, gate: AgentWorkGate) {
        self.session = session
        self.gate = gate
    }

    /// The catalog categories the agent's register names.
    public var categoryIDs: [String] { session.choices(of: "categories", in: "storage.clean") }

    public var selected: [String] { categoryIDs.filter { !switchedOff.contains($0) } }

    public func isSelected(_ id: String) -> Bool { !switchedOff.contains(id) }

    public func setSelected(_ id: String, _ on: Bool) {
        let changed = on ? switchedOff.remove(id) != nil : switchedOff.insert(id).inserted
        if changed { scan = .idle }
    }

    /// Words for a category id before a scan told its title.
    public static func title(of id: String) -> String {
        id.replacingOccurrences(of: "_", with: " ").capitalized
    }

    public func scanSelected() async {
        guard !selected.isEmpty, gate.begin("Cleanup scan") else { return }
        defer { gate.end() }
        confirmation = nil
        scan = .loading
        let outcome = await session.plan(
            "storage.clean", params: ["categories": .array(selected.map(AgentJSON.string))],
            timeout: AgentSession.longRunning
        )
        switch outcome {
        case .needsConfirmation(let plan):
            do {
                let categories = try AgentDecoding.decode([CleanCategory].self, from: plan.details["categories"] ?? .null)
                scan = .loaded(CleanScan(
                    plan: plan, categories: categories,
                    skipped: plan.details["skipped"]?.arrayValue?.count ?? 0
                ))
            } catch {
                scan = .failed("The scan result could not be read: \(error.localizedDescription)")
            }
        case .failed(let message, let exitClass):
            scan = .failure(message, exitClass: exitClass)
        case .done:
            scan = .failed("The Cockpit agent answered without a plan.")
        }
    }

    /// Opens the shared confirmation for the scanned plan.
    public func review() {
        guard let result = scan.value, result.itemCount > 0, confirmation == nil else { return }
        let model = PlanConfirmationModel(plan: result.plan, session: session)
        // The plan is used up whatever the outcome: another scan is needed for a new one.
        model.onFinished = { [weak self] _ in self?.scan = .idle }
        confirmation = model
    }

    public func closeConfirmation() { confirmation = nil }
}

// MARK: - Duplicates

public struct DuplicateGroup: Decodable, Equatable, Sendable, Identifiable {
    public let size: Int
    public let hash: String
    public let reclaimableBytes: Int
    public let files: [String]
    public var id: String { hash }
}

public struct DuplicateScan: Decodable, Equatable, Sendable {
    public let root: String
    public let minSize: Int
    public let filesSeen: Int
    public let hardlinksSkipped: Int
    public let unreadable: Int
    public let groupCount: Int
    public let reclaimableBytes: Int
    public let groups: [DuplicateGroup]
}

/// Duplicate search in one folder and the choice of which copies go to the Trash. Every group
/// keeps at least one copy: the model refuses the last selection and the agent checks it again.
@MainActor
@Observable
public final class DuplicatesModel {
    /// Smallest file the search looks at, in bytes: the choices of the page.
    public static let minimumSizes: [(bytes: Int, label: String)] = [
        (1, "Non-empty files"),
        (1 << 20, "1 MiB and larger"),
        (10 << 20, "10 MiB and larger"),
        (100 << 20, "100 MiB and larger"),
    ]

    public private(set) var state: SectionState<DuplicateScan> = .idle
    public private(set) var folder: String?
    public private(set) var selection: Set<String> = []
    public private(set) var planning = false
    public private(set) var failure: String?
    public private(set) var confirmation: PlanConfirmationModel?
    public var minimumSize = 1

    @ObservationIgnored private let session: AgentSession
    @ObservationIgnored private let gate: AgentWorkGate

    public init(session: AgentSession, gate: AgentWorkGate) {
        self.session = session
        self.gate = gate
    }

    public func search(_ path: String? = nil) async {
        guard let target = path ?? folder, gate.begin("Duplicate search") else { return }
        defer { gate.end() }
        folder = target
        selection = []
        failure = nil
        confirmation = nil
        state = .loading
        let outcome = await session.perform(
            "storage.duplicates",
            params: ["path": .string(target), "min_size": .number(Double(minimumSize))],
            timeout: AgentSession.longRunning
        )
        switch outcome {
        case .done(let output):
            do {
                state = .loaded(try AgentDecoding.decode(DuplicateScan.self, from: output))
            } catch {
                state = .failed("The duplicate search could not be read: \(error.localizedDescription)")
            }
        case .failed(let message, let exitClass):
            state = .failure(message, exitClass: exitClass)
        case .needsConfirmation:
            state = .failed("The Cockpit agent asked for a confirmation to search a folder.")
        }
    }

    public func isSelected(_ path: String) -> Bool { selection.contains(path) }

    /// A copy may be marked for removal unless it is the last one of its group left unmarked.
    public func canMark(_ path: String, in group: DuplicateGroup) -> Bool {
        group.files.contains(path)
            && (selection.contains(path) || group.files.contains { $0 != path && !selection.contains($0) })
    }

    public func toggle(_ path: String, in group: DuplicateGroup) {
        if selection.contains(path) {
            selection.remove(path)
        } else if canMark(path, in: group) {
            selection.insert(path)
        }
    }

    /// Marks every copy but the first of each group.
    public func markAllButFirst() {
        guard let scan = state.value else { return }
        selection = Set(scan.groups.flatMap { $0.files.dropFirst() })
    }

    public func clearSelection() { selection = [] }

    public var selectedCount: Int { selection.count }

    public var selectedBytes: Int {
        state.value?.groups.reduce(0) { $0 + $1.size * $1.files.filter(selection.contains).count } ?? 0
    }

    /// Records the plan that moves the marked copies to the Trash and opens the shared confirmation.
    public func requestRemoval() async {
        guard let scan = state.value, !selection.isEmpty, confirmation == nil,
              scan.groups.allSatisfy({ group in group.files.contains { !selection.contains($0) } }),
              gate.begin("Duplicate removal planning") else { return }
        planning = true
        failure = nil
        defer {
            planning = false
            gate.end()
        }
        let outcome = await session.plan(
            "storage.duplicates.remove",
            params: [
                "path": .string(scan.root),
                "select": .array(selection.sorted().map(AgentJSON.string)),
                "min_size": .number(Double(scan.minSize)),
            ],
            timeout: AgentSession.longRunning
        )
        switch outcome {
        case .needsConfirmation(let plan):
            let model = PlanConfirmationModel(plan: plan, session: session)
            // The copies are gone or changed: the groups on screen are out of date.
            model.onFinished = { [weak self] _ in
                self?.state = .idle
                self?.selection = []
            }
            confirmation = model
        case .failed(let message, _):
            failure = SecretRedactor.redact(message)
        case .done:
            failure = "The Cockpit agent answered without a plan."
        }
    }

    public func closeConfirmation() { confirmation = nil }
}

// MARK: - Uninstall

/// The plan to uninstall an app: the app and everything the agent found that belongs to it.
public struct UninstallPlan: Equatable, Sendable {
    public struct Leftover: Equatable, Sendable, Identifiable {
        public let path: String
        public let category: String
        public let bytes: Int
        public var id: String { path }
    }

    public struct Excluded: Equatable, Sendable, Identifiable {
        public let path: String
        public let reason: String
        public var id: String { path }
    }

    public let plan: AgentPlan
    public let appName: String
    public let bundleID: String
    public let appPath: String
    public let items: [Leftover]
    public let excluded: [Excluded]

    public var totalBytes: Int { items.reduce(0) { $0 + $1.bytes } }
}

@MainActor
@Observable
public final class UninstallModel {
    public private(set) var state: SectionState<UninstallPlan> = .idle
    public private(set) var confirmation: PlanConfirmationModel?
    public private(set) var appPath: String?

    @ObservationIgnored private let session: AgentSession
    @ObservationIgnored private let gate: AgentWorkGate

    public init(session: AgentSession, gate: AgentWorkGate) {
        self.session = session
        self.gate = gate
    }

    /// Records the uninstall plan of the app at `path`; nothing is removed.
    public func plan(appPath path: String) async {
        guard confirmation == nil, gate.begin("Uninstall planning") else { return }
        defer { gate.end() }
        appPath = path
        state = .loading
        switch await session.plan(
            "apps.uninstall", params: ["app": .string(path)], timeout: AgentSession.longRunning
        ) {
        case .needsConfirmation(let plan):
            let details = plan.details
            state = .loaded(UninstallPlan(
                plan: plan,
                appName: details["app"]?["name"]?.stringValue ?? path,
                bundleID: details["app"]?["bundle_id"]?.stringValue ?? "",
                appPath: details["app"]?["path"]?.stringValue ?? path,
                items: (details["items"]?.arrayValue ?? []).map {
                    UninstallPlan.Leftover(
                        path: $0["target"]?.stringValue ?? "",
                        category: $0["category"]?.stringValue ?? "",
                        bytes: $0["bytes"]?.intValue ?? 0
                    )
                },
                excluded: (details["excluded"]?.arrayValue ?? []).map {
                    UninstallPlan.Excluded(
                        path: $0["path"]?.stringValue ?? "", reason: $0["reason"]?.stringValue ?? ""
                    )
                }
            ))
        case .failed(let message, let exitClass):
            state = .failure(message, exitClass: exitClass)
        case .done:
            state = .failed("The Cockpit agent answered without a plan.")
        }
    }

    public func review() {
        guard let plan = state.value?.plan, !plan.items.isEmpty, confirmation == nil else { return }
        let model = PlanConfirmationModel(plan: plan, session: session)
        model.onFinished = { [weak self] _ in self?.state = .idle }
        confirmation = model
    }

    public func closeConfirmation() { confirmation = nil }

}

// MARK: - Speed test

public struct SpeedResult: Decodable, Equatable, Sendable {
    public struct Phase: Decodable, Equatable, Sendable {
        public let bytes: Double
        public let durationSeconds: Double
        public let mibPerS: Double
        public let mbPerS: Double
    }

    public struct Cleanup: Decodable, Equatable, Sendable {
        public let removed: Bool
        public let error: String?
    }

    public let target: String
    public let sizeMib: Int
    public let cacheMode: String
    public let cacheModeApplied: Bool
    public let write: Phase
    public let read: Phase
    public let cleanup: Cleanup
}

/// Sequential write and read of one test file (`storage.speedtest`). The agent writes the file
/// into a folder of its own below the target and removes it again; the test cannot be cancelled.
@MainActor
@Observable
public final class SpeedtestModel {
    public static let sizes = 1...1024

    public private(set) var state: SectionState<SpeedResult> = .idle
    /// The folder to test; `nil` is the agent's default, the home folder.
    public private(set) var target: String?
    public var sizeMiB = 256

    @ObservationIgnored private let session: AgentSession
    @ObservationIgnored private let gate: AgentWorkGate

    public init(session: AgentSession, gate: AgentWorkGate) {
        self.session = session
        self.gate = gate
    }

    public func chooseTarget(_ path: String?) { target = path }

    public func run() async {
        guard Self.sizes.contains(sizeMiB), gate.begin("Speed test") else { return }
        defer { gate.end() }
        state = .loading
        var params: [String: AgentJSON] = ["size_mib": .number(Double(sizeMiB))]
        if let target { params["path"] = .string(target) }
        switch await session.perform("storage.speedtest", params: params, timeout: AgentSession.longRunning) {
        case .done(let output):
            do {
                state = .loaded(try AgentDecoding.decode(SpeedResult.self, from: output))
            } catch {
                state = .failed("The speed test result could not be read: \(error.localizedDescription)")
            }
        case .failed(let message, let exitClass):
            state = .failure(message, exitClass: exitClass)
        case .needsConfirmation:
            state = .failed("The Cockpit agent asked for a confirmation to run the speed test.")
        }
    }
}
