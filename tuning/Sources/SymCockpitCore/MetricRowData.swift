import Foundation

/// A prepared row of the metrics-history card.
///
/// Formatting and min/max aggregation happen once per refresh in
/// ``TuneViewModel``, not once per SwiftUI body evaluation. `Equatable` lets
/// the card skip re-rendering entirely while the numbers stand still.
public struct MetricRowData: Identifiable, Equatable, Sendable {
    public let id: MetricIdentifier
    public let title: String
    public let current: String
    public let minimum: String
    public let maximum: String
    public let samples: [MetricSample]

    public init(
        id: MetricIdentifier,
        title: String,
        current: String,
        minimum: String,
        maximum: String,
        samples: [MetricSample]
    ) {
        self.id = id
        self.title = title
        self.current = current
        self.minimum = minimum
        self.maximum = maximum
        self.samples = samples
    }
}

/// Orders the selected metrics for display.
///
/// The user can reorder metrics in Preferences; the history card and the
/// status item both render the enabled metrics in that order. Extracted from
/// the app's view model so the ordering rule is unit-testable.
public enum MetricOrdering {

    /// The metrics in `order` that are also in `selected`, preserving `order`.
    ///
    /// Falls back to `fallback` when nothing is selected or no order is
    /// configured — the status item then shows its default metrics instead of
    /// an empty readout.
    public static func ordered(
        _ selected: Set<MetricIdentifier>,
        order: [MetricIdentifier],
        fallback: [MetricIdentifier] = []
    ) -> [MetricIdentifier] {
        guard !selected.isEmpty, !order.isEmpty else { return fallback }
        return order.filter { selected.contains($0) }
    }
}
