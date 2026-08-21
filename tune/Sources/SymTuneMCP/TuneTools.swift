import Foundation
import SymTuneCore
import SymairaMCP

// MARK: - Tool protocol and registry

/// A single MCP tool: schema metadata plus an invocation handler.
/// Concrete tools are immutable structs — safe to share across concurrency domains.
protocol TuneTool: Sendable {
    var name: String { get }
    var description: String { get }
    var inputSchema: MCPJSONSchema { get }
    var isReadOnly: Bool { get }

    /// Invoke the tool with parsed arguments.
    /// - Parameters:
    ///   - arguments: the typed JSON-RPC `arguments` object.
    ///   - controller: facade to the core services.
    func invoke(arguments: [String: MCPJSONValue], controller: TuneController) throws -> any Encodable
}

extension TuneTool {
    var isReadOnly: Bool { false }
}

/// Registry that maps tool names to implementations and renders the
/// `tools/list` schema array. Adding a new tool is a single entry in
/// `TuneToolRegistry.defaultTools`.
struct TuneToolRegistry: Sendable {
    private let tools: [TuneTool]
    private let toolsByName: [String: TuneTool]

    init(tools: [TuneTool]) {
        self.tools = tools
        self.toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
    }

    func tool(named name: String) -> TuneTool? {
        toolsByName[name]
    }

    func schemas() -> [MCPTool] {
        tools.map {
            MCPTool(
                name: $0.name,
                description: $0.description,
                inputSchema: $0.inputSchema
            )
        }
    }
}

extension TuneToolRegistry {
    static let defaultTools: [TuneTool] = {
        // Read / session / profile / status tools
        var tools: [TuneTool] = [
            CapabilitiesTool(),
            SensorsTool(),
            BatteryTool(),
            ListDisplaysTool(),
            MetricsTool(),
            TopProcessesTool(),
            GetAIUsageTool(),
            KeepAwakeTool(),
            KeepAwakeStatusTool(),
            GetBrightnessTool(),
            SaveProfileTool(),
            LoadProfileTool(),
            ListProfilesTool(),
            DeleteProfileTool(),
            GetStatusTool(),
            GetHistoryTool(),
        ]
        // Write tools — generated from the shared WriteCommand table
        for cmd in WriteCommand.all {
            tools.append(WriteCommandTool(descriptor: cmd))
        }
        return tools
    }()
}

// MARK: - Read-only capability / sensor tools

struct CapabilitiesTool: TuneTool {
    let name = "get_capabilities"
    let description = "Report tool version, host info, and which tuning capabilities are available."
    let inputSchema = MCPJSONSchema()
    var isReadOnly: Bool { true }

    func invoke(arguments: [String: MCPJSONValue], controller: TuneController) throws -> any Encodable {
        controller.capabilities()
    }
}

struct SensorsTool: TuneTool {
    let name = "get_sensors"
    let description = "Read thermal pressure and (when available) temperatures and fan RPM."
    let inputSchema = MCPJSONSchema()
    var isReadOnly: Bool { true }

    func invoke(arguments: [String: MCPJSONValue], controller: TuneController) throws -> any Encodable {
        controller.sensorsReport()
    }
}

struct BatteryTool: TuneTool {
    let name = "get_battery"
    let description = "Read battery health: charge %, cycle count, capacity, condition — plus Apple's own Maximum Capacity/Condition when available."
    let inputSchema = MCPJSONSchema()
    var isReadOnly: Bool { true }

    func invoke(arguments: [String: MCPJSONValue], controller: TuneController) throws -> any Encodable {
        controller.batteryReport()
    }
}

struct ListDisplaysTool: TuneTool {
    let name = "list_displays"
    let description = "List displays with EDR headroom (extended-brightness capability)."
    let inputSchema = MCPJSONSchema()
    var isReadOnly: Bool { true }

    func invoke(arguments: [String: MCPJSONValue], controller: TuneController) throws -> any Encodable {
        controller.displaysReport()
    }
}

