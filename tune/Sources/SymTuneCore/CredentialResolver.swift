import Foundation

// MARK: - Credential resolution

/// The resolution chain for a single provider credential (issue #18).
///
/// Mirrors symdesk's `secrets.ResolveKey` / `secrets.Source` pattern:
/// `op://` reference → symvault subprocess; else env var; else Keychain fallback.
/// Runtime detection of `symvault` with silent degradation when absent —
/// standalone-first, as everywhere else in the ecosystem.
///
/// All methods are side-effect-free reads. Resolution is bounded by a
/// subprocess timeout so a wedged symvault cannot block provider reads.
public protocol CredentialResolver: Sendable {
    /// Resolve the credential value for a provider, or `nil` when no
    /// credential is available through any source.
    func resolve(
        opReference: String?,
        envKey: String,
        keychainService: String?,
        keychainAccount: String?
    ) -> String?

    /// Human-readable source of the resolved credential, matching the
    /// symdesk `Source()` vocabulary (`symvault`, `env`, `keychain`, `none`).
    /// Called *after* `resolve` to report which path produced the value.
    func source(
        opReference: String?,
        envKey: String,
        keychainService: String?,
        keychainAccount: String?
    ) -> String
}

/// Default credential resolver: symvault (`op://`) → env → Keychain.
///
/// - `op://` references are resolved by spawning `symvault get --print <ref>`.
/// - When `symvault` is not installed, an `op://` reference yields `nil`
///   with source `"symvault (missing)"` — it never falls through to return
///   the raw reference string as a key (that would leak the vault path to
///   a third-party API endpoint).
/// - Env vars are checked next; Keychain is the last fallback.
///
/// Resolution never writes to disk, the Keychain, or the vault.
public struct DefaultCredentialResolver: CredentialResolver, Sendable {
    public init(
        symvault: SymVaultServiceProtocol = SymVaultService(),
        keychainReader: @escaping @Sendable (String?, String?) -> String? = { service, account in
            guard let service, let account else { return nil }
            return KeychainCredentials.read(service: service, account: account)
        },
        env: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.symvault = symvault
        self.keychainReader = keychainReader
        self.env = env
    }

    /// The symvault subprocess wrapper. Injected for testability.
    public let symvault: SymVaultServiceProtocol

    /// The Keychain read function. Injected for testability.
    public let keychainReader: @Sendable (String?, String?) -> String?

    /// Environment dictionary snapshot. Injected primarily so tests can
    /// control it deterministically.
    public let env: [String: String]

    // MARK: - Resolution

    public func resolve(
        opReference: String?,
        envKey: String,
        keychainService: String?,
        keychainAccount: String?
    ) -> String? {
        // 1. op:// reference → symvault
        if let ref = opReference, ref.hasPrefix("op://") {
            return symvault.get(reference: ref)
        }
        // 2. Env var
        if let value = env[envKey], !value.isEmpty {
            return value
        }
        // 3. Keychain fallback
        guard let service = keychainService, let account = keychainAccount else { return nil }
        return keychainReader(service, account)
    }

    public func source(
        opReference: String?,
        envKey: String,
        keychainService: String?,
        keychainAccount: String?
    ) -> String {
        // 1. op:// → symvault
        if let ref = opReference, ref.hasPrefix("op://") {
            if symvault.isAvailable {
                return "symvault"
            }
            return "symvault (missing)"
        }
        // 2. Env var
        if let value = env[envKey], !value.isEmpty {
            return "env"
        }
        // 3. Keychain
        if let service = keychainService, let account = keychainAccount,
           let _ = keychainReader(service, account) {
            return "keychain"
        }
        return "none"
    }
}

/// Protocol wrapping the `symvault` subprocess so tests can inject a fake.
public protocol SymVaultServiceProtocol: Sendable {
    /// Whether `symvault` is installed and callable on PATH.
    var isAvailable: Bool { get }
    /// Resolve an `op://…` reference via `symvault get --print`.
    /// Returns `nil` on any failure (absent, timeout, non-empty error).
    /// Never returns the raw reference string.
    func get(reference: String) -> String?
}

/// Production symvault subprocess wrapper.
///
/// Calls `symvault get --print <reference>` with a bounded timeout.
/// Uses `--print` so the value goes to stdout (clipboard mode has no
/// place in a headless credential read). The subprocess output is
/// trimmed of surrounding whitespace (trailing newline etc.).
///
/// A 2-second timeout matches symdesk's behaviour. On any error —
/// symvault absent, timeout, non-zero exit — returns `nil`. The caller
/// then reports `"symvault (missing)"` in the source field.
public final class SymVaultService: SymVaultServiceProtocol, @unchecked Sendable {
    public init() {}

    public var isAvailable: Bool {
        resolveSymvault() != nil
    }

    public func get(reference: String) -> String? {
        guard let path = resolveSymvault() else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["get", "--print", reference]
        // Redirect stderr to /dev/null so symvault's interactive prompts
        // (auto-copy to clipboard on TTY, etc.) never surface.
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        let pipe = task.standardOutput as! Pipe
        do {
            try task.run()
        } catch {
            return nil
        }
        // Bounded wait: a hung symvault (e.g. waiting for keychain auth)
        // must not block provider credential reads.
        let deadline = DispatchTime.now() + .seconds(2)
        while task.isRunning && DispatchTime.now() < deadline {
            usleep(10_000) // 10ms
        }
        let success = task.terminationStatus == 0
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        if success, let output {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        // Timeout or error: kill if still alive.
        if task.isRunning {
            task.terminate()
        }
        return nil
    }

    private func resolveSymvault() -> String? {
        if let bin = ProcessInfo.processInfo.environment["SYMAIRA_BIN"],
           let path = exec(withPath: "\(bin)/symvault", args: nil) {
            return path
        }
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            let managed = "\(home)/.symaira/bin/symvault"
            if FileManager.default.isExecutableFile(atPath: managed) {
                return managed
            }
        }
        return exec(withPath: "symvault", args: nil)
    }

    /// Minimal `which`/`exec`-style lookup. Returns the full path if the
    /// binary exists and is executable, `nil` otherwise.
    private func exec(withPath path: String, args: [String]?) -> String? {
        if path.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        return Self.lookPath(path)
    }

    private static func lookPath(_ name: String) -> String? {
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in pathEnv.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
