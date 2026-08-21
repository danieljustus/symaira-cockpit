import Foundation

/// XDG-style path resolution, matching the ecosystem convention
/// (`~/.config/sym{name}/`, `~/.cache/sym{name}/`, `~/.local/share/sym{name}/`).
/// Honors `XDG_CONFIG_HOME` / `XDG_CACHE_HOME` / `XDG_DATA_HOME` overrides.
public struct ConfigPaths: Sendable {
    public let configDir: URL
    public let cacheDir: URL
    public let dataDir: URL

    public init(
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: URL? = nil
    ) {
        let effectiveHome: URL
        if let home {
            effectiveHome = home
        } else if geteuid() == 0, let sudoUser = env["SUDO_USER"], let pwd = getpwnam(sudoUser) {
            effectiveHome = URL(fileURLWithPath: String(cString: pwd.pointee.pw_dir), isDirectory: true)
        } else {
            effectiveHome = FileManager.default.homeDirectoryForCurrentUser
        }

        func base(_ envKey: String, _ fallback: String) -> URL {
            if let value = env[envKey], !value.isEmpty {
                return URL(fileURLWithPath: value, isDirectory: true)
            }
            return effectiveHome.appendingPathComponent(fallback, isDirectory: true)
        }
        self.configDir = base("XDG_CONFIG_HOME", ".config")
            .appendingPathComponent("symtune", isDirectory: true)
        self.cacheDir = base("XDG_CACHE_HOME", ".cache")
            .appendingPathComponent("symtune", isDirectory: true)
        self.dataDir = base("XDG_DATA_HOME", ".local/share")
            .appendingPathComponent("symtune", isDirectory: true)
    }

    public var configFile: URL { configDir.appendingPathComponent("config.toml") }

    /// Load a `TuneConfig` from this path's `config.toml`, applying
    /// `SYMTUNE_*` environment overrides. Missing or malformed files
    /// silently fall back to defaults.
    public func loadConfig(
        env: [String: String] = ProcessInfo.processInfo.environment,
        parser: TOMLParser = TOMLParser()
    ) -> TuneConfig {
        TuneConfig.load(paths: self, env: env, parser: parser)
    }
}

// MARK: - Metric Identifiers

/// Identifies a system metric category.
/// The four base categories map to fields of ``SystemMetricsReport``.
public struct MetricIdentifier: RawRepresentable, Hashable, Codable, Sendable, CaseIterable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let cpu = MetricIdentifier(rawValue: "cpu")
    public static let memory = MetricIdentifier(rawValue: "memory")
    public static let disk = MetricIdentifier(rawValue: "disk")
    public static let network = MetricIdentifier(rawValue: "network")

    public static var allCases: [MetricIdentifier] { [.cpu, .memory, .disk, .network] }

    public var displayName: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .disk: return "Disk"
        case .network: return "Network"
        default: return rawValue
        }
    }
}

/// Unit preference for network throughput display.
public enum NetworkUnit: String, CaseIterable, Sendable {
    case bytesPerSecond = "bytes_per_second"
    case bitsPerSecond = "bits_per_second"

    public var displayName: String {
        switch self {
        case .bytesPerSecond: return "Bytes/s"
        case .bitsPerSecond: return "Bits/s"
        }
    }
}

/// Unit preference for temperature display.
public enum TemperatureUnit: String, CaseIterable, Sendable {
    case celsius
    case fahrenheit

    public var displayName: String {
        switch self {
        case .celsius: return "°C"
        case .fahrenheit: return "°F"
        }
    }
}

// MARK: - TuneConfig

/// User-tunable configuration for symtune, loaded from `config.toml` with
/// `SYMTUNE_*` env overrides taking precedence over file values. Defaults
/// match `SafetyPolicy` constants.
public struct TuneConfig: Equatable, Sendable {
    // MARK: - Brightness / Fan / Charge bounds

    public let extendedBrightnessMin: Double
    public let extendedBrightnessMax: Double
    public let dimMin: Double
    public let dimMax: Double
    public let brightnessMin: Double
    public let brightnessMax: Double
    public let fanFractionMin: Double
    public let fanFractionMax: Double
    public let chargeLimitMin: Int
    public let chargeLimitMax: Int
    /// Charging is re-allowed only once the battery has dropped this many
    /// percent below the target (band control instead of a single threshold).
    public let chargeLimitHysteresisPercent: Int
    public let defaultProfile: String
    public let mcpMode: String

