import SwiftUI
import SymCockpitCore
import SymairaTheme

/// Secure provider credential input backed by SymVault.
///
/// The view never reads a stored secret. It writes user input to `symvault`
/// over stdin and displays only the non-secret reference used by symbrain.
///
/// A user who already keeps the key in another SymVault entry can point the
/// provider at it instead (issue #376). Cockpit then only passes that opaque
/// reference to symbrain: the secret entry field is hidden, so Cockpit never
/// writes over — or reads — an entry it does not own.
struct SymVaultCredentialField: View {
    let providerID: String
    let store: SymVaultCredentialStore
    let title: String
    @ObservedObject var preferences: AIUsagePreferences
    let onCredentialChange: () -> Void

    @State private var pathDraft = ""
    @State private var pathMessage: String?
    @State private var value = ""
    @State private var saved = false
    @State private var statusMessage: String?
    @State private var isMigrating = false
    @State private var isConfirmingRemoval = false

    private var customPath: String? {
        preferences.entryPaths.customPath(for: providerID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            entryPathRow
            if let customPath {
                Text("Using the existing SymVault entry \(SymVaultEntryPaths.scheme)\(customPath). Cockpit only passes this reference to symbrain; it never reads or overwrites the entry.")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink2)
                    .textSelection(.enabled)
            } else {
                ownedEntryContent
            }
        }
        .padding(.leading, 20)
        .accessibilityElement(children: .contain)
        .onAppear {
            pathDraft = customPath ?? ""
            if customPath == nil { migrateLegacyCredential() }
        }
    }

    /// The SymVault entry usage looks up. Empty means the default, which is
    /// the entry Cockpit writes to below.
    private var entryPathRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(
                    "SymVault entry",
                    text: $pathDraft,
                    prompt: Text(SymVaultCredentialStore.defaultEntryPath(for: providerID))
                )
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit(applyEntryPath)
                Button("Use entry", action: applyEntryPath)
                    .disabled(pathDraft.trimmingCharacters(in: .whitespacesAndNewlines) == (customPath ?? ""))
                if customPath != nil {
                    Button("Use default") {
                        pathDraft = ""
                        applyEntryPath()
                    }
                }
            }
            if let pathMessage {
                Text(pathMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func applyEntryPath() {
        guard preferences.setVaultEntryPath(pathDraft, for: providerID) else {
            pathMessage = "Not a valid SymVault entry path."
            return
        }
        pathMessage = nil
        pathDraft = customPath ?? ""
        onCredentialChange()
    }

    @ViewBuilder
    private var ownedEntryContent: some View {
        Text("Stored in SymVault as \(store.reference(for: providerID))")
            .symairaText(.caption)
            .foregroundStyle(SymairaTokens.ink2)
            .textSelection(.enabled)

        HStack {
            SecureField(title, text: $value)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if saved {
                Text("Saved")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Button("Save", action: save)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }

        Button("Remove saved credential", role: .destructive) {
            isConfirmingRemoval = true
        }
        .font(.caption)
        .confirmationDialog("Remove saved credential?", isPresented: $isConfirmingRemoval) {
            Button("Remove saved credential", role: .destructive, action: delete)
        }
        if let statusMessage {
            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(statusMessage.hasPrefix("Saved") || statusMessage.hasPrefix("Migrated")
                                 || statusMessage.hasPrefix("Removed") ? .green : .red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try store.save(trimmed, for: providerID)
            value = ""
            statusMessage = "Saved to SymVault."
            saved = true
            onCredentialChange()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                saved = false
            }
        } catch {
            statusMessage = SecretRedactor.redact(error.localizedDescription)
            saved = false
        }
    }

    private func delete() {
        guard store.delete(for: providerID) else {
            statusMessage = "The SymVault credential could not be removed."
            return
        }
        value = ""
        statusMessage = "Removed from SymVault."
        saved = false
        onCredentialChange()
    }

    private func migrateLegacyCredential() {
        guard !isMigrating else { return }
        isMigrating = true
        Task { @MainActor in
            defer { isMigrating = false }
            do {
                if try store.migrateLegacyCredential(for: providerID) {
                    statusMessage = "Migrated legacy credential into SymVault."
                    onCredentialChange()
                }
            } catch {
                statusMessage = SecretRedactor.redact(error.localizedDescription)
            }
        }
    }
}
