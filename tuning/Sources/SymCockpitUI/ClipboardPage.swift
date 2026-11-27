import SwiftUI
import SymCockpitCore
import SymairaTheme

// Screen card
// 1. Destination: Clipboard, eighth in the sidebar.
// 2. Job: look back at what you copied and put an entry back on the clipboard; switch the
//    history on or off, pause it, delete it, and choose which apps it never records.
// 3. Data: the agent's own methods `clipboard.settings/list/read/copy/delete/configure` (human
//    only, never a CLI command or MCP tool) and the register commands `clipboard.pause/resume/
//    clear`, read when the page opens, on Refresh and when the `clipboard.status` topic reports a
//    change. The list gives time, type and size; the source app and the text come from opening
//    an entry and are held only while the page is on screen.
// 4. States: loading ("Loading clipboard history…"), empty (off: why and a way to Settings; on:
//    nothing copied yet), error (message with Retry), not offered by this agent, unreachable
//    (the shell's diagnosis). A capture error of the service is a notice above the content.
// 5. Density: table with a detail pane, 960 pt; Settings is a form column. The table scrolls,
//    the page does not.
// 6. Platform: macOS workspace; no preference keys (the settings live in the agent's data).

@MainActor
public struct ClipboardPage: View {
    private enum Tab: Hashable { case history, settings }

    @State private var model: ClipboardModel
    @State private var tab = Tab.history

    public init(session: AgentSession) {
        _model = State(initialValue: ClipboardModel(session: session))
    }

    public var body: some View {
        SymairaPage(
            title: CockpitDestination.clipboard.title, subtitle: CockpitDestination.clipboard.subtitle,
            scrolls: false, maxWidth: CockpitLayout.pageWidth
        ) {
            if model.isOffered, model.state.value != nil {
                SymairaSegmentedControl(
                    "Clipboard view", selection: $tab,
                    options: [(Tab.history, "History"), (Tab.settings, "Settings")]
                )
                .frame(width: 220)
                Spacer(minLength: 0)
                if let settings = model.state.value?.settings, settings.enabled {
                    Button(settings.paused ? "Resume Capture" : "Pause Capture") {
                        Task { await model.setPaused(!settings.paused) }
                    }
                    .symairaButtonStyle(.secondary)
                    .disabled(model.isBusy)
                    .help(settings.paused ? "Start recording copies again" : "Stop recording copies; saved entries stay")
                }
            } else {
                Spacer(minLength: 0)
            }
            Button("Refresh") { Task { await model.load() } }
                .symairaButtonStyle(.secondary)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.isOffered || model.state == .loading || model.isBusy)
        } content: {
            VStack(alignment: .leading, spacing: SymairaSpacing.medium) {
                messages
                if model.isOffered {
                    SymairaPageState(
                        state: pageState, loading: "Loading clipboard history…",
                        retry: { Task { await model.load() } }
                    ) { snapshot in
                        switch tab {
                        case .history:
                            ClipboardHistoryView(model: model, snapshot: snapshot, showSettings: { tab = .settings })
                        case .settings:
                            ClipboardSettingsView(model: model, snapshot: snapshot)
                        }
                    }
                } else {
                    SymairaPageEmpty(
                        icon: .paste, title: "Not Offered by This Agent",
                        message: "The Cockpit agent does not host the clipboard history. Update Symaira Cockpit so the app and its agent match."
                    )
                }
            }
        }
        .task {
            guard model.isOffered else { return }
            model.setVisible(true)
            await model.load()
        }
        .onDisappear { model.setVisible(false) }
    }

    private var pageState: SymairaPageLoadState<ClipboardSnapshot> {
        switch model.state {
        case .idle: .idle
        case .loading: .loading
        case .failed(let message): .failed(message)
        case .loaded(let snapshot): .loaded(snapshot)
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let error = model.state.value?.serviceError {
            SymairaNotice(title: "Capture Problem", message: error, tone: .critical)
                .accessibilityIdentifier("clipboard-service-error")
        }
        if let failure = model.failure {
            SymairaNotice(message: failure, tone: .critical, onDismiss: { model.clearMessages() })
                .accessibilityIdentifier("clipboard-error")
        } else if let notice = model.notice {
            SymairaNotice(message: notice, tone: .positive, onDismiss: { model.clearMessages() })
                .accessibilityIdentifier("clipboard-notice")
        }
    }
}

// MARK: - History

@MainActor
private struct ClipboardHistoryView: View {
    let model: ClipboardModel
    let snapshot: ClipboardSnapshot
    let showSettings: () -> Void

    @State private var selection: String?
    @State private var sortOrder = [KeyPathComparator(\ClipboardItem.date, order: .reverse)]
    @State private var isWide = false
    @State private var deleting: String?

    var body: some View {
        if snapshot.items.isEmpty {
            empty
        } else {
            let layout = isWide
                ? AnyLayout(HStackLayout(alignment: .top, spacing: SymairaSpacing.large))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: SymairaSpacing.medium))
            layout {
                table
                ClipboardDetailView(
                    model: model, item: snapshot.items.first { $0.id == selection },
                    askDelete: { deleting = $0 }
                )
                .frame(maxWidth: isWide ? 300 : .infinity, maxHeight: isWide ? .infinity : 200, alignment: .topLeading)
            }
            .onGeometryChange(for: Bool.self) { $0.size.width >= 700 } action: { isWide = $0 }
            .task(id: selection) {
                if let selection { await model.loadDetail(selection) } else { model.clearDetail() }
            }
            .onDisappear { model.clearDetail() }
            .confirmationDialog(
                "Delete this entry?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible, presenting: deleting
            ) { id in
                Button("Delete Entry", role: .destructive) {
                    if selection == id { selection = nil }
                    Task { await model.delete(id) }
                    deleting = nil
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: { _ in
                Text("It is removed from the history on this Mac and cannot be restored.")
            }
        }
    }

