import Foundation

// All structs are `Codable`. The CLI and MCP layers encode them with
// `.convertToSnakeCase`, so a property `thermalPressure` is emitted as
// `thermal_pressure` for agent-friendly JSON.

// MARK: - Sensors

public struct SensorReading: Codable, Sendable, Equatable {
    public let key: String
    public let label: String
    public let celsius: Double

    public init(key: String, label: String, celsius: Double) {
        self.key = key
        self.label = label
        self.celsius = celsius
    }
}

public struct FanReading: Codable, Sendable, Equatable {
    public let index: Int
    public let label: String
    public let rpm: Int
    public let minRpm: Int?
    public let maxRpm: Int?

    public init(index: Int, label: String, rpm: Int, minRpm: Int?, maxRpm: Int?) {
        self.index = index
        self.label = label
        self.rpm = rpm
        self.minRpm = minRpm
        self.maxRpm = maxRpm
    }
}

public struct SensorReport: Codable, Sendable, Equatable {
    /// `nominal` | `fair` | `serious` | `critical` | `unknown`
    public let thermalPressure: String
    public let smcSupported: Bool
    public let temperatures: [SensorReading]
    public let fans: [FanReading]
    public let notes: [String]
}

// MARK: - Battery

public struct BatteryReport: Codable, Sendable, Equatable {
    public let present: Bool
    public let charging: Bool?
    public let externalConnected: Bool?
    public let currentCapacityPercent: Int?
    public let cycleCount: Int?
    public let designCapacityMah: Int?
    public let maxCapacityMah: Int?
    /// maxCapacity / designCapacity, in percent. ~100 on a healthy battery.
    public let healthPercent: Int?
    public let temperatureCelsius: Double?
    /// Apple's own whole-percent figure from `system_profiler
    /// SPPowerDataType` ("Maximum Capacity", as shown in System Settings).
    /// Absent when the block cannot be read or parsed. This legitimately
    /// differs from `healthPercent` — see the README's battery section.
    public let appleMaximumCapacityPercent: Int?
    /// Apple's own "Condition" verdict from the same source (e.g. "Normal",
    /// "Replace Soon"). Absent when the block cannot be read or parsed.
    public let appleCondition: String?
    /// Whether the SMC exposes a charge-limit key on this Mac. This depends on
    /// the platform key probe (CHTE/CH0B/CHLC) and an SMC connection.
    public let chargeLimitSupported: Bool
    public let notes: [String]

    public init(
        present: Bool,
        charging: Bool?,
        externalConnected: Bool?,
        currentCapacityPercent: Int?,
        cycleCount: Int?,
        designCapacityMah: Int?,
        maxCapacityMah: Int?,
        healthPercent: Int?,
        temperatureCelsius: Double?,
        appleMaximumCapacityPercent: Int? = nil,
        appleCondition: String? = nil,
        chargeLimitSupported: Bool,
        notes: [String]
    ) {
        self.present = present
        self.charging = charging
        self.externalConnected = externalConnected
        self.currentCapacityPercent = currentCapacityPercent
        self.cycleCount = cycleCount
        self.designCapacityMah = designCapacityMah
        self.maxCapacityMah = maxCapacityMah
        self.healthPercent = healthPercent
        self.temperatureCelsius = temperatureCelsius
        self.appleMaximumCapacityPercent = appleMaximumCapacityPercent
        self.appleCondition = appleCondition
        self.chargeLimitSupported = chargeLimitSupported
        self.notes = notes
    }
}

// MARK: - Displays

public struct DisplayInfo: Codable, Sendable, Equatable {
    public let name: String
    public let displayID: UInt32
    public let isBuiltin: Bool?
    /// Current max EDR headroom (1.0 = no extended range available right now).
    public let maxEDRHeadroom: Double
    /// Headroom the panel *could* provide (drives the extended-brightness cap).
    public let potentialEDRHeadroom: Double
    public let edrCapable: Bool
    public let backingScaleFactor: Double
}

public struct DisplaysReport: Codable, Sendable, Equatable {
    public let displays: [DisplayInfo]
    public let notes: [String]
}

public struct BrightnessReadback: Codable, Sendable {
    public let brightness: Double
    public let notes: [String]

    public init(brightness: Double, notes: [String] = []) {
        self.brightness = brightness
        self.notes = notes
    }
}

public struct ApplyResult: Codable, Sendable {
    public let applied: Bool

    public init(applied: Bool) {
        self.applied = applied
    }
}

public struct ProfileSaved: Codable, Sendable {
    public let saved: String

    public init(saved: String) {
        self.saved = saved
    }
}

public struct ProfileList: Codable, Sendable {
    public let profiles: [TuneProfile]

