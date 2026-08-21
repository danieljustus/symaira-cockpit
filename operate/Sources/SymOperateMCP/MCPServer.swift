import Foundation
import SymOperateCore
import SymairaMCP

/// MCP server for `symoperate`, built on appkit's `SymairaMCP` module.
///
/// The JSON-RPC 2.0 loop (parse → validate → dispatch → respond), the
/// method-handler registry, and the stdio transport are provided by
/// `SymairaMCP.MCPServer` + `MCPStdioTransport` — the shared implementation
/// that replaced this package's hand-rolled server (see `symaira-appkit`
/// issue #55, migration issue #97). This type owns only the symoperate-
/// specific parts:
///
/// - the tool registry (`tools()`) and the `tools/call` implementations,
///   which drive `AutomationController`;
/// - the safety-refusal payload shape (`refusalPayload`): classified
///   `.permissionDenied` outcomes are returned as successful `tools/call`
///   results with a stable `structuredContent.refusal.code`, never as
///   JSON-RPC errors;
/// - the in-process `dispatch(method:params:)` seam used by unit tests and
///   embedders, which shares the exact same tool implementations as the
///   wire handlers.
///
/// The wire payload shapes are intentionally byte-compatible with the
/// previous implementation (same `tools/list` schemas including `oneOf` /
/// `anyOf` / `enum` constraints, same `structuredContent` extension key on
/// `tools/call` results, and genuine `AutomationError` faults returned as
/// JSON-RPC `-32603` errors carrying the machine-readable classification in
/// `error.data.code`). `SymairaMCP`'s generic `MCPJSONValue` result type
/// makes this possible without constraining the tool metadata to the
/// module's minimal `MCPTool` schema shape.
public final class MCPServer: @unchecked Sendable {
    private let controller: AutomationController
    private let server: SymairaMCP.MCPServer

    public init(controller: AutomationController = AutomationController()) {
        self.controller = controller
        self.server = SymairaMCP.MCPServer(name: "symoperate", version: SymOperateVersion.current)
        registerHandlers()
    }

    /// Serves MCP over stdio until stdin closes.
    public func run(transport: any MCPTransport = MCPStdioTransport()) async throws {
        try await server.start(transport: transport)
    }

    /// In-process dispatch, sharing the same tool implementations as the
    /// wire handlers. Returns the JSON-RPC result object, or throws
    /// `AutomationError` — the error-to-wire mapping (JSON-RPC errors vs.
    /// refusal results) happens in the wire handlers.
    public func dispatch(method: String, params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "initialize":
            return initializeResult(requestedProtocol: params["protocolVersion"] as? String)
        case "notifications/initialized":
            return [:]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": tools()]
        case "tools/call":
            guard let name = params["name"] as? String else {
                throw AutomationError.invalidArgument("tools/call requires a tool name.")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return try await callTool(name: name, arguments: arguments)
        default:
            throw AutomationError.invalidArgument("Method not found: \(method)")
        }
    }

    /// Registers the symoperate methods on appkit's server. `initialize` is
    /// deliberately overridden to preserve the previous echo semantics:
    /// the server answers with the client's requested protocol version (or
    /// the legacy default) instead of always advertising its own.
    private func registerHandlers() {
        server
            .withMethodHandler("initialize") { [self] (params: MCPInitializeParams) async throws -> MCPJSONValue in
                Self.jsonValue(initializeResult(requestedProtocol: params.protocolVersion))
            }
            .withMethodHandler("tools/list") { [self] (_: MCPNoParams) async throws -> MCPJSONValue in
                .object(["tools": .array(tools().map(Self.jsonValue))])
            }
            .withMethodHandler("tools/call") { [self] (params: MCPCallToolParams) async throws -> MCPJSONValue in
                let arguments = (params.arguments ?? [:]).mapValues(Self.jsonAny)
                do {
                    return Self.jsonValue(try await callTool(name: params.name, arguments: arguments))
                } catch let error as AutomationError {
                    if case .permissionDenied = error {
                        // Deliberate safety refusals are NOT JSON-RPC errors —
                        // the call executed correctly and the outcome is the
                        // refusal.
                        return Self.jsonValue(Self.refusalPayload(code: error.code, message: error.localizedDescription))
                    }
                    // Genuine faults surface as JSON-RPC internal errors,
                    // carrying the stable machine-readable classification in
                    // `error.data.code` (same contract as before the
                    // SymairaMCP migration).
                    throw MCPError(error.localizedDescription, data: .object(["code": .string(error.code)]))
                } catch {
                    throw MCPError(error.localizedDescription)
                }
            }
    }

