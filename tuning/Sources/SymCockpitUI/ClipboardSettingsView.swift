import AppKit
import SwiftUI
import SymCockpitCore
import SymairaTheme

/// The Settings tab of the Clipboard page: the opt-in with what it means, the capture state,
/// the apps it never records, and deleting everything. Every value is the agent's.
@MainActor
struct ClipboardSettingsView: View {
    let model: ClipboardModel
    let snapshot: ClipboardSnapshot

    @State private var newApp = ""
    @State private var confirmingClear = false

    private var settings: ClipboardSettings { snapshot.settings }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SymairaSpacing.large) {
                historySection
                privacySection
                exclusionsSection
                deleteSection
            }
            .padding(.bottom, SymairaSpacing.xLarge)
        }
        .confirmationDialog(
            "Delete all entries?", isPresented: $confirmingClear, titleVisibility: .visible
        ) {
            Button("Delete All Entries", role: .destructive) {
                Task { await model.clearAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes every saved entry on this Mac, including entries not shown in the list.")
        }
    }

    // MARK: Sections

    private var historySection: some View {
        SymairaFormSection("Clipboard History") {
            SymairaFormRow(
                "Keep a clipboard history",
                description: "Off unless you turn it on. Saves text and images you copy so you can copy them back later."
            ) {
                Toggle(isOn: Binding(
                    get: { settings.enabled }, set: { value in Task { await model.setEnabled(value) } }
                )) { EmptyView() }
                .toggleStyle(.symairaSwitch)
                .labelsHidden()
                .disabled(model.isBusy)
                .accessibilityLabel("Keep a clipboard history")
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            SymairaFormDivider()
            SymairaFormRow("Capture") {
                status
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if snapshot.serviceError != nil {
            SymairaStatusLabel("Failed", tone: .critical)
        } else if !settings.enabled {
            SymairaStatusLabel("Off", tone: .neutral)
        } else if settings.paused {
            SymairaStatusLabel("Paused", tone: .warning)
        } else {
            SymairaStatusLabel("Capturing", tone: .positive)
        }
    }

    private var privacySection: some View {
        SymairaFormSection(
            "What Is Kept",
            footer: "Pause stops recording and keeps what is saved. Turning the history off stops it too; saved entries stay until you delete them."
        ) {
            SymairaFormRow(
                "Encrypted, on this Mac",
                description: "Entries are encrypted with a key kept in your Keychain. Nothing leaves this Mac."
            )
            SymairaFormDivider()
            SymairaFormRow(
                "Secrets are skipped",
                description: "Content that an app marks as secret, such as a password field, and anything copied from an excluded app is never stored."
            )
            SymairaFormDivider()
            SymairaFormRow(
                "Not Shared via MCP",
                description: "Clipboard content is not exposed through MCP or Cockpit's clipboard CLI commands."
            )
            SymairaFormDivider()
            SymairaFormRow(
                "Limits",
                description: "Up to \(settings.maxItems) entries, for \(settings.maxAgeDays) days. Older ones are removed."
            )
        }
    }

    private var exclusionsSection: some View {
        SymairaFormSection(
            "Excluded Apps",
            footer: "Copies from these apps are never stored. Password managers are excluded to begin with."
        ) {
            if settings.excludedApps.isEmpty {
                SymairaFormRow("No excluded apps", description: "Everything you copy is recorded while the history is on.")
            }
            ForEach(Array(settings.excludedApps.enumerated()), id: \.element) { offset, bundleID in
                if offset > 0 { SymairaFormDivider() }
                SymairaFormRow(ClipboardFormat.appName(bundleID: bundleID), description: bundleID) {
                    Button("Remove") { Task { await model.removeExcludedApp(bundleID) } }
                        .symairaButtonStyle(.secondary)
                        .disabled(model.isBusy)
                        .accessibilityLabel("Stop excluding \(bundleID)")
                }
            }
            SymairaFormDivider()
            SymairaFormRow("Add an app") {
                HStack(spacing: SymairaSpacing.small) {
                    TextField("com.example.App", text: $newApp)
                        .textFieldStyle(.symaira)
                        .frame(width: 200)
                        .onSubmit(add)
                        .accessibilityLabel("Bundle identifier of the app to exclude")
                    Button("Add", action: add)
                        .symairaButtonStyle(.secondary)
                        .disabled(model.isBusy || newApp.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Choose App…", action: chooseApp)
                        .symairaButtonStyle(.secondary)
                        .disabled(model.isBusy)
                }
            }
        }
    }

    private var deleteSection: some View {
        SymairaFormSection("Saved Entries") {
            SymairaFormRow(
                "Delete all entries",
                description: snapshot.items.isEmpty
                    ? "There is nothing saved."
                    : "Permanently removes every saved entry, including entries not shown in the list."
            ) {
                Button("Delete All…") { confirmingClear = true }
                    .symairaButtonStyle(.secondary)
                    .disabled(model.isBusy || snapshot.items.isEmpty)
            }
        }
    }

    // MARK: Actions

    private func add() {
        let text = newApp
        Task { if await model.addExcludedApp(text) { newApp = "" } }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an App to Exclude"
        panel.prompt = "Exclude"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bundleID = Bundle(url: url)?.bundleIdentifier ?? ""
        Task { _ = await model.addExcludedApp(bundleID) }
    }
}
