import XCTest
@testable import SymTuneCore

final class MetricStyleTests: XCTestCase {

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

    private func text(
        _ identifiers: [MetricIdentifier],
        _ styles: [MetricIdentifier: MetricStyle] = [:],
        report: SystemMetricsReport? = nil
    ) -> String {
        let segments = MetricStyleFormatting.statusItemSegments(
            report: report ?? self.report(),
            identifiers: identifiers,
            styles: styles
        )
        return MetricStyleFormatting.plainText(segments)
    }

    // MARK: - Defaults

    func testDefaultStyleMatchesThePreviousStatusItemFormat() {
        XCTAssertEqual(text([.cpu, .memory]), "CPU 50%  RAM 8.0G")
    }

    func testMetricsWithoutStylesFallBackToTheDefault() {
        XCTAssertEqual(text([.cpu], [:]), text([.cpu], [.cpu: .default]))
    }

    // MARK: - Label style

    func testTextLabelPrefixesTheShortName() {
        XCTAssertEqual(text([.disk], [.disk: MetricStyle(label: .text)]), "Disk 256.0G")
    }

    func testHiddenLabelDropsThePrefixEntirely() {
        XCTAssertEqual(text([.disk], [.disk: MetricStyle(label: .hidden)]), "256.0G")
    }

    func testIconLabelEmitsASymbolSegmentInsteadOfTextPrefix() {
        let segments = MetricStyleFormatting.statusItemSegments(
            report: report(),
            identifiers: [.cpu],
            styles: [.cpu: MetricStyle(label: .icon)]
        )
        XCTAssertEqual(segments.first, .symbol(MetricIdentifier.cpu.statusItemSymbol))
        XCTAssertEqual(segments.last, .text(" 50%"))
    }

    // MARK: - Scale

    func testRelativeMemoryIsAShareOfUsedPlusFree() {
        // 8 GB used of 16 GB total.
        XCTAssertEqual(text([.memory], [.memory: MetricStyle(scale: .relative)]), "RAM 50%")
    }

    func testRelativeDiskIsAShareOfCapacity() {
        XCTAssertEqual(text([.disk], [.disk: MetricStyle(scale: .relative)]), "Disk 50%")
    }

    func testAbsoluteMemoryIsAByteAmount() {
        XCTAssertEqual(text([.memory], [.memory: MetricStyle(scale: .absolute)]), "RAM 8.0G")
    }

    /// CPU is already a percentage and network has no total, so the scale
    /// control is inert for them — and the UI disables it on that basis.
    func testScaleIsInertForMetricsThatHaveNoTotal() {
        XCTAssertEqual(
            text([.cpu], [.cpu: MetricStyle(scale: .relative)]),
            text([.cpu], [.cpu: MetricStyle(scale: .absolute)])
        )
        XCTAssertFalse(MetricIdentifier.cpu.supportsRelativeScale)
        XCTAssertFalse(MetricIdentifier.network.supportsRelativeScale)
        XCTAssertTrue(MetricIdentifier.memory.supportsRelativeScale)
        XCTAssertTrue(MetricIdentifier.disk.supportsRelativeScale)
    }

    // MARK: - Basis

    func testFreeBasisMemoryAbsoluteReportsWhatIsStillAvailable() {
        // 8 GB free of 16 GB total.
        XCTAssertEqual(
            text([.memory], [.memory: MetricStyle(basis: .free)]),
            "RAM 8.0G"
        )
    }

    func testFreeBasisMemoryRelativeReportsTheFreeShare() {
        let partial = report(memoryUsed: 4_294_967_296, memoryFree: 12_884_901_888) // 4 GB used, 12 GB free
        XCTAssertEqual(
            text([.memory], [.memory: MetricStyle(scale: .relative, basis: .free)], report: partial),
            "RAM 75%"
        )
    }

    func testFreeBasisDiskAbsoluteReportsWhatIsStillAvailable() {
        let partial = report(disk: DiskReport(
            capacityBytes: 549_755_813_888,
            usedBytes: 137_438_953_472, // 128 GB used
            freeBytes: 412_316_860_416 // 384 GB free
        ))
        XCTAssertEqual(
            text([.disk], [.disk: MetricStyle(basis: .free)], report: partial),
            "Disk 384.0G"
        )
    }