    private func initializeResult(requestedProtocol: String?) -> [String: Any] {
        [
            "protocolVersion": requestedProtocol ?? "2024-11-05",
            "capabilities": [
                "tools": [
                    "listChanged": false,
                ],
            ],
            "serverInfo": [
                "name": "symoperate",
                "version": SymOperateVersion.current,
            ],
        ]
    }

    private func tools() -> [[String: Any]] {
        [
            tool("list_apps", description: "List currently running GUI apps on macOS.", input: [:]),
            tool("list_windows", description: "List currently visible windows.", input: [:]),
            tool("list_displays", description: "List all connected displays with bounds and IDs.", input: [:]),
            tool("snapshot", description: "Capture a display or window as PNG plus coordinate transform metadata. Both parameters are optional: omit both for the main display, provide display_id for a specific display, or provide window_id for a specific window. When window_id is provided, display_id is ignored.", input: [
                "type": "object",
                "properties": [
                    "display_id": ["type": "integer", "description": "Display ID to capture. Omit for main display."],
                    "window_id": ["type": "integer", "description": "Window ID to capture. When provided, display_id is ignored."],
                ],
            ]),
            tool("query_ui", description: "Capture a screenshot and accessible UI tree for the frontmost app.", input: [
                "type": "object",
                "properties": [
                    "max_depth": ["type": "integer", "default": 4],
                    "max_nodes": ["type": "integer", "default": 200],
                    "display_id": ["type": "integer", "description": "Display ID to capture. Omit for main display."],
                    "window_id": ["type": "integer", "description": "Window ID to capture. When provided, display_id is ignored."],
                ],
            ]),
            tool("query_ui_ocr", description: "Like query_ui but falls back to Vision OCR when the Accessibility tree is weak. Returns OCR text regions with coordinates.", input: [
                "type": "object",
                "properties": [
                    "max_depth": ["type": "integer", "default": 4],
                    "max_nodes": ["type": "integer", "default": 200],
                    "display_id": ["type": "integer", "description": "Display ID to capture. Omit for main display."],
                    "window_id": ["type": "integer", "description": "Window ID to capture. When provided, display_id is ignored."],
                ],
            ]),
            tool("find_ui", description: "Search the UI tree by role, title, label, value, subrole, or actions. Supports regex patterns (wrap in /slashes/). When snapshot_id is provided and the snapshot is still cached, reuses the existing snapshot instead of taking a fresh one.", input: [
                "type": "object",
                "properties": [
                    "role": ["type": "string"],
                    "title": ["type": "string"],
                    "label": ["type": "string"],
                    "value": ["type": "string"],
                    "subrole": ["type": "string"],
                    "actions": ["type": "array", "items": ["type": "string"]],
                    "snapshot_id": ["type": "string", "description": "Reuse an existing snapshot. If omitted, takes a fresh one."],
                ],
            ]),
            tool("click", description: "Click by x/y coordinates or by snapshot_id + element_id. Requires exactly one of two groups: (x, y) for coordinate-based clicking, or (snapshot_id, element_id) for element-based clicking. Raw coordinates require a prior query_ui snapshot so the target element can be identified and safety-checked; destructive controls and secure text fields are always blocked. Optional: button (default \"left\"), double_click.", input: [
                "type": "object",
                "properties": [
                    "snapshot_id": ["type": "string"],
                    "element_id": ["type": "string"],
                    "x": ["type": "number"],
                    "y": ["type": "number"],
                    "button": ["type": "string", "enum": ["left", "right"]],
                    "double_click": ["type": "boolean"],
                ],
                "oneOf": [
                    ["required": ["x", "y"]],
                    ["required": ["snapshot_id", "element_id"]],
                ],
            ]),
            tool("type_text", description: "Type raw unicode text into the current focused control.", input: [
                "type": "object",
                "properties": ["text": ["type": "string"]],
                "required": ["text"],
            ]),
            tool("press_keys", description: "Press a keyboard shortcut like [\"cmd\", \"s\"] or [\"return\"].", input: [
                "type": "object",
                "properties": ["keys": ["type": "array", "items": ["type": "string"]]],
                "required": ["keys"],
            ]),
            tool("scroll", description: "Scroll by pixel deltas.", input: [
                "type": "object",
                "properties": [
                    "delta_x": ["type": "number", "default": 0],
                    "delta_y": ["type": "number"],
                ],
                "required": ["delta_y"],
            ]),
            tool("drag", description: "Drag from one coordinate or element to another. Requires exactly one of two groups: (from_x, from_y, to_x, to_y) for coordinate-based dragging, or (snapshot_id, from_element_id, to_element_id) for element-based dragging. Raw coordinates require a prior query_ui snapshot so the target element can be identified and safety-checked; destructive controls and secure text fields are always blocked.", input: [
                "type": "object",
                "properties": [
                    "snapshot_id": ["type": "string"],
                    "from_element_id": ["type": "string"],
                    "to_element_id": ["type": "string"],
                    "from_x": ["type": "number"],
                    "from_y": ["type": "number"],
                    "to_x": ["type": "number"],
                    "to_y": ["type": "number"],
                ],
                "oneOf": [
                    ["required": ["from_x", "from_y", "to_x", "to_y"]],
                    ["required": ["snapshot_id", "from_element_id", "to_element_id"]],
                ],
            ]),
            tool("launch_app", description: "Launch an app by bundle_id or app_name. At least one of bundle_id or app_name is required.", input: [
                "type": "object",
                "properties": [
                    "bundle_id": ["type": "string"],
                    "app_name": ["type": "string"],
                ],
                "anyOf": [
                    ["required": ["bundle_id"]],
                    ["required": ["app_name"]],
                ],
            ]),
            tool("focus_window", description: "Activate an app and optionally raise a matching window title. At least one of bundle_id or app_name is required.", input: [
                "type": "object",
                "properties": [
                    "bundle_id": ["type": "string"],
                    "app_name": ["type": "string"],
                    "title": ["type": "string"],
                ],
                "anyOf": [
                    ["required": ["bundle_id"]],
                    ["required": ["app_name"]],
                ],
            ]),
            tool("menu_action", description: "Trigger a frontmost-app menu path like [\"File\", \"Save\"].", input: [
                "type": "object",
                "properties": [
                    "path": ["type": "array", "items": ["type": "string"]],
                ],
                "required": ["path"],
            ]),
            tool("wait_for", description: "Wait until text appears in the frontmost UI or an app becomes available.", input: [
                "type": "object",
                "properties": [
                    "text": ["type": "string"],
                    "app": ["type": "string"],
                    "timeout_seconds": ["type": "number", "default": 10],
                ],
            ]),
            tool("permissions_status", description: "Report screen recording and accessibility permission status.", input: [:]),
            tool("get_policy", description: "Get the current action policy (deny/allow keywords, allowed bundle IDs, granted permissions).", input: [:]),
            setPolicyToolSchema(),
            tool("version", description: "Print current version and check for updates from GitHub releases.", input: [:]),
        ]
    }

