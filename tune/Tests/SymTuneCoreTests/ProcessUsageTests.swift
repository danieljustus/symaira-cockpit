import XCTest
@testable import SymTuneCore

/// Replays a scripted sequence of sweeps.
private final class ScriptedProcessSource: ProcessSampleSource, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [ProcessSampleSet]
    private(set) var sampleCount = 0

    init(_ sets: [ProcessSampleSet]) { self.pending = sets }

    func sample(knownNames: [Int32: String]) -> (set: ProcessSampleSet, resolvedNames: [Int32: String]) {
        lock.lock(); defer { lock.unlock() }
        sampleCount += 1
        guard !pending.isEmpty else {
            return (ProcessSampleSet(timestamp: 0, samples: [], unreadableCount: 0), [:])
        }
        let set = pending.count == 1 ? pending[0] : pending.removeFirst()
        // Report every name as freshly resolved so the caller's cache mirrors
        // the scripted sweep exactly.
        var resolved: [Int32: String] = [:]
        resolved.reserveCapacity(set.samples.count)
        for sample in set.samples { resolved[sample.pid] = sample.name }
        return (set, resolved)
    }
}

private func sample(
    _ pid: Int32,
    _ name: String,
    cpuNanoseconds: UInt64,
    memoryMB: UInt64,
    threads: Int? = 4
) -> ProcessSample {
    ProcessSample(
        pid: pid,
        name: name,
        cpuTimeNanoseconds: cpuNanoseconds,
        memoryBytes: memoryMB * 1_048_576,
        threadCount: threads
    )
}

/// Resolves a name only for a PID absent from `knownNames`, mirroring how the
/// real libproc source skips `proc_pidpath` for cached PIDs. Counting the
/// resolutions makes the service's caching observable.
///
/// Each entry in `tables` is the ground truth for one call (last repeats),
/// like repeated reads of the process table — a PID can exit and later be
/// recycled under a different name.
private final class ResolutionCountingSource: ProcessSampleSource, @unchecked Sendable {
    private let lock = NSLock()
    private var tables: [[Int32: String]]
    private(set) var resolutionCount = 0
    private var tick = 0

    init(tables: [[Int32: String]]) { self.tables = tables }

    func sample(knownNames: [Int32: String]) -> (set: ProcessSampleSet, resolvedNames: [Int32: String]) {
        lock.lock(); defer { lock.unlock() }
        guard !tables.isEmpty else {
            return (ProcessSampleSet(timestamp: Double(tick), samples: [], unreadableCount: 0), [:])
        }
        let table = tables.count == 1 ? tables[0] : tables.removeFirst()
        tick += 1
        var samples: [ProcessSample] = []
        var resolved: [Int32: String] = [:]
        for pid in table.keys.sorted() {
            let name: String
            if let known = knownNames[pid] {
                name = known
            } else {
                name = table[pid]!
                resolutionCount += 1
                resolved[pid] = name
            }
            samples.append(ProcessSample(pid: pid, name: name, cpuTimeNanoseconds: 0, memoryBytes: 0, threadCount: nil))
        }
        return (ProcessSampleSet(timestamp: Double(tick), samples: samples, unreadableCount: 0), resolved)
    }
}

final class ProcessUsageRankingTests: XCTestCase {

    func testCPUPercentIsTheRateBetweenTwoSweeps() throws {
        let first = ProcessSampleSet(
            timestamp: 100,
            samples: [sample(1, "busy", cpuNanoseconds: 0, memoryMB: 10)],
            unreadableCount: 0
        )
        // Half a second of CPU time over one second of wall clock = 50%.
        let second = ProcessSampleSet(
            timestamp: 101,
            samples: [sample(1, "busy", cpuNanoseconds: 500_000_000, memoryMB: 10)],
            unreadableCount: 0
        )

        let report = ProcessUsageRanking.report(
            current: second, previous: first, sortedBy: .cpu, limit: 5
        )

        XCTAssertEqual(try XCTUnwrap(report.processes.first?.cpuPercent), 50, accuracy: 0.001)
    }

    func testMultiCoreUsageExceedsOneHundredPercent() throws {
        let first = ProcessSampleSet(
            timestamp: 0, samples: [sample(1, "render", cpuNanoseconds: 0, memoryMB: 10)],
            unreadableCount: 0
        )
        let second = ProcessSampleSet(
            timestamp: 1, samples: [sample(1, "render", cpuNanoseconds: 3_000_000_000, memoryMB: 10)],
            unreadableCount: 0
        )

        let report = ProcessUsageRanking.report(
            current: second, previous: first, sortedBy: .cpu, limit: 5
        )

        // Three cores fully busy — Activity Monitor's convention, not a clamp.
        XCTAssertEqual(try XCTUnwrap(report.processes.first?.cpuPercent), 300, accuracy: 0.001)
    }

