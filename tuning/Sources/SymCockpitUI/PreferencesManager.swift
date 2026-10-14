import SwiftUI
import Combine
import SymCockpitCore

/// Observable preferences for the SymCockpitMenuBarApp menu-bar app.
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
    /// Whether the status item appends the current ISO-8601 calendar week.
    @Published var showCalendarWeek: Bool
    /// Which cards the popover shows.
    @Published var visibleCards: Set<PopoverCard>

    /// GUI-only selection, saved immediately without changing CLI/MCP discovery.
    @Published var hiddenStorageVolumeIDs: Set<String> {
        didSet {
            defaults.set(hiddenStorageVolumeIDs.sorted(), forKey: Self.hiddenStorageVolumeIDsKey)
        }
    }

    static let hiddenStorageVolumeIDsKey = "com.symaira.symtune.hiddenStorageVolumes"
    private let defaults: UserDefaults

    private let configPaths: ConfigPaths

    // MARK: - Init

    init(
        config: TuneConfig = TuneConfig(),
        defaults: UserDefaults = .standard,
        configPaths: ConfigPaths = ConfigPaths()
    ) {
        self.configPaths = configPaths
        self.defaults = defaults
        self.hiddenStorageVolumeIDs = Set(defaults.stringArray(forKey: Self.hiddenStorageVolumeIDsKey) ?? [])
        self.metricsRefreshInterval = config.metricsRefreshInterval
        self.enabledMetrics = config.enabledMetrics
        self.visibleMetrics = config.visibleMetrics
        self.metricOrder = config.metricOrder
        self.networkUnit = config.networkUnit
        self.temperatureUnit = config.temperatureUnit
        self.metricStyles = config.metricStyles
        self.showCalendarWeek = config.showCalendarWeek
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

    /// The same binding is used by every panel. Detached-volume choices remain
    /// stored, while a newly discovered volume is shown unless explicitly hidden.
    func storageVolumeVisibility(for volume: StorageVolumeReport) -> Binding<Bool> {
        Binding(
            get: { !self.hiddenStorageVolumeIDs.contains(volume.selectionID) },
            set: { visible in
                if visible {
                    self.hiddenStorageVolumeIDs.remove(volume.selectionID)
                } else {
                    self.hiddenStorageVolumeIDs.insert(volume.selectionID)
                }
            }
        )
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
            showCalendarWeek: showCalendarWeek,
            visibleCards: visibleCards
        )
    }

    // MARK: - Persistence

    /// Write current preferences to `config.toml`, preserving other sections.
    func writeToConfig() throws {
        let existingContent: String
        let configFile = configPaths.configFile

        do {
            existingContent = try String(contentsOf: configFile, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
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
        // Match whole header lines, never examples inside comments or strings.
        // Inline comments and array-of-table headers also end the current block.
        let pattern = #"(?m)^[\t ]*\[([^\r\n]+?)\][\t ]*(?:#[^\r\n]*)?\r?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let headers = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
        guard let index = headers.firstIndex(where: { match in
            guard let name = Range(match.range(at: 1), in: content) else { return false }
            return content[name].trimmingCharacters(in: .whitespaces) == section
        }), let header = Range(headers[index].range, in: content) else { return nil }

        let start = header.lowerBound
        var end = content.endIndex
        if index + 1 < headers.count, let next = Range(headers[index + 1].range, in: content) {
            end = next.lowerBound
        }
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
        lines.append("show_calendar_week = \(showCalendarWeek)")

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
