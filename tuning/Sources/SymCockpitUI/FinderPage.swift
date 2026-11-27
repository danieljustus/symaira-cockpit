import AppKit
import SwiftUI
import SymCockpitCore
import SymairaTheme

// Screen card
// 1. Destination: Finder, ninth in the sidebar.
// 2. Job: see whether the Finder extensions are there, what their context menu does, where
//    their job files go, and how to switch them on (the one primary action opens System Settings).
// 3. Data: static facts about this build (which extensions are inside the app, the app group's job
//    folder) and the agent's `services` method for the job counts. The agent does not report
//    whether macOS has enabled an extension and there is no reliable reading of it in the app, so
//    the page says "Status unknown" rather than guess.
// 4. States: loading ("Reading job status…") and error (message with Retry) in the job section;
//    an agent without `services`, a build without an app group and an agent without a job
//    folder each say so; unreachable (the shell's diagnosis). Nothing is empty: the page is guidance.
// 5. Density: prose column of form sections.
// 6. Platform: macOS workspace; no preference keys.

@MainActor
public struct FinderPage: View {
    @State private var model: FinderModel

    public init(session: AgentSession) {
        _model = State(initialValue: FinderModel(session: session))
    }

    public var body: some View {
        SymairaPage(
            title: CockpitDestination.finder.title, subtitle: CockpitDestination.finder.subtitle,
            maxWidth: SymairaMetrics.readableContentWidth
        ) {
            Spacer(minLength: 0)
            Button("Refresh") { Task { await model.load() } }
                .symairaButtonStyle(.secondary)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.state == .loading)
        } content: {
            VStack(alignment: .leading, spacing: SymairaSpacing.large) {
                extensionsSection
                actionsSection
                jobsSection
                stepsSection
            }
        }
        .task { await model.load() }
    }

    // MARK: Extensions

    private var extensionsSection: some View {
                VStack(alignment: .leading, spacing: SymairaSpacing.small) {
        GroupBox {

            ForEach(Array(model.extensions.enumerated()), id: \.element.id) { offset, ext in
                if offset > 0 { SymairaFormDivider() }
                SymairaFormRow(ext.name, description: ext.summary) {
                    if ext.isInBundle {
                        SymairaStatusLabel("Status unknown", tone: .neutral)
                    } else {
                        SymairaStatusLabel("Not in this build", tone: .warning)
                    }
                }
            }
            SymairaFormDivider()
            SymairaFormRow("System Settings", description: "General › Login Items & Extensions › Extensions") {
                Button("Open Extension Settings") { NSWorkspace.shared.open(FinderModel.extensionSettingsURL) }
                    .symairaButtonStyle(.primary)
            }
                } label: {
            Text("Extensions")
                .symairaText(.sectionLabel)
                .accessibilityAddTraits(.isHeader)
        }
            Text("Cockpit cannot see whether macOS has switched an extension on. Check it in System Settings.")
                .symairaText(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("finder-extensions")
    }

    // MARK: Actions

    private var actionsSection: some View {
                VStack(alignment: .leading, spacing: SymairaSpacing.small) {
        GroupBox {

            ForEach(Array(FinderAction.all.enumerated()), id: \.element.id) { offset, action in
                if offset > 0 { SymairaFormDivider() }
                SymairaFormRow(action.title, description: action.summary)
            }
                } label: {
            Text("Context Menu")
                .symairaText(.sectionLabel)
                .accessibilityAddTraits(.isHeader)
        }
            Text("Finder passes your choice to Cockpit, which runs it once. Cockpit has to be running for it to work.")
                .symairaText(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("finder-actions")
    }

    // MARK: Jobs

    private var jobsSection: some View {
                VStack(alignment: .leading, spacing: SymairaSpacing.small) {
        GroupBox {

            if let directory = model.jobsDirectory {
                SymairaFormRow("Folder", description: "Where the Finder extension leaves a file for each action.") {
                    HStack(spacing: SymairaSpacing.small) {
                        Text(directory.path)
                            .symairaText(.caption)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: 300, alignment: .trailing)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([directory])
                        }
                        .symairaButtonStyle(.secondary)
                        .disabled(!FileManager.default.fileExists(atPath: directory.path))
                        .help("The folder is created with the first job")
                    }
                }
            } else {
                SymairaNotice(
                    title: "No App Group in This Build",
                    message: "Finder actions reach Cockpit through an app group, which only a team-signed build has. In this build the menu items cannot run.",
                    tone: .warning
                )
                .padding(.vertical, SymairaSpacing.small)
            }
            SymairaFormDivider()
            counts
                } label: {
            Text("Job Files")
                .symairaText(.sectionLabel)
                .accessibilityAddTraits(.isHeader)
        }
            Text("A job is dropped when it is older than a minute or was already run.")
                .symairaText(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("finder-jobs")
    }

    @ViewBuilder
    private var counts: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView("Reading job status…")
                .padding(.vertical, SymairaSpacing.small)
        case .failed(let message):
            VStack(alignment: .leading, spacing: SymairaSpacing.small) {
                SymairaNotice(message: message, tone: .critical)
                Button("Retry") { Task { await model.load() } }
                    .symairaButtonStyle(.secondary)
            }
            .padding(.vertical, SymairaSpacing.small)
        case .loaded(let report):
            if !report.isReported {
                SymairaFormRow("Run since launch", description: "This agent does not report its job service.")
            } else if let status = report.status {
                SymairaFormRow("Run since launch", description: "Counted by the agent since it started.") {
                    HStack(spacing: SymairaSpacing.medium) {
                        FinderCountLine(value: status.succeeded, label: "Done")
                        FinderCountLine(value: status.failed, label: "Failed")
                        FinderCountLine(value: status.rejected, label: "Refused")
                    }
                }
            } else {
                SymairaFormRow(
                    "Run since launch",
                    description: "The agent was started without a job folder and watches none."
                )
            }
        }
    }

    // MARK: Steps

    private var stepsSection: some View {
                VStack(alignment: .leading, spacing: SymairaSpacing.small) {
        GroupBox {

            ForEach(Array(Self.steps.enumerated()), id: \.offset) { offset, step in
                if offset > 0 { SymairaFormDivider() }
                SymairaFormRow("\(offset + 1). \(step.title)", description: step.detail)
            }
                } label: {
            Text("Turn Them On")
                .symairaText(.sectionLabel)
                .accessibilityAddTraits(.isHeader)
        }
            Text("Nothing is switched on by installing the app; each extension is yours to enable.")
                .symairaText(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("finder-steps")
    }

    private static let steps: [(title: String, detail: String)] = [
        ("Open Cockpit once", "That is how macOS learns the extensions that come with it."),
        ("Open Extension Settings", "System Settings › General › Login Items & Extensions, then Extensions."),
        ("Switch them on", "Turn on Finder (Symaira Cockpit) for the context menu and Quick Look for previews."),
    ]
}

/// A count with its label, digits aligned.
private struct FinderCountLine: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("\(value)").symairaText(.heading).monospacedDigit()
            Text(label).symairaText(.caption)
        }
        .accessibilityElement(children: .combine)
    }
}