    func testFirstSweepReportsMemoryButNoCPUAndSaysSo() {
        let only = ProcessSampleSet(
            timestamp: 10,
            samples: [
                sample(1, "small", cpuNanoseconds: 5_000, memoryMB: 10),
                sample(2, "large", cpuNanoseconds: 1_000, memoryMB: 900),
            ],
            unreadableCount: 0
        )

        let report = ProcessUsageRanking.report(
            current: only, previous: nil, sortedBy: .cpu, limit: 5
        )

        XCTAssertTrue(report.processes.allSatisfy { $0.cpuPercent == nil })
        // Memory breaks the tie, so the first frame is still ordered sensibly.
        XCTAssertEqual(report.processes.first?.pid, 2)
        XCTAssertTrue(report.notes.contains { $0.contains("second sample") })
    }

    func testRestartedPIDDoesNotUnderflowIntoAHugePercentage() {
        let first = ProcessSampleSet(
            timestamp: 0, samples: [sample(7, "old", cpuNanoseconds: 9_000_000_000, memoryMB: 50)],
            unreadableCount: 0
        )
        // Same PID, freshly started: less cumulative CPU than the sweep before.
        let second = ProcessSampleSet(
            timestamp: 1, samples: [sample(7, "new", cpuNanoseconds: 1_000_000, memoryMB: 50)],
            unreadableCount: 0
        )

        let report = ProcessUsageRanking.report(
            current: second, previous: first, sortedBy: .cpu, limit: 5
        )

        XCTAssertNil(report.processes.first?.cpuPercent)
    }

    func testMemorySortRanksByResidentSize() {
        let set = ProcessSampleSet(
            timestamp: 0,
            samples: [
                sample(1, "a", cpuNanoseconds: 0, memoryMB: 100),
                sample(2, "b", cpuNanoseconds: 0, memoryMB: 700),
                sample(3, "c", cpuNanoseconds: 0, memoryMB: 300),
            ],
            unreadableCount: 0
        )

        let report = ProcessUsageRanking.report(
            current: set, previous: nil, sortedBy: .memory, limit: 2
        )

        XCTAssertEqual(report.processes.map(\.pid), [2, 3])
        XCTAssertEqual(report.sortedBy, .memory)
    }

    func testUnreadableProcessesAreCountedAndExplained() {
        let set = ProcessSampleSet(
            timestamp: 0,
            samples: [sample(1, "mine", cpuNanoseconds: 0, memoryMB: 10)],
            unreadableCount: 212
        )

        let report = ProcessUsageRanking.report(
            current: set, previous: nil, sortedBy: .memory, limit: 5
        )

        XCTAssertEqual(report.unreadableProcessCount, 212)
        XCTAssertEqual(report.sampledProcessCount, 1)
        XCTAssertTrue(report.notes.contains { $0.contains("another user") })
    }

    func testLimitTruncatesTheRanking() {
        let samples = (1...20).map { sample(Int32($0), "p\($0)", cpuNanoseconds: 0, memoryMB: UInt64($0)) }
        let set = ProcessSampleSet(timestamp: 0, samples: samples, unreadableCount: 0)

        let report = ProcessUsageRanking.report(
            current: set, previous: nil, sortedBy: .memory, limit: 3
        )

        XCTAssertEqual(report.processes.count, 3)
        XCTAssertEqual(report.processes.map(\.pid), [20, 19, 18])
        XCTAssertEqual(report.sampledProcessCount, 20, "the count reflects the sweep, not the limit")
    }
}

final class ProcessUsageServiceTests: XCTestCase {

    func testServiceDifferencesConsecutiveCalls() throws {
        let source = ScriptedProcessSource([
            ProcessSampleSet(timestamp: 0,
                             samples: [sample(1, "busy", cpuNanoseconds: 0, memoryMB: 10)],
                             unreadableCount: 0),
            ProcessSampleSet(timestamp: 2,
                             samples: [sample(1, "busy", cpuNanoseconds: 1_000_000_000, memoryMB: 10)],
                             unreadableCount: 0),
        ])
        let service = ProcessUsageService(source: source)

        XCTAssertNil(service.report().processes.first?.cpuPercent)
        // 1s of CPU over 2s of wall clock.
        XCTAssertEqual(try XCTUnwrap(service.report().processes.first?.cpuPercent), 50, accuracy: 0.001)
    }

