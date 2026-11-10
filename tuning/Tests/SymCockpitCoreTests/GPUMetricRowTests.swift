import XCTest
import Foundation
@testable import SymCockpitCore

/// GPU as an opt-in metric row (issue #402): selectable and renderable like
/// the other four, but never part of a default.
final class GPUMetricRowTests: XCTestCase {

    private let previousDefaults: [MetricIdentifier] = [.cpu, .memory, .disk, .network]

    // MARK: - Fixtures

    private func report(gpu: Double?) -> SystemMetricsReport {
        SystemMetricsReport(
            cpu: CPUReport(totalUtilization: 0.5, perCoreUtilization: []),
            memory: MemoryReport(
                usedBytes: 8_589_934_592, freeBytes: 8_589_934_592,
                wiredBytes: nil, compressedBytes: nil, pressure: nil
            ),
            disk: nil,
            network: NetworkReport(
                interfaces: [], aggregateBytesIn: 0, aggregateBytesOut: 0,
                aggregateBytesInPerSecond: nil, aggregateBytesOutPerSecond: nil
            ),
            gpu: gpu.map { GPUReport(utilizationPercent: $0) }
        )
    }

    private func loadConfig(_ toml: String?) throws -> TuneConfig {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("gpu-metric-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        if let toml {
            let dir = home.appendingPathComponent(".config/symtune", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try toml.write(to: dir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        }
        return TuneConfig.load(paths: ConfigPaths(home: home), env: [:])
    }

    // MARK: - Defaults unchanged

    func testDefaultSetsAreStillTheFormerFourMetrics() throws {
        XCTAssertEqual(MetricIdentifier.defaultCases, previousDefaults)
        let config = TuneConfig()
        XCTAssertEqual(config.enabledMetrics, Set(previousDefaults))
        XCTAssertEqual(config.visibleMetrics, Set(previousDefaults))
        XCTAssertEqual(config.metricOrder, previousDefaults)
        XCTAssertEqual(TuneConfig.defaultMetricOrder, previousDefaults)
        XCTAssertFalse(config.enabledMetrics.contains(.gpu))
        XCTAssertFalse(config.visibleMetrics.contains(.gpu))
        XCTAssertFalse(config.metricOrder.contains(.gpu))
    }

    func testLoadingWithoutAConfigFileKeepsTheFormerDefaults() throws {
        let config = try loadConfig(nil)
        XCTAssertEqual(config.enabledMetrics, Set(previousDefaults))
        XCTAssertEqual(config.visibleMetrics, Set(previousDefaults))
        XCTAssertEqual(config.metricOrder, previousDefaults)
    }

    func testAConfigThatNeverMentionsMetricSetsKeepsTheFormerDefaults() throws {
        let config = try loadConfig("[metrics]\nshow_calendar_week = true\n")
        XCTAssertEqual(config.enabledMetrics, Set(previousDefaults))
        XCTAssertEqual(config.visibleMetrics, Set(previousDefaults))
        XCTAssertEqual(config.metricOrder, previousDefaults)
    }

    func testAnExistingConfigWithoutGPUBehavesAsBefore() throws {
        let config = try loadConfig("""
        [metrics]
        enabled = ["cpu", "memory"]
        visible = ["cpu"]
        order = ["memory", "cpu", "disk", "network"]
        """)
        XCTAssertEqual(config.enabledMetrics, [.cpu, .memory])
        XCTAssertEqual(config.visibleMetrics, [.cpu])
        XCTAssertEqual(config.metricOrder, [.memory, .cpu, .disk, .network])
    }

    func testGPUIsSelectableButNotADefault() {
        XCTAssertEqual(MetricIdentifier.allCases, previousDefaults + [.gpu])
        XCTAssertEqual(MetricIdentifier.gpu.rawValue, "gpu")
        XCTAssertEqual(MetricIdentifier.gpu.displayName, "GPU")
    }

    // MARK: - Config parsing with gpu

    func testConfigAcceptsGPUInEnabledVisibleAndOrder() throws {
        let config = try loadConfig("""
        [metrics]
        enabled = ["cpu", "gpu"]
        visible = ["gpu", "cpu"]
        order = ["gpu", "cpu", "memory", "disk", "network"]
        """)
        XCTAssertEqual(config.enabledMetrics, [.cpu, .gpu])
        XCTAssertEqual(config.visibleMetrics, [.cpu, .gpu])
        XCTAssertEqual(config.metricOrder.first, .gpu)
        XCTAssertEqual(config.metricOrder, [.gpu, .cpu, .memory, .disk, .network])
    }

    func testGPUStyleKeysParse() {
        let table = TOMLParser().parse("[metrics]\ngpu_label = \"icon\"\n")
        let styles = TuneConfig.parseMetricStyles(table: table, section: "metrics")
        XCTAssertEqual(styles[.gpu]?.label, .icon)
    }

    // MARK: - Ordering including gpu

    func testOrderingPlacesGPUWhereTheUserPutIt() {
        let order: [MetricIdentifier] = [.gpu, .cpu, .memory, .disk, .network]
        XCTAssertEqual(MetricOrdering.ordered([.cpu, .gpu], order: order), [.gpu, .cpu])
    }

    func testOrderingAppendsAnOptedInMetricAStoredOrderNeverMentioned() {
        // A pre-GPU order still shows the row once gpu is enabled.
        XCTAssertEqual(
            MetricOrdering.ordered([.cpu, .gpu], order: previousDefaults),
            [.cpu, .gpu]
        )
    }

    func testOrderingDoesNotAddGPUWhenItIsNotSelected() {
        XCTAssertEqual(
            MetricOrdering.ordered(Set(previousDefaults), order: previousDefaults),
            previousDefaults
        )
    }

    func testCompletedOrderKeepsExistingPositionsAndAppendsGPU() {
        XCTAssertEqual(
            MetricOrdering.completed([.memory, .cpu, .disk, .network]),
            [.memory, .cpu, .disk, .network, .gpu]
        )
        XCTAssertEqual(
            MetricOrdering.completed([.gpu, .cpu, .memory, .disk, .network]),
            [.gpu, .cpu, .memory, .disk, .network]
        )
        XCTAssertEqual(MetricOrdering.completed([]), [])
    }

    // MARK: - Row formatting: present / absent

    func testStatusItemShowsGPUWhenPublished() {
        let segments = MetricStyleFormatting.statusItemSegments(
            report: report(gpu: 37.4), identifiers: [.cpu, .gpu]
        )
        XCTAssertEqual(MetricStyleFormatting.plainText(segments), "CPU 50%  GPU 37%")
    }

    func testStatusItemSkipsGPUWhenTheMacPublishesNothing() {
        let segments = MetricStyleFormatting.statusItemSegments(
            report: report(gpu: nil), identifiers: [.cpu, .gpu]
        )
        XCTAssertEqual(MetricStyleFormatting.plainText(segments), "CPU 50%")
    }

    func testFallbackValueIsAPercentageOrNil() {
        XCTAssertEqual(MetricFormatting.fallbackValue(.gpu, report: report(gpu: 37.4)), "37%")
        XCTAssertNil(MetricFormatting.fallbackValue(.gpu, report: report(gpu: nil)), "no fake 0 %")
    }

    func testZeroUtilizationIsARealReadingNotAnAbsence() {
        XCTAssertEqual(MetricFormatting.fallbackValue(.gpu, report: report(gpu: 0)), "0%")
        XCTAssertTrue(MetricFormatting.hasData(.gpu, report: report(gpu: 0)))
    }

    func testHasDataFollowsTheGPUBlock() {
        XCTAssertTrue(MetricFormatting.hasData(.gpu, report: report(gpu: 12)))
        XCTAssertFalse(MetricFormatting.hasData(.gpu, report: report(gpu: nil)))
    }

    func testHistoryValueFormatsAsPercentage() {
        XCTAssertEqual(MetricFormatting.value(.gpu, 63.6), "64%")
        let stats = MetricStats(current: 40, min: 10, max: 90)
        let row = MetricFormatting.historyRowValues(.gpu, stats: stats, style: .default)
        XCTAssertEqual(row.current, "40%")
        XCTAssertEqual(row.minimum, "10%")
        XCTAssertEqual(row.maximum, "90%")
    }

    func testCompactStatusItemTextIncludesGPUOnlyWhenPublished() {
        XCTAssertEqual(
            MetricFormatting.statusItemText(report: report(gpu: 37), identifiers: [.gpu]),
            "GPU 37%"
        )
        XCTAssertEqual(
            MetricFormatting.statusItemText(report: report(gpu: nil), identifiers: [.gpu]), ""
        )
    }

    func testStatusItemLabelAndSymbol() {
        XCTAssertEqual(MetricIdentifier.gpu.statusItemLabel, "GPU")
        XCTAssertNotEqual(MetricIdentifier.gpu.statusItemSymbol, MetricIdentifier.cpu.statusItemSymbol)
    }

    // MARK: - History sampling

    func testHistoryRecordsGPUOnlyWhenEnabledAndGapsWhenAbsent() {
        let svc = MetricsHistoryService(capacity: 10)
        svc.ensureBuffers(for: [.cpu])
        svc.record(report(gpu: 50))
        XCTAssertNil(svc.buffer(for: .gpu), "gpu is not sampled unless enabled")

        svc.ensureBuffers(for: [.cpu, .gpu])
        svc.record(report(gpu: 50))
        svc.record(report(gpu: nil))
        svc.record(report(gpu: 0))

        let samples = svc.samples(for: .gpu)
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples[0].value, 50)
        XCTAssertNil(samples[1].value, "an absent reading is a gap, not 0 %")
        XCTAssertEqual(samples[2].value, 0)
        XCTAssertEqual(svc.stats(for: .gpu)?.current, 0)
    }

    // MARK: - HUD

    func testHUDKnowsGPUButNeverShowsItByDefault() {
        XCTAssertTrue(HUDItemKind.allCases.contains(.metric(.gpu)))
        XCTAssertEqual(HUDItemKind.metric(.gpu).displayName, "GPU")
        let layout = HUDItemLayout.default
        XCTAssertFalse(layout.placement(for: .metric(.gpu)).isEnabled)
        for presentation in HUDPresentation.allCases {
            XCTAssertFalse(layout.items(at: presentation).contains(.metric(.gpu)))
        }
    }
}
