import Foundation
@testable import SymTuneCore

/// Replays scripted process sweeps, so tests can drive CPU deltas without
/// depending on whatever the host happens to be running.
///
/// The last sweep repeats once the script is exhausted, which keeps a test that
/// samples one extra time from falling off the end.
final class FakeProcessSampleSource: ProcessSampleSource, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [ProcessSampleSet]
    private(set) var sampleCount = 0

    init(_ sets: [ProcessSampleSet]) {
        precondition(!sets.isEmpty, "a scripted source needs at least one sweep")
        self.pending = sets
    }

    func sample(knownNames: [Int32: String]) -> (set: ProcessSampleSet, resolvedNames: [Int32: String]) {
        lock.lock()
        defer { lock.unlock() }
        sampleCount += 1
        let set = pending.count == 1 ? pending[0] : pending.removeFirst()
        // Treat every name as freshly resolved so the caller's cache mirrors
        // this scripted sweep.
        var resolved: [Int32: String] = [:]
        resolved.reserveCapacity(set.samples.count)
        for sample in set.samples { resolved[sample.pid] = sample.name }
        return (set, resolved)
    }
}

/// One scripted process reading.
func fakeProcessSample(
    pid: Int32,
    name: String,
    cpuNanoseconds: UInt64 = 0,
    memoryMB: UInt64 = 1,
    threads: Int? = 2
) -> ProcessSample {
    ProcessSample(
        pid: pid,
        name: name,
        cpuTimeNanoseconds: cpuNanoseconds,
        memoryBytes: memoryMB * 1_048_576,
        threadCount: threads
    )
}
