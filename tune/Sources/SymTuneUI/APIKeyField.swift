import SwiftUI
import SymairaTheme
import SymTuneCore

/// A SecureField that stores the entered value in the Keychain on submit.
///
/// The stored account is `<providerID>-api-key` under the standard
/// `com.symaira.symtune` service — the same slot the providers read at
/// construction time. The field is deliberately a local write: nothing here
/// ever reads the value back into `config.toml`.
///
/// Issue #358: when the Keychain rejects the write (e.g. signing-identity
/// ACL mismatch on a locally-built unsigned app), the field shows a clear
/// error state instead of silently returning to blank. The write path now
/// includes read-back verification, but the UI must also surface a visible
/// failure signal — previously `write` returning `false` rendered an empty
/// field identical to "never entered".
struct APIKeyField: View {
    let providerID: String
    /// Keychain account name override (issue #360: `credentialDescriptor`'s
    /// `.apiKey(account:)` provides this so different providers can share
    /// or namespace their account keys cleanly).
    let accountId: String?
    let label: String
    let placeholder: String
    /// Called after the credential is saved or cleared, so the caller can
    /// drop the AI-usage cache and trigger an immediate refresh (issue #324).
    var onCredentialChange: (() -> Void)?

    @State private var value: String
    @State private var saved = false
    /// Visible error state (issue #358): non-nil when the Keychain write
    /// succeeded at the SecItem level but failed read-back, or was rejected.
    @State private var saveError: String?

    /// - Parameters:
    ///   - providerID: the provider identifier (e.g. `"openrouter"`).
    ///   - accountId: override for the Keychain account name; defaults to
    ///     `"<providerID>-api-key"`.
    ///   - label: human-readable field label.
    ///   - placeholder: placeholder shown in the SecureField.
    ///   - onCredentialChange: called after save/clear.
    init(
        providerID: String,
        accountId: String? = nil,
        label: String,
        placeholder: String,
        onCredentialChange: (() -> Void)? = nil
    ) {
        self.providerID = providerID
        self.accountId = accountId
        self.label = label
        self.placeholder = placeholder
        self.onCredentialChange = onCredentialChange
        let account = accountId ?? "\(providerID)-api-key"
        self._value = State(initialValue: KeychainCredentials.read(
            service: "com.symaira.symtune",
            account: account
        ) ?? "")
    }

    /// The Keychain account used for this field.
    private var keychainAccount: String {
        accountId ?? "\(providerID)-api-key"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                SecureField(label, text: $value, prompt: Text(placeholder))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                if saved {
                    Text("saved")
                        .font(.caption2)
                        .foregroundStyle(Color.green)
                } else if saveError != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.red)
                } else {
                    Button("Save") {
                        save()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(SymairaTheme.goldPrimary)
                }
            }
            .padding(.leading, 20)

            if let error = saveError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Color.red)
                    .padding(.leading, 20)
            }
        }
    }

    private func save() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = keychainAccount
        if trimmed.isEmpty {
            _ = KeychainCredentials.delete(service: "com.symaira.symtune", account: account)
            value = ""
        } else {
            let writeResult = KeychainCredentials.write(
                service: "com.symaira.symtune",
                account: account,
                value: trimmed
            )
            if !writeResult.success {
                // Issue #358: the Keychain write failed or failed read-back
                // verification. Show a visible error instead of silently
                // returning to a blank field.
                saveError = writeResult.errorMessage ?? "Keychain write failed — the key was not saved."
                return
            }
        }
        saveError = nil
        withAnimation(.easeInOut(duration: 0.15)) {
            saved = true
        }
        // The credential changed (added or removed): drop the provider's
        // stale cache and refresh now so the usage card updates immediately.
        onCredentialChange?()
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.15)) {
                    saved = false
                }
            }
        }
    }
}
