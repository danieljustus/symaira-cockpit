import Foundation

/// Value type for a write command's argument.
public enum ValueType: Sendable {
    case double
    case integer
}

/// A single write-command descriptor that drives both the CLI dispatch table and
/// the MCP tool list from one shared source.  Adding a new write command is a
/// single entry in `WriteCommand.all` — no changes needed in `main.swift` or
/// `MCPTools.swift`.
public struct WriteCommand: Sendable {
    /// Canonical dotted identifier, e.g. "brightness.set", "dim.reset".
    public let name: String

    /// MCP tool name (snake_case), e.g. "set_brightness", "reset_dim".
    public let mcpName: String

    /// CLI subcommand prefix used for dispatch, e.g. "brightness set", "dim reset".
    public let cliPrefix: String

    /// Human-readable description (used as the MCP tool description).
    public let description: String

    /// Lower bound for the numeric value, or `nil` for toggle/reset commands.
    public let minimum: Double?

    /// Upper bound for the numeric value, or `nil` for toggle/reset commands.
    public let maximum: Double?

    /// Whether the value is a `Double` or an `Int` (affects MCP schema generation).
    public let valueType: ValueType

    /// `true` = setter (takes a value), `false` = toggle / reset / restore.
    public let isContinuous: Bool

    /// Name of the MCP argument property in the JSON schema.
    /// Typically "value" for continuous doubles, "fraction" for fan, "percent" for charge limit.
    public let mcpArgName: String

    /// Apply the command to the given controller.
    /// For non-continuous commands the `Double` parameter is ignored.
    public let apply: @Sendable (TuneController, Double) throws -> Void

    public init(
        name: String,
        mcpName: String,
        cliPrefix: String,
        description: String,
        minimum: Double?,
        maximum: Double?,
        valueType: ValueType,
        isContinuous: Bool,
        mcpArgName: String,
        apply: @escaping @Sendable (TuneController, Double) throws -> Void
    ) {
        self.name = name
        self.mcpName = mcpName
        self.cliPrefix = cliPrefix
        self.description = description
        self.minimum = minimum
        self.maximum = maximum
        self.valueType = valueType
        self.isContinuous = isContinuous
        self.mcpArgName = mcpArgName
        self.apply = apply
    }
}

// MARK: - Shared write-command table

extension WriteCommand {
    /// Every write command the tool knows about.  The MCP tool list and the CLI
    /// dispatch table are both derived from this array.
    public static let all: [WriteCommand] = [
        WriteCommand(
            name: "brightness.set",
            mcpName: "set_brightness",
            cliPrefix: "brightness set",
            description: "Set built-in display brightness (0.0–1.0).",
            minimum: SafetyPolicy.brightnessMin,
            maximum: SafetyPolicy.brightnessMax,
            valueType: .double,
            isContinuous: true,
            mcpArgName: "value",
            apply: { try $0.applyBuiltinBrightness($1) }
        ),
        WriteCommand(
            name: "extbright.set",
            mcpName: "set_extended_brightness",
            cliPrefix: "extbright set",
            description: "Set extended/EDR brightness multiplier (1.0–1.6) via on-screen EDR layer.",
            minimum: SafetyPolicy.extendedBrightnessMin,
            maximum: SafetyPolicy.extendedBrightnessMax,
            valueType: .double,
            isContinuous: true,
            mcpArgName: "value",
            apply: { try $0.applyExtendedBrightness($1) }
        ),
        WriteCommand(
            name: "dim.set",
            mcpName: "set_dim",
            cliPrefix: "dim set",
            description: "Set software dim overlay (0.15=max dim, 1.0=no dim).",
            minimum: SafetyPolicy.dimMin,
            maximum: SafetyPolicy.dimMax,
            valueType: .double,
            isContinuous: true,
            mcpArgName: "value",
            apply: { try $0.applyDim($1) }
        ),
        WriteCommand(
            name: "dim.reset",
            mcpName: "reset_dim",
            cliPrefix: "dim reset",
            description: "Remove all dim overlays.",
            minimum: nil,
            maximum: nil,
            valueType: .double,
            isContinuous: false,
            mcpArgName: "value",
            apply: { (ctrl, _) in ctrl.resetDim(); return }
        ),
        WriteCommand(
            name: "warmth.set",
            mcpName: "set_warmth",
            cliPrefix: "warmth set",
            description: "Set color temperature warmth (0.0=neutral, 1.0=max warm). Uses gamma LUT.",
            minimum: 0.0,
            maximum: 1.0,
            valueType: .double,
            isContinuous: true,
            mcpArgName: "value",
            apply: { try $0.applyWarmth($1) }
        ),
        WriteCommand(
            name: "warmth.reset",
            mcpName: "reset_warmth",
            cliPrefix: "warmth reset",
            description: "Reset color temperature warmth to neutral (identity gamma).",
            minimum: nil,
            maximum: nil,
            valueType: .double,
            isContinuous: false,
            mcpArgName: "value",
            apply: { (ctrl, _) in try ctrl.resetWarmth(); return }
        ),
        WriteCommand(
            name: "restore",
            mcpName: "restore",
            cliPrefix: "restore",
            description: "Restore all overrides to system defaults.",
            minimum: nil,
            maximum: nil,
            valueType: .double,
            isContinuous: false,
            mcpArgName: "value",
            apply: { (ctrl, _) in ctrl.restoreAll(); return }
        ),
        WriteCommand(
            name: "fan.set",
            mcpName: "set_fan",
            cliPrefix: "fan set",
            description: "Set fan speed as a fraction 0.0–1.0. Requires root/SMC write access.",
            minimum: SafetyPolicy.fanFractionMin,
            maximum: SafetyPolicy.fanFractionMax,
            valueType: .double,
            isContinuous: true,
            mcpArgName: "fraction",
            apply: { try $0.applyFan(fraction: $1) }
        ),
        WriteCommand(
            name: "battery-limit.set",
            mcpName: "set_charge_limit",
            cliPrefix: "battery-limit set",
            description: "Hold battery charge at a target percent (50–100). Requires root/SMC write access.",
            minimum: Double(SafetyPolicy.chargeLimitMin),
            maximum: Double(SafetyPolicy.chargeLimitMax),
            valueType: .integer,
            isContinuous: true,
            mcpArgName: "percent",
            apply: { try $0.applyChargeLimit(percent: Int($1)) }
        ),
        WriteCommand(
            name: "battery-limit.clear",
            mcpName: "clear_charge_limit",
            cliPrefix: "battery-limit clear",
            description: "Clear battery charge limit and re-enable charging. Requires root/SMC write access.",
            minimum: nil,
            maximum: nil,
            valueType: .integer,
            isContinuous: false,
            mcpArgName: "percent",
            apply: { (ctrl, _) in try ctrl.clearChargeLimit(); return }
        ),
    ]

    /// Look up a write command by its CLI prefix.
    /// - Parameter prefix: The `cliPrefix` to find, e.g. "brightness set".
    /// - Returns: The matching `WriteCommand`, or `nil`.
    public static func forCLIPrefix(_ prefix: String) -> WriteCommand? {
        all.first { $0.cliPrefix == prefix }
    }

    /// Look up a write command by its MCP tool name.
    /// - Parameter mcpName: The `mcpName` to find, e.g. "set_brightness".
    /// - Returns: The matching `WriteCommand`, or `nil`.
    public static func forMCPName(_ mcpName: String) -> WriteCommand? {
        all.first { $0.mcpName == mcpName }
    }
}
