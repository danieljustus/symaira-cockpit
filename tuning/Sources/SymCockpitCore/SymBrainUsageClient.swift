import Foundation
import SymCockpitHistory

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
    public let history: AIUsageRecordedHistory?

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case configured
        case authStatus = "auth_status"
        case snapshot
        case error, history
    }

    public init(
        id: String,
        displayName: String,
        configured: Bool,
        authStatus: SymBrainAuthStatus,
        snapshot: SymBrainUsageSnapshot?,
        error: String = "",
        history: AIUsageRecordedHistory? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.configured = configured
        self.authStatus = authStatus
        self.snapshot = snapshot
        self.error = error
        self.history = history
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        configured = try container.decode(Bool.self, forKey: .configured)
        authStatus = try container.decode(SymBrainAuthStatus.self, forKey: .authStatus)
        snapshot = try container.decodeIfPresent(SymBrainUsageSnapshot.self, forKey: .snapshot)
        error = try container.decodeIfPresent(String.self, forKey: .error) ?? ""
        // An invalid optional extension must not discard usable quota data.
        history = try? container.decodeIfPresent(AIUsageRecordedHistory.self, forKey: .history)
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
            currency: currency.map(SecretRedactor.redact),
            fetchedAt: fetchedAt,
            source: SecretRedactor.redact(source)
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
        default: unitValue = .currency(SecretRedactor.redact(unit))
        }
        return AIUsageMeter(
            label: SecretRedactor.redact(label),
            used: try decimal(used, field: "used"),
            limit: try decimal(limit, field: "limit"),
            unit: unitValue,
            resetsAt: resetsAt
        )
    }
}

