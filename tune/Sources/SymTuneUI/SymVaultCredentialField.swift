import SwiftUI
import SymTuneCore
import SymairaTheme

/// Secure provider credential input backed by SymVault.
///
/// The view never reads a stored secret. It writes user input to `symvault`
/// over stdin and displays only the non-secret reference used by symbrain.
struct SymVaultCredentialField: View {
    let providerID: String
    let store: SymVaultCredentialStore
    let title: String
    let onCredentialChange: () -> Void

    @State private var value = ""
    @State private var saved = false
    @State private var statusMessage: String?
    @State private var isMigrating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stored in SymVault as \(store.reference(for: providerID))")
                .symairaText(.caption)
                .foregroundStyle(SymairaTheme.textSecondary)
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

            if !value.isEmpty {
                Button("Remove saved credential", role: .destructive, action: delete)
                    .font(.caption)
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(statusMessage.hasPrefix("Saved") || statusMessage.hasPrefix("Migrated") ? .green : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 20)
        .accessibilityElement(children: .contain)
        .onAppear(perform: migrateLegacyCredential)
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
