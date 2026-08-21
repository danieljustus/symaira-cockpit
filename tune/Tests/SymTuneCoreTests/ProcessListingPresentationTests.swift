import XCTest
@testable import SymTuneCore

/// The `processes` command's flags and table layout. These used to live in the
/// CLI target, where coverage cannot see them at all — the CLI is exercised by
/// spawning the binary, so its lines are absent from reports rather than
/// counted as uncovered.
final class ProcessListingPresentationTests: XCTestCase {

    // MARK: - Options

    func testDefaultsRankByCPUWithTheDefaultLimit() throws {
        let options = try ProcessListingPresentation.parseOptions([])

        XCTAssertEqual(options.sortedBy, .cpu)
        XCTAssertEqual(options.limit, ProcessUsageService.defaultLimit)
        XCTAssertFalse(options.wantsJSON)
        XCTAssertFalse(options.wantsHelp)
    }

    func testParsesEveryFlagTogether() throws {
        let options = try ProcessListingPresentation.parseOptions(
            ["--sort", "memory", "--limit", "12", "--json"]
        )

        XCTAssertEqual(options.sortedBy, .memory)
        XCTAssertEqual(options.limit, 12)
        XCTAssertTrue(options.wantsJSON)
    }

    func testSortKeyIsCaseInsensitive() throws {
        let options = try ProcessListingPresentation.parseOptions(["--sort", "MEMORY"])
        XCTAssertEqual(options.sortedBy, .memory)
    }

    func testIntervalDefaultsToOneSecondAndParsesADuration() throws {
        XCTAssertEqual(try ProcessListingPresentation.parseOptions([]).interval, 1.0)

        let options = try ProcessListingPresentation.parseOptions(["--interval", "2.5"])
        XCTAssertEqual(options.interval, 2.5, accuracy: 0.0001)
    }

    func testIntervalRequiresAPositiveDuration() {
        assertUsageError(["--interval"], contains: "--interval")
        assertUsageError(["--interval", "0"], contains: "--interval")
        assertUsageError(["--interval", "-1"], contains: "--interval")
        assertUsageError(["--interval", "abc"], contains: "--interval")
    }

    func testHelpDocumentsTheIntervalFlag() {
        let usage = ProcessListingPresentation.usageLines.joined(separator: "\n")
        XCTAssertTrue(usage.contains("--interval"), usage)
    }

    func testHelpShortCircuitsBeforeAnyOtherParsing() throws {
        // `--help` must win even next to nonsense, so `processes --help` always
        // explains itself instead of erroring.
        let options = try ProcessListingPresentation.parseOptions(["--bogus", "--help"])

        XCTAssertTrue(options.wantsHelp)
        XCTAssertFalse(ProcessListingPresentation.usageLines.isEmpty)
    }

    /// An unknown flag must fail rather than silently fall back to a CPU
    /// ranking — a typo in a script should be visible.
    func testUnknownArgumentIsAUsageError() {
        assertUsageError(["--top"], contains: "unexpected argument '--top'")
        assertUsageError(["memory"], contains: "unexpected argument 'memory'")
    }

    func testSortRequiresAKnownKey() {
        assertUsageError(["--sort"], contains: "--sort")
        assertUsageError(["--sort", "disk"], contains: "--sort")
    }

    func testLimitRequiresAPositiveInteger() {
        assertUsageError(["--limit"], contains: "--limit")
        assertUsageError(["--limit", "0"], contains: "--limit")
        assertUsageError(["--limit", "-3"], contains: "--limit")
        assertUsageError(["--limit", "many"], contains: "--limit")
    }

    private func assertUsageError(
        _ args: [String],
        contains fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try ProcessListingPresentation.parseOptions(args), file: file, line: line) { error in
            guard case TuneError.usage(let message) = error else {
                return XCTFail("expected a usage error, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(
                message.contains(fragment),
                "message '\(message)' does not mention \(fragment)",
                file: file, line: line
            )
        }
    }

    // MARK: - Table

    private func report(_ processes: [ProcessUsage]) -> ProcessUsageReport {
        ProcessUsageReport(
            sortedBy: .cpu,
            processes: processes,
            sampledProcessCount: processes.count,
            unreadableProcessCount: 0
        )
    }

    func testTableStartsWithAHeaderAndARuleOfMatchingWidth() {
        let lines = ProcessListingPresentation.tableLines(for: report([]))

        XCTAssertEqual(lines.count, 2, "an empty report is header + rule, no rows")
        let header = lines[0]
        XCTAssertTrue(header.hasPrefix("PID"), header)
        XCTAssertTrue(header.contains("PROCESS"), header)
        XCTAssertTrue(header.contains("CPU %"), header)
        XCTAssertTrue(header.hasSuffix("MEMORY"), header)
        XCTAssertEqual(lines[1], String(repeating: "-", count: ProcessListingPresentation.ruleWidth))
        XCTAssertEqual(header.count, ProcessListingPresentation.ruleWidth,
                       "header and rule must line up")
    }

    func testRowsAreColumnAlignedWithTheHeader() {
        let lines = ProcessListingPresentation.tableLines(for: report([
            ProcessUsage(pid: 42, name: "safari", cpuPercent: 12.34, memoryBytes: 2_147_483_648),
        ]))

        let row = try? XCTUnwrap(lines.last)
        XCTAssertEqual(row?.count, ProcessListingPresentation.ruleWidth,
                       "a row that is wider than the rule breaks the table")
        XCTAssertTrue(row?.hasPrefix("42") == true, row ?? "")
        XCTAssertTrue(row?.contains("safari") == true, row ?? "")
        // One decimal, right-aligned against the CPU column.
        XCTAssertTrue(row?.contains("12.3") == true, row ?? "")
        XCTAssertTrue(row?.hasSuffix("2.0 GB") == true, row ?? "")
    }

    /// A missing CPU rate is `n/a`, never `0.0` — the first sweep has no rate
    /// yet, and a zero would read as a genuinely idle process.
    func testMissingCPURateRendersAsNotAvailable() {
        let lines = ProcessListingPresentation.tableLines(for: report([
            ProcessUsage(pid: 7, name: "fresh", cpuPercent: nil, memoryBytes: 1_048_576),
        ]))

        let row = lines[2]
        XCTAssertTrue(row.contains("n/a"), row)
        XCTAssertFalse(row.contains("0.0"), row)
    }

    func testOverlongProcessNameIsClippedToItsColumn() {
        let long = String(repeating: "x", count: 80)
        let lines = ProcessListingPresentation.tableLines(for: report([
            ProcessUsage(pid: 1, name: long, cpuPercent: 1, memoryBytes: 1024),
        ]))

        let row = lines[2]
        XCTAssertEqual(row.count, ProcessListingPresentation.ruleWidth,
                       "a long name must not push the later columns out of line")
        XCTAssertFalse(row.contains(String(repeating: "x", count: ProcessListingPresentation.nameWidth + 1)))
    }

    func testOneRowPerReportedProcess() {
        let processes = (1...5).map {
            ProcessUsage(pid: Int32($0), name: "p\($0)", cpuPercent: Double($0), memoryBytes: 1024)
        }
        let lines = ProcessListingPresentation.tableLines(for: report(processes))

        XCTAssertEqual(lines.count, 2 + processes.count)
    }
}
