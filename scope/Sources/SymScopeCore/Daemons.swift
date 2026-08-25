import Foundation

/// A read-only snapshot of one launchd agent/daemon or Homebrew service.
public struct Daemon: Codable, Equatable, Sendable {
    public var label: String
    public var state: String // running | loading | not-loaded
    public var pid: Int?
    public var lastExitStatus: Int?
    public var domain: String // user | system
    public var origin: String // brew | manual | unknown
    public var keepAlive: Bool?
    public var runAtLoad: Bool?
    public var ports: [Int]
    public var notes: [String]

    public init(
        label: String,
        state: String,
        pid: Int? = nil,
        lastExitStatus: Int? = nil,
        domain: String,
        origin: String = "unknown",
        keepAlive: Bool? = nil,
        runAtLoad: Bool? = nil,
        ports: [Int] = [],
        notes: [String] = []
    ) {
        self.label = label
        self.state = state
        self.pid = pid
        self.lastExitStatus = lastExitStatus
        self.domain = domain
        self.origin = origin
        self.keepAlive = keepAlive
        self.runAtLoad = runAtLoad
        self.ports = ports.sorted()
        self.notes = notes
    }

    public enum CodingKeys: String, CodingKey {
        case label
        case state
        case pid
        case lastExitStatus = "last_exit_status"
        case domain
        case origin
        case keepAlive = "keep_alive"
        case runAtLoad = "run_at_load"
        case ports
        case notes
    }
}

/// The compact result returned by `scope daemons health`.
public struct DaemonHealthResult: Codable, Equatable, Sendable {
    public var label: String
    public var state: String
    public var healthy: Bool
    public var lastExitStatus: Int?
    public var notes: [String]

    public init(label: String, state: String, healthy: Bool, lastExitStatus: Int?, notes: [String] = []) {
        self.label = label
        self.state = state
        self.healthy = healthy
        self.lastExitStatus = lastExitStatus
        self.notes = notes
    }

    public enum CodingKeys: String, CodingKey {
        case label
        case state
        case healthy
        case lastExitStatus = "last_exit_status"
        case notes
    }
}

public struct LaunchctlRecord: Equatable, Sendable {
    public var label: String
    public var pid: Int?
    public var lastExitStatus: Int?
    public var domain: String

    public init(label: String, pid: Int?, lastExitStatus: Int?, domain: String) {
        self.label = label
        self.pid = pid
        self.lastExitStatus = lastExitStatus
        self.domain = domain
    }
}

public struct BrewServiceRecord: Equatable, Sendable {
    public var name: String
    public var status: String
    public var user: String
    public var file: String?
    public var label: String

    public init(name: String, status: String, user: String, file: String?, label: String) {
        self.name = name
        self.status = status
        self.user = user
        self.file = file
        self.label = label
    }
}

public struct PlistRecord: Equatable, Sendable {
    public var label: String
    public var domain: String
    public var origin: String
    public var keepAlive: Bool?
    public var runAtLoad: Bool?
    public var notes: [String]

    public init(
        label: String,
        domain: String,
        origin: String,
        keepAlive: Bool?,
        runAtLoad: Bool?,
        notes: [String] = []
    ) {
        self.label = label
        self.domain = domain
        self.origin = origin
        self.keepAlive = keepAlive
        self.runAtLoad = runAtLoad
        self.notes = notes
    }
}

public protocol DaemonCommandRunning: Sendable {
    func run(executable: String, arguments: [String]) throws -> String
}

public struct LocalDaemonCommandRunner: DaemonCommandRunning, Sendable {
    public init() {}