    // MARK: - Metrics preferences

    /// Refresh interval in seconds. Clamped to a documented minimum of 1.0 s.
    public let metricsRefreshInterval: TimeInterval

    /// Which metrics the service should sample.
    public let enabledMetrics: Set<MetricIdentifier>

    /// Which metrics to show in the menu bar / popover.
    public let visibleMetrics: Set<MetricIdentifier>

    /// Display order for visible metrics (menu bar / popover).
    public let metricOrder: [MetricIdentifier]

    /// Network throughput display unit.
    public let networkUnit: NetworkUnit

    /// Temperature display unit.
    public let temperatureUnit: TemperatureUnit

    /// Per-metric menu-bar rendering options. Metrics absent from the map use
    /// ``MetricStyle/default``, so an untouched config behaves as before.
    public let metricStyles: [MetricIdentifier: MetricStyle]

    /// Which cards the status popover shows.
    public let visibleCards: Set<PopoverCard>

    /// Documented minimum refresh interval (seconds).
    public static let minimumRefreshInterval: TimeInterval = 1.0

    /// Default metrics order.
    public static let defaultMetricOrder: [MetricIdentifier] = MetricIdentifier.allCases

    public var isMCPReadOnly: Bool {
        let mode = mcpMode.lowercased()
        return mode == "read-only" || mode == "read_only" || mode == "readonly"
    }

    public init(
        extendedBrightnessMin: Double = SafetyPolicy.extendedBrightnessMin,
        extendedBrightnessMax: Double = SafetyPolicy.extendedBrightnessMax,
        dimMin: Double = SafetyPolicy.dimMin,
        dimMax: Double = SafetyPolicy.dimMax,
        brightnessMin: Double = SafetyPolicy.brightnessMin,
        brightnessMax: Double = SafetyPolicy.brightnessMax,
        fanFractionMin: Double = SafetyPolicy.fanFractionMin,
        fanFractionMax: Double = SafetyPolicy.fanFractionMax,
        chargeLimitMin: Int = SafetyPolicy.chargeLimitMin,
        chargeLimitMax: Int = SafetyPolicy.chargeLimitMax,
        chargeLimitHysteresisPercent: Int = SafetyPolicy.chargeLimitHysteresis,
        defaultProfile: String = "default",
        mcpMode: String = "full",
        metricsRefreshInterval: TimeInterval = 3.0,
        enabledMetrics: Set<MetricIdentifier> = Set(MetricIdentifier.allCases),
        visibleMetrics: Set<MetricIdentifier> = Set(MetricIdentifier.allCases),
        metricOrder: [MetricIdentifier] = MetricIdentifier.allCases,
        networkUnit: NetworkUnit = .bytesPerSecond,
        temperatureUnit: TemperatureUnit = .celsius,
        metricStyles: [MetricIdentifier: MetricStyle] = [:],
        visibleCards: Set<PopoverCard> = Set(PopoverCard.allCases)
    ) {
        self.extendedBrightnessMin = extendedBrightnessMin
        self.extendedBrightnessMax = extendedBrightnessMax
        self.dimMin = dimMin
        self.dimMax = dimMax
        self.brightnessMin = brightnessMin
        self.brightnessMax = brightnessMax
        self.fanFractionMin = fanFractionMin
        self.fanFractionMax = fanFractionMax
        self.chargeLimitMin = chargeLimitMin
        self.chargeLimitMax = chargeLimitMax
        self.chargeLimitHysteresisPercent = chargeLimitHysteresisPercent
        self.defaultProfile = defaultProfile
        self.mcpMode = mcpMode
        self.metricsRefreshInterval = max(metricsRefreshInterval, TuneConfig.minimumRefreshInterval)
        self.enabledMetrics = enabledMetrics
        self.visibleMetrics = visibleMetrics
        self.metricOrder = metricOrder
        self.networkUnit = networkUnit
        self.temperatureUnit = temperatureUnit
        self.metricStyles = metricStyles
        self.visibleCards = visibleCards
    }

    // MARK: - Loading

