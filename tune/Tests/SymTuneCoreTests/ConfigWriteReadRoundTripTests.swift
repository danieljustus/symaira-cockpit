import XCTest
@testable import SymTuneCore

/// The exact document `PreferencesManager` writes must parse back into the
/// same choices — a save that cannot be reloaded is a silent data loss.
final class ConfigWriteReadRoundTripTests: XCTestCase {
    func testWrittenConfigParsesBackIntoTheSameChoices() {
        let written = """
        [brightness]
        dim_min = 0.15

        [metrics]
        refresh_interval_seconds = 3.0
        enabled = ["cpu", "memory"]
        visible = ["cpu"]
        order = ["cpu", "memory", "disk", "network"]
        network_unit = "bytes_per_second"
        temperature_unit = "celsius"
        cpu_label = "icon"
        cpu_scale = "absolute"
        cpu_unit = "full"
        cpu_basis = "free"
        memory_basis = "free"

        [popover]
        cards_version = 2
        cards = ["display_controls", "system_status"]
        """
        let table = TOMLParser().parse(written)

        let styles = TuneConfig.parseMetricStyles(table: table, section: "metrics")
        XCTAssertEqual(styles[.cpu], MetricStyle(label: .icon, scale: .absolute, unit: .full, basis: .free))
        // A basis-only override (no label/scale/unit keys) must still round-trip
        // rather than being silently dropped by the "all axes absent" guard.
        XCTAssertEqual(styles[.memory], MetricStyle(basis: .free))
        XCTAssertNil(styles[.disk])

        // A list written at the current vocabulary version is authoritative:
        // the two cards left out stay out.
        XCTAssertEqual(
            TuneConfig.parseCardSet(table: table),
            [.displayControls, .systemStatus]
        )

        // The unrelated section a user may have hand-written is still readable.
        XCTAssertEqual(table["brightness", "dim_min"]?.doubleValue, 0.15)
    }
}