    func testResetBaselineDropsThePreviousSweep() throws {
        let source = ScriptedProcessSource([
            ProcessSampleSet(timestamp: 0,
                             samples: [sample(1, "busy", cpuNanoseconds: 0, memoryMB: 10)],
                             unreadableCount: 0),
            ProcessSampleSet(timestamp: 1,
                             samples: [sample(1, "busy", cpuNanoseconds: 500_000_000, memoryMB: 10)],
                             unreadableCount: 0),
        ])
        let service = ProcessUsageService(source: source)
        _ = service.report()

        service.resetBaseline()

        XCTAssertNil(service.report().processes.first?.cpuPercent,
                     "a stale baseline would average across the whole idle gap")
    }

    func testLimitIsClampedToTheMaximum() {
        let samples = (1...80).map { sample(Int32($0), "p\($0)", cpuNanoseconds: 0, memoryMB: UInt64($0)) }
        let source = ScriptedProcessSource([
            ProcessSampleSet(timestamp: 0, samples: samples, unreadableCount: 0),
        ])
        let service = ProcessUsageService(source: source)

        let report = service.report(sortedBy: .memory, limit: 5_000)

        XCTAssertEqual(report.processes.count, ProcessUsageService.maximumLimit)
    }

    func testLibprocSourceReadsThisHost() throws {
        // Smoke test against the real process table: the sweep must find at
        // least this test process and report a plausible RSS for it.
        let report = ProcessUsageService().report(sortedBy: .memory, limit: 50)
        XCTAssertGreaterThan(report.sampledProcessCount, 0)
        let own = report.processes.first { $0.pid == ProcessInfo.processInfo.processIdentifier }
        if let own {
            XCTAssertGreaterThan(own.memoryBytes, 0)
        }
    }

    // MARK: - Name caching (issue #319)

    func testRepeatSweepsResolveNamesOnlyForNotYetCachedPIDs() throws {
        let source = ResolutionCountingSource(tables: [
            [1: "a", 2: "b", 3: "c"],
            [1: "a", 2: "b", 3: "c"],
            [1: "a", 2: "b", 3: "c"],
        ])
        let service = ProcessUsageService(source: source)

        _ = service.report()   // first sweep resolves all three
        _ = service.report()   // all cached -> no new resolutions
        _ = service.report()

        XCTAssertEqual(source.resolutionCount, 3,
                       "only the first sweep should pay for name resolution")
        // Cached names still flow through unchanged on later sweeps.
        XCTAssertEqual(service.report().processes.map(\.name).sorted(), ["a", "b", "c"])
    }

    func testRecycledPIDDoesNotReportThePreviousProcessName() throws {
        // pid 3 runs as "old" for two sweeps, exits (absent from sweep 3), and
        // is recycled by a different process in sweep 4.
        let source = ResolutionCountingSource(tables: [
            [1: "one", 3: "old"],
            [1: "one", 3: "old"],
            [1: "one"],                 // pid 3 exited
            [1: "one", 3: "fresh"],     // pid 3 recycled
        ])
        let service = ProcessUsageService(source: source)

        _ = service.report()
        _ = service.report()
        _ = service.report()           // pid 3 absent -> pruned from the cache
        let final = service.report()

        XCTAssertEqual(final.processes.first { $0.pid == 3 }?.name, "fresh",
                       "a recycled PID must be re-resolved, not served a stale cached name")
    }

    func testCacheIsPrunedToTheSweepsPIDsAndCannotGrowAcrossSweeps() throws {
        // 3 and 4 leave the table, then come back; 5 is brand-new.
        let source = ResolutionCountingSource(tables: [
            [1: "a", 2: "b", 3: "c", 4: "d"],
            [1: "a", 2: "b"],                       // 3, 4 exited
            [1: "a", 2: "b", 3: "c"],                // long-lost 3 returns
            [1: "a", 2: "b", 3: "c", 4: "d", 5: "e"], // 4 returns, brand-new 5
        ])
        let service = ProcessUsageService(source: source)

        _ = service.report()
        _ = service.report()
        _ = service.report()
        _ = service.report()

        // Sweep 1 resolves all four. Sweeps 2-4 resolve only what was pruned
        // while absent: 3 and 4 each get one re-resolution, 5 one resolution.
        XCTAssertEqual(source.resolutionCount, 4 + 1 + 1 + 1)
    }
}