    public init(profiles: [TuneProfile]) {
        self.profiles = profiles
    }
}

// MARK: - Capabilities (doctor)

public struct Capability: Codable, Sendable {
    public let id: String
    public let available: Bool
    /// Capability tier: `core` for features shipped in the open binary.
    /// The previous `pro` tier has been removed; all features live in core.
    public let tier: String
    public let detail: String
}

public struct PermissionStatus: Codable, Sendable {
    /// True when the SMC connection is open. Fan and charge-limit writes still
    /// require the process to run with root privileges.
    public let privilegedHelperInstalled: Bool
    public let historyWritable: Bool?
    public let mcpMode: String?
    public let notes: [String]

    public init(privilegedHelperInstalled: Bool, historyWritable: Bool? = nil, mcpMode: String? = nil, notes: [String]) {
        self.privilegedHelperInstalled = privilegedHelperInstalled
        self.historyWritable = historyWritable
        self.mcpMode = mcpMode
        self.notes = notes
    }
}

public struct CapabilityReport: Codable, Sendable {
    public let tool: String
    public let version: String
    public let macosVersion: String
    public let architecture: String
    public let capabilities: [Capability]
    public let permissions: PermissionStatus
    public let recommendations: [String]
}

// MARK: - Active Overrides

/// Enforcement state of a charge limit as verified against the SMC.
/// On Apple Silicon the inhibit bit is volatile and resets on sleep, so a
/// tracked limit can silently stop being enforced; `lapsed` reports exactly
/// that discrepancy instead of pretending the limit is still in force.
public enum ChargeLimitEnforcementState: String, Codable, Sendable, Equatable {
    /// The hardware still reports the inhibit bit / value we applied.
    case active
    /// A limit is configured but the hardware no longer enforces it.
    case lapsed
}

public struct ActiveOverrides: Codable, Sendable, Equatable {
    public let brightness: Double?
    public let dim: Double?
    public let warmth: Double?
    public let edrBrightness: Double?
    /// Active uniform fan fraction when fans are in manual mode.
    public let fanFraction: Double?
    /// Configured charge limit percent (the value this process applied),
    /// while a limit is set. Reported regardless of enforcement so a lapsed
    /// limit stays visible.
    public let chargeLimitPercent: Int?
    /// `active` when the SMC still enforces the configured limit, `lapsed`
    /// when it does not, `nil` when no limit is configured.
    public let chargeLimitState: ChargeLimitEnforcementState?

    public init(
        brightness: Double? = nil,
        dim: Double? = nil,
        warmth: Double? = nil,
        edrBrightness: Double? = nil,
        fanFraction: Double? = nil,
        chargeLimitPercent: Int? = nil,
        chargeLimitState: ChargeLimitEnforcementState? = nil
    ) {
        self.brightness = brightness
        self.dim = dim
        self.warmth = warmth
        self.edrBrightness = edrBrightness
        self.fanFraction = fanFraction
        self.chargeLimitPercent = chargeLimitPercent
        self.chargeLimitState = chargeLimitState
    }
}

/// How an extended-brightness boost is being produced.
public enum ExtendedBrightnessMode: String, Codable, Sendable, Equatable {
    /// EDR is engaged: output above SDR white renders brighter, up to the
    /// headroom the display granted. This is the real thing.
    case extendedRange
    /// No EDR headroom available, so the gamma lift is applied on its own: the
    /// picture brightens but the brightest areas clip. Capped well below the
    /// EDR maximum for that reason.
    case softwareLift
}

/// What extended ("beyond 100%") brightness is doing on the built-in display.
///
/// Four separate facts, because they routinely differ: what was asked for, what
/// is in effect, how it is being produced, and what the panel currently allows.
public struct ExtendedBrightnessStatus: Codable, Sendable, Equatable {
    /// Multiplier the user or an agent asked for (`nil` when neutral).
    public let requested: Double?
    /// Multiplier currently written to the display (`nil` when nothing is).
    public let effective: Double?
    /// How ``effective`` is produced (`nil` when nothing is applied).
    public let mode: ExtendedBrightnessMode?
    /// Headroom the system grants right now (`1.0` = SDR only).
    public let availableHeadroom: Double?
    /// Whether any attached display can do extended brightness at all.
    public let isSupported: Bool

    /// A boost is requested, but EDR has not engaged — the display is being
    /// lifted in software (or not at all) rather than driven above SDR white.
    public var isWaitingForEDR: Bool {
        requested != nil && mode != .extendedRange
    }

    public init(
        requested: Double?,
        effective: Double?,
        mode: ExtendedBrightnessMode? = nil,
        availableHeadroom: Double?,
        isSupported: Bool
    ) {
        self.requested = requested
        self.effective = effective
        self.mode = mode
        self.availableHeadroom = availableHeadroom
        self.isSupported = isSupported
    }
}

