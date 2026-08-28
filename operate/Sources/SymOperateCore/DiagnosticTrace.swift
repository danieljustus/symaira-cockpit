import Foundation

public struct DiagnosticTraceRecord: Codable, Sendable, Equatable {
    public let sequence: Int
    public let action: String
    public let outcome: String
    public let fields: [String: String]

    public init(sequence: Int, action: String, outcome: String, fields: [String: String] = [:]) {
        self.sequence = sequence
        self.action = action
        self.outcome = outcome
        self.fields = Self.redacted(fields)
    }

    private static func redacted(_ fields: [String: String]) -> [String: String] {
        let sensitive = ["password", "secret", "token", "credential", "authorization", "cookie", "key"]
        return Dictionary(uniqueKeysWithValues: fields.map { key, value in
            let lowered = key.lowercased()
            return (key, sensitive.contains(where: lowered.contains) ? "[REDACTED]" : value)
        })
    }
}

public struct DiagnosticTrace: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public let version: Int
    public let records: [DiagnosticTraceRecord]

    public init(records: [DiagnosticTraceRecord]) {
        version = Self.currentVersion
        self.records = records.sorted { $0.sequence < $1.sequence }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
