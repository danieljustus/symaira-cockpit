import XCTest
@testable import SymTuneCore

final class MetricFormattingTests: XCTestCase {

    // MARK: - Fixtures

    /// 8 GB used of 16 GB, 50% CPU, 256 GB used of 512 GB, 2 MB/s down + 512 KB/s up.
    private func report(
        cpu: Double? = 0.5,
        memoryUsed: UInt64? = 8_589_934_592,
        memoryFree: UInt64? = 8_589_934_592,
        disk: DiskReport? = DiskReport(
            capacityBytes: 549_755_813_888,
            usedBytes: 274_877_906_944,
            freeBytes: 274_877_906_944
        ),
        down: Double? = 2_097_152,
        up: Double? = 524_288
    ) -> SystemMetricsReport {
        SystemMetricsReport(
            cpu: CPUReport(totalUtilization: cpu, perCoreUtilization: []),
            memory: MemoryReport(
                usedBytes: memoryUsed,
                freeBytes: memoryFree,
                wiredBytes: nil,
                compressedBytes: nil,
                pressure: nil
            ),
            disk: disk,
            network: NetworkReport(
                interfaces: [],
                aggregateBytesIn: 0,
                aggregateBytesOut: 0,
                aggregateBytesInPerSecond: down,
                aggregateBytesOutPerSecond: up
            )
        )
    }

    /// A report where no metric has any data.
    private func emptyReport() -> SystemMetricsReport {
        report(cpu: nil, memoryUsed: nil, memoryFree: nil, disk: nil, down: nil, up: nil)
    }

    // MARK: - hasData

    func testHasDataIsTrueWhenTheMetricHasAReading() {
        let report = self.report()
        XCTAssertTrue(MetricFormatting.hasData(.cpu, report: report))
        XCTAssertTrue(MetricFormatting.hasData(.memory, report: report))
        XCTAssertTrue(MetricFormatting.hasData(.disk, report: report))
        XCTAssertTrue(MetricFormatting.hasData(.network, report: report))
    }

    func testHasDataIsFalseWhenTheMetricHasNoReading() {
        let report = emptyReport()
        XCTAssertFalse(MetricFormatting.hasData(.cpu, report: report))
        XCTAssertFalse(MetricFormatting.hasData(.memory, report: report))
        XCTAssertFalse(MetricFormatting.hasData(.disk, report: report))
        XCTAssertFalse(MetricFormatting.hasData(.network, report: report))
    }

    func testHasDataTreatsEitherNetworkDirectionAsData() {
        let downOnly = report(down: 1_024, up: nil)
        let upOnly = report(down: nil, up: 1_024)
        XCTAssertTrue(MetricFormatting.hasData(.network, report: downOnly))
        XCTAssertTrue(MetricFormatting.hasData(.network, report: upOnly))
    }

    func testHasDataIsFalseForUnknownMetrics() {
        XCTAssertFalse(MetricFormatting.hasData(MetricIdentifier(rawValue: "battery"), report: report()))
    }

    // MARK: - value

    func testValueFormatsCpuAndDiskAsPercentages() {
        XCTAssertEqual(MetricFormatting.value(.cpu, 42.3), "42%")
        XCTAssertEqual(MetricFormatting.value(.cpu, 0.0), "0%")
        // Rounds, like the history card always has.
        XCTAssertEqual(MetricFormatting.value(.disk, 12.6), "13%")
    }

    func testValueFormatsMemoryAsGigabytesAboveTheGiBThreshold() {
        XCTAssertEqual(MetricFormatting.value(.memory, 1_073_741_824), "1.0 GB")
        XCTAssertEqual(MetricFormatting.value(.memory, 2_147_483_648), "2.0 GB")
    }

    func testValueFormatsMemoryAsMegabytesBelowTheGiBThreshold() {
        XCTAssertEqual(MetricFormatting.value(.memory, 536_870_912), "512 MB")
        // One byte below the threshold still renders in MB.
        XCTAssertEqual(MetricFormatting.value(.memory, 1_073_741_823), "1024 MB")
    }

    func testValueFormatsNetworkRates() {
        XCTAssertEqual(MetricFormatting.value(.network, 2_097_152), "2.0 MB/s")
        XCTAssertEqual(MetricFormatting.value(.network, 1_048_576), "1.0 MB/s")
        XCTAssertEqual(MetricFormatting.value(.network, 1_536), "2 KB/s")
        XCTAssertEqual(MetricFormatting.value(.network, 1_024), "1 KB/s")
        XCTAssertEqual(MetricFormatting.value(.network, 500), "500 B/s")
        XCTAssertEqual(MetricFormatting.value(.network, 0), "0 B/s")
    }

