import Darwin
import Foundation

/// JSON values used for component-specific fields in the canonical history envelope.
public enum HistoryJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case integer(Int64)
    case bool(Bool)
    case object([String: HistoryJSONValue])
    case array([HistoryJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: HistoryJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([HistoryJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public static func fromJSONData(_ data: Data) throws -> HistoryJSONValue {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try fromFoundation(object)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    private static func fromFoundation(_ value: Any) throws -> HistoryJSONValue {
        if value is NSNull { return .null }
        if let value = value as? String { return .string(value) }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
            if value.doubleValue.rounded() == value.doubleValue,
               value.doubleValue >= Double(Int64.min), value.doubleValue <= Double(Int64.max) {
                return .integer(value.int64Value)
            }
            return .number(value.doubleValue)
        }
        if let value = value as? [Any] {
            return .array(try value.map(fromFoundation))
        }
        if let value = value as? [String: Any] {
            return .object(try value.mapValues(fromFoundation))
        }
        throw CocoaError(.propertyListReadCorrupt)
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

/// Versioned, append-only history envelope shared by all symcockpit families.
public struct CanonicalHistoryEvent: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let source: String
    public let timestamp: String
    public let action: String
    public let payload: [String: HistoryJSONValue]

    public init(
        source: String,
        timestamp: String,
        action: String,
        payload: [String: HistoryJSONValue] = [:],
        schemaVersion: Int = CanonicalHistoryEvent.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.timestamp = timestamp
        self.action = action
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case source
        case timestamp
        case action
        case payload
    }

    fileprivate func redacted() -> CanonicalHistoryEvent {
        CanonicalHistoryEvent(
            source: SecretRedactor.redact(source),
            timestamp: SecretRedactor.redact(timestamp),
            action: SecretRedactor.redact(action),
            payload: payload.mapValues { SecretRedactor.redact($0) },
            schemaVersion: schemaVersion
        )
    }
}

public typealias HistoryRecord = CanonicalHistoryEvent


/// The sole JSONL writer/reader used by tune and tune.
public final class CanonicalHistoryStore: @unchecked Sendable {
    private static let processLock = NSLock()

    public let fileURL: URL
    private let lockFileURL: URL
    private let maxEvents: Int

    public init(fileURL: URL, maxEvents: Int = 1000) {
        self.fileURL = fileURL.standardizedFileURL
        self.lockFileURL = self.fileURL.appendingPathExtension("lock")
        self.maxEvents = max(1, maxEvents)
        let manager = FileManager.default
        try? manager.createDirectory(
            at: self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.fileURL.deletingLastPathComponent().path)
        ensureFile(at: self.fileURL)
        ensureFile(at: lockFileURL)
        secureFiles()
    }

    public var isWritable: Bool {
        let manager = FileManager.default
        if manager.fileExists(atPath: fileURL.path) { return manager.isWritableFile(atPath: fileURL.path) }
        return manager.isWritableFile(atPath: fileURL.deletingLastPathComponent().path)
    }

    public func append(_ event: CanonicalHistoryEvent) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(event.redacted())
        line.append(0x0A)

        try withExclusiveAccess {
            defer { secureFiles() }
            ensureFile(at: fileURL)
            try appendRecoveringTail(line)
            try trimIfNeeded()
        }
    }

    /// Reads canonical records and migrates the two legacy flat JSON shapes in memory.
    /// Invalid and unknown lines are ignored so one corrupt append cannot hide later data.
    public func read(limit: Int? = nil) throws -> [CanonicalHistoryEvent] {
        try withExclusiveAccess {
            guard let data = try? Data(contentsOf: fileURL) else { return [] }
            let records = data.split(separator: 0x0A).compactMap { Self.decodeRecord(Data($0)) }
            if let limit, limit > 0 { return Array(records.suffix(limit)) }
            return records
        }
    }

    private func withExclusiveAccess<T>(_ body: () throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        ensureFile(at: lockFileURL)
        secureFiles()
        let lockHandle = try FileHandle(forUpdating: lockFileURL)
        defer { try? lockHandle.close() }
        var fileLock = Darwin.flock()
        fileLock.l_type = Int16(F_WRLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        while Darwin.fcntl(lockHandle.fileDescriptor, F_SETLKW, &fileLock) == -1 {
            guard errno == EINTR else { throw Self.currentPOSIXError() }
        }
        defer {
            var unlock = Darwin.flock()
            unlock.l_type = Int16(F_UNLCK)
            unlock.l_whence = Int16(SEEK_SET)
            _ = Darwin.fcntl(lockHandle.fileDescriptor, F_SETLK, &unlock)
        }
        return try body()
    }

    private func appendRecoveringTail(_ line: Data) throws {
        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }

        let contents = try Data(contentsOf: fileURL)
        if let lastByte = contents.last, lastByte != 0x0A {
            let tailStart = contents.lastIndex(of: 0x0A).map { contents.index(after: $0) } ?? contents.startIndex
            let tail = Data(contents[tailStart...])
            if Self.decodeRecord(tail) != nil {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0x0A]))
            } else {
                try handle.truncate(atOffset: UInt64(tailStart))
            }
        }

        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    private func trimIfNeeded() throws {
        let contents = try Data(contentsOf: fileURL)
        let lines = contents.split(separator: 0x0A)
        guard lines.count > maxEvents else { return }

        var trimmed = Data()
        for line in lines.suffix(maxEvents) {
            trimmed.append(contentsOf: line)
            trimmed.append(0x0A)
        }

        let temporaryURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        let manager = FileManager.default
        guard manager.createFile(
            atPath: temporaryURL.path,
            contents: trimmed,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? manager.removeItem(at: temporaryURL) }
        guard Darwin.rename(temporaryURL.path, fileURL.path) == 0 else {
            throw Self.currentPOSIXError()
        }
    }

    private static func decodeRecord(_ data: Data) -> CanonicalHistoryEvent? {
        if let event = try? JSONDecoder().decode(CanonicalHistoryEvent.self, from: data),
           event.schemaVersion <= CanonicalHistoryEvent.currentSchemaVersion {
            return event
        }
        guard let value = try? HistoryJSONValue.fromJSONData(data),
              case .object(let payload) = value,
              let action = payload["action"]?.stringValue,
              let timestamp = payload["timestamp"]?.stringValue else { return nil }
        return CanonicalHistoryEvent(source: "legacy", timestamp: timestamp, action: action, payload: payload)
    }

    private func ensureFile(at url: URL) {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
    }

    private func secureFiles() {
        let manager = FileManager.default
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockFileURL.path)
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
