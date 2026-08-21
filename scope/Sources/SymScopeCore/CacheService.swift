import Foundation

/// Snapshot cache on the XDG cache path (~/Library/Caches/symscope on macOS).
/// Mirrors the Go original's internal/cache: one JSON file holding the last
/// snapshot, with stats and clear.
public enum CacheService: Sendable {
    public static let cacheDir = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/Caches/symscope"
    public static let cacheFile = "\(cacheDir)/snapshot.json"

    public struct Stats: Codable, Equatable, Sendable {
        public var path: String
        public var exists: Bool
        public var sizeBytes: Int64
        public var modifiedAt: String?

        public init(path: String, exists: Bool, sizeBytes: Int64, modifiedAt: String?) {
            self.path = path
            self.exists = exists
            self.sizeBytes = sizeBytes
            self.modifiedAt = modifiedAt
        }
    }

    public static func stats() -> Stats {
        let fm = FileManager.default
        var modified: String?
        var size: Int64 = 0
        if let attrs = try? fm.attributesOfItem(atPath: cacheFile),
           let fileSize = attrs[.size] as? Int64 {
            size = fileSize
        }
        if let modDate = try? fm.attributesOfItem(atPath: cacheFile)[.modificationDate] as? Date {
            modified = ISO8601DateFormatter().string(from: modDate)
        }
        return Stats(path: cacheFile, exists: fm.fileExists(atPath: cacheFile), sizeBytes: size, modifiedAt: modified)
    }

    /// Loads the cached snapshot, if present.
    public static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cacheFile)) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// Stores a snapshot. Returns nil on success, or the error.
    public static func save(_ snapshot: Snapshot) -> String? {
        do {
            try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: URL(fileURLWithPath: cacheFile), options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public static func clear() -> String? {
        do {
            if FileManager.default.fileExists(atPath: cacheFile) {
                try FileManager.default.removeItem(atPath: cacheFile)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