    /// Load config from disk (if present) and apply env overrides.
    /// Missing file or parse errors silently return defaults.
    public static func load(
        paths: ConfigPaths = ConfigPaths(),
        env: [String: String] = ProcessInfo.processInfo.environment,
        parser: TOMLParser = TOMLParser()
    ) -> TuneConfig {
        // Parse config file (empty table on missing / unreadable)
        var table = TOMLTable()
        if let data = try? Data(contentsOf: paths.configFile),
           let content = String(data: data, encoding: .utf8) {
            table = parser.parse(content)
        }

        // Helper: env override wins over TOML, then fallback
        func doubleVal(_ section: String, _ key: String,
                       _ envKey: String, _ fallback: Double) -> Double {
            if let raw = env[envKey], !raw.isEmpty, let d = Double(raw) { return d }
            if let val = table[section, key]?.doubleValue { return val }
            return fallback
        }
        func intVal(_ section: String, _ key: String,
                    _ envKey: String, _ fallback: Int) -> Int {
            if let raw = env[envKey], !raw.isEmpty, let i = Int(raw) { return i }
            if let val = table[section, key]?.intValue { return val }
            return fallback
        }
        func stringVal(_ section: String, _ key: String,
                       _ envKey: String, _ fallback: String) -> String {
            if let raw = env[envKey], !raw.isEmpty { return raw }
            if let val = table[section, key]?.stringValue { return val }
            return fallback
        }

        /// Parse a set of `MetricIdentifier` from TOML (array or comma-separated string).
        func metricSetVal(_ section: String, _ key: String,
                          _ fallback: [MetricIdentifier]) -> Set<MetricIdentifier> {
            Self.parseMetricSet(table: table, section: section, key: key, fallback: fallback)
        }

        /// Parse an ordered list of `MetricIdentifier` from TOML.
        func metricOrderVal(_ section: String, _ key: String,
                            _ fallback: [MetricIdentifier]) -> [MetricIdentifier] {
            Self.parseMetricOrder(table: table, section: section, key: key, fallback: fallback)
        }

        /// Parse a `NetworkUnit` from string value.
        func networkUnitVal(_ section: String, _ key: String,
                            _ fallback: NetworkUnit) -> NetworkUnit {
            Self.parseNetworkUnit(table: table, section: section, key: key, fallback: fallback)
        }

        /// Parse a `TemperatureUnit` from string value.
        func temperatureUnitVal(_ section: String, _ key: String,
                                _ fallback: TemperatureUnit) -> TemperatureUnit {
            Self.parseTemperatureUnit(table: table, section: section, key: key, fallback: fallback)
        }

        var config = TuneConfig(
            extendedBrightnessMin: doubleVal(
                "brightness", "extended_brightness_min",
                "SYMTUNE_EXTBRIGHT_MIN", SafetyPolicy.extendedBrightnessMin),
            extendedBrightnessMax: doubleVal(
                "brightness", "extended_brightness_max",
                "SYMTUNE_EXTBRIGHT_MAX", SafetyPolicy.extendedBrightnessMax),
            dimMin: doubleVal(
                "brightness", "dim_min",
                "SYMTUNE_DIM_MIN", SafetyPolicy.dimMin),
            dimMax: doubleVal(
                "brightness", "dim_max",
                "SYMTUNE_DIM_MAX", SafetyPolicy.dimMax),
            brightnessMin: doubleVal(
                "brightness", "brightness_min",
                "SYMTUNE_BRIGHTNESS_MIN", SafetyPolicy.brightnessMin),
            brightnessMax: doubleVal(
                "brightness", "brightness_max",
                "SYMTUNE_BRIGHTNESS_MAX", SafetyPolicy.brightnessMax),
            fanFractionMin: doubleVal(
                "fan", "fan_fraction_min",
                "SYMTUNE_FAN_MIN", SafetyPolicy.fanFractionMin),
            fanFractionMax: doubleVal(
                "fan", "fan_fraction_max",
                "SYMTUNE_FAN_MAX", SafetyPolicy.fanFractionMax),
            chargeLimitMin: intVal(
                "charge", "charge_limit_min",
                "SYMTUNE_CHARGE_MIN", SafetyPolicy.chargeLimitMin),
            chargeLimitMax: intVal(
                "charge", "charge_limit_max",
                "SYMTUNE_CHARGE_MAX", SafetyPolicy.chargeLimitMax),
            chargeLimitHysteresisPercent: intVal("charge", "limit_hysteresis_percent", "SYMTUNE_CHARGE_HYSTERESIS", SafetyPolicy.chargeLimitHysteresis),
            defaultProfile: stringVal("general", "default_profile", "SYMTUNE_DEFAULT_PROFILE", "default"),
            mcpMode: stringVal("mcp", "mode", "SYMTUNE_MCP_MODE", "full"),
            // --- Metrics preferences ---
            metricsRefreshInterval: doubleVal(
                "metrics", "refresh_interval_seconds",
                "SYMTUNE_METRICS_INTERVAL", 3.0),
            enabledMetrics: metricSetVal("metrics", "enabled", MetricIdentifier.allCases),
            visibleMetrics: metricSetVal("metrics", "visible", MetricIdentifier.allCases),
            metricOrder: metricOrderVal("metrics", "order", MetricIdentifier.allCases),
            networkUnit: networkUnitVal("metrics", "network_unit", .bytesPerSecond),
            temperatureUnit: temperatureUnitVal("metrics", "temperature_unit", .celsius),
            metricStyles: Self.parseMetricStyles(table: table, section: "metrics"),
            visibleCards: Self.parseCardSet(table: table)
        )

        // Clamp user-defined bounds to the non-negotiable SafetyPolicy hard limits.
        config = TuneConfig(
            extendedBrightnessMin: max(config.extendedBrightnessMin, SafetyPolicy.extendedBrightnessMin),
            extendedBrightnessMax: min(config.extendedBrightnessMax, SafetyPolicy.extendedBrightnessMax),
            dimMin: max(config.dimMin, SafetyPolicy.dimMin),
            dimMax: min(config.dimMax, SafetyPolicy.dimMax),
            brightnessMin: max(config.brightnessMin, SafetyPolicy.brightnessMin),
            brightnessMax: min(config.brightnessMax, SafetyPolicy.brightnessMax),
            fanFractionMin: max(config.fanFractionMin, SafetyPolicy.fanFractionMin),
            fanFractionMax: min(config.fanFractionMax, SafetyPolicy.fanFractionMax),
            chargeLimitMin: max(config.chargeLimitMin, SafetyPolicy.chargeLimitMin),
            chargeLimitMax: min(config.chargeLimitMax, SafetyPolicy.chargeLimitMax),
            chargeLimitHysteresisPercent: SafetyPolicy.clamp(config.chargeLimitHysteresisPercent, 1, SafetyPolicy.chargeLimitHysteresisMax),
            defaultProfile: config.defaultProfile,
            mcpMode: config.mcpMode,
            metricsRefreshInterval: config.metricsRefreshInterval,
            enabledMetrics: config.enabledMetrics,
            visibleMetrics: config.visibleMetrics,
            metricOrder: config.metricOrder,
            networkUnit: config.networkUnit,
            temperatureUnit: config.temperatureUnit,
            metricStyles: config.metricStyles,
            visibleCards: config.visibleCards
        )

        // Validate min < max for each range; fall back to defaults on inversion.
        let rangesValid =
            config.extendedBrightnessMin < config.extendedBrightnessMax
            && config.dimMin < config.dimMax
            && config.brightnessMin < config.brightnessMax
            && config.fanFractionMin < config.fanFractionMax
            && config.chargeLimitMin < config.chargeLimitMax

        if !rangesValid {
            fputs("symtune: config error: inverted min/max range detected, falling back to defaults\n", stderr)
            config = TuneConfig()
        }

        return config
    }

