import Foundation

public final class HistoryService: @unchecked Sendable {
    private let dataDir: URL
    private let lock = NSLock()
    private let maxFileSizeBytes: Int64 = 5 * 1024 * 1024 // 5 MiB

    public init(dataDir: URL) {
        self.dataDir = dataDir
        try? StateFilePermissions.ensureDirectory(dataDir)
    }

    /// Check if history directory or file is writable.
    public var isWritable: Bool {
        let file = dataDir.appendingPathComponent("history.ndjson")
        let fm = FileManager.default
        if fm.fileExists(atPath: file.path) {
            return fm.isWritableFile(atPath: file.path)
        }
        return fm.isWritableFile(atPath: dataDir.path)
    }

    public func logEvent(_ event: HistoryEvent) {
        lock.lock()
        defer { lock.unlock() }

        let file = dataDir.appendingPathComponent("history.ndjson")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase

        let data: Data
        let line: String
        do {
            data = try encoder.encode(event)
            guard let jsonStr = String(data: data, encoding: .utf8) else {
                fputs("symtune: warning: failed to write history event: utf8 encoding failed\n", stderr)
                return
            }
            line = jsonStr + "\n"
        } catch {
            fputs("symtune: warning: failed to write history event: \(error.localizedDescription)\n", stderr)
            return
        }

        do {
            try StateFilePermissions.ensureDirectory(dataDir)

            let fm = FileManager.default
            if fm.fileExists(atPath: file.path) {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } else {
                fm.createFile(atPath: file.path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600])
            }
            StateFilePermissions.applyFilePermissions(at: file)
            rotateIfNeeded(file: file)
        } catch {
            fputs("symtune: warning: failed to write history event: \(error.localizedDescription)\n", stderr)
        }
    }

    public func readEvents(limit: Int? = 100) -> [HistoryEvent] {
        lock.lock()
        defer { lock.unlock() }

        let file = dataDir.appendingPathComponent("history.ndjson")
        guard let data = try? Data(contentsOf: file),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let lines = content.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let selectedLines: [String]
        if let limit, limit > 0 {
            selectedLines = Array(lines.suffix(limit))
        } else {
            selectedLines = lines
        }

        return selectedLines.compactMap { try? decoder.decode(HistoryEvent.self, from: Data($0.utf8)) }
    }

    private func rotateIfNeeded(file: URL) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? Int64,
              size > maxFileSizeBytes,
              let data = try? Data(contentsOf: file),
              let content = String(data: data, encoding: .utf8) else {
            return
        }
        let lines = content.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // Retain the most recent 1000 events when rotating
        let tailLines = Array(lines.suffix(1000)).joined(separator: "\n") + "\n"
        try? tailLines.write(to: file, atomically: true, encoding: .utf8)
        StateFilePermissions.applyFilePermissions(at: file)
    }
}
