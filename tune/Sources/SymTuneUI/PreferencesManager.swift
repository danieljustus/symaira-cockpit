import SwiftUI
import Combine
import SymTuneCore

/// Observable preferences for the SymTuneApp menu-bar app.
///
/// Reads initial values from ``TuneConfig`` (config.toml) and publishes changes
/// so the status bar and preferences window react instantly. Writes back to
/// `config.toml` when the user applies preferences.
@MainActor
final class PreferencesManager: ObservableObject {
    // MARK: - Published state

    @Published var metricsRefreshInterval: TimeInterval
    @Published var enabledMetrics: Set<MetricIdentifier>
    @Published var visibleMetrics: Set<MetricIdentifier>
    @Published var metricOrder: [MetricIdentifier]
    @Published var networkUnit: NetworkUnit
    @Published var temperatureUnit: TemperatureUnit
    /// Per-metric menu-bar rendering. Metrics absent here use ``MetricStyle/default``.
    @Published var metricStyles: [MetricIdentifier: MetricStyle]
    /// Which cards the popover shows.
    @Published var visibleCards: Set<PopoverCard>

    private let configPaths = ConfigPaths()

    // MARK: - Init

    init(config: TuneConfig = TuneConfig()) {
        self.metricsRefreshInterval = config.metricsRefreshInterval
        self.enabledMetrics = config.enabledMetrics
        self.visibleMetrics = config.visibleMetrics
        self.metricOrder = config.metricOrder
        self.networkUnit = config.networkUnit
        self.temperatureUnit = config.temperatureUnit
        self.metricStyles = config.metricStyles
        self.visibleCards = config.visibleCards
    }

    /// Whether `card` should be rendered, given whether its hardware exists.
    ///
    /// A card the user turned off stays off. A card whose hardware is missing
    /// is hidden by default (see ``PopoverCard/hidesWhenHardwareMissing``) but
    /// still appears if the user explicitly asked for it.
    func showsCard(_ card: PopoverCard, hardwareAvailable: Bool = true) -> Bool {
        guard visibleCards.contains(card) else { return false }
        return hardwareAvailable || !card.hidesWhenHardwareMissing
    }

    /// The style for `metric`, defaulted, as a binding the pickers can drive.
    func style(for metric: MetricIdentifier) -> Binding<MetricStyle> {
        Binding(
            get: { self.metricStyles[metric] ?? .default },
            set: { self.metricStyles[metric] = $0 }
        )
    }

    // MARK: - Snapshot as TuneConfig

    /// Returns the current preferences merged into the given base config.
    func apply(to base: TuneConfig) -> TuneConfig {
        TuneConfig(
            extendedBrightnessMin: base.extendedBrightnessMin,
            extendedBrightnessMax: base.extendedBrightnessMax,
            dimMin: base.dimMin,
            dimMax: base.dimMax,
            brightnessMin: base.brightnessMin,
            brightnessMax: base.brightnessMax,
            fanFractionMin: base.fanFractionMin,
            fanFractionMax: base.fanFractionMax,
            chargeLimitMin: base.chargeLimitMin,
            chargeLimitMax: base.chargeLimitMax,
            defaultProfile: base.defaultProfile,
            mcpMode: base.mcpMode,
            metricsRefreshInterval: metricsRefreshInterval,
            enabledMetrics: enabledMetrics,
            visibleMetrics: visibleMetrics,
            metricOrder: metricOrder,
            networkUnit: networkUnit,
            temperatureUnit: temperatureUnit,
            metricStyles: metricStyles,
            visibleCards: visibleCards
        )
    }

    // MARK: - Persistence

    /// Write current preferences to `config.toml`, preserving other sections.
    func writeToConfig() throws {
        let existingContent: String
        let configFile = configPaths.configFile

        if let data = try? Data(contentsOf: configFile),
           let content = String(data: data, encoding: .utf8) {
            existingContent = content
        } else {
            existingContent = ""
        }

        let updatedContent = mergePopoverSection(into: mergeMetricsSection(into: existingContent))
        try FileManager.default.createDirectory(
            at: configPaths.configDir,
            withIntermediateDirectories: true
        )
        try updatedContent.write(to: configFile, atomically: true, encoding: .utf8)
    }