// MARK: - Status Report

public struct StatusReport: Codable, Sendable {
    public let healthScore: Int
    public let healthScoreMsg: String
    public let recommendations: [String]
    public let activeOverrides: ActiveOverrides
    public let sensors: SensorReport
    public let battery: BatteryReport
    public let displays: DisplaysReport

    public init(
        healthScore: Int,
        healthScoreMsg: String,
        recommendations: [String],
        activeOverrides: ActiveOverrides,
        sensors: SensorReport,
        battery: BatteryReport,
        displays: DisplaysReport
    ) {
        self.healthScore = healthScore
        self.healthScoreMsg = healthScoreMsg
        self.recommendations = recommendations
        self.activeOverrides = activeOverrides
        self.sensors = sensors
        self.battery = battery
        self.displays = displays
    }
}

// MARK: - Keep-Awake Session

public struct KeepAwakeSession: Codable, Sendable, Equatable {
    public let active: Bool
    public let preventDisplaySleep: Bool
    public let startedAt: Date
    public let expiresAt: Date?
    public let reason: String

    public init(
        active: Bool,
        preventDisplaySleep: Bool,
        startedAt: Date,
        expiresAt: Date?,
        reason: String
    ) {
        self.active = active
        self.preventDisplaySleep = preventDisplaySleep
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.reason = reason
    }

    /// Convenience: an inactive (ended) session.
    public static let inactive = KeepAwakeSession(
        active: false,
        preventDisplaySleep: false,
        startedAt: Date(),
        expiresAt: nil,
        reason: ""
    )
}

// MARK: - History Event

public struct HistoryEvent: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let action: String
    public let requestedValue: Double?
    public let clampedValue: Double?
    public let appliedValue: Double?
    public let result: String
    public let errorReason: String?

    public init(
        timestamp: Date = Date(),
        action: String,
        requestedValue: Double? = nil,
        clampedValue: Double? = nil,
        appliedValue: Double? = nil,
        result: String,
        errorReason: String? = nil
    ) {
        self.timestamp = timestamp
        self.action = action
        self.requestedValue = requestedValue
        self.clampedValue = clampedValue
        self.appliedValue = appliedValue
        self.result = result
        self.errorReason = errorReason
    }
}

// MARK: - System Metrics

public struct CPUReport: Codable, Sendable, Equatable {
    public let totalUtilization: Double?
    public let perCoreUtilization: [Double]
}

public struct MemoryReport: Codable, Sendable, Equatable {
    public let usedBytes: UInt64?
    public let freeBytes: UInt64?
    public let wiredBytes: UInt64?
    public let compressedBytes: UInt64?
    public let pressure: String?
}

public struct DiskReport: Codable, Sendable, Equatable {
    public let capacityBytes: UInt64
    public let usedBytes: UInt64
    public let freeBytes: UInt64
}

public struct NetworkInterfaceReport: Codable, Sendable, Equatable {
    public let name: String
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    public let bytesInPerSecond: Double?
    public let bytesOutPerSecond: Double?
}

public struct NetworkReport: Codable, Sendable, Equatable {
    public let interfaces: [NetworkInterfaceReport]
    public let aggregateBytesIn: UInt64
    public let aggregateBytesOut: UInt64
    public let aggregateBytesInPerSecond: Double?
    public let aggregateBytesOutPerSecond: Double?
}

/// Live power draw from the SMC DC-in rail. Every field is optional: the
/// `VD0R`/`ID0R`/`PDTR` keys are not exposed on every Mac, and the whole
/// block is omitted from JSON when nothing is readable — no zeros, no guesses.
public struct PowerReport: Codable, Sendable, Equatable {
    /// DC-in rail voltage in volts (`VD0R`).
    public let volts: Double?
    /// DC-in rail current in amps (`ID0R`).
    public let amps: Double?
    /// DC-in rail power draw in watts (`PDTR`).
    public let watts: Double?

    public init(volts: Double? = nil, amps: Double? = nil, watts: Double? = nil) {
        self.volts = volts
        self.amps = amps
        self.watts = watts
    }
}

public struct SystemMetricsReport: Codable, Sendable, Equatable {
    public let cpu: CPUReport
    public let memory: MemoryReport
    public let disk: DiskReport?
    public let network: NetworkReport
    /// Live power draw; absent when the SMC does not expose the DC-in keys.
    public let power: PowerReport?
    public let notes: [String]
    public init(
        cpu: CPUReport,
        memory: MemoryReport,
        disk: DiskReport?,
        network: NetworkReport,
        power: PowerReport? = nil,
        notes: [String] = []
    ) {
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.network = network
        self.power = power
        self.notes = notes
    }
}
