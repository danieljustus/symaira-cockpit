import Foundation

public struct SymVaultCommandResult: Sendable, Equatable {
    public let standardOutput: Data
    public let standardError: Data
    public let terminationStatus: Int32

    public init(standardOutput: Data, standardError: Data, terminationStatus: Int32) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.terminationStatus = terminationStatus
    }
}

public protocol SymVaultCommandRunner: Sendable {
    func run(arguments: [String], standardInput: Data?) throws -> SymVaultCommandResult
}

public struct ProcessSymVaultCommandRunner: SymVaultCommandRunner, Sendable {
    public let binaryName: String
    public let timeout: TimeInterval

    public init(binaryName: String = "symvault", timeout: TimeInterval = 30) {
        self.binaryName = binaryName
        self.timeout = timeout
    }

    public func run(arguments: [String], standardInput: Data?) throws -> SymVaultCommandResult {
        let environment = ProcessInfo.processInfo.environment
        guard let binary = Self.resolve(binaryName, environment: environment) else {
            throw SymVaultCredentialError.binaryUnavailable
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment

        let input = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = input
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw SymVaultCredentialError.binaryUnavailable
        }

        if let standardInput {
            do {
                try input.fileHandleForWriting.write(contentsOf: standardInput)
            } catch {
                process.terminate()
                process.waitUntilExit()
                throw SymVaultCredentialError.commandFailed(-1)
            }
        }
        try? input.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw SymVaultCredentialError.commandFailed(-1)
        }

        return SymVaultCommandResult(
            standardOutput: stdout.fileHandleForReading.readDataToEndOfFile(),
            standardError: stderr.fileHandleForReading.readDataToEndOfFile(),
            terminationStatus: process.terminationStatus
        )
    }

    private static func resolve(_ name: String, environment: [String: String]) -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        guard let path = environment["PATH"] else { return nil }
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

public enum SymVaultCredentialError: Error, LocalizedError, Sendable, Equatable {
    case binaryUnavailable
    case commandFailed(Int32)
    case invalidValue
    case legacyDeletionFailed

    public var errorDescription: String? {
        switch self {
        case .binaryUnavailable:
            return "symvault is not installed"
        case .commandFailed:
            return "symvault could not update the credential"
        case .invalidValue:
            return "The credential cannot be empty."
        case .legacyDeletionFailed:
            return "The legacy Keychain credential was migrated but could not be removed."
        }
    }
}

/// Stores provider credentials in SymVault and exposes only opaque references.
/// The only operation that receives a plaintext value is the one-shot legacy
/// migration; normal reads and usage launches never resolve a credential here.
public struct SymVaultCredentialStore: Sendable {
    public static let entryPrefix = "symtune"
    public static let legacyKeychainService = "com.symaira.symtune"

    private let runner: any SymVaultCommandRunner
    private let keychainReader: @Sendable (String, String) -> String?
    private let keychainDeleter: @Sendable (String, String) -> Bool

    public init(
        runner: any SymVaultCommandRunner = ProcessSymVaultCommandRunner(),
        keychainReader: @escaping @Sendable (String, String) -> String? = { service, account in
            KeychainCredentials.read(service: service, account: account)
        },
        keychainDeleter: @escaping @Sendable (String, String) -> Bool = { service, account in
            KeychainCredentials.delete(service: service, account: account)
        }
    ) {
        self.runner = runner
        self.keychainReader = keychainReader
        self.keychainDeleter = keychainDeleter
    }

    public static func reference(for providerID: String) -> String {
        "symvault://\(entryPrefix)/\(providerID)"
    }

    public func reference(for providerID: String) -> String {
        Self.reference(for: providerID)
    }

    public func save(_ value: String, for providerID: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SymVaultCredentialError.invalidValue }

        let result = try runner.run(
            arguments: [
                "--quiet", "--no-pipe-warning",
                "set", "\(entryPath(for: providerID)).password",
                "--stdin-value", "--force",
            ],
            standardInput: Data((trimmed + "\n").utf8)
        )
        guard result.terminationStatus == 0 else {
            throw SymVaultCredentialError.commandFailed(result.terminationStatus)
        }
    }

    @discardableResult
    public func delete(for providerID: String) -> Bool {
        guard let result = try? runner.run(
            arguments: ["--quiet", "delete", entryPath(for: providerID), "--yes"],
            standardInput: nil
        ) else {
            return false
        }
        return result.terminationStatus == 0
    }

    /// Moves one legacy Keychain item into SymVault. The plaintext is scoped
    /// to this helper and is never returned, logged, or passed as an argument.
    @discardableResult
    public func migrateLegacyCredential(for providerID: String) throws -> Bool {
        let account = "\(providerID)-api-key"
        guard let value = keychainReader(Self.legacyKeychainService, account), !value.isEmpty else {
            return false
        }

        try save(value, for: providerID)
        guard keychainDeleter(Self.legacyKeychainService, account) else {
            throw SymVaultCredentialError.legacyDeletionFailed
        }
        return true
    }

    private func entryPath(for providerID: String) -> String {
        "\(Self.entryPrefix)/\(providerID)"
    }
}