    func testFreeBasisDiskRelativeReportsTheFreeShareOfCapacity() {
        let partial = report(disk: DiskReport(
            capacityBytes: 549_755_813_888,
            usedBytes: 137_438_953_472, // 128 GB used
            freeBytes: 412_316_860_416 // 384 GB free
        ))
        XCTAssertEqual(
            text([.disk], [.disk: MetricStyle(scale: .relative, basis: .free)], report: partial),
            "Disk 75%"
        )
    }

    func testUsedBasisIsTheDefaultAndMatchesPriorBehavior() {
        XCTAssertEqual(MetricStyle.default.basis, .used)
        XCTAssertEqual(
            text([.memory], [.memory: MetricStyle()]),
            text([.memory], [.memory: MetricStyle(basis: .used)])
        )
    }

    func testBasisIsInertForMetricsWithoutAUsedFreeSplit() {
        XCTAssertEqual(
            text([.cpu], [.cpu: MetricStyle(basis: .free)]),
            text([.cpu], [.cpu: MetricStyle(basis: .used)])
        )
        XCTAssertFalse(MetricIdentifier.cpu.supportsBasis)
        XCTAssertFalse(MetricIdentifier.network.supportsBasis)
        XCTAssertTrue(MetricIdentifier.memory.supportsBasis)
        XCTAssertTrue(MetricIdentifier.disk.supportsBasis)
    }

    func testFreeBasisMemoryFallsBackToNothingWhenFreeIsUnknown() {
        let partial = report(memoryFree: nil)
        XCTAssertEqual(
            text([.memory], [.memory: MetricStyle(basis: .free)], report: partial),
            ""
        )
    }

    // MARK: - Units

    func testFullUnitsSpellOutTheSuffix() {
        XCTAssertEqual(text([.memory], [.memory: MetricStyle(unit: .full)]), "RAM 8.0 GB")
    }

    func testHiddenUnitsLeaveABareNumber() {
        XCTAssertEqual(text([.memory], [.memory: MetricStyle(unit: .hidden)]), "RAM 8.0")
        XCTAssertEqual(
            text([.cpu], [.cpu: MetricStyle(unit: .hidden)]),
            "CPU 50"
        )
    }

    func testNetworkUnitsApplyToBothDirections() {
        XCTAssertEqual(
            text([.network], [.network: MetricStyle(unit: .full)]),
            "Net \u{2193}2.0 MB/s \u{2191}512 KB/s"
        )
        XCTAssertEqual(
            text([.network], [.network: MetricStyle(unit: .abbreviated)]),
            "Net \u{2193}2.0M \u{2191}512K"
        )
    }

    // MARK: - Missing data

    func testMetricsWithoutDataAreOmittedRatherThanShownEmpty() {
        let partial = report(cpu: nil, disk: nil)
        XCTAssertEqual(text([.cpu, .memory, .disk], report: partial), "RAM 8.0G")
    }

    func testRelativeMemoryFallsBackToNothingWhenTotalIsUnknown() {
        let partial = report(memoryFree: nil)
        XCTAssertEqual(
            text([.memory], [.memory: MetricStyle(scale: .relative)], report: partial),
            ""
        )
    }

    func testSeparatorAppearsOnlyBetweenMetrics() {
        XCTAssertEqual(text([.cpu]), "CPU 50%")
        XCTAssertFalse(text([.cpu]).hasPrefix(" "))
    }

    // MARK: - Config round-trip

    func testStylesParseFromTheMetricsSection() {
        let toml = """
        [metrics]
        cpu_label = "icon"
        memory_scale = "relative"
        memory_unit = "full"
        """
        let table = TOMLParser().parse(toml)
        let styles = TuneConfig.parseMetricStyles(table: table, section: "metrics")

        XCTAssertEqual(styles[.cpu]?.label, .icon)
        XCTAssertEqual(styles[.cpu]?.unit, MetricStyle.default.unit, "unspecified axes keep the default")
        XCTAssertEqual(styles[.memory]?.scale, .relative)
        XCTAssertEqual(styles[.memory]?.unit, .full)
        XCTAssertNil(styles[.disk], "a metric with no style keys stays absent")
    }