    func testValueFallsBackToOneDecimalForUnknownMetrics() {
        XCTAssertEqual(MetricFormatting.value(MetricIdentifier(rawValue: "battery"), 42), "42.0")
    }

    // MARK: - value basis

    /// The disk history buffer stores a used percentage; `.free` reports the
    /// complement without needing any extra context.
    func testValueHonoursFreeBasisForDiskAsComplement() {
        let freeStyle = MetricStyle(basis: .free)
        XCTAssertEqual(MetricFormatting.value(.disk, 30, style: freeStyle), "70%")
        XCTAssertEqual(MetricFormatting.value(.disk, 0, style: freeStyle), "100%")
        // `.used` (default) is unaffected.
        XCTAssertEqual(MetricFormatting.value(.disk, 30, style: .default), "30%")
    }

    /// The memory history buffer stores used bytes; `.free` needs `totalBytes`
    /// (used + free) to derive the free amount.
    func testValueHonoursFreeBasisForMemoryGivenTotalBytes() {
        let freeStyle = MetricStyle(basis: .free)
        let total: UInt64 = 16_106_127_360 // 15 GB
        // 8 GB used of 15 GB total -> 7 GB free.
        XCTAssertEqual(
            MetricFormatting.value(.memory, 8_589_934_592, style: freeStyle, totalBytes: total),
            "7.0 GB"
        )
        // `.used` (default) ignores totalBytes entirely.
        XCTAssertEqual(
            MetricFormatting.value(.memory, 8_589_934_592, style: .default, totalBytes: total),
            "8.0 GB"
        )
    }

    /// Without `totalBytes` there is nothing to convert against, so a `.free`
    /// memory value renders as-is rather than crashing or guessing.
    func testValueFreeBasisForMemoryWithoutTotalBytesRendersAsIs() {
        let freeStyle = MetricStyle(basis: .free)
        XCTAssertEqual(MetricFormatting.value(.memory, 8_589_934_592, style: freeStyle), "8.0 GB")
    }

    // MARK: - historyRowValues

    /// `.used` (the default/control case) matches the pre-basis behavior:
    /// current/min/max map straight through to the formatted used figures.
    func testHistoryRowValuesMatchesPriorBehaviorForUsedBasis() {
        let stats = MetricStats(current: 20, min: 10, max: 40)
        let row = MetricFormatting.historyRowValues(.disk, stats: stats, style: .default)
        XCTAssertEqual(row.current, "20%")
        XCTAssertEqual(row.minimum, "10%")
        XCTAssertEqual(row.maximum, "40%")
    }

    /// `.free` both converts to the complement and swaps min/max: the sample
    /// with the least usage (min) is the one with the most free space, so it
    /// becomes the "maximum" free reading, and vice versa.
    func testHistoryRowValuesConvertsAndSwapsMinMaxForFreeDiskBasis() {
        let stats = MetricStats(current: 20, min: 10, max: 40)
        let freeStyle = MetricStyle(basis: .free)
        let row = MetricFormatting.historyRowValues(.disk, stats: stats, style: freeStyle)
        XCTAssertEqual(row.current, "80%")   // 100 - 20
        XCTAssertEqual(row.minimum, "60%")   // 100 - max(40): least free observed
        XCTAssertEqual(row.maximum, "90%")   // 100 - min(10): most free observed
    }

    /// Same swap-and-convert behavior for memory, using `totalBytes` to turn
    /// used-byte samples into free-byte ones.
    func testHistoryRowValuesConvertsAndSwapsMinMaxForFreeMemoryBasis() {
        let total: UInt64 = 16_106_127_360 // 15 GB
        let stats = MetricStats(
            current: 8_589_934_592,   // 8 GB used
            min: 4_294_967_296,       // 4 GB used (min usage -> max free)
            max: 12_884_901_888       // 12 GB used (max usage -> min free)
        )
        let freeStyle = MetricStyle(basis: .free)
        let row = MetricFormatting.historyRowValues(.memory, stats: stats, style: freeStyle, totalBytes: total)
        XCTAssertEqual(row.current, "7.0 GB")   // 15 - 8
        XCTAssertEqual(row.minimum, "3.0 GB")   // 15 - max(12): least free observed
        XCTAssertEqual(row.maximum, "11.0 GB")  // 15 - min(4): most free observed
    }

    // MARK: - bytes
    //
    // Shared by the CLI process listing and the popover's process card, so the
    // unit boundaries are a contract between two surfaces, not cosmetics.

