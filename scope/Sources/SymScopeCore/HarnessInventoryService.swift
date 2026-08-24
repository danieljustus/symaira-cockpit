import Foundation

/// One global or project-local harness config, as reported by
/// `symbrain harness list --output json`. Mirrors symbrain's
/// `internal/harness.ConfigInventory` (schema_version 1).
public struct HarnessConfigInventory: Codable, Equatable, Sendable {
    public let path: String
    public let exists: Bool
    public let parsed: Bool
    public let error: String?
    public let servers: [String]
}

/// One harness (e.g. "claude", "cursor", "codex") as reported by symbrain.
/// Mirrors `internal/harness.HarnessInventory`.
public struct HarnessInventoryEntry: Codable, Equatable, Sendable {
    public let name: String
    public let displayName: String
    public let global: HarnessConfigInventory
    public let project: HarnessConfigInventory?

    enum CodingKeys: String, CodingKey {
        case name
        case displayName = "display_name"
        case global
        case project
    }
}

/// The full inventory returned by `symbrain harness list --output json`.
/// Mirrors `internal/harness.Inventory`.
public struct HarnessInventory: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let projectDir: String?
    public let harnesses: [HarnessInventoryEntry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case projectDir = "project_dir"
        case harnesses
    }
}

/// symbrain's harness inventory is the SSOT for which AI harnesses exist and
/// where their configs live (issue #19, symaira-brain#275). Cockpit's own
/// `MCPDiscovery` client list is kept only as a standalone fallback.
public protocol HarnessInventoryProviding: Sendable {
    /// Whether `symbrain` is installed and callable on PATH.
    var isAvailable: Bool { get }
    /// Fetch the inventory, or `nil` on any failure (absent, timeout,
    /// non-zero exit, malformed JSON).
    func list(projectDir: String?) -> HarnessInventory?
}

/// Production `symbrain` subprocess wrapper. Standalone-first: absence of
/// `symbrain` is never an error, only a signal to use the built-in fallback.
public final class SymBrainHarnessService: HarnessInventoryProviding, @unchecked Sendable {
    public init() {}

    public var isAvailable: Bool {
        resolveSymbrain() != nil
    }

    public func list(projectDir: String?) -> HarnessInventory? {
        guard let path = resolveSymbrain() else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        var arguments = ["harness", "list", "--output", "json"]
        if let projectDir {
            arguments += ["--project", projectDir]
        }
        task.arguments = arguments
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        // Bounded wait — a wedged symbrain must not block MCP discovery.
        let deadline = DispatchTime.now() + .seconds(3)
        while task.isRunning && DispatchTime.now() < deadline {
            usleep(10_000) // 10ms
        }
        if task.isRunning {
            task.terminate()
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return try? JSONDecoder().decode(HarnessInventory.self, from: data)
    }

    private func resolveSymbrain() -> String? {
        if let bin = ProcessInfo.processInfo.environment["SYMAIRA_BIN"] {
            let candidate = "\(bin)/symbrain"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            let managed = "\(home)/.symaira/bin/symbrain"
            if FileManager.default.isExecutableFile(atPath: managed) {
                return managed
            }
        }
        return Self.lookPath("symbrain")
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
