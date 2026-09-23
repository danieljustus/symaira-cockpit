import Darwin
import Foundation
import XCTest
@testable import SymCockpitHistory

final class CanonicalHistoryStoreTests: XCTestCase {
    private struct WorkerProcess {
        let process: Process
        let output: Pipe
    }

    private var temporaryDirectoryURL: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("symcockpit-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        fileURL = temporaryDirectoryURL.appendingPathComponent("history.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        try super.tearDownWithError()
    }

    func testFixtureRoundTripsTuneAndTuneRecords() throws {
        let fixture = Bundle.module.url(forResource: "cross-component", withExtension: "jsonl", subdirectory: "Fixtures")!
        try FileManager.default.copyItem(at: fixture, to: fileURL)

        let records = try CanonicalHistoryStore(fileURL: fileURL).read(limit: nil)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].source, "tune")
        XCTAssertEqual(records[0].action, "brightness.set")
        XCTAssertEqual(records[1].source, "tune")
        XCTAssertEqual(records[1].action, "click")
        XCTAssertEqual(records[1].payload["targets"], .object(["button": .string("left")]))
    }

    func testMalformedAndLegacyLinesAreTolerated() throws {
        let legacy = #"{"action":"dim.set","result":"success","timestamp":"2026-08-28T10:00:02Z"}"#
        let content = "not-json\n{\"schema_version\":999}\n\(legacy)\n{\"action\":\"missing timestamp\"}\n"
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let records = try CanonicalHistoryStore(fileURL: fileURL).read(limit: nil)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].source, "legacy")
        XCTAssertEqual(records[0].action, "dim.set")
    }

    func testWriterIsDeterministicVersionedAndRedactsPayload() throws {
        let event = CanonicalHistoryEvent(
            source: "tune",
            timestamp: "2026-08-28T10:00:00Z",
            action: "type_text",
            payload: [
                "message": .string("token=sk-abcdEFGH12345678ijkl"),
                "success": .bool(true),
            ]
        )
        let store = CanonicalHistoryStore(fileURL: fileURL)
        try store.append(event)

        let line = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(line.contains("\"schema_version\":1"))
        XCTAssertTrue(line.contains("<redacted>"))
        XCTAssertFalse(line.contains("sk-abcdEFGH12345678ijkl"))
        XCTAssertEqual(try store.read(limit: nil).first?.payload["message"], .string("token=<redacted>"))
    }

    func testAppendDropsOnlyCorruptUnterminatedTail() throws {
        let retained = event(id: "retained")
        var contents = try encodedLine(retained)
        contents.append(0x0A)
        contents.append(contentsOf: Data(#"{"schema_version":1,"payload":{"id":"partial""#.utf8))
        try contents.write(to: fileURL)

        let store = CanonicalHistoryStore(fileURL: fileURL)
        try store.append(event(id: "appended"))

        XCTAssertEqual(try ids(in: store), ["retained", "appended"])
        let persisted = try Data(contentsOf: fileURL)
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains("partial"))
        try assertEveryLineIsValidJSON(at: fileURL, expectedCount: 2)
    }

    func testAppendPreservesCompleteUnterminatedRecord() throws {
        try encodedLine(event(id: "unterminated")).write(to: fileURL)

        let store = CanonicalHistoryStore(fileURL: fileURL)
        try store.append(event(id: "appended"))

        XCTAssertEqual(try ids(in: store), ["unterminated", "appended"])
        let persisted = try Data(contentsOf: fileURL)
        XCTAssertEqual(persisted.last, 0x0A)
        try assertEveryLineIsValidJSON(at: fileURL, expectedCount: 2)
    }

    func testRetentionKeepsHistoryAndLockFilesPrivate() throws {
        let store = CanonicalHistoryStore(fileURL: fileURL, maxEvents: 1)
        try store.append(event(id: "first"))
        try store.append(event(id: "second"))

        XCTAssertEqual(try ids(in: store), ["second"])
        try assertPermissions(0o600, at: fileURL)
        try assertPermissions(0o600, at: fileURL.appendingPathExtension("lock"))
    }

    func testIndependentProcessesSerializeTailRecoveryAppendAndRetention() throws {
        let sequentialURL = temporaryDirectoryURL.appendingPathComponent("sequential.jsonl")
        try encodedLine(event(id: "seed")).write(to: sequentialURL)
        let sequentialPrefixes = ["cli-sequential", "gui-sequential"]
        try runWorkers(prefixes: sequentialPrefixes, count: 8, maxEvents: 100, fileURL: sequentialURL, sequentially: true)
        let sequentialIDs = Set(["seed"] + expectedWorkerIDs(prefixes: sequentialPrefixes, count: 8))
        try assertHistory(at: sequentialURL, expectedIDs: sequentialIDs, allowedIDs: sequentialIDs, expectedCount: 17)

        let belowLimitURL = temporaryDirectoryURL.appendingPathComponent("below-limit.jsonl")
        var corruptTail = try encodedLine(event(id: "seed"))
        corruptTail.append(0x0A)
        corruptTail.append(contentsOf: Data(#"{"schema_version":1,"payload":{"id":"partial""#.utf8))
        try corruptTail.write(to: belowLimitURL)
        let concurrentPrefixes = ["cli-a", "gui-a", "cli-b", "gui-b"]
        try runWorkers(prefixes: concurrentPrefixes, count: 10, maxEvents: 100, fileURL: belowLimitURL, sequentially: false)
        let belowLimitIDs = Set(["seed"] + expectedWorkerIDs(prefixes: concurrentPrefixes, count: 10))
        try assertHistory(at: belowLimitURL, expectedIDs: belowLimitIDs, allowedIDs: belowLimitIDs, expectedCount: 41)

        let retainedURL = temporaryDirectoryURL.appendingPathComponent("retained.jsonl")
        let retainedPrefixes = ["cli-c", "gui-c", "cli-d", "gui-d"]
        let retainedLimit = 35
        try runWorkers(prefixes: retainedPrefixes, count: 20, maxEvents: retainedLimit, fileURL: retainedURL, sequentially: false)
        let attemptedIDs = Set(expectedWorkerIDs(prefixes: retainedPrefixes, count: 20))
        try assertHistory(at: retainedURL, expectedIDs: nil, allowedIDs: attemptedIDs, expectedCount: retainedLimit)
    }

    func testConcurrentAppendWorker() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SYMCOCKPIT_HISTORY_WORKER"] == "1" else { return }
        guard let path = environment["SYMCOCKPIT_HISTORY_FILE"],
              let prefix = environment["SYMCOCKPIT_HISTORY_PREFIX"],
              let countText = environment["SYMCOCKPIT_HISTORY_COUNT"],
              let count = Int(countText),
              let maxEventsText = environment["SYMCOCKPIT_HISTORY_MAX_EVENTS"],
              let maxEvents = Int(maxEventsText) else {
            XCTFail("worker environment is incomplete")
            return
        }

        let store = CanonicalHistoryStore(fileURL: URL(fileURLWithPath: path), maxEvents: maxEvents)
        for index in 0..<count {
            try store.append(event(id: "\(prefix)-\(index)", source: prefix.hasPrefix("cli") ? "cli" : "gui"))
        }
    }

    private func event(id: String, source: String = "tune") -> CanonicalHistoryEvent {
        CanonicalHistoryEvent(
            source: source,
            timestamp: "2026-09-23T08:00:00Z",
            action: "test.append",
            payload: ["id": .string(id)]
        )
    }

    private func encodedLine(_ event: CanonicalHistoryEvent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(event)
    }

    private func ids(in store: CanonicalHistoryStore) throws -> [String] {
        try store.read(limit: nil).compactMap { $0.payload["id"]?.stringValue }
    }

    private func expectedWorkerIDs(prefixes: [String], count: Int) -> [String] {
        prefixes.flatMap { prefix in (0..<count).map { "\(prefix)-\($0)" } }
    }

    private func runWorkers(
        prefixes: [String],
        count: Int,
        maxEvents: Int,
        fileURL: URL,
        sequentially: Bool
    ) throws {
        var running: [WorkerProcess] = []
        for prefix in prefixes {
            let worker = makeWorker(prefix: prefix, count: count, maxEvents: maxEvents, fileURL: fileURL)
            try worker.process.run()
            if sequentially {
                try waitForWorkers([worker], timeout: 20)
            } else {
                running.append(worker)
            }
        }
        if !running.isEmpty {
            try waitForWorkers(running, timeout: 30)
        }
    }

    private func makeWorker(prefix: String, count: Int, maxEvents: Int, fileURL: URL) -> WorkerProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            "SymCockpitHistoryTests.CanonicalHistoryStoreTests/testConcurrentAppendWorker",
            Bundle(for: CanonicalHistoryStoreTests.self).bundleURL.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["SYMCOCKPIT_HISTORY_WORKER"] = "1"
        environment["SYMCOCKPIT_HISTORY_FILE"] = fileURL.path
        environment["SYMCOCKPIT_HISTORY_PREFIX"] = prefix
        environment["SYMCOCKPIT_HISTORY_COUNT"] = String(count)
        environment["SYMCOCKPIT_HISTORY_MAX_EVENTS"] = String(maxEvents)
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        return WorkerProcess(process: process, output: output)
    }

    private func waitForWorkers(_ workers: [WorkerProcess], timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while workers.contains(where: { $0.process.isRunning }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        let timedOut = workers.filter { $0.process.isRunning }
        for worker in timedOut {
            worker.process.terminate()
        }
        if !timedOut.isEmpty {
            let terminationDeadline = Date().addingTimeInterval(2)
            while timedOut.contains(where: { $0.process.isRunning }), Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            for worker in timedOut where worker.process.isRunning {
                Darwin.kill(worker.process.processIdentifier, SIGKILL)
            }
        }

        for worker in workers {
            worker.process.waitUntilExit()
            let output = worker.output.fileHandleForReading.readDataToEndOfFile()
            let details = String(decoding: output, as: UTF8.self)
            XCTAssertEqual(worker.process.terminationStatus, 0, details)
        }
        if !timedOut.isEmpty {
            XCTFail("history append workers exceeded \(timeout) seconds")
        }
    }

    private func assertHistory(
        at url: URL,
        expectedIDs: Set<String>?,
        allowedIDs: Set<String>,
        expectedCount: Int
    ) throws {
        try assertEveryLineIsValidJSON(at: url, expectedCount: expectedCount)
        let records = try CanonicalHistoryStore(fileURL: url, maxEvents: expectedCount).read(limit: nil)
        let recordIDs = records.compactMap { $0.payload["id"]?.stringValue }
        XCTAssertEqual(recordIDs.count, expectedCount)
        XCTAssertEqual(Set(recordIDs).count, recordIDs.count, "every retained event ID must be unique")
        XCTAssertTrue(Set(recordIDs).isSubset(of: allowedIDs))
        if let expectedIDs {
            XCTAssertEqual(Set(recordIDs), expectedIDs)
        }
    }

    private func assertEveryLineIsValidJSON(at url: URL, expectedCount: Int) throws {
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.last, 0x0A)
        let lines = data.split(separator: 0x0A)
        XCTAssertEqual(lines.count, expectedCount)
        for line in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line)))
            XCTAssertNoThrow(try JSONDecoder().decode(CanonicalHistoryEvent.self, from: Data(line)))
        }
    }

    private func assertPermissions(_ expected: Int, at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
        XCTAssertEqual(permissions, expected)
    }
}