    func testBytesUsesTheLargestUnitThatFits() {
        XCTAssertEqual(MetricFormatting.bytes(0), "0 B")
        XCTAssertEqual(MetricFormatting.bytes(512), "512 B")
        XCTAssertEqual(MetricFormatting.bytes(4_096), "4 KB")
        XCTAssertEqual(MetricFormatting.bytes(5_242_880), "5 MB")
        XCTAssertEqual(MetricFormatting.bytes(2_147_483_648), "2.0 GB")
    }

    /// One byte either side of each unit switch: an off-by-one here would print
    /// "1024 KB" or "0.0 GB" in the process list.
    func testBytesSwitchesUnitExactlyAtTheBoundary() {
        XCTAssertEqual(MetricFormatting.bytes(1_023), "1023 B")
        XCTAssertEqual(MetricFormatting.bytes(1_024), "1 KB")
        XCTAssertEqual(MetricFormatting.bytes(1_048_575), "1024 KB")
        XCTAssertEqual(MetricFormatting.bytes(1_048_576), "1 MB")
        XCTAssertEqual(MetricFormatting.bytes(1_073_741_823), "1024 MB")
        XCTAssertEqual(MetricFormatting.bytes(1_073_741_824), "1.0 GB")
    }

    /// Gigabytes keep one decimal (a 1.6 GB process must not read as "2 GB"),
    /// while smaller units stay whole so the column does not jitter.
    func testBytesKeepsOneDecimalOnlyForGigabytes() {
        XCTAssertEqual(MetricFormatting.bytes(1_717_986_918), "1.6 GB")
        XCTAssertEqual(MetricFormatting.bytes(16_106_127_360), "15.0 GB")
        XCTAssertEqual(MetricFormatting.bytes(1_572_864), "2 MB")
    }

    // MARK: - fallbackValue

    func testFallbackValueShowsCpuUtilizationAsPercent() {
        XCTAssertEqual(MetricFormatting.fallbackValue(.cpu, report: report(cpu: 0.5)), "50%")
        XCTAssertNil(MetricFormatting.fallbackValue(.cpu, report: report(cpu: nil)))
    }

    func testFallbackValueShowsMemoryUsedInBytes() {
        XCTAssertEqual(MetricFormatting.fallbackValue(.memory, report: report()), "8.0 GB")
        XCTAssertNil(MetricFormatting.fallbackValue(.memory, report: report(memoryUsed: nil)))
    }

    func testFallbackValueShowsDiskUsageAsPercentOfCapacity() {
        XCTAssertEqual(MetricFormatting.fallbackValue(.disk, report: report()), "50%")
        XCTAssertNil(MetricFormatting.fallbackValue(.disk, report: report(disk: nil)))
        // A zero-capacity disk has no meaningful percentage.
        let zeroCapacity = DiskReport(capacityBytes: 0, usedBytes: 0, freeBytes: 0)
        XCTAssertNil(MetricFormatting.fallbackValue(.disk, report: report(disk: zeroCapacity)))
    }

    func testFallbackValueSumsBothNetworkDirections() {
        // 2 MB/s down + 512 KB/s up.
        XCTAssertEqual(MetricFormatting.fallbackValue(.network, report: report()), "2.5 MB/s")
        let downOnly = report(down: 2_097_152, up: nil)
        XCTAssertEqual(MetricFormatting.fallbackValue(.network, report: downOnly), "2.0 MB/s")
        let upOnly = report(down: nil, up: 524_288)
        XCTAssertEqual(MetricFormatting.fallbackValue(.network, report: upOnly), "512 KB/s")
        XCTAssertNil(MetricFormatting.fallbackValue(.network, report: report(down: nil, up: nil)))
    }

    func testFallbackValueIsNilForUnknownMetrics() {
        XCTAssertNil(MetricFormatting.fallbackValue(MetricIdentifier(rawValue: "battery"), report: report()))
    }

    // MARK: - fallbackValue basis

    /// 8 GB used of 16 GB total: `.used` reports the used half, `.free`
    /// reports the other half — the same figure the menu bar would show for
    /// the same style, so the popover chip never contradicts it.
    func testFallbackValueHonoursFreeBasisForMemory() {
        let usedStyle = MetricStyle(basis: .used)
        let freeStyle = MetricStyle(basis: .free)
        XCTAssertEqual(MetricFormatting.fallbackValue(.memory, report: report(), style: usedStyle), "8.0 GB")
        XCTAssertEqual(MetricFormatting.fallbackValue(.memory, report: report(), style: freeStyle), "8.0 GB")

        let lopsided = report(memoryUsed: 12_884_901_888, memoryFree: 4_294_967_296) // 12 GB used, 4 GB free
        XCTAssertEqual(MetricFormatting.fallbackValue(.memory, report: lopsided, style: usedStyle), "12.0 GB")
        XCTAssertEqual(MetricFormatting.fallbackValue(.memory, report: lopsided, style: freeStyle), "4.0 GB")
    }