    private func tool(_ name: String, description: String, input: [String: Any]) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": input.isEmpty ? ["type": "object", "properties": [:]] : input,
        ]
    }

    /// Schema of the `set_policy` tool. Kept in its own function so `tools()`
    /// stays within SwiftLint's function-body budget.
    private func setPolicyToolSchema() -> [String: Any] {
        tool("set_policy", description: "Update the action policy. Extends defaults; cannot weaken the built-in safety guard. Requires the policy_modify permission. When granted_permissions is provided it REPLACES the full granted permission set (defaults to .all when absent).", input: [
            "type": "object",
            "properties": [
                "extra_deny_keywords": ["type": "array", "items": ["type": "string"], "description": "Additional keywords to block."],
                "allow_keywords": ["type": "array", "items": ["type": "string"], "description": "Keywords to allow (overrides deny)."],
                "allow_bundle_ids": ["type": "array", "items": ["type": "string"], "description": "Bundle IDs to exempt from destructive checks."],
                "granted_permissions": ["type": "array", "items": ["type": "string"], "description": "Permission flag names to grant: capture, input, app_control, menu_action, destructive_action, secure_field_access, policy_modify. Replaces the current set when present."],
            ],
        ])
    }

    /// Executes one tool and builds the `tools/call` result payload:
    /// `content` (human-readable JSON summary), `structuredContent`
    /// (machine-readable payload), and `isError: false`.
    private func callTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        let payload: Encodable
        switch name {
        case "snapshot":
            payload = try controller.snapshot(
                displayID: uint32(arguments["display_id"]),
                windowID: intOptional(arguments["window_id"])
            )
        case "list_apps":
            payload = controller.listApps()
        case "list_windows":
            payload = controller.listWindows()
        case "list_displays":
            payload = controller.listDisplays()
        case "query_ui":
            payload = try controller.queryUI(
                maxDepth: int(arguments["max_depth"], default: 4),
                maxNodes: int(arguments["max_nodes"], default: 200),
                displayID: uint32(arguments["display_id"]),
                windowID: intOptional(arguments["window_id"])
            )
        case "query_ui_ocr":
            payload = try controller.queryUIWithOCR(
                maxDepth: int(arguments["max_depth"], default: 4),
                maxNodes: int(arguments["max_nodes"], default: 200),
                displayID: uint32(arguments["display_id"]),
                windowID: intOptional(arguments["window_id"])
            )
        case "click":
            payload = try controller.click(
                snapshotID: string(arguments["snapshot_id"]),
                elementID: string(arguments["element_id"]),
                x: double(arguments["x"]),
                y: double(arguments["y"]),
                button: string(arguments["button"]) ?? "left",
                doubleClick: bool(arguments["double_click"], default: false)
            )
        case "type_text":
            payload = try controller.typeText(requireString(arguments["text"], name: "text"))
        case "press_keys":
            payload = try controller.pressKeys(requireStringArray(arguments["keys"], name: "keys"))
        case "scroll":
            payload = try controller.scroll(
                deltaX: double(arguments["delta_x"]) ?? 0,
                deltaY: requireDouble(arguments["delta_y"], name: "delta_y")
            )
        case "drag":
            payload = try controller.drag(
                snapshotID: string(arguments["snapshot_id"]),
                fromElementID: string(arguments["from_element_id"]),
                toElementID: string(arguments["to_element_id"]),
                fromX: double(arguments["from_x"]),
                fromY: double(arguments["from_y"]),
                toX: double(arguments["to_x"]),
                toY: double(arguments["to_y"])
            )
        case "launch_app":
            payload = try controller.launchApp(
                bundleID: string(arguments["bundle_id"]),
                appName: string(arguments["app_name"])
            )
        case "focus_window":
            payload = try controller.focusWindow(
                bundleID: string(arguments["bundle_id"]),
                appName: string(arguments["app_name"]),
                title: string(arguments["title"])
            )
        case "menu_action":
            payload = try controller.menuAction(path: requireStringArray(arguments["path"], name: "path"))
        case "wait_for":
            payload = try await controller.waitFor(
                text: string(arguments["text"]),
                app: string(arguments["app"]),
                timeoutSeconds: double(arguments["timeout_seconds"]) ?? 10
            )
        case "permissions_status":
            payload = controller.permissionsStatus()
        case "get_policy":
            payload = policyPayload()
        case "set_policy":
            // Gate BEFORE mutating: an agent without policy_modify cannot change
            // the policy — including restricting its own permission set.
            if let violation = controller.actionPolicy.firstViolation(requiredPermission: .policyModify) {
                throw AutomationError.permissionDenied(
                    "Permission denied: the '\(violation.flagNames.joined(separator: ", "))' permission is required for set_policy."
                )
            }
            if let extraDeny = arguments["extra_deny_keywords"] as? [String] {
                for kw in extraDeny { controller.actionPolicy.addDenyKeyword(kw) }
            }
            if let allowKw = arguments["allow_keywords"] as? [String] {
                for kw in allowKw { controller.actionPolicy.allowKeyword(kw) }
            }
            if let allowBundle = arguments["allow_bundle_ids"] as? [String] {
                for bid in allowBundle { controller.actionPolicy.allowBundleID(bid) }
            }
            if let granted = arguments["granted_permissions"] as? [String] {
                // REPLACE (not union) the granted set with the parsed flags.
                controller.actionPolicy.grantedPermissions = PermissionFlags.parse(names: granted)
            }
            payload = policyPayload()
        case "find_ui":
            let predicate = UIElementPredicate(
                role: string(arguments["role"]),
                title: string(arguments["title"]),
                label: string(arguments["label"]),
                value: string(arguments["value"]),
                subrole: string(arguments["subrole"]),
                actions: arguments["actions"] as? [String]
            )
            payload = try controller.findUI(
                predicate: predicate,
                snapshotID: string(arguments["snapshot_id"]),
                maxDepth: int(arguments["max_depth"], default: 4),
                maxNodes: int(arguments["max_nodes"], default: 200),
                displayID: uint32(arguments["display_id"]),
                windowID: intOptional(arguments["window_id"])
            )
        case "version":
            let checker = UpdateChecker()
            payload = await checker.checkForUpdate()
        default:
            throw AutomationError.notFound("Unknown tool '\(name)'.")
        }

        let structured = try encodeToJSONObject(payload)
        let summary = textSummary(for: name, payload: structured)
        return [
            "content": [
                ["type": "text", "text": summary],
            ],
            "structuredContent": structured,
            "isError": false,
        ]
    }

    private func encodeToJSONObject(_ value: Encodable) throws -> Any {
        let boxed = AnyEncodable(value)
        let data = try encoder.encode(boxed)
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Human-readable policy snapshot for get_policy/set_policy responses.
    /// `granted_permissions` is the array of granted flag names so agents can
    /// classify refusals without decoding OptionSet raw values.
    private func policyPayload() -> PolicyPayload {
        let policy = controller.actionPolicy
        return PolicyPayload(
            extraDenyKeywords: Array(policy.extraDenyKeywords).sorted(),
            allowedKeywords: Array(policy.allowedKeywords).sorted(),
            allowedBundleIDs: Array(policy.allowedBundleIDs).sorted(),
            grantedPermissions: policy.grantedPermissions.flagNames
        )
    }

    private func textSummary(for tool: String, payload: Any) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return "\(tool) completed."
        }
        // For snapshot responses, skip the text field to avoid double base64 serialization
        if tool == "snapshot" || tool == "query_ui" || tool == "query_ui_ocr" || tool == "find_ui" {
            if let dict = payload as? [String: Any],
               dict["imageBase64PNG"] != nil {
                return "\(tool) completed. See structuredContent for full result."
            }
        }
        return text
    }

    /// Builds the JSON-RPC result payload for a classified safety refusal.
    /// Refusals are deliberately NOT JSON-RPC errors (`isError: false`) and
    /// carry a stable machine-readable `refusal.code` for agent-side
    /// classification. Every `.permissionDenied` — destructive-keyword guard
    /// or permission gate — flows through this same payload shape.
    static func refusalPayload(code: String, message: String) -> [String: Any] {
        [
            "isError": false,
            "content": [
                ["type": "text", "text": message],
            ],
            "structuredContent": [
                "status": "refused",
                "refusal": [
                    "code": code,
                    "message": message,
                ],
            ],
        ]
    }

    // MARK: - MCPJSONValue bridging
    //
    // The tool payloads above are built as `[String: Any]` (the shape the
    // in-process `dispatch` seam returns and the tests assert against).
    // These two converters bridge that shape to `SymairaMCP`'s
    // `MCPJSONValue` for the wire handlers without changing any payload
    // semantics.

    private static func jsonValue(_ value: Any) -> MCPJSONValue {
        switch value {
        case let number as NSNumber:
            // JSONSerialization produces __NSCFBoolean for JSON true/false and
            // __NSCFNumber for numbers. A plain `as? Bool` cast would also
            // match numeric 0/1 NSNumbers and corrupt integer payloads
            // (e.g. displayID 1 → true), so booleans must be discriminated
            // by their CF type. Swift-native Bool values are never NSNumbers
            // and are caught by the `as Bool` case below.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let bool as Bool:
            return .bool(bool)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(array.map(jsonValue))
        case let object as [String: Any]:
            return .object(object.mapValues(jsonValue))
        default:
            return .null
        }
    }

    private static func jsonAny(_ value: MCPJSONValue) -> Any {
        switch value {
        case .null:
            return NSNull()
        case .bool(let bool):
            return bool
        case .number(let number):
            return number
        case .string(let string):
            return string
        case .array(let array):
            return array.map(jsonAny)
        case .object(let object):
            return object.mapValues(jsonAny)
        }
    }
}