    // MARK: - Parse helpers (static, extracted to keep `load` body under limit)

    /// Read per-metric style keys out of `[metrics]`.
    ///
    /// Flat keys (`cpu_label`, `memory_scale`, ...) rather than a nested table
    /// per metric: it matches the existing `[metrics]` keys and keeps the
    /// section rewritable as one block when preferences are saved.
    static func parseMetricStyles(
        table: TOMLTable, section: String
    ) -> [MetricIdentifier: MetricStyle] {
        var styles: [MetricIdentifier: MetricStyle] = [:]

        for metric in MetricIdentifier.allCases {
            let id = metric.rawValue
            let label = table[section, "\(id)_label"]?.stringValue
                .flatMap(MetricStyle.LabelStyle.init(rawValue:))
            let scale = table[section, "\(id)_scale"]?.stringValue
                .flatMap(MetricStyle.ValueScale.init(rawValue:))
            let unit = table[section, "\(id)_unit"]?.stringValue
                .flatMap(MetricStyle.UnitStyle.init(rawValue:))
            let basis = table[section, "\(id)_basis"]?.stringValue
                .flatMap(MetricStyle.MetricBasis.init(rawValue:))

            guard label != nil || scale != nil || unit != nil || basis != nil else { continue }

            styles[metric] = MetricStyle(
                label: label ?? MetricStyle.default.label,
                scale: scale ?? MetricStyle.default.scale,
                unit: unit ?? MetricStyle.default.unit,
                basis: basis ?? MetricStyle.default.basis
            )
        }

        return styles
    }

