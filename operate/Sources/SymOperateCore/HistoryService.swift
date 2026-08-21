import Foundation

public final class HistoryService: HistoryServiceProtocol, Sendable {
    private let fileURL: URL
    private let maxEvents = 1000

    public init(fileURL: URL? = nil) {
        if let fileURL = fileURL {
            self.fileURL = fileURL
        } else {
            let localShare = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/symoperate")
            HistoryService.secureDirectory(at: localShare)
            self.fileURL = localShare.appendingPathComponent("history.jsonl")
        }
        secureFile()
    }

    /// Creates `~/.local/share/symoperate` with 0700 permissions (or hardens an
    /// existing directory), so other local users cannot read the operation log.
    static func secureDirectory(at url: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Ensures the history file exists with 0600 permissions. Never clobbers the
    /// content of an existing file; it only adjusts permissions.
    private func secureFile() {
        let fileManager = FileManager.default
        let path = fileURL.path
        if fileManager.fileExists(atPath: path) {
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } else {
            fileManager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
    }

    public func record(_ event: HistoryEvent) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(event)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            return
        }

        let line = jsonString + "\n"
        if let fileHandle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? fileHandle.close() }
            if #available(macOS 10.15.4, *) {
                try fileHandle.seekToEnd()
                try fileHandle.write(contentsOf: Data(line.utf8))
            } else {
                fileHandle.seekToEndOfFile()
                fileHandle.write(Data(line.utf8))
            }
        } else {
            try line.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        try trimToMaxEvents()
        secureFile()
    }

    /// Enforces the event cap on write: if the file holds more than `maxEvents`
    /// lines, rewrites it keeping only the newest `maxEvents` lines. The newest
    /// event is always present and order is preserved.
    private func trimToMaxEvents() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = contents.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count > maxEvents else {
            return
        }

        let trimmed = lines.suffix(maxEvents).joined(separator: "\n") + "\n"
        try trimmed.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    public func events() throws -> [HistoryEvent] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = contents.components(separatedBy: .newlines).filter { !$0.isEmpty }

        let decoder = JSONDecoder()
        var results: [HistoryEvent] = []
        for line in lines {
            if let data = line.data(using: .utf8),
               let event = try? decoder.decode(HistoryEvent.self, from: data) {
                results.append(event)
            }
        }

        if results.count > maxEvents {
            return Array(results.suffix(maxEvents))
        }
        return results
    }
}
