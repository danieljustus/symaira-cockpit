import Foundation

// MARK: - Published symbrain usage contract

/// The stable report returned by `symbrain usage --output json`.
public struct SymBrainUsageReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let providers: [SymBrainProviderUsage]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case providers
    }
}

public struct SymBrainProviderUsage: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let configured: Bool
    public let authStatus: SymBrainAuthStatus
    public let snapshot: SymBrainUsageSnapshot?
    public let error: String

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case configured
        case authStatus = "auth_status"
        case snapshot
        case error
    }

    public init(
        id: String,
        displayName: String,
        configured: Bool,
        authStatus: SymBrainAuthStatus,
        snapshot: SymBrainUsageSnapshot?,
        error: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.configured = configured
        self.authStatus = authStatus
        self.snapshot = snapshot
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        configured = try container.decode(Bool.self, forKey: .configured)
        authStatus = try container.decode(SymBrainAuthStatus.self, forKey: .authStatus)
        snapshot = try container.decodeIfPresent(SymBrainUsageSnapshot.self, forKey: .snapshot)
        error = try container.decodeIfPresent(String.self, forKey: .error) ?? ""
    }
}

public struct SymBrainAuthStatus: Codable, Sendable, Equatable {
    public let status: String
    public let detail: String
    public let source: String?
}

public struct SymBrainUsageSnapshot: Codable, Sendable, Equatable {
    public let providerID: String
    public let meters: [SymBrainUsageMeter]?
    public let balance: String?
    public let currency: String?
    public let fetchedAt: Date
    public let source: String

    private enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case meters
        case balance
        case currency
        case fetchedAt = "fetched_at"
        case source
    }

    /// Convert only the documented symbrain fields to the legacy normalized
    /// model consumed by the existing card, CLI, and MCP compatibility path.
    public func aiUsageSnapshot() throws -> AIUsageSnapshot {
        let convertedMeters = try (meters ?? []).map { try $0.aiUsageMeter() }
        let balanceValue = try decimal(balance, field: "balance")
        return AIUsageSnapshot(
            providerID: providerID,
            meters: convertedMeters,
            balance: balanceValue,
            currency: currency,
            fetchedAt: fetchedAt,
            source: source
        )
    }
}

public struct SymBrainUsageMeter: Codable, Sendable, Equatable {
    public let label: String
    public let used: String?
    public let limit: String?
    public let unit: String
    public let resetsAt: Date?

    private enum CodingKeys: String, CodingKey {
        case label
        case used
        case limit
        case unit
        case resetsAt = "resets_at"
    }

    fileprivate func aiUsageMeter() throws -> AIUsageMeter {
        let unitValue: AIUsageUnit
        switch unit {
        case "tokens": unitValue = .tokens
        case "requests": unitValue = .requests
        case "credits": unitValue = .credits
        case "%", "percent": unitValue = .percent
        default: unitValue = .currency(unit)
        }
        return AIUsageMeter(
            label: label,
            used: try decimal(used, field: "used"),
            limit: try decimal(limit, field: "limit"),
            unit: unitValue,
            resetsAt: resetsAt
        )
    }
}

private func decimal(_ value: String?, field: String) throws -> Decimal? {
    guard let value else { return nil }
    guard let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
        throw SymBrainUsageError.invalidValue(field)
    }
    return decimal
}

// MARK: - Runtime command bridge

public struct SymBrainCommandResult: Sendable, Equatable {
    public let standardOutput: Data
    public let standardError: Data
    public let terminationStatus: Int32

    public init(standardOutput: Data, standardError: Data, terminationStatus: Int32) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.terminationStatus = terminationStatus
    }
}

public protocol SymBrainCommandRunner: Sendable {
    func run(arguments: [String], environment: [String: String]) throws -> SymBrainCommandResult
}

public enum SymBrainUsageError: Error, LocalizedError, Sendable, Equatable {
    case binaryUnavailable
    case commandFailed(Int32)
    case emptyOutput
    case invalidJSON
    case unsupportedSchemaVersion(Int)
    case invalidValue(String)

    public var errorDescription: String? {
        switch self {
        case .binaryUnavailable: return "symbrain is not installed"
        case .commandFailed: return "symbrain usage failed"
        case .emptyOutput: return "symbrain usage returned no output"
        case .invalidJSON: return "symbrain usage returned invalid JSON"
        case .unsupportedSchemaVersion: return "symbrain usage returned an unsupported schema version"
        case .invalidValue(let field): return "symbrain usage returned an invalid \(field) value"
        }
    }
}

/// Executes `symbrain` without a shell. Binary resolution is PATH-only; no
/// user-specific path is assumed and callers can inject a runner in tests.
public struct ProcessSymBrainCommandRunner: SymBrainCommandRunner, Sendable {
    public let binaryName: String
    public let timeout: TimeInterval

    public init(binaryName: String = "symbrain", timeout: TimeInterval = 30) {
        self.binaryName = binaryName
        self.timeout = timeout
    }

    public func run(arguments: [String], environment: [String: String]) throws -> SymBrainCommandResult {
        guard let binary = Self.resolve(binaryName, environment: environment) else {
            throw SymBrainUsageError.binaryUnavailable
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw SymBrainUsageError.binaryUnavailable
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            process.terminate()
            throw SymBrainUsageError.commandFailed(-1)
        }

        return SymBrainCommandResult(
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

public protocol SymBrainUsageClientProtocol: Sendable {
    func fetchReport() throws -> SymBrainUsageReport
}

/// Runtime adapter for the published symbrain usage contract.
public struct SymBrainUsageClient: SymBrainUsageClientProtocol, Sendable {
    private let runner: any SymBrainCommandRunner
    private let environment: [String: String]
    private let credentialReference: @Sendable (String) -> String?

    public init(
        runner: any SymBrainCommandRunner = ProcessSymBrainCommandRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        credentialReference: @escaping @Sendable (String) -> String? = { providerID in
            SymVaultCredentialStore.reference(for: providerID)
        }
    ) {
        self.runner = runner
        self.environment = environment
        self.credentialReference = credentialReference
    }

    public func fetchReport() throws -> SymBrainUsageReport {
        let result = try runner.run(
            arguments: ["usage", "--output", "json"],
            environment: childEnvironment()
        )
        guard result.terminationStatus == 0 else {
            throw SymBrainUsageError.commandFailed(result.terminationStatus)
        }
        guard !result.standardOutput.isEmpty else {
            throw SymBrainUsageError.emptyOutput
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let report = try decoder.decode(SymBrainUsageReport.self, from: result.standardOutput)
            guard report.schemaVersion == 1 else {
                throw SymBrainUsageError.unsupportedSchemaVersion(report.schemaVersion)
            }
            return report
        } catch let error as SymBrainUsageError {
            throw error
        } catch {
            throw SymBrainUsageError.invalidJSON
        }
    }

    private func childEnvironment() -> [String: String] {
        var result = environment
        // symbrain resolves these references itself. Keeping them opaque here
        // avoids a second credential store and prevents plaintext values from
        // entering cockpit's process environment.
        let mappings = [
            ("OPENROUTER_API_KEY", "openrouter"),
            ("MOONSHOT_API_KEY", "moonshot"),
            ("KIMI_CODE_API_KEY", "kimi"),
        ]
        for (environmentKey, providerID) in mappings where result[environmentKey]?.isEmpty != false {
            if let reference = credentialReference(providerID), !reference.isEmpty {
                result[environmentKey] = reference
            }
        }
        return result
    }
}
