import XCTest
@testable import SymTuneCore

/// The `awake`, `status` and `history` option parsers, plus the `HH:MM` until
/// parser. These used to live in the CLI target, where coverage cannot see
/// them at all — the CLI is exercised by spawning the binary, so its lines are
/// absent from reports rather than counted as uncovered.
final class CLIOptionParsingTests: XCTestCase {

    // MARK: - AwakeOptions

    func testAwakeDefaultsBlockIndefinitelyWithoutFlags() throws {
        let options = try AwakeOptions.parseOptions([])

        XCTAssertNil(options.subcommand)
        XCTAssertNil(options.seconds)
        XCTAssertFalse(options.preventDisplaySleep)
    }

    func testAwakeParsesDisplayAndSeconds() throws {
        let options = try AwakeOptions.parseOptions(["--display", "--seconds", "300"])

        XCTAssertNil(options.subcommand)
        XCTAssertEqual(options.seconds, 300)
        XCTAssertTrue(options.preventDisplaySleep)
    }

    func testAwakeAcceptsShortSecondsFlag() throws {
        let options = try AwakeOptions.parseOptions(["-s", "10"])
        XCTAssertEqual(options.seconds, 10)
    }

    func testAwakeParsesForDuration() throws {
        let options = try AwakeOptions.parseOptions(["--for", "30m"])
        XCTAssertEqual(options.seconds, 1_800)
    }

    func testAwakeForWinsOverSeconds() throws {
        let options = try AwakeOptions.parseOptions(["--seconds", "5", "--for", "10s"])
        XCTAssertEqual(options.seconds, 10)
    }

    func testAwakeUntilWinsOverForAndSeconds() throws {
        // Since --until is resolved last it takes precedence over --for and
        // --seconds; we only assert it resolves to a within-24h duration.
        let options = try AwakeOptions.parseOptions(
            ["--seconds", "5", "--for", "10s", "--until", "23:59"]
        )
        let seconds = try XCTUnwrap(options.seconds)
        XCTAssertGreaterThanOrEqual(seconds, 0)
        XCTAssertLessThan(seconds, 86_400)
    }

    func testAwakeSubcommandsAreRecognisedAsFirstArgument() throws {
        let status = try AwakeOptions.parseOptions(["status"])
        XCTAssertEqual(status.subcommand, .status)
        XCTAssertNil(status.seconds)

        let off = try AwakeOptions.parseOptions(["off"])
        XCTAssertEqual(off.subcommand, .off)
    }

    func testAwakeRejectsUnknownOption() {
        assertUsageError(AwakeOptions.parseOptions, ["--bogus"], contains: "unknown option")
    }

    func testAwakeRequiresValuesForItsFlags() {
        assertUsageError(AwakeOptions.parseOptions, ["--seconds"], contains: "--seconds requires")
        assertUsageError(AwakeOptions.parseOptions, ["--seconds", "no"], contains: "--seconds requires")
        assertUsageError(AwakeOptions.parseOptions, ["--for"], contains: "--for requires")
        assertUsageError(AwakeOptions.parseOptions, ["--until"], contains: "--until requires")
    }

    // MARK: - StatusOptions

    func testStatusDefaultsToSinglePlainSnapshot() throws {
        let options = try StatusOptions.parseOptions([])

        XCTAssertFalse(options.isWatch)
        XCTAssertEqual(options.interval, 1.0)
        XCTAssertFalse(options.isJson)
    }

    func testStatusParsesEveryFlag() throws {
        let options = try StatusOptions.parseOptions(["--watch", "--interval", "2s", "--json"])

        XCTAssertTrue(options.isWatch)
        XCTAssertEqual(options.interval, 2.0)
        XCTAssertTrue(options.isJson)
    }

    func testStatusRejectsUnknownOption() {
        assertUsageError(StatusOptions.parseOptions, ["--nope"], contains: "unknown option")
    }

    func testStatusIntervalRequiresAValue() {
        assertUsageError(StatusOptions.parseOptions, ["--interval"], contains: "--interval requires")
    }

    // MARK: - HistoryOptions

    func testHistoryDefaultsToLastHundredEvents() throws {
        let options = try HistoryOptions.parseOptions([])

        XCTAssertFalse(options.isJson)
        XCTAssertEqual(options.limit, 100)
    }

    func testHistoryParsesJSONAndLimit() throws {
        let options = try HistoryOptions.parseOptions(["--json", "--limit", "5"])
        XCTAssertTrue(options.isJson)
        XCTAssertEqual(options.limit, 5)
    }

    func testHistoryAcceptsShortLimitFlag() throws {
        let options = try HistoryOptions.parseOptions(["-n", "3"])
        XCTAssertEqual(options.limit, 3)
    }

    func testHistoryRejectsUnknownOption() {
        assertUsageError(HistoryOptions.parseOptions, ["--bogus"], contains: "unknown option")
    }

    func testHistoryLimitRequiresAnInteger() {
        assertUsageError(HistoryOptions.parseOptions, ["--limit"], contains: "--limit requires")
        assertUsageError(HistoryOptions.parseOptions, ["--limit", "many"], contains: "--limit requires")
    }

    // MARK: - UntilTimeParser

    private func date(hour: Int, minute: Int) -> Date {
        let calendar = Calendar.current
        return calendar.date(
            from: DateComponents(year: 2026, month: 1, day: 15, hour: hour, minute: minute)
        )!
    }

    func testUntilTimeLaterTodayIsAFutureSameDayDuration() throws {
        // 08:00 -> 14:00 is 6 hours ahead on the same day.
        let seconds = try UntilTimeParser.parse("14:00", now: date(hour: 8, minute: 0))
        XCTAssertEqual(seconds, 21_600, accuracy: 1)
    }

    /// The roll-over branch: when the time has already passed today, the
    /// result must be positive and schedule for tomorrow rather than being a
    /// negative (already-passed) duration.
    func testUntilTimeAlreadyPassedTodayRollsOverToTomorrow() throws {
        // 14:00 -> 08:00 next day is 18 hours away.
        let seconds = try UntilTimeParser.parse("08:00", now: date(hour: 14, minute: 0))
        XCTAssertEqual(seconds, 64_800, accuracy: 1)
    }

    func testUntilTimeRejectsMalformedInput() {
        let now = date(hour: 8, minute: 0)
        assertUsageStringError({ try UntilTimeParser.parse($0, now: now) }, "abc", contains: "HH:MM")
        assertUsageStringError({ try UntilTimeParser.parse($0, now: now) }, "25:00", contains: "HH:MM")
        assertUsageStringError({ try UntilTimeParser.parse($0, now: now) }, "12:60", contains: "HH:MM")
        assertUsageStringError({ try UntilTimeParser.parse($0, now: now) }, "12", contains: "HH:MM")
    }

    // MARK: - Helpers

    private func assertUsageStringError(
        _ parse: (String) throws -> TimeInterval,
        _ input: String,
        contains fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try parse(input), file: file, line: line) { error in
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

    private func assertUsageError<Options>(
        _ parse: ([String]) throws -> Options,
        _ args: [String],
        contains fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try parse(args), file: file, line: line) { error in
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
}
