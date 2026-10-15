import SwiftUI
import SymairaTheme
import SymairaUpdateCheck

/// A compact card view displayed when a newer release is available.
/// Shows the version tag, a Download button (opens the release URL),
/// an Install button (uses UpdateApplier for self-update when assets
/// are available), and a Skip button.
@MainActor
struct UpdateNotificationView: View {
    @ObservedObject var updateChecker: AppUpdateChecker

    @State private var isInstalling = false
    @State private var installError: String?
    @State private var installComplete = false

    /// Progress callback passed to UpdateApplier. Tracks download progress.
    private let progressHandler: UpdateProgressHandler = { _, _ in
        // Progress tracking is handled by the caller via local state
    }

    /// Shared UpdateApplier for this app. Configured for macOS
    /// (auto-detects current arch) with install-method detection disabled
    /// for simplicity.
    ///
    /// `static` on purpose: a stored property here is constructed every time the
    /// view struct is rebuilt, which happens on every panel refresh.
    private static let applier = UpdateApplier(
        checkInstallMethod: false,
        binaryName: "SymCockpitMenuBarApp"
    )

    var body: some View {
        if case .available(let release) = updateChecker.status {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(SymairaTokens.selected)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Update Available")
                            .symairaText(.subheading)
                            .foregroundStyle(SymairaTokens.selected)
                        Text(release.tagName)
                            .symairaText(.monoSmall)
                            .foregroundStyle(SymairaTokens.ink2)
                    }
                    Spacer()

                    // Install button — uses UpdateApplier when assets exist
                    if release.assets.isEmpty {
                        Button("Download") {
                            if let url = URL(string: release.htmlURL) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .symairaText(.caption, respectsForeground: false)
                        .buttonStyle(.borderedProminent)
                        .tint(SymairaTokens.selected)
                        .controlSize(.small)
                    } else {
                        Button("Jetzt installieren") {
                            installUpdate(release: release)
                        }
                        .symairaText(.caption, respectsForeground: false)
                        .buttonStyle(.borderedProminent)
                        .tint(SymairaTokens.selected)
                        .controlSize(.small)
                        .disabled(isInstalling)
                    }

                    Button("Skip") {
                        updateChecker.skip(release)
                    }
                    .symairaText(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(SymairaTokens.ink3)
                }

                // Installation progress / error
                if isInstalling {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.7)
                            .controlSize(.small)
                        Text("Installiere...")
                            .symairaText(.caption)
                            .foregroundStyle(SymairaTokens.ink2)
                    }
                }
                if let error = installError {
                    Text(error)
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTokens.critical)
                }
            }
            .padding(SymairaSpacing.medium)
            .background(SymairaTokens.surface)
            .clipShape(RoundedRectangle(cornerRadius: SymairaRadius.card))
            .overlay(
                RoundedRectangle(cornerRadius: SymairaRadius.card)
                    .stroke(SymairaTokens.line, lineWidth: 1)
            )
        } else if case .error(let message) = updateChecker.status {
            VStack(alignment: .leading, spacing: 4) {
                Text("Update check unavailable")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink2)
                Text(message)
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink3)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SymairaSpacing.medium)
            .background(SymairaTokens.surface)
            .clipShape(RoundedRectangle(cornerRadius: SymairaRadius.card))
        }
    }

    // MARK: - Install action

    private func installUpdate(release: ReleaseInfo) {
        isInstalling = true
        installError = nil

        Task {
            do {
                _ = try await Self.applier.applyBundle(release: release)
                // Installation succeeded — mark locally
                installComplete = true
                isInstalling = false

                // Prompt user to relaunch
                let alert = NSAlert()
                alert.messageText = "Update installiert"
                alert.informativeText = "Symaira Cockpit \(release.tagName) wurde nach /Applications installiert. Bitte starte die App neu, um das Update zu aktivieren."
                alert.addButton(withTitle: "Schließen")
                alert.runModal()
            } catch {
                installError = "Installation fehlgeschlagen: \(error.localizedDescription)"
                isInstalling = false
                // Fall back to opening the download page
                if let url = URL(string: release.htmlURL) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
