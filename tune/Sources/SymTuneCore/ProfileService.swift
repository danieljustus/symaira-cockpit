import Foundation

/// A named tuning profile containing brightness, dim, and warmth settings.
/// Persisted as JSON under the data directory.
public struct TuneProfile: Codable, Sendable, Identifiable, Hashable {
    public let name: String
    public var brightness: Double?
    public var dim: Double?
    public var warmth: Double?
    public var version: String?
    public let createdAt: Date
    public var updatedAt: Date

    public var id: String { name }

    public init(
        name: String,
        brightness: Double? = nil,
        dim: Double? = nil,
        warmth: Double? = nil,
        version: String? = TuneVersion.current,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) throws {
        guard TuneProfile.isValidProfileName(name) else {
            throw TuneError.usage("Invalid profile name: '\(name)'. Profile names may only contain letters, digits, hyphens, and underscores.")
        }
        self.name = name
        self.brightness = brightness
        self.dim = dim
        self.warmth = warmth
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Validates a profile name: rejects `/`, `..`, null bytes, and characters outside `[a-zA-Z0-9_-]`.
    public static func isValidProfileName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        guard !name.contains("/") && !name.contains("..") && !name.contains("\0") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// A rule that maps a condition to a profile name.
public struct TuneRule: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let condition: Condition
    public let profileName: String
    public let enabled: Bool

    public enum Condition: String, Codable, Sendable {
        case onBattery
        case onAC
        case thermalSerious
        case thermalCritical
    }

    public init(id: String = UUID().uuidString, condition: Condition, profileName: String, enabled: Bool = true) {
        self.id = id
        self.condition = condition
        self.profileName = profileName
        self.enabled = enabled
    }
}

/// Manages named tuning profiles and simple rules, persisted under the data directory.
public final class ProfileService: @unchecked Sendable {
    private let dataDir: URL

    public init(dataDir: URL) {
        self.dataDir = dataDir
        try? StateFilePermissions.ensureDirectory(dataDir)
    }

    private func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private func makeDecoder() -> JSONDecoder { JSONDecoder() }

    // MARK: - Profiles

    public func saveProfile(_ profile: TuneProfile) throws {
        guard TuneProfile.isValidProfileName(profile.name) else {
            throw TuneError.usage("Invalid profile name: '\(profile.name)'.")
        }
        let file = dataDir.appendingPathComponent("profile-\(profile.name).json")
        let data = try makeEncoder().encode(profile)
        try data.write(to: file, options: .atomic)
        StateFilePermissions.applyFilePermissions(at: file)
    }

    public func loadProfile(name: String) throws -> TuneProfile {
        guard TuneProfile.isValidProfileName(name) else {
            throw TuneError.usage("Invalid profile name: '\(name)'.")
        }
        let file = dataDir.appendingPathComponent("profile-\(name).json")
        let data = try Data(contentsOf: file)
        return try makeDecoder().decode(TuneProfile.self, from: data)
    }

    public func listProfiles() -> [TuneProfile] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.lastPathComponent.hasPrefix("profile-") && $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? makeDecoder().decode(TuneProfile.self, from: $0) }
            .sorted { $0.name < $1.name }
    }

    public func deleteProfile(name: String) throws {
        guard TuneProfile.isValidProfileName(name) else {
            throw TuneError.usage("Invalid profile name: '\(name)'.")
        }
        let file = dataDir.appendingPathComponent("profile-\(name).json")
        if fm.fileExists(atPath: file.path) {
            try fm.removeItem(at: file)
        }
    }

    private var fm: FileManager { .default }

    // MARK: - Rules

    public func saveRules(_ rules: [TuneRule]) throws {
        let file = dataDir.appendingPathComponent("rules.json")
        let data = try makeEncoder().encode(rules)
        try data.write(to: file, options: .atomic)
        StateFilePermissions.applyFilePermissions(at: file)
    }

    public func loadRules() -> [TuneRule] {
        let file = dataDir.appendingPathComponent("rules.json")
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? makeDecoder().decode([TuneRule].self, from: data)) ?? []
    }

    public func addRule(_ rule: TuneRule) throws {
        var rules = loadRules()
        rules.removeAll { $0.id == rule.id }
        rules.append(rule)
        try saveRules(rules)
    }

    public func removeRule(id: String) throws {
        var rules = loadRules()
        rules.removeAll { $0.id == id }
        try saveRules(rules)
    }
}