struct MetricsTool: TuneTool {
    let name = "get_system_metrics"
    let description = "Read system metrics: CPU utilization, memory pressure, disk usage, network throughput, and live power draw (volts/amps/watts, when the SMC exposes them)."
    let inputSchema = MCPJSONSchema()
    var isReadOnly: Bool { true }

    func invoke(arguments: [String: MCPJSONValue], controller: TuneController) throws -> any Encodable {
        controller.metricsReport()
    }
}

struct TopProcessesTool: TuneTool {
    let name = "get_top_processes"
    let description = """
        List the processes currently using the most CPU or memory — the answer to \
        "what is making this Mac hot/slow?". CPU is a rate measured between two \
        samples taken about a second apart. Processes owned by another user (root) \
        are counted in unreadable_process_count but cannot be inspected without \
        elevation.
        """
    var isReadOnly: Bool { true }

    var inputSchema: MCPJSONSchema {
        MCPJSONSchema(
            properties: [
                "sort_by": MCPJSONSchemaProperty(
                    type: "string",
                    description: "Ranking key: 'cpu' (default) or 'memory'."
                ),
                "limit": MCPJSONSchemaProperty(
                    type: "integer",
                    description: "How many processes to return (1–\(ProcessUsageService.maximumLimit)).",
                    minimum: 1,
                    maximum: Double(ProcessUsageService.maximumLimit)
                ),
            ]
        )
    }

    func invoke(arguments: [String: MCPJSONValue], controller: TuneController) throws -> any Encodable {
        let sortRaw = arguments["sort_by"]?.stringValue ?? ProcessSortKey.cpu.rawValue
        guard let sort = ProcessSortKey(rawValue: sortRaw.lowercased()) else {
            throw TuneError.usage("sort_by must be 'cpu' or 'memory'.")
        }
        let limit = arguments["limit"]?.intValue.map(Int.init) ?? ProcessUsageService.defaultLimit

        // Two sweeps: CPU usage only exists as a difference between samples.
        _ = controller.topProcesses(sortedBy: sort, limit: limit)
        Thread.sleep(forTimeInterval: 1.0)
        return controller.topProcesses(sortedBy: sort, limit: limit)
    }
}

struct GetAIUsageTool: TuneTool {
    let name = "get_ai_usage"
    let description = "Read AI subscription/token usage per provider (OpenRouter, …). Read-only; never returns credential material. Unconfigured providers report as not set up."
    let inputSchema = MCPJSONSchema()
    var isReadOnly: Bool { true }

    func invoke(arguments: [String: MCPJSONValue], controller: TuneController) throws -> any Encodable {
        controller.aiUsageReport()
    }
}

// MARK: - Keep-awake (session-level)

struct KeepAwakeTool: TuneTool {
    let name = "keep_awake"
    let description = "Start or stop a keep-awake session. Prevents idle/system sleep and optionally display sleep. Runs indefinitely without duration_seconds. Returns full session state."

    /// Maximum accepted keep-awake duration in seconds (24 hours). Mirrors
    /// the CLI's awake cap so the MCP tool cannot retain a sleep assertion
    /// beyond the CLI contract.
    static let maxDurationSeconds: TimeInterval = 86_400

    var inputSchema: MCPJSONSchema {
        MCPJSONSchema(
            properties: [
                "enabled": MCPJSONSchemaProperty(
                    type: "boolean",
                    description: "Set to true to start a session, false to end it."
                ),
                "prevent_display_sleep": MCPJSONSchemaProperty(
                    type: "boolean",
                    description: "When true, also prevent display sleep."
                ),
                "duration_seconds": MCPJSONSchemaProperty(
                    type: "number",
                    description: "Optional session duration in seconds, between 0 and 86400 (24 hours). Omit for an indefinite session.",
                    minimum: 0,
                    maximum: KeepAwakeTool.maxDurationSeconds
                ),
            ],
            required: ["enabled"]
        )
    }

