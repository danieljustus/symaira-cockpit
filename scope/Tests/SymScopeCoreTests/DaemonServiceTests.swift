import XCTest
@testable import SymScopeCore

private struct FixtureCommandRunner: DaemonCommandRunning {
    let outputs: [String: String]

    func run(executable: String, arguments: [String]) throws -> String {
        let key = ([executable] + arguments).joined(separator: " ")
        guard let output = outputs[key] else {
            throw DaemonCommandError.nonZero(127)
        }
        return output
    }
}

private struct FixtureFileSystem: DaemonFileSystemReading {
    let directories: [String: [String]]
    let files: [String: Data]
    let executables: Set<String>

    func directoryContents(atPath path: String) -> [String] {
        directories[path] ?? []
    }

    func data(atPath path: String) -> Data? {
        files[path]
    }

    func isExecutableFile(atPath path: String) -> Bool {
        executables.contains(path)
    }
}

final class DaemonParserTests: XCTestCase {
    func testParseLaunchctlList() {
        let output = """
        PID\tStatus\tLabel
        123\t0\tcom.example.worker
        -\t7\tcom.example.failed
        -\t0\tcom.apple.WindowServer
        """

        let records = DaemonService.parseLaunchctlList(output, domain: "user")

        XCTAssertEqual(records, [
            LaunchctlRecord(label: "com.example.worker", pid: 123, lastExitStatus: 0, domain: "user"),
            LaunchctlRecord(label: "com.example.failed", pid: nil, lastExitStatus: 7, domain: "user"),
            LaunchctlRecord(label: "com.apple.WindowServer", pid: nil, lastExitStatus: 0, domain: "user"),
        ])
    }

    func testParseBrewServices() {
        let output = """
        Name              Status  User  File
        redis             started daniel ~/Library/LaunchAgents/homebrew.mxcl.redis.plist
        postgresql@16     stopped daniel ~/Library/LaunchAgents/homebrew.mxcl.postgresql@16.plist
        """

        let records = DaemonService.parseBrewServices(output)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].name, "redis")
        XCTAssertEqual(records[0].status, "started")
        XCTAssertEqual(records[0].label, "homebrew.mxcl.redis")
        XCTAssertEqual(records[1].label, "homebrew.mxcl.postgresql@16")
    }

    func testMalformedPlistDegradesToNil() {
        XCTAssertNil(
            DaemonService.parsePlist(
                Data("not a plist".utf8),
                path: "/fixture/home/Library/LaunchAgents/broken.plist",
                domain: "user"
            )
        )
    }

    func testListMergesSourcesFiltersAppleSortsFailuresAndLinksPorts() async {
        let home = "/fixture/home"
        let userAgents = "\(home)/Library/LaunchAgents"
        let redisPath = "\(userAgents)/homebrew.mxcl.redis.plist"
        let brokenPath = "\(userAgents)/broken.plist"
        let runner = FixtureCommandRunner(outputs: [
            "/bin/launchctl list": """
            PID Status Label
            55 0 homebrew.mxcl.redis
            - 7 com.example.failed
            99 0 com.apple.WindowServer
            """,
            "/bin/launchctl list system": "",
            "/opt/homebrew/bin/brew services list": """
            Name Status User File
            redis started daniel ~/Library/LaunchAgents/homebrew.mxcl.redis.plist
            """,
        ])
        let fileSystem = FixtureFileSystem(
            directories: [
                userAgents: ["homebrew.mxcl.redis.plist", "broken.plist"],
                "/Library/LaunchAgents": [],
                "/Library/LaunchDaemons": [],
            ],
            files: [
                redisPath: Self.plistData([
                    "Label": "homebrew.mxcl.redis",
                    "ProgramArguments": ["/opt/homebrew/bin/redis-server", "--port", "6379"],
                    "KeepAlive": true,
                    "RunAtLoad": true,
                ]),
                brokenPath: Data("broken".utf8),
            ],
            executables: ["/opt/homebrew/bin/brew"]
        )
        let service = DaemonService(
            commandRunner: runner,
            fileSystem: fileSystem,
            portProvider: {
                [Port(port: 6379, protocol_: "tcp", address: "127.0.0.1", pid: 55, process: "redis-server")]
            },
            homeDirectory: home
        )

        let (rows, notes) = await service.list()

        XCTAssertEqual(rows.map(\.label), ["com.example.failed", "homebrew.mxcl.redis"])
        XCTAssertEqual(rows[0].lastExitStatus, 7)
        XCTAssertEqual(rows[1].origin, "brew")
        XCTAssertEqual(rows[1].state, "running")
        XCTAssertEqual(rows[1].keepAlive, true)
        XCTAssertEqual(rows[1].runAtLoad, true)
        XCTAssertEqual(rows[1].ports, [6379])
        XCTAssertTrue(rows[1].notes.contains { $0.contains("program: /opt/homebrew/bin/redis-server --port 6379") })
        XCTAssertTrue(notes.contains { $0.contains("plist malformed") })
        XCTAssertFalse(rows.contains { $0.label.hasPrefix("com.apple.") })

        let (allRows, _) = await service.list(all: true)
        XCTAssertTrue(allRows.contains { $0.label == "com.apple.WindowServer" })

        let health = DaemonService.health(rows)
        XCTAssertFalse(health[0].healthy)
        XCTAssertTrue(health[1].healthy)
    }

    func testMissingHomebrewIsOnlyANote() async {
        let runner = FixtureCommandRunner(outputs: [
            "/bin/launchctl list": "PID Status Label\n- 0 com.example.worker\n",
            "/bin/launchctl list system": "",
        ])
        let fileSystem = FixtureFileSystem(directories: [:], files: [:], executables: [])
        let service = DaemonService(
            commandRunner: runner,
            fileSystem: fileSystem,
            portProvider: { [] },
            homeDirectory: "/fixture/home"
        )

        let (rows, notes) = await service.list()

        XCTAssertEqual(rows.map(\.label), ["com.example.worker"])
        XCTAssertTrue(notes.contains { $0.contains("brew CLI not found") })
    }

    func testConflictsIncludeLaunchdLabelForKnownPID() {
        let ports = [
            Port(port: 8080, protocol_: "tcp", address: "127.0.0.1", pid: 42, process: "worker"),
            Port(port: 8080, protocol_: "tcp", address: "0.0.0.0", pid: 43, process: "other"),
        ]
        let daemons = [Daemon(label: "com.example.worker", state: "running", pid: 42, domain: "user")]

        let conflicts = ConflictDetector.detect(ports, daemons: daemons)

        XCTAssertTrue(conflicts[0].holders.contains { $0.contains("com.example.worker") })
    }

    private static func plistData(_ values: [String: Any]) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)) ?? Data()
    }
}
