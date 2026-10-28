import Foundation

/// Shared CLI/GUI cache of normalized usage only. Never persists auth metadata,
/// raw provider responses, errors, or credentials. Each provider is an atomic
/// file so independent CLI and GUI refreshes cannot overwrite other providers.
public struct AIUsageSnapshotCache: Sendable {
    public static let freshness: TimeInterval = 300
    private let directory: URL
    private static let maximumBytes = 262_144

    private struct Entry: Codable {
        let version: Int
        let snapshot: AIUsageSnapshot
        let refreshFailed: Bool?
    }

    public init(directory: URL) {
        self.directory = directory
    }

    public static var persistent: Self {
        Self(directory: ConfigPaths().cacheDir.appendingPathComponent("ai-usage", isDirectory: true))
    }

    public func load(providerID: String, now: Date = Date()) -> AIUsageSnapshot? {
        loadEntry(providerID: providerID, now: now)?.snapshot
    }

    public func lastRefreshFailed(providerID: String) -> Bool {
        loadEntry(providerID: providerID, now: Date())?.refreshFailed == true
    }

    public func markRefreshFailed(providerID: String) {
        guard let snapshot = load(providerID: providerID) else { return }
        try? save(snapshot, refreshFailed: true)
    }

    private func loadEntry(providerID: String, now: Date) -> Entry? {
        guard let file = fileURL(providerID),
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumBytes,
              let data = try? Data(contentsOf: file),
              data.count <= Self.maximumBytes,
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.version == 1, entry.snapshot.providerID == providerID,
              entry.snapshot.fetchedAt <= now.addingTimeInterval(60),
              Self.isValid(entry.snapshot)
        else { return nil }
        return entry
    }

    public func save(_ snapshot: AIUsageSnapshot, refreshFailed: Bool = false) throws {
        guard let file = fileURL(snapshot.providerID), Self.isValid(snapshot) else {
            throw AIUsageError.unavailable
        }
        let data = try JSONEncoder().encode(Entry(version: 1, snapshot: sanitized(snapshot), refreshFailed: refreshFailed))
        guard data.count <= Self.maximumBytes else { throw AIUsageError.unavailable }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
           attributes[.type] as? FileAttributeType != .typeDirectory {
            throw AIUsageError.unavailable
        }
        try StateFilePermissions.ensureDirectory(directory)
        // A cache must not redirect writes outside its private directory.
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw AIUsageError.unavailable }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public func remove(providerID: String) {
        guard let file = fileURL(providerID) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    public static func isFresh(_ snapshot: AIUsageSnapshot, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(snapshot.fetchedAt)
        return age >= 0 && age < freshness
    }

    private func fileURL(_ providerID: String) -> URL? {
        guard !providerID.isEmpty, providerID.utf8.count <= 128,
              providerID.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 })
        else { return nil }
        return directory.appendingPathComponent(providerID + ".json")
    }

    private static func isValid(_ snapshot: AIUsageSnapshot) -> Bool {
        func finite(_ value: Decimal?) -> Bool {
            value.map { NSDecimalNumber(decimal: $0).doubleValue.isFinite } ?? true
        }
        return snapshot.fetchedAt.timeIntervalSince1970.isFinite
            && finite(snapshot.balance) && snapshot.meters.count <= 256
            && snapshot.meters.allSatisfy {
                finite($0.used) && finite($0.limit)
                    && ($0.resetsAt?.timeIntervalSince1970.isFinite ?? true)
            }
    }

    private func sanitized(_ snapshot: AIUsageSnapshot) -> AIUsageSnapshot {
        AIUsageSnapshot(
            providerID: snapshot.providerID,
            meters: snapshot.meters.map { meter in
                let unit: AIUsageUnit
                if case .currency(let code) = meter.unit {
                    unit = .currency(SecretRedactor.redact(code))
                } else {
                    unit = meter.unit
                }
                return AIUsageMeter(label: SecretRedactor.redact(meter.label), used: meter.used,
                                    limit: meter.limit, unit: unit, resetsAt: meter.resetsAt)
            },
            balance: snapshot.balance,
            currency: snapshot.currency.map(SecretRedactor.redact),
            fetchedAt: snapshot.fetchedAt,
            source: SecretRedactor.redact(snapshot.source)
        )
    }
}