private extension MCPServer {
    var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    func string(_ value: Any?) -> String? { value as? String }

    func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        return (value as? String).flatMap(Double.init)
    }

    func uint32(_ value: Any?) -> UInt32? {
        if let n = value as? NSNumber { return n.uint32Value }
        return (value as? String).flatMap(UInt32.init)
    }

    func intOptional(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        return (value as? String).flatMap(Int.init)
    }

    func int(_ value: Any?, default defaultValue: Int) -> Int {
        intOptional(value) ?? defaultValue
    }

    func bool(_ value: Any?, default defaultValue: Bool) -> Bool {
        if let b = value as? Bool { return b }
        return (value as? NSNumber)?.boolValue ?? defaultValue
    }

    func requireString(_ value: Any?, name: String) throws -> String {
        guard let string = value as? String, !string.isEmpty else {
            throw AutomationError.invalidArgument("Missing required string argument '\(name)'.")
        }
        return string
    }

    func requireDouble(_ value: Any?, name: String) throws -> Double {
        guard let double = double(value) else {
            throw AutomationError.invalidArgument("Missing required numeric argument '\(name)'.")
        }
        return double
    }

    func requireStringArray(_ value: Any?, name: String) throws -> [String] {
        guard let array = value as? [String], !array.isEmpty else {
            throw AutomationError.invalidArgument("Missing required string array argument '\(name)'.")
        }
        return array
    }
}

private struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init(_ wrapped: Encodable) {
        self.encodeImpl = wrapped.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}

/// Encodable snapshot of the action policy for get_policy/set_policy responses.
/// `grantedPermissions` is exposed on the wire as `granted_permissions` — the
/// array of granted flag names in canonical order.
private struct PolicyPayload: Encodable {
    let extraDenyKeywords: [String]
    let allowedKeywords: [String]
    let allowedBundleIDs: [String]
    let grantedPermissions: [String]

    enum CodingKeys: String, CodingKey {
        case extraDenyKeywords
        case allowedKeywords
        case allowedBundleIDs
        case grantedPermissions = "granted_permissions"
    }
}
