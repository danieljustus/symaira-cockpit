import Foundation
@testable import SymTuneCore

/// Mutable battery source so tests can simulate battery level changes
/// (e.g. the charge-limit hysteresis band) between reads.
final class FakeBatterySource: BatterySource, @unchecked Sendable {
    var result: BatterySourceResult

    init(result: BatterySourceResult = .unavailable) {
        self.result = result
    }

    func readProperties() -> BatterySourceResult {
        result
    }
}