private func decimal(_ value: String?, field: String) throws -> Decimal? {
    guard let value else { return nil }
    guard value.range(of: #"\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z"#,
                      options: .regularExpression) != nil,
          let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
          NSDecimalNumber(decimal: decimal).doubleValue.isFinite else {
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
    case providerSelectionUnsupported

    public var errorDescription: String? {
        switch self {
        case .providerSelectionUnsupported: return "Update symbrain to use provider-specific refresh safely"
        case .binaryUnavailable: return "symbrain is not installed"
        case .commandFailed: return "symbrain usage failed"
        case .emptyOutput: return "symbrain usage returned no output"
        case .invalidJSON: return "symbrain usage returned invalid JSON"
        case .unsupportedSchemaVersion: return "symbrain usage returned an unsupported schema version"
        case .invalidValue(let field): return "symbrain usage returned an invalid \(field) value"
        }
    }
}

/// Executes `symbrain` without a shell using the shared bounded runner's
/// PATH-first resolution and managed-install fallbacks. Tests inject a runner
/// or place a fixture executable first on PATH; removing PATH entries alone
/// does not isolate an installed Brain.
public struct ProcessSymBrainCommandRunner: SymBrainCommandRunner, Sendable {
    public let binaryName: String
    public let timeout: TimeInterval

    public init(binaryName: String = "symbrain", timeout: TimeInterval = 30) {
        self.binaryName = binaryName
        self.timeout = timeout
    }

    public func run(arguments: [String], environment: [String: String]) throws -> SymBrainCommandResult {
        let result: BoundedProcessResult
        do {
            result = try SymCockpitHistory.BoundedProcessRunner.run(
                executable: binaryName,
                arguments: arguments,
                timeoutSeconds: timeout,
                environment: environment
            )
        } catch let error as BoundedProcessRunnerError {
            switch error {
            case .executableUnavailable:
                throw SymBrainUsageError.binaryUnavailable
            case .standardInputWriteFailed:
                throw SymBrainUsageError.commandFailed(-1)
            }
        } catch {
            throw SymBrainUsageError.binaryUnavailable
        }

        if result.timedOut {
            throw SymBrainUsageError.commandFailed(-1)
        }
        return SymBrainCommandResult(
            standardOutput: result.standardOutput,
            standardError: result.standardError,
            terminationStatus: result.terminationStatus
        )
    }
}

public protocol SymBrainUsageClientProtocol: Sendable {
    func fetchReport() throws -> SymBrainUsageReport
    func fetchReport(providerIDs: Set<String>) throws -> SymBrainUsageReport
    func fetchReport(providerIDs: Set<String>, grokHistoryEnabled: Bool) throws -> SymBrainUsageReport
    func fetchReport(providerIDs: Set<String>, grokHistoryEnabled: Bool, opencodeHistoryEnabled: Bool) throws -> SymBrainUsageReport
    func fetchReport(providerIDs: Set<String>, grokHistoryEnabled: Bool, opencodeHistoryEnabled: Bool,
                     claudeHistoryEnabled: Bool, claudeHistoryOnly: Bool) throws -> SymBrainUsageReport
    // Preserve explicit consent arguments and existing adapter callers.
    // swiftlint:disable:next function_parameter_count
    func fetchReport(providerIDs: Set<String>, grokHistoryEnabled: Bool, opencodeHistoryEnabled: Bool,
                     claudeHistoryEnabled: Bool, claudeHistoryOnly: Bool,
                     codexHistoryEnabled: Bool, codexHistoryOnly: Bool) throws -> SymBrainUsageReport
}

public extension SymBrainUsageClientProtocol {
    // Preserve explicit consent arguments and existing adapter callers.
    // swiftlint:disable:next function_parameter_count
    func fetchReport(providerIDs: Set<String>, grokHistoryEnabled: Bool, opencodeHistoryEnabled: Bool,
                     claudeHistoryEnabled: Bool, claudeHistoryOnly: Bool,
                     codexHistoryEnabled: Bool, codexHistoryOnly: Bool) throws -> SymBrainUsageReport {
        guard !codexHistoryEnabled, !codexHistoryOnly else { throw SymBrainUsageError.providerSelectionUnsupported }
        return try fetchReport(providerIDs: providerIDs, grokHistoryEnabled: grokHistoryEnabled,
            opencodeHistoryEnabled: opencodeHistoryEnabled, claudeHistoryEnabled: claudeHistoryEnabled, claudeHistoryOnly: claudeHistoryOnly)
    }

    func fetchReport(providerIDs: Set<String>, grokHistoryEnabled: Bool, opencodeHistoryEnabled: Bool,
                     claudeHistoryEnabled: Bool, claudeHistoryOnly: Bool) throws -> SymBrainUsageReport {
        guard !claudeHistoryEnabled, !claudeHistoryOnly else { throw SymBrainUsageError.providerSelectionUnsupported }
        return try fetchReport(providerIDs: providerIDs, grokHistoryEnabled: grokHistoryEnabled, opencodeHistoryEnabled: opencodeHistoryEnabled)
    }

    func fetchReport(providerIDs: Set<String>, grokHistoryEnabled: Bool, opencodeHistoryEnabled: Bool) throws -> SymBrainUsageReport {
        guard !opencodeHistoryEnabled else { throw SymBrainUsageError.providerSelectionUnsupported }
        return try fetchReport(providerIDs: providerIDs, grokHistoryEnabled: grokHistoryEnabled)
    }

    func fetchReport(providerIDs: Set<String>, grokHistoryEnabled: Bool) throws -> SymBrainUsageReport {
        guard !grokHistoryEnabled else { throw SymBrainUsageError.providerSelectionUnsupported }
        return try fetchReport(providerIDs: providerIDs)
    }

    /// Older adapters cannot promise selective credential/network access.
    /// Do not silently substitute an all-provider fetch for an opt-in request.
    func fetchReport(providerIDs: Set<String>) throws -> SymBrainUsageReport {
        throw SymBrainUsageError.providerSelectionUnsupported
    }
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
            // Read lazily, per fetch: the user's chosen SymVault entry path (a
            // preference, not a credential) decides which entry symbrain
            // resolves. No vault access happens here.
            SymVaultEntryPaths.load().reference(for: providerID)
        }
    ) {
        self.runner = runner
        self.environment = environment
        self.credentialReference = credentialReference
    }

    public func fetchReport() throws -> SymBrainUsageReport {
        try fetchReport(selection: nil)
    }

    public func fetchReport(providerIDs: Set<String>) throws -> SymBrainUsageReport {
        try fetchReport(providerIDs: providerIDs, grokHistoryEnabled: false)
    }

    public func fetchReport(providerIDs: Set<String>, grokHistoryEnabled: Bool) throws -> SymBrainUsageReport {
        try fetchReport(providerIDs: providerIDs, grokHistoryEnabled: grokHistoryEnabled, opencodeHistoryEnabled: false)
    }

    public func fetchReport(providerIDs: Set<String>, grokHistoryEnabled: Bool, opencodeHistoryEnabled: Bool) throws -> SymBrainUsageReport {
        try fetchReport(providerIDs: providerIDs, grokHistoryEnabled: grokHistoryEnabled,
                        opencodeHistoryEnabled: opencodeHistoryEnabled, claudeHistoryEnabled: false, claudeHistoryOnly: false)
    }

    public func fetchReport(providerIDs: Set<String>, grokHistoryEnabled: Bool, opencodeHistoryEnabled: Bool,
                            claudeHistoryEnabled: Bool, claudeHistoryOnly: Bool = false) throws -> SymBrainUsageReport {
        return try fetchReport(providerIDs: providerIDs, grokHistoryEnabled: grokHistoryEnabled,
            opencodeHistoryEnabled: opencodeHistoryEnabled, claudeHistoryEnabled: claudeHistoryEnabled,
            claudeHistoryOnly: claudeHistoryOnly, codexHistoryEnabled: false, codexHistoryOnly: false)
    }

    // Additive overload keeps existing adapter callers unchanged.
    // swiftlint:disable:next function_parameter_count
    public func fetchReport(providerIDs: Set<String>, grokHistoryEnabled: Bool, opencodeHistoryEnabled: Bool,
                            claudeHistoryEnabled: Bool, claudeHistoryOnly: Bool,
                            codexHistoryEnabled: Bool, codexHistoryOnly: Bool = false) throws -> SymBrainUsageReport {
        guard !providerIDs.isEmpty else {
            return SymBrainUsageReport(schemaVersion: 1, providers: [])
        }
        guard providerIDs.allSatisfy({ id in
            !id.isEmpty && id.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
        }) else { throw SymBrainUsageError.invalidValue("provider ID") }
        return try fetchReport(selection: providerIDs, grokHistoryEnabled: grokHistoryEnabled, opencodeHistoryEnabled: opencodeHistoryEnabled,
                               claudeHistoryEnabled: claudeHistoryEnabled, claudeHistoryOnly: claudeHistoryOnly,
                               codexHistoryEnabled: codexHistoryEnabled, codexHistoryOnly: codexHistoryOnly)
    }

    private func fetchReport(selection: Set<String>?, grokHistoryEnabled: Bool = false, opencodeHistoryEnabled: Bool = false,
                             claudeHistoryEnabled: Bool = false, claudeHistoryOnly: Bool = false,
                             codexHistoryEnabled: Bool = false, codexHistoryOnly: Bool = false) throws -> SymBrainUsageReport {
        var arguments = ["usage", "--output", "json"]
        if let selection { arguments += ["--providers", selection.sorted().joined(separator: ",")] }
        let result = try runner.run(
            arguments: arguments,
            environment: childEnvironment(selection: selection, grokHistoryEnabled: grokHistoryEnabled, opencodeHistoryEnabled: opencodeHistoryEnabled,
                                          claudeHistoryEnabled: claudeHistoryEnabled, claudeHistoryOnly: claudeHistoryOnly,
                                          codexHistoryEnabled: codexHistoryEnabled, codexHistoryOnly: codexHistoryOnly)
        )
        guard result.terminationStatus == 0 else {
            if selection != nil && result.terminationStatus == 2 {
                throw SymBrainUsageError.providerSelectionUnsupported
            }
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

    /// Environment variable symbrain reads each API-key provider's key from.
    static let credentialEnvironment: [(environmentKey: String, providerID: String)] = [
        ("OPENROUTER_API_KEY", "openrouter"),
        ("MOONSHOT_API_KEY", "moonshot"),
        ("KIMI_CODE_API_KEY", "kimi"),
        ("ZAI_API_KEY", "zai"),
        ("DEVIN_API_KEY", "devin"),
        ("GROK_ACCESS_TOKEN", "grok"),
        ("OPENCODE_GO_API_KEY", "opencode"),
    ]

    // Each provider consent is independent; inherited flags never grant consent.
    // swiftlint:disable:next function_parameter_count
    private func childEnvironment(selection: Set<String>?, grokHistoryEnabled: Bool, opencodeHistoryEnabled: Bool,
                                  claudeHistoryEnabled: Bool, claudeHistoryOnly: Bool,
                                  codexHistoryEnabled: Bool, codexHistoryOnly: Bool) -> [String: String] {
        // Strip every inherited history opt-in, including flags for unsupported providers.
        var result = environment.filter { !($0.key.hasPrefix("SYMBRAIN_USAGE_") && $0.key.contains("_HISTORY")) }
        if codexHistoryEnabled, selection?.contains("codex") == true {
            result["SYMBRAIN_USAGE_CODEX_HISTORY"] = "1"
            if codexHistoryOnly { result["SYMBRAIN_USAGE_CODEX_HISTORY_ONLY"] = "1" }
        }
        if claudeHistoryEnabled, selection?.contains("claude") == true {
            result["SYMBRAIN_USAGE_CLAUDE_HISTORY"] = "1"
            if claudeHistoryOnly { result["SYMBRAIN_USAGE_CLAUDE_HISTORY_ONLY"] = "1" }
        }
        if opencodeHistoryEnabled, selection?.contains("opencode") == true {
            result["SYMBRAIN_USAGE_OPENCODE_HISTORY"] = "1"
        }
        if grokHistoryEnabled, selection?.contains("grok") == true {
            result["SYMBRAIN_USAGE_GROK_HISTORY"] = "1"
        }
        // symbrain resolves these references itself. Keeping them opaque here
        // avoids a second credential store and prevents plaintext values from
        // entering cockpit's process environment.
        for (environmentKey, providerID) in Self.credentialEnvironment {
            if let selection, !selection.contains(providerID) {
                result.removeValue(forKey: environmentKey)
                continue
            }
            guard result[environmentKey]?.isEmpty != false else { continue }
            if let reference = credentialReference(providerID), !reference.isEmpty {
                result[environmentKey] = reference
            }
        }
        return result
    }
}
