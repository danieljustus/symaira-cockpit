import AppKit
import SwiftUI
import SymCockpitCore
import SymairaTheme
import UniformTypeIdentifiers

// Pieces the Storage and Processes pages share: the card frame, the rendering of a section's
// state, the file panels and the number formatting. No logic of the agent lives here.

/// One titled card of a page: icon and title, an explaining line, then the section.
struct PageCard<Content: View>: View {
    let title: String
    let icon: SymairaIcon
    var detail: String?
    var identifier: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            Label(title, symairaIcon: icon, iconSize: 16)
                .symairaText(.subheading)
                .foregroundStyle(SymairaTokens.ink2)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail)
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// A caption line in the muted ink; the page's one way of saying a small thing.
struct MutedNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .symairaText(.caption)
            .foregroundStyle(SymairaTokens.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Renders a section's state: loading with words, the agent's failure with a retry, "not available
/// on this Mac" without one, the idle hint, then the loaded content (STATE-1 to STATE-8).
struct SectionStateView<Value: Equatable & Sendable, Idle: View, Loaded: View>: View {
    let state: SectionState<Value>
    let loading: String
    var retry: (() -> Void)?
    @ViewBuilder let idle: Idle
    @ViewBuilder let loaded: (Value) -> Loaded

    var body: some View {
        switch state {
        case .idle:
            idle
        case .loading:
            ProgressView(loading)
        case .failed(let message):
            VStack(alignment: .leading, spacing: SymairaSpacing.small) {
                SymairaNotice(message: message, tone: .critical)
                if let retry {
                    Button("Try Again", action: retry)
                        .symairaButtonStyle(.secondary)
                }
            }
        case .unavailable(let message):
            SymairaNotice(title: "Not Available", message: message, tone: .warning)
        case .loaded(let value):
            loaded(value)
        }
    }
}

enum FilePanels {
    /// Asks for a folder; `nil` when the person cancels.
    @MainActor
    static func chooseFolder(message: String, prompt: String = "Choose") -> String? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// Asks for an application bundle; `nil` when the person cancels.
    @MainActor
    static func chooseApp() -> String? {
        let panel = NSOpenPanel()
        panel.message = "Choose the app to uninstall."
        panel.prompt = "Choose App"
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

enum StorageFormat {
    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func measuredBytes(_ value: Double) -> String {
        if let count = Int(exactly: value) { return size(count) }
        return value.formatted(.number.precision(.fractionLength(0))) + " bytes"
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    /// `/Users/me/Library` as `~/Library`: paths read shorter and say whose they are.
    static func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func grade(_ grade: HealthGrade) -> (label: String, tone: SymairaTone) {
        switch grade {
        case .good: ("Good", .positive)
        case .warning: ("Warning", .warning)
        case .critical: ("Critical", .critical)
        case .unknown: ("Unknown", .neutral)
        }
    }
}
