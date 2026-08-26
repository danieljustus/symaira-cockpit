import Foundation
import SymairaKeychain

/// Keychain access for provider credentials — thin adapter over
/// appkit's `SymairaKeychain`.
///
/// Credentials live in the macOS Keychain, never in `config.toml` or any
/// other plain-text file. This type exists so the usage axis (which is
/// out of scope of the provider-UI consolidation, issue #42) keeps its
/// established API and its headless-safety guarantees without owning any
/// storage code: the storage itself is `SymairaKeychain`'s
/// data-protection-keychain implementation.
///
/// Task#358/#42 behaviour preserved by the adapter:
/// - reads are **bounded** (`read(key:timeout:)`): a wedged `securityd`
///   in a headless context degrades to "no credential" instead of
///   freezing the provider stack (each provider reads eagerly at
///   construction),
/// - writes are **read-back verified** (`saveVerified`): a signing-
///   identity ACL mismatch on locally built unsigned apps surfaces
///   immediately instead of silently losing the key.
public enum KeychainCredentials {
    /// Result of a Keychain write operation with read-back verification
    /// (issue #358). Carries a human-readable error message when the write
    /// or read-back failed, so the UI can surface it instead of silently
    /// returning to a blank field.
    public struct KeychainWriteResult: Sendable, Equatable {
        public let success: Bool
        public let errorMessage: String?
        public init(success: Bool, errorMessage: String?) {
            self.success = success
            self.errorMessage = errorMessage
        }
    }

    private static func keychain(service: String) -> SymairaKeychain {
        SymairaKeychain(service: service)
    }

    /// Reads a generic-password item, or `nil` when absent.
    ///
    /// This runs automatically on every CLI invocation (each AI-usage
    /// provider's `init()` reads its key eagerly), so it must never hang the
    /// caller: the bounded read (3s) degrades a wedged keychain to
    /// "no credential" instead of freezing the whole process (task#358).
    public static func read(service: String, account: String) -> String? {
        try? keychain(service: service).read(key: account, timeout: 3)
    }

    /// Stores a generic-password item, replacing an existing value.
    /// Returns a `KeychainWriteResult` with read-back verification (issue #358).
    public static func write(service: String, account: String, value: String) -> KeychainWriteResult {
        do {
            _ = try keychain(service: service).saveVerified(value, key: account)
            return KeychainWriteResult(success: true, errorMessage: nil)
        } catch {
            return KeychainWriteResult(success: false, errorMessage: error.localizedDescription)
        }
    }

    /// Deletes a generic-password item. Returns `true` when absent or removed.
    public static func delete(service: String, account: String) -> Bool {
        let kc = keychain(service: service)
        if kc.delete(key: account) {
            return true
        }
        // SymairaKeychain.delete reports `false` when the item does not
        // exist; absence counts as deleted (legacy semantics).
        return (try? kc.read(key: account, timeout: 3)) == nil
    }
}