    /// Merge the `[metrics]` section into the existing TOML content.
    /// If the section already exists, it is replaced; otherwise it is appended.
    private func mergeMetricsSection(into content: String) -> String {
        let metricsTOML = metricsSectionTOML()

        // If content already has a [metrics] section, replace it
        if let range = existingSectionRange(section: "metrics", in: content) {
            var updated = content
            updated.replaceSubrange(range, with: metricsTOML)
            return updated
        }

        // Append to the end, with a blank line separator if needed
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return metricsTOML + "\n"
        }
        return trimmed + "\n\n" + metricsTOML + "\n"
    }

    /// Merge the `[popover]` section into the existing TOML content, replacing
    /// it if present and appending it otherwise.
    private func mergePopoverSection(into content: String) -> String {
        let cards = PopoverCard.allCases
            .filter { visibleCards.contains($0) }
            .map { "\"\($0.rawValue)\"" }
            .joined(separator: ", ")
        // The version marks which card vocabulary this list was written with, so
        // a card turned off here stays off while a card added by a later release
        // still appears (see `TuneConfig.parseCardSet`).
        let popoverTOML = """
        [popover]
        cards_version = \(TuneConfig.popoverCardsSchemaVersion)
        cards = [\(cards)]
        """

        if let range = existingSectionRange(section: "popover", in: content) {
            var updated = content
            updated.replaceSubrange(range, with: popoverTOML)
            return updated
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return popoverTOML + "\n" }
        return trimmed + "\n\n" + popoverTOML + "\n"
    }

    /// Find the range of an existing `[section]` block in TOML content.
    private func existingSectionRange(section: String, in content: String) -> Range<String.Index>? {
        let header = "[\(section)]"
        guard let headerStart = content.range(of: header) else { return nil }

        // Start from the header
        let start = headerStart.lowerBound

        // Find the start of the next section (any [xxx] header after this one)
        let searchStart = headerStart.upperBound
        var end = content.endIndex

        while searchStart < content.endIndex {
            // Find next line starting with '[' that isn't '[['
            let remaining = content[searchStart...]
            let lines = remaining.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") && !trimmed.hasPrefix("[[") && trimmed.hasSuffix("]") {
                    // Found the next section header
                    if let nextHeaderRange = content.range(of: line, range: searchStart..<content.endIndex) {
                        // Back up to before any trailing whitespace/newlines of previous section
                        var scanEnd = nextHeaderRange.lowerBound
                        while scanEnd > start, content[content.index(before: scanEnd)].isNewline {
                            scanEnd = content.index(before: scanEnd)
                        }
                        end = scanEnd
                        return start..<end
                    }
                }
            }
            break
        }

        // No following section — take everything to the end
        // Trim trailing newlines
        while end > start, content[content.index(before: end)].isNewline {
            end = content.index(before: end)
        }

        return start..<end
    }

    /// Build the TOML `[metrics]` section from current preferences.
    private func metricsSectionTOML() -> String {
        var lines = ["[metrics]"]

        lines.append("refresh_interval_seconds = \(metricsRefreshInterval)")

        let enabledStr = metricOrder
            .filter { enabledMetrics.contains($0) }
            .map { "\"\($0.rawValue)\"" }
            .joined(separator: ", ")
        lines.append("enabled = [\(enabledStr)]")

        let visibleStr = metricOrder
            .filter { visibleMetrics.contains($0) }
            .map { "\"\($0.rawValue)\"" }
            .joined(separator: ", ")
        lines.append("visible = [\(visibleStr)]")

        let orderStr = metricOrder
            .map { "\"\($0.rawValue)\"" }
            .joined(separator: ", ")
        lines.append("order = [\(orderStr)]")

        lines.append("network_unit = \"\(networkUnit.rawValue)\"")
        lines.append("temperature_unit = \"\(temperatureUnit.rawValue)\"")

        // Per-metric style, flat keys so the whole section stays one block.
        // Only non-default metrics are written — an untouched config keeps a
        // short, readable [metrics] section.
        for metric in metricOrder {
            guard let style = metricStyles[metric], style != .default else { continue }
            lines.append("\(metric.rawValue)_label = \"\(style.label.rawValue)\"")
            lines.append("\(metric.rawValue)_scale = \"\(style.scale.rawValue)\"")
            lines.append("\(metric.rawValue)_unit = \"\(style.unit.rawValue)\"")
            lines.append("\(metric.rawValue)_basis = \"\(style.basis.rawValue)\"")
        }

        return lines.joined(separator: "\n")
    }
}