    func invoke(arguments: [String: MCPJSONValue], controller: TuneController) throws -> any Encodable {
        let enabled = arguments["enabled"]?.boolValue ?? false
        let preventDisplaySleep = arguments["prevent_display_sleep"]?.boolValue ?? false

        if enabled {
            let duration = try Self.validatedDuration(arguments["duration_seconds"])
            return try controller.beginKeepAwakeSession(
                duration: duration,
                preventDisplaySleep: preventDisplaySleep,
                reason: "symtune MCP keep_awake"
            )
        } else {
            controller.endKeepAwakeSession()
            return KeepAwakeSession.inactive
        }
    }

    /// Validates the optional `duration_seconds` argument against the
    /// 24-hour keep-awake contract. Returns `nil` when the argument is
    /// omitted or null (indefinite session). Accepts 0 and 86400 as valid
    /// boundaries; throws a clear usage error for negative, non-finite
    /// (NaN/±infinity), or > 86400 values.
    private static func validatedDuration(_ value: MCPJSONValue?) throws -> TimeInterval? {
        guard let value, value != .null else { return nil }
        guard let duration = value.doubleValue else {
            throw TuneError.usage("keep_awake duration_seconds must be a number.")
        }
        guard duration.isFinite else {
            throw TuneError.usage("keep_awake duration_seconds must be finite.")
        }
        guard duration >= 0 else {
            throw TuneError.usage("keep_awake duration_seconds must be non-negative.")
        }
        guard duration <= maxDurationSeconds else {
            throw TuneError.usage("keep_awake duration_seconds must not exceed \(Int(maxDurationSeconds)) seconds (24 hours).")
        }
        return duration
    }
}

struct KeepAwakeStatusTool: TuneTool {
    let name = "keep_awake_status"
    let description = "Return the current keep-awake session state (active, type, remaining time, reason)."
    let inputSchema = MCPJSONSchema()
    var isReadOnly: Bool { true }

    func invoke(arguments: [String: MCPJSONValue], controller: TuneController) throws -> any Encodable {
        controller.keepAwakeSessionStatus()
    }
}

// MARK: - Brightness / warmth / dim tools (read-only)

struct GetBrightnessTool: TuneTool {
    let name = "get_brightness"
    let description = "Read the built-in display brightness (0.0–1.0)."
    let inputSchema = MCPJSONSchema()
    var isReadOnly: Bool { true }

    func invoke(arguments: [String: MCPJSONValue], controller: TuneController) throws -> any Encodable {
        BrightnessReadback(brightness: try controller.getBuiltinBrightness())
    }
}

// MARK: - Generic write tool (driven by WriteCommand descriptor)

struct WriteCommandTool: TuneTool {
    let descriptor: WriteCommand

    var name: String { descriptor.mcpName }
    var description: String { descriptor.description }
    var isReadOnly: Bool { false }

    var inputSchema: MCPJSONSchema {
        guard descriptor.isContinuous, let min = descriptor.minimum, let max = descriptor.maximum else {
            return MCPJSONSchema()
        }
        let argName = descriptor.mcpArgName
        if descriptor.valueType == .integer {
            return MCPJSONSchema(
                properties: [
                    argName: MCPJSONSchemaProperty(
                        type: "integer",
                        minimum: min,
                        maximum: max
                    ),
                ],
                required: [argName]
            )
        } else {
            return MCPJSONSchema(
                properties: [
                    argName: MCPJSONSchemaProperty(
                        type: "number",
                        minimum: min,
                        maximum: max
                    ),
                ],
                required: [argName]
            )
        }
    }