    @ViewBuilder
    private var empty: some View {
        if !snapshot.settings.enabled {
            SymairaPageEmpty(
                icon: .paste, title: "Clipboard History Is Off",
                message: "Nothing is recorded until you turn it on. It is encrypted, stays on this Mac and skips password managers."
            ) {
                Button("Review Settings", action: showSettings)
                    .symairaButtonStyle(.secondary)
            }
        } else {
            SymairaPageEmpty(
                icon: .paste, title: "Nothing Copied Yet",
                message: snapshot.settings.paused
                    ? "Capture is paused. Resume it to record what you copy."
                    : "What you copy from now on appears here."
            )
        }
    }

    private var table: some View {
        Table(snapshot.items.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Copied", value: \.date) { item in
                Text(item.date, format: .dateTime.day().month(.abbreviated).hour().minute().second())
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 140)
            TableColumn("Source") { item in
                ClipboardSourceText(source: model.details[item.id]?.source)
                    .help("Select an entry to read its source app")
            }
            .width(min: 90, ideal: 120)
            TableColumn("Type", value: \.kind) { item in
                Text(item.isText ? "Text" : item.isImage ? "Image" : item.kind.capitalized)
            }
            .width(min: 50, ideal: 60)
            TableColumn("Size", value: \.size) { item in
                Text(ClipboardFormat.size(item.size)).monospacedDigit()
            }
            .width(min: 60, ideal: 70)
        }
        .frame(minHeight: 200)
        .accessibilityLabel("Clipboard history")
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first {
                if model.canCopyBack {
                    Button("Copy to Clipboard") { Task { await model.copyBack(id) } }
                }
                if model.canDelete {
                    Button("Delete Entry…", role: .destructive) { deleting = id }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, model.canCopyBack { Task { await model.copyBack(id) } }
        }
        .onDeleteCommand { if model.canDelete, let selection { deleting = selection } }
        .onChange(of: snapshot.items) { _, items in
            if let selection, !items.contains(where: { $0.id == selection }) { self.selection = nil }
        }
    }
}

private struct ClipboardSourceText: View {
    let source: String?

    var body: some View {
        if let source, !source.isEmpty {
            Text(ClipboardFormat.appName(bundleID: source)).lineLimit(1).help(source)
        } else {
            Text("—").symairaText(.secondary)
        }
    }
}

// MARK: - Detail

@MainActor
private struct ClipboardDetailView: View {
    let model: ClipboardModel
    let item: ClipboardItem?
    let askDelete: (String) -> Void

    private static let shownCharacters = 20_000

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: SymairaSpacing.small) {
                header(item)
                content(item)
                HStack(spacing: SymairaSpacing.small) {
                    if model.canCopyBack {
                        Button("Copy to Clipboard") { Task { await model.copyBack(item.id) } }
                            .symairaButtonStyle(.primary)
                            .disabled(model.isBusy)
                    }
                    if model.canDelete {
                        Button("Delete Entry…") { askDelete(item.id) }
                            .symairaButtonStyle(.secondary)
                            .disabled(model.isBusy)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
            .task(id: item.id) { await model.loadDetail(item.id) }
            .accessibilityIdentifier("clipboard-detail")
        } else {
            Text("Select an entry to see its content and copy it back.")
                .symairaText(.caption)
                .foregroundStyle(SymairaTokens.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()
        }
    }

    private func header(_ item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.xSmall) {
            Text(item.date, format: .dateTime.day().month(.wide).year().hour().minute())
                .symairaText(.subheading)
            let source = model.details[item.id]?.source
            Text([
                item.isImage ? "Image" : "Text", ClipboardFormat.size(item.size),
                source.flatMap { $0.isEmpty ? nil : "from \(ClipboardFormat.appName(bundleID: $0))" },
            ].compactMap { $0 }.joined(separator: " · "))
                .symairaText(.caption)
                .foregroundStyle(SymairaTokens.ink3)
        }
    }

    @ViewBuilder
    private func content(_ item: ClipboardItem) -> some View {
        if !model.canReadContent {
            SymairaNotice(message: "This agent cannot open clipboard entries.", tone: .neutral)
        } else if let failure = model.detailFailures[item.id] {
            SymairaNotice(message: failure, tone: .warning)
        } else if let detail = model.details[item.id] {
            if let png = detail.png, let image = NSImage(data: png) {
                Image(nsImage: image)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .accessibilityLabel("Copied image")
            } else if let text = detail.text {
                ScrollView {
                    Text(text.count > Self.shownCharacters ? String(text.prefix(Self.shownCharacters)) + "…" : text)
                        .symairaText(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                if text.count > Self.shownCharacters {
                    Text("Showing the first 20,000 characters; Copy to Clipboard copies all of it.")
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTokens.ink3)
                }
            }
        } else {
            ProgressView("Opening entry…")
        }
    }
}

// MARK: - Formatting

enum ClipboardFormat {
    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// The app's name when it is installed here, otherwise the bundle id as it is.
    static func appName(bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