    /// Parse the popover card set. An explicit empty list is honoured — a user
    /// who turned every card off gets an empty panel, not a silent reset.
    ///
    /// A list written *before a card existed* cannot be an opinion about that
    /// card, so cards newer than the stored vocabulary are added rather than
    /// silently hidden by every pre-existing config. `cards_version` marks which
    /// vocabulary the writer had: at the current version the list is
    /// authoritative, so turning a card off keeps it off.
    ///
    /// Adding a card therefore means: add it to ``PopoverCard/allCases``, add it
    /// to ``cardVocabulary`` for the *next* version, and bump
    /// ``popoverCardsSchemaVersion``.
    static func parseCardSet(
        table: TOMLTable, section: String = "popover", key: String = "cards",
        fallback: [PopoverCard] = PopoverCard.allCases
    ) -> Set<PopoverCard> {
        guard let arr = table[section, key]?.stringArrayValue else { return Set(fallback) }
        let known = Set(PopoverCard.allCases.map(\.rawValue))
        var cards = Set(arr.filter { known.contains($0) }.map(PopoverCard.init(rawValue:)))

        // Empty means "show nothing", whatever the version.
        guard !arr.isEmpty else { return cards }

        let version = table[section, "cards_version"]?.intValue ?? 1
        guard version < popoverCardsSchemaVersion else { return cards }
        let vocabulary = cardVocabulary(version: version)
        for card in PopoverCard.allCases where !vocabulary.contains(card.rawValue) {
            cards.insert(card)
        }
        return cards
    }

    /// Current `[popover] cards` vocabulary version, written alongside the list.
    public static let popoverCardsSchemaVersion = 2

    /// Card identifiers a writer at `version` could name. Version 1 is the
    /// unversioned list that shipped through v0.9.1.
    static func cardVocabulary(version: Int) -> Set<String> {
        let v1: Set<String> = [
            "display_controls", "keep_awake", "fan_control",
            "system_status", "metrics_history", "displays",
        ]
        guard version >= 2 else { return v1 }
        return Set(PopoverCard.allCases.map(\.rawValue))
    }

    private static func parseMetricSet(
        table: TOMLTable, section: String, key: String,
        fallback: [MetricIdentifier]
    ) -> Set<MetricIdentifier> {
        if let arr = table[section, key]?.stringArrayValue {
            let values = arr.compactMap { MetricIdentifier(rawValue: $0) }
            if values.isEmpty { return Set(fallback) }
            return Set(values)
        }
        return Set(fallback)
    }

    private static func parseMetricOrder(
        table: TOMLTable, section: String, key: String,
        fallback: [MetricIdentifier]
    ) -> [MetricIdentifier] {
        if let arr = table[section, key]?.stringArrayValue {
            let values = arr.compactMap { MetricIdentifier(rawValue: $0) }
            if values.isEmpty { return fallback }
            return values
        }
        return fallback
    }

    private static func parseNetworkUnit(
        table: TOMLTable, section: String, key: String,
        fallback: NetworkUnit
    ) -> NetworkUnit {
        if let raw = table[section, key]?.stringValue,
           let unit = NetworkUnit(rawValue: raw) {
            return unit
        }
        return fallback
    }

    private static func parseTemperatureUnit(
        table: TOMLTable, section: String, key: String,
        fallback: TemperatureUnit
    ) -> TemperatureUnit {
        if let raw = table[section, key]?.stringValue,
           let unit = TemperatureUnit(rawValue: raw) {
            return unit
        }
        return fallback
    }
}