    func invoke(arguments: [String: MCPJSONValue], controller: TuneController) throws -> any Encodable {
        if descriptor.isContinuous {
            if descriptor.valueType == .integer {
                let intVal = try requireInt(arguments[descriptor.mcpArgName], name: descriptor.mcpArgName)
                try descriptor.apply(controller, Double(intVal))
            } else {
                let doubleVal = try requireDouble(arguments[descriptor.mcpArgName], name: descriptor.mcpArgName)
                try descriptor.apply(controller, doubleVal)
            }
        } else {
            try descriptor.apply(controller, 0)
        }
        return ApplyResult(applied: true)
    }
}

// MARK: - Profile tools

struct SaveProfileTool: TuneTool {
    let name = "save_profile"
    let description = "Save current settings as a named profile."
    let inputSchema = MCPJSONSchema(
        properties: [
            "name": MCPJSONSchemaProperty(type: "string"),
        ],
        required: ["name"]
    )

    func invoke(arguments: [String: MCPJSONValue], controller: TuneController) throws -> any Encodable {
        guard let name = arguments["name"]?.stringValue else {
            throw TuneError.usage("save_profile requires a name.")
        }
        let brightness = try? controller.getBuiltinBrightness()
        let profile = try TuneProfile(
            name: name,
            brightness: brightness,
            dim: controller.getDimLevel(),
            warmth: controller.getWarmthLevel()
        )
        try controller.saveProfile(profile)
        return ProfileSaved(saved: name)
    }
}

struct LoadProfileTool: TuneTool {
    let name = "load_profile"
    let description = "Apply a saved profile by name."
    let inputSchema = MCPJSONSchema(
        properties: [
            "name": MCPJSONSchemaProperty(type: "string"),
        ],
        required: ["name"]
    )

    func invoke(arguments: [String: MCPJSONValue], controller: TuneController) throws -> any Encodable {
        guard let name = arguments["name"]?.stringValue else {
            throw TuneError.usage("load_profile requires a name.")
        }
        let profile = try controller.loadProfile(name: name)
        try controller.applyProfile(profile)
        return ApplyResult(applied: true)
    }
}

struct ListProfilesTool: TuneTool {
    let name = "list_profiles"
    let description = "List all saved profiles."
    let inputSchema = MCPJSONSchema()
    var isReadOnly: Bool { true }

    func invoke(arguments: [String: MCPJSONValue], controller: TuneController) throws -> any Encodable {
        ProfileList(profiles: controller.listProfiles())
    }
}

struct DeleteProfileTool: TuneTool {
    let name = "delete_profile"
    let description = "Delete a saved profile by name."
    let inputSchema = MCPJSONSchema(
        properties: [
            "name": MCPJSONSchemaProperty(type: "string"),
        ],
        required: ["name"]
    )

    func invoke(arguments: [String: MCPJSONValue], controller: TuneController) throws -> any Encodable {
        guard let name = arguments["name"]?.stringValue else {
            throw TuneError.usage("delete_profile requires a name.")
        }
        try controller.deleteProfile(name: name)
        return ApplyResult(applied: true)
    }
}

// MARK: - Status / history tools

struct GetStatusTool: TuneTool {
    let name = "get_status"
    let description = "Get the consolidated health status snapshot of the system, including score, recommendations, overrides, and raw reports."
    let inputSchema = MCPJSONSchema()
    var isReadOnly: Bool { true }

    func invoke(arguments: [String: MCPJSONValue], controller: TuneController) throws -> any Encodable {
        controller.statusReport()
    }
}

struct GetHistoryTool: TuneTool {
    let name = "get_history"
    let description = "Retrieve the write operations history log."
    var inputSchema: MCPJSONSchema {
        MCPJSONSchema(
            properties: [
                "limit": MCPJSONSchemaProperty(
                    type: "integer",
                    description: "Maximum number of events to return (default 100)."
                ),
            ]
        )
    }
    var isReadOnly: Bool { true }

    func invoke(arguments: [String: MCPJSONValue], controller: TuneController) throws -> any Encodable {
        let limit = arguments["limit"]?.intValue.map(Int.init) ?? 100
        return controller.getHistory(limit: limit)
    }
}