    /// Default style (no explicit basis) matches prior `.used` behavior.
    func testFallbackValueDefaultStyleMatchesPriorMemoryBehavior() {
        XCTAssertEqual(MetricFormatting.fallbackValue(.memory, report: report()), "8.0 GB")
        XCTAssertEqual(MetricFormatting.fallbackValue(.memory, report: report(), style: .default), "8.0 GB")
    }

    /// `.free` with no free-byte data still returns `nil`, same as `.used`
    /// with no used-byte data.
    func testFallbackValueFreeBasisIsNilWithoutFreeData() {
        let freeStyle = MetricStyle(basis: .free)
        XCTAssertNil(MetricFormatting.fallbackValue(.memory, report: report(memoryFree: nil), style: freeStyle))
    }

    /// 256 GB used of 512 GB: `.free` reports the other 50%, same shape as
    /// `.used` because this fixture is an even split, so a lopsided fixture
    /// below is what actually proves the basis is honoured.
    func testFallbackValueHonoursFreeBasisForDisk() {
        let usedStyle = MetricStyle(basis: .used)
        let freeStyle = MetricStyle(basis: .free)
        let lopsided = DiskReport(
            capacityBytes: 400_000_000_000,
            usedBytes: 300_000_000_000,
            freeBytes: 100_000_000_000
        )
        XCTAssertEqual(MetricFormatting.fallbackValue(.disk, report: report(disk: lopsided), style: usedStyle), "75%")
        XCTAssertEqual(MetricFormatting.fallbackValue(.disk, report: report(disk: lopsided), style: freeStyle), "25%")
    }

    // MARK: - statusItemText

    func testStatusItemTextRendersAllMetricsInOrder() {
        let text = MetricFormatting.statusItemText(
            report: report(),
            identifiers: [.cpu, .memory, .disk, .network]
        )
        XCTAssertEqual(text, "CPU 50%  RAM 8.0G  💾256G  ↓2.0M ↑512K")
    }

    func testStatusItemTextIsEmptyWhenNothingHasData() {
        let text = MetricFormatting.statusItemText(
            report: emptyReport(),
            identifiers: [.cpu, .memory, .disk, .network]
        )
        XCTAssertEqual(text, "")
    }

    func testStatusItemTextIsEmptyForNoIdentifiers() {
        XCTAssertEqual(MetricFormatting.statusItemText(report: report(), identifiers: []), "")
    }

    func testStatusItemTextSkipsMetricsWithoutDataButKeepsTheRest() {
        let text = MetricFormatting.statusItemText(
            report: report(cpu: nil, disk: nil),
            identifiers: [.cpu, .memory, .disk, .network]
        )
        XCTAssertEqual(text, "RAM 8.0G  ↓2.0M ↑512K")
    }

    func testStatusItemTextHandlesSingleDirectionNetwork() {
        let downOnly = MetricFormatting.statusItemText(
            report: report(down: 2_097_152, up: nil),
            identifiers: [.network]
        )
        XCTAssertEqual(downOnly, "↓2.0M")

        let upOnly = MetricFormatting.statusItemText(
            report: report(down: nil, up: 524_288),
            identifiers: [.network]
        )
        XCTAssertEqual(upOnly, "↑512K")
    }

    func testStatusItemTextPadsCpuPercentToTwoDigits() {
        let text = MetricFormatting.statusItemText(
            report: report(cpu: 0.05),
            identifiers: [.cpu]
        )
        XCTAssertEqual(text, "CPU  5%")
    }

    func testStatusItemTextUsesMegabytesBelowOneGigabyteOfRam() {
        let text = MetricFormatting.statusItemText(
            report: report(memoryUsed: 536_870_912, memoryFree: 536_870_912),
            identifiers: [.memory]
        )
        XCTAssertEqual(text, "RAM 512M")
    }

    func testStatusItemTextFollowsTheGivenIdentifierOrder() {
        let text = MetricFormatting.statusItemText(
            report: report(),
            identifiers: [.network, .cpu]
        )
        XCTAssertEqual(text, "↓2.0M ↑512K  CPU 50%")
    }

    func testStatusItemTextSkipsUnknownMetrics() {
        let text = MetricFormatting.statusItemText(
            report: report(),
            identifiers: [MetricIdentifier(rawValue: "battery")]
        )
        XCTAssertEqual(text, "")
    }
}
