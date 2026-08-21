import Foundation
import Security

/// Keychain access for provider credentials.
///
/// Credentials live in the macOS Keychain, never in `config.toml` or any
/// other plain-text file. Reading is the only operation the provider stack
/// performs automatically; writing happens only from an explicit user
/// action in the app's preferences.
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
    /// Reads a generic-password item, or `nil` when absent.
    ///
    /// This runs automatically on every CLI invocation (each AI-usage
    /// provider's `init()` reads its key eagerly), so it must never hang the
    /// caller. `SecItemCopyMatching` can block indefinitely on a securityd
    /// round-trip when there is no GUI session to service it — headless
    /// automation, a locked screen, or an SSH session (observed: 0% CPU,
    /// stuck in `mach_msg` waiting on a reply that never arrives). The read
    /// runs on a background queue with a bounded wait so a wedged keychain
    /// degrades to "no credential" instead of freezing the whole process.
    /// - Parameters:
    ///   - service: keychain service name (e.g. `com.symaira.symtune`).
    ///   - account: credential slot (e.g. `openrouter-api-key`).
    public static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        let outcome = LockedOutcome()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            outcome.set(status: status, item: item)
            done.signal()
        }
        guard done.wait(timeout: .now() + 3) == .success else {
            return nil
        }
        guard let (status, item) = outcome.get(), status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Thread-safe carrier for the `SecItemCopyMatching` result. `get()` is
    /// only ever called after the background thread's `done.signal()` has
    /// been observed by `done.wait(timeout:)`, so the semaphore itself
    /// provides the happens-before edge — the lock only guards against the
    /// (never-exercised) case of a spurious concurrent access.
    private final class LockedOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (status: OSStatus, item: CFTypeRef?)?

        func set(status: OSStatus, item: CFTypeRef?) {
            lock.lock(); defer { lock.unlock() }
            value = (status, item)
        }

        func get() -> (status: OSStatus, item: CFTypeRef?)? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    /// Stores a generic-password item, replacing an existing value.
    /// Returns a `KeychainWriteResult` with read-back verification (issue #358).
    ///
    /// After the write succeeds, the credential is **read back** and compared
    /// against the value that was just written. This closes the signing-identity
    /// gap (issue #358): items written by one locally-built, unsigned binary
    /// can be unreadable by the next build if the ACL binding to the signing
    /// identity doesn't match. Without read-back verification, `write` reports
    /// success on a `SecItemAdd`/`SecItemUpdate` success, but the field reads
    /// back empty on relaunch — indistinguishable from "never entered".
    /// - Parameters:
    ///   - service: keychain service name (e.g. `com.symaira.symtune`).
    ///   - account: credential slot (e.g. `openrouter-api-key`).
    ///   - value: the secret to store.
    public static func write(service: String, account: String, value: String) -> KeychainWriteResult {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        var writeStatus: OSStatus
        if updateStatus == errSecSuccess {
            writeStatus = updateStatus
        } else if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            writeStatus = SecItemAdd(addQuery as CFDictionary, nil)
        } else {
            writeStatus = updateStatus
        }

        // Read-back verification (issue #358): a successful SecItemAdd/Update
        // does NOT guarantee the item is retrievable by this binary — on locally
        // built unsigned apps the ACL can be bound to a signing identity that
        // doesn't match on the next build. Verify the round-trip here.
        if writeStatus == errSecSuccess {
            let readBack = read(service: service, account: account)
            if readBack == value {
                return KeychainWriteResult(success: true, errorMessage: nil)
            } else {
                return KeychainWriteResult(success: false, errorMessage: "Keychain write succeeded but read-back failed — the credential may not be retrievable.")
            }
        }
        return KeychainWriteResult(success: false, errorMessage: keychainErrorMessage(writeStatus))
    }

    /// Human-readable error for a Keychain status code.
    private static func keychainErrorMessage(_ status: OSStatus) -> String? {
        #if os(macOS)
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "Keychain error: \(message) (code \(status))"
        }
        #endif
        return "Keychain write failed (code \(status))"
    }

    /// Deletes a generic-password item. Returns `true` when absent or removed.
    public static func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
