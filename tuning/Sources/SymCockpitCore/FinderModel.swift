import Foundation
import Observation

// The Finder page's model. The Finder actions have no register command, CLI path or MCP tool
// (`areas/finder.rs`): the FinderSync extension writes job files, the agent runs them. The agent
// reports only counts (`services.finder_jobs`). It does not report whether macOS has switched
// an extension on, and this app has no reliable reading of that either, so the model says
// "unknown" and never guesses. What it can state as fact: whether the extension is inside this
// build, where the job files are, and what the agent counted.

/// One app extension of `Symaira Cockpit.app` (docs/extensions.md).
public struct FinderExtension: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let summary: String
    /// Whether the `.appex` is inside this app bundle (`Contents/PlugIns`). Nothing more is known.
    public let isInBundle: Bool
}

/// A Finder context action; the ids are the job vocabulary of `areas/finder.rs`.
public struct FinderAction: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String

    public static let all = [
        FinderAction(id: "copy_path", title: "Copy Path", summary: "Puts the path of the selected item on the clipboard."),
        FinderAction(id: "new_file", title: "New File Here", summary: "Creates an empty file in the open folder."),
        FinderAction(id: "open_in_terminal", title: "Open in Terminal", summary: "Opens the folder in Terminal."),
    ]
}

/// What the agent counted for the job directory (`services.finder_jobs`).
public struct FinderJobsStatus: Equatable, Sendable {
    /// The directory the agent watches; `nil` when it was started without one.
    public let directory: String?
    public let succeeded: Int
    public let failed: Int
    public let rejected: Int

    init(json: AgentJSON) {
        directory = json["directory"]?.stringValue
        succeeded = json["succeeded"]?.intValue ?? 0
        failed = json["failed"]?.intValue ?? 0
        rejected = json["rejected"]?.intValue ?? 0
    }
}

@MainActor
@Observable
public final class FinderModel {
    /// `System Settings > General > Login Items & Extensions > Extensions`.
    public static let extensionSettingsURL = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!

    public private(set) var state: LoadState<FinderJobsReport> = .idle
    public let extensions: [FinderExtension]
    /// Where the FinderSync extension writes its job files; `nil` in a build without an app group.
    public let jobsDirectory: URL?

    @ObservationIgnored private let session: AgentSession

    public init(session: AgentSession, bundle: Bundle = .main) {
        self.session = session
        let plugIns = bundle.builtInPlugInsURL
        func inBundle(_ file: String) -> Bool {
            plugIns.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(file).path) } ?? false
        }
        extensions = [
            FinderExtension(
                id: "com.symaira.cockpit.findersync", name: "Finder Actions",
                summary: "Adds Copy Path, New File Here and Open in Terminal to Finder's context menu.",
                isInBundle: inBundle("SymCockpitFinderSync.appex")),
            FinderExtension(
                id: "com.symaira.cockpit.quicklook", name: "Quick Look",
                summary: "Previews folders and ZIP, TAR and 7z archives with the space bar.",
                isInBundle: inBundle("SymCockpitQuickLook.appex")),
        ]
        jobsDirectory = AgentSession.finderJobsDirectory(
            appGroup: bundle.object(forInfoDictionaryKey: "SymCockpitAppGroup") as? String)
    }

    public func load() async {
        guard session.offers(method: "services") else {
            state = .loaded(FinderJobsReport(isReported: false, status: nil))
            return
        }
        if state.value == nil { state = .loading }
        switch await session.invoke("services") {
        case .done(let json):
            // `{"state":"off"}` when the agent got no job directory, else the directory and counts.
            let jobs = json["finder_jobs"].flatMap { $0["directory"] == nil ? nil : FinderJobsStatus(json: $0) }
            state = .loaded(FinderJobsReport(isReported: true, status: jobs))
        case .failed(let message, _):
            state = .failed(SecretRedactor.redact(message))
        case .needsConfirmation:
            state = .failed("The Cockpit agent asked for a confirmation to report its services.")
        }
    }
}

/// What the page shows about the job service once the agent answered.
public struct FinderJobsReport: Equatable, Sendable {
    /// `false`: this agent has no `services` method, so nothing is known about the jobs.
    public let isReported: Bool
    /// `nil` while reported: the agent was started without a job directory and watches none.
    public let status: FinderJobsStatus?
}