    public func run(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DaemonCommandError.nonZero(process.terminationStatus)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

public protocol DaemonFileSystemReading: Sendable {
    func directoryContents(atPath path: String) -> [String]
    func data(atPath path: String) -> Data?
    func isExecutableFile(atPath path: String) -> Bool
}

public struct LocalDaemonFileSystem: DaemonFileSystemReading, Sendable {
    public init() {}

    public func directoryContents(atPath path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    public func data(atPath path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    public func isExecutableFile(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

public enum DaemonCommandError: Error, LocalizedError, Sendable {
    case nonZero(Int32)

    public var errorDescription: String? {
        switch self {
        case .nonZero(let status): return "command exited with status \(status)"
        }
    }
}

/// Read-only launchd/Homebrew inventory. All process and filesystem access is
/// injected, making parser and merge tests deterministic and safe in CI.
public struct DaemonService: Sendable {
    public let commandRunner: any DaemonCommandRunning
    public let fileSystem: any DaemonFileSystemReading
    public let portProvider: @Sendable () async throws -> [Port]
    public let homeDirectory: String

    public init(
        commandRunner: any DaemonCommandRunning = LocalDaemonCommandRunner(),
        fileSystem: any DaemonFileSystemReading = LocalDaemonFileSystem(),
        portProvider: @escaping @Sendable () async throws -> [Port] = { try await PortService.listListening() },
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.commandRunner = commandRunner
        self.fileSystem = fileSystem
        self.portProvider = portProvider
        self.homeDirectory = homeDirectory
    }

    public static func list(all: Bool = false) async -> ([Daemon], [String]) {
        await DaemonService().list(all: all)
    }

    public func list(all: Bool = false) async -> ([Daemon], [String]) {
        var notes: [String] = []
        var launchctlRecords: [LaunchctlRecord] = []

        for (domain, arguments) in [("user", ["list"]), ("system", ["list", "system"])] {
            do {
                let output = try commandRunner.run(executable: "/bin/launchctl", arguments: arguments)
                launchctlRecords += Self.parseLaunchctlList(output, domain: domain)
            } catch {
                notes.append("launchctl \(domain) unavailable: \(error.localizedDescription)")
            }
        }

        var rows = launchctlRecords.map { record in
            Daemon(
                label: record.label,
                state: record.pid == nil ? "loading" : "running",
                pid: record.pid,
                lastExitStatus: record.lastExitStatus,
                domain: record.domain
            )
        }

        for directory in Self.plistDirectories(home: homeDirectory) {
            let domain = directory.hasSuffix("LaunchDaemons") ? "system" : "user"
            for filename in fileSystem.directoryContents(atPath: directory) where filename.hasSuffix(".plist") {
                let path = (directory as NSString).appendingPathComponent(filename)
                guard let data = fileSystem.data(atPath: path) else {
                    notes.append("plist unreadable: \(path)")
                    continue
                }
                guard let plist = Self.parsePlist(data, path: path, domain: domain) else {
                    notes.append("plist malformed: \(path)")
                    continue
                }
                if let index = rows.firstIndex(where: { $0.label == plist.label && $0.domain == plist.domain }) {
                    rows[index].keepAlive = plist.keepAlive
                    rows[index].runAtLoad = plist.runAtLoad
                    rows[index].notes = Self.mergeNotes(rows[index].notes, plist.notes)
                    rows[index].origin = Self.preferredOrigin(rows[index].origin, plist.origin)
                } else {
                    rows.append(
                        Daemon(
                            label: plist.label,
                            state: "not-loaded",
                            domain: plist.domain,
                            origin: plist.origin,
                            keepAlive: plist.keepAlive,
                            runAtLoad: plist.runAtLoad,
                            notes: plist.notes
                        )
                    )
                }
            }
        }

        let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        guard let brew = brewPaths.first(where: { fileSystem.isExecutableFile(atPath: $0) }) else {
            notes.append("homebrew: brew CLI not found; service inventory unavailable")
            return Self.finalize(rows, all: all, ports: await loadPorts(notes: &notes), notes: notes)
        }

        do {
            let output = try commandRunner.run(executable: brew, arguments: ["services", "list"])
            for service in Self.parseBrewServices(output) {
                let candidates = [service.label, service.name, "homebrew.mxcl.\(service.name)"]
                if let index = rows.firstIndex(where: { candidates.contains($0.label) }) {
                    rows[index].origin = "brew"
                    rows[index].notes = Self.mergeNotes(rows[index].notes, service.status == "started" ? [] : ["homebrew status: \(service.status)"])
                    if rows[index].state == "not-loaded", service.status == "started" {
                        rows[index].state = "loading"
                    }
                } else {
                    let state = service.status == "started" ? "loading" : "not-loaded"
                    rows.append(
                        Daemon(
                            label: service.label,
                            state: state,
                            domain: "user",
                            origin: "brew",
                            notes: service.status == "started" ? [] : ["homebrew status: \(service.status)"]
                        )
                    )
                }
            }
        } catch {
            notes.append("homebrew: brew services unavailable: \(error.localizedDescription)")
        }

        return Self.finalize(rows, all: all, ports: await loadPorts(notes: &notes), notes: notes)
    }

    public static func health(_ daemons: [Daemon]) -> [DaemonHealthResult] {
        daemons.map { daemon in
            let healthy = daemon.state != "not-loaded" && (daemon.lastExitStatus ?? 0) == 0
            return DaemonHealthResult(
                label: daemon.label,
                state: daemon.state,
                healthy: healthy,
                lastExitStatus: daemon.lastExitStatus,
                notes: daemon.notes
            )
        }
    }

    /// Parses the tabular output from `launchctl list`.
    public static func parseLaunchctlList(_ output: String, domain: String) -> [LaunchctlRecord] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let fields = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 3, fields[0].lowercased() != "pid" else { return nil }
            guard !fields[2].isEmpty else { return nil }
            let pid = fields[0] == "-" ? nil : Int(fields[0])
            let status = fields[1] == "-" ? nil : Int(fields[1])
            return LaunchctlRecord(label: fields[2], pid: pid, lastExitStatus: status, domain: domain)
        }
    }

    /// Parses `brew services list` output: Name, Status, User, File.
    public static func parseBrewServices(_ output: String) -> [BrewServiceRecord] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let fields = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2, fields[0].lowercased() != "name" else { return nil }
            let name = fields[0]
            let status = fields[1]
            let user = fields.count > 2 ? fields[2] : ""
            let file = fields.count > 3 ? fields.dropFirst(3).joined(separator: " ") : nil
            let label = file.flatMap(Self.plistLabel(from:)) ?? "homebrew.mxcl.\(name)"
            return BrewServiceRecord(name: name, status: status, user: user, file: file, label: label)
        }
    }

    /// Parses one launchd plist. Invalid or non-dictionary property lists return nil.
    public static func parsePlist(_ data: Data, path: String, domain: String) -> PlistRecord? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        let fallback = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let rawLabel = (dictionary["Label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = if let rawLabel, !rawLabel.isEmpty { rawLabel } else { fallback }
        guard !label.isEmpty else { return nil }
        let keepAlive = plistBool(dictionary["KeepAlive"])
        let runAtLoad = plistBool(dictionary["RunAtLoad"])
        let origin = label.hasPrefix("homebrew.mxcl.") || path.contains("homebrew.mxcl.") ? "brew" : "manual"
        let programNotes = (dictionary["ProgramArguments"] as? [String])?.isEmpty == false
            ? ["program: \((dictionary["ProgramArguments"] as? [String] ?? []).joined(separator: " "))"]
            : []
        return PlistRecord(
            label: label,
            domain: domain,
            origin: origin,
            keepAlive: keepAlive,
            runAtLoad: runAtLoad,
            notes: programNotes
        )
    }

    public static func annotatePorts(_ daemons: [Daemon], ports: [Port]) -> [Daemon] {
        daemons.map { daemon in
            var copy = daemon
            if let pid = daemon.pid {
                copy.ports = ports.filter { $0.pid == pid }.map(\.port).sorted()
            }
            return copy
        }
    }

    public static func plistDirectories(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        [
            (home as NSString).appendingPathComponent("Library/LaunchAgents"),
            "/Library/LaunchAgents",
            "/Library/LaunchDaemons",
        ]
    }

    private func loadPorts(notes: inout [String]) async -> [Port] {
        do {
            return try await portProvider()
        } catch {
            notes.append("ports: \(error.localizedDescription)")
            return []
        }
    }

    private static func finalize(
        _ rows: [Daemon],
        all: Bool,
        ports: [Port],
        notes: [String]
    ) -> ([Daemon], [String]) {
        let filtered = all ? rows : rows.filter { !$0.label.hasPrefix("com.apple.") }
        let annotated = annotatePorts(filtered, ports: ports)
        let sorted = annotated.sorted {
            let lhsFailed = ($0.lastExitStatus ?? 0) != 0
            let rhsFailed = ($1.lastExitStatus ?? 0) != 0
            if lhsFailed != rhsFailed { return lhsFailed && !rhsFailed }
            if $0.domain != $1.domain { return $0.domain < $1.domain }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
        return (sorted, notes)
    }

    private static func plistBool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if value is [String: Any] { return true }
        return nil
    }

    private static func plistLabel(from file: String) -> String? {
        let name = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func preferredOrigin(_ current: String, _ candidate: String) -> String {
        if candidate == "brew" || current == "brew" { return "brew" }
        if candidate == "manual" || current == "manual" { return "manual" }
        return current
    }

    private static func mergeNotes(_ current: [String], _ additions: [String]) -> [String] {
        current + additions.filter { !current.contains($0) }
    }
}