    func testBasisOnlyOverrideIsNotDroppedByTheAllAxesAbsentGuard() {
        let toml = """
        [metrics]
        disk_basis = "free"
        """
        let table = TOMLParser().parse(toml)
        let styles = TuneConfig.parseMetricStyles(table: table, section: "metrics")

        XCTAssertEqual(styles[.disk]?.basis, .free)
        XCTAssertEqual(styles[.disk]?.label, MetricStyle.default.label, "unspecified axes keep the default")
        XCTAssertNil(styles[.cpu], "a metric with no style keys stays absent")
    }

    func testUnknownStyleValuesFallBackToTheDefaultAxis() {
        let table = TOMLParser().parse("""
        [metrics]
        cpu_label = "hologram"
        """)
        let styles = TuneConfig.parseMetricStyles(table: table, section: "metrics")
        XCTAssertNil(styles[.cpu], "no recognised axis means no style entry at all")
    }
}

final class PopoverCardTests: XCTestCase {

    func testAllCardsAreVisibleByDefault() {
        XCTAssertEqual(TuneConfig().visibleCards, Set(PopoverCard.allCases))
    }

    /// Cards newer than the v1 vocabulary. A v1 (unversioned) list cannot be an
    /// opinion about them, so they are added rather than hidden.
    private var cardsAddedAfterVersionOne: Set<PopoverCard> {
        Set(PopoverCard.allCases.filter { !TuneConfig.cardVocabulary(version: 1).contains($0.rawValue) })
    }

    func testCardSetParsesFromThePopoverSection() {
        let table = TOMLParser().parse("""
        [popover]
        cards_version = \(TuneConfig.popoverCardsSchemaVersion)
        cards = ["display_controls", "system_status"]
        """)
        // At the current vocabulary version the list is authoritative: a card
        // the user turned off stays off.
        XCTAssertEqual(
            TuneConfig.parseCardSet(table: table),
            Set<PopoverCard>([.displayControls, .systemStatus])
        )
    }

    func testUnknownCardNamesAreIgnoredRatherThanFailingTheWholeList() {
        let table = TOMLParser().parse("""
        [popover]
        cards_version = \(TuneConfig.popoverCardsSchemaVersion)
        cards = ["display_controls", "teleporter"]
        """)
        XCTAssertEqual(TuneConfig.parseCardSet(table: table), Set<PopoverCard>([.displayControls]))
    }

    /// A config written by an older release lists every card that existed then.
    /// The card added afterwards has to appear, or the feature ships invisible
    /// for everyone who already used the app.
    func testACardAddedAfterTheConfigWasWrittenBecomesVisible() {
        let table = TOMLParser().parse("""
        [popover]
        cards = ["display_controls", "keep_awake", "fan_control", "system_status", "metrics_history", "displays"]
        """)
        let parsed = TuneConfig.parseCardSet(table: table)
        XCTAssertTrue(parsed.contains(.topProcesses))
        XCTAssertEqual(parsed, Set(PopoverCard.allCases))
        XCTAssertFalse(cardsAddedAfterVersionOne.isEmpty, "the v1 vocabulary must stay frozen")
    }

    /// The same legacy list, minus one card the user had turned off: the opt-out
    /// survives, and only the genuinely new card is added.
    func testALegacyOptOutIsPreserved() {
        let table = TOMLParser().parse("""
        [popover]
        cards = ["display_controls", "keep_awake", "system_status", "metrics_history", "displays"]
        """)
        let parsed = TuneConfig.parseCardSet(table: table)
        XCTAssertFalse(parsed.contains(.fanControl))
        XCTAssertTrue(parsed.contains(.topProcesses))
    }

    /// Turning every card off is a real choice, not a config error — it must
    /// not silently spring back to "show everything".
    func testAnExplicitlyEmptyListIsHonoured() {
        let table = TOMLParser().parse("""
        [popover]
        cards = []
        """)
        XCTAssertEqual(TuneConfig.parseCardSet(table: table), [])
    }

    func testAMissingSectionFallsBackToEveryCard() {
        XCTAssertEqual(
            TuneConfig.parseCardSet(table: TOMLParser().parse("")),
            Set(PopoverCard.allCases)
        )
    }

    func testOnlyFanControlIsHiddenWhenItsHardwareIsMissing() {
        XCTAssertTrue(PopoverCard.fanControl.hidesWhenHardwareMissing)
        for card in PopoverCard.allCases where card != .fanControl {
            XCTAssertFalse(card.hidesWhenHardwareMissing, "\(card.displayName)")
        }
    }
}
