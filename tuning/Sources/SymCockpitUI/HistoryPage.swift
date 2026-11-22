import SwiftUI
import SymCockpitCore
import SymairaTheme

// Screen card
// 1. Destination: History, last in the sidebar.
// 2. Job: look back at what Cockpit changed on this Mac (brightness, fans, charge limit...).
// 3. Data: the agent's `history` command, read when the page opens and on Refresh.
//    Open plans are not listed: the agent offers `plan.show` for one id but no list of plans.
// 4. States: loading ("Loading history…"), empty (nothing recorded yet), error (message with
//    Retry), unreachable (the shell's diagnosis).
// 5. Density: table, 960 pt; the table scrolls, the page does not.
// 6. Platform: macOS workspace; no preference keys.

@MainActor
struct HistoryPage: View {
    let model: HistoryModel
    @State private var sortOrder = [KeyPathComparator(\HistoryEntry.date, order: .reverse)]

    var body: some View {
        SymairaPage(
            title: CockpitDestination.history.title, subtitle: CockpitDestination.history.subtitle,
            scrolls: false, maxWidth: CockpitLayout.pageWidth
        ) {
            Button("Refresh") { Task { await model.load() } }
                .symairaButtonStyle(.secondary)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.state == .loading)
        } content: {
            SymairaPageState(state: pageState, loading: "Loading history…", retry: { Task { await model.load() } }) { entries in
                if entries.isEmpty {
                    SymairaPageEmpty(
                        icon: .history, title: "No History Yet",
                        message: "Changes Cockpit makes to this Mac, such as brightness or fan settings, are recorded here."
                    )
                } else {
                    table(entries)
                }
            }
        }
        .task { await model.load() }
    }

    private var pageState: SymairaPageLoadState<[HistoryEntry]> {
        switch model.state {
        case .idle: .idle
        case .loading: .loading
        case .failed(let message): .failed(message)
        case .loaded(let entries): .loaded(entries)
        }
    }

    private func table(_ entries: [HistoryEntry]) -> some View {
        Table(entries.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn("Time", value: \.date) { entry in
                Text(entry.date, format: .dateTime.day().month(.abbreviated).hour().minute().second())
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .width(min: 140, ideal: 160)
            TableColumn("Action", value: \.action) { entry in
                Text(entry.action)
            }
            TableColumn("Value") { entry in
                Text(Self.value(entry))
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn("Result", value: \.result) { entry in
                SymairaStatusLabel(
                    entry.isSuccess ? "Applied" : "Failed", tone: entry.isSuccess ? .positive : .critical
                )
                .help(entry.errorReason ?? "")
            }
        }
        .frame(minHeight: 280)
        .accessibilityLabel("History of changes")
        .contextMenu(forSelectionType: HistoryEntry.ID.self) { ids in
            if let id = ids.first, let entry = entries.first(where: { $0.id == id }) {
                Button("Copy Entry") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.line(entry), forType: .string)
                }
            }
        }
    }

    /// What was applied, or what was asked when nothing was applied.
    static func value(_ entry: HistoryEntry) -> String {
        guard let value = entry.appliedValue ?? entry.requestedValue else { return "—" }
        return String(format: "%.2f", value)
    }

    static func line(_ entry: HistoryEntry) -> String {
        [entry.date.formatted(.iso8601), entry.action, value(entry), entry.result, entry.errorReason ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "  ")
    }
}
