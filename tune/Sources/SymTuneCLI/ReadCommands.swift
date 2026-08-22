import Foundation
import SymTuneCore

/// One-line description shown after `Usage: symtune <command>` for each of
/// the always-JSON read commands. Kept in sync with the `READ COMMANDS`
/// section of the top-level `usage` string in `main.swift`.
private let alwaysJSONCommandHelp: [String: String] = [
    "doctor": "Capabilities, host info, and recommendations (JSON).",
    "sensors": "Thermal pressure + (when available) temps/fan RPM (JSON).",
    "battery": "Battery health: charge %, cycles, capacity, condition (JSON).",
    "displays": "Displays with EDR headroom / extended-brightness capability (JSON).",
    "permissions": "Permission & SMC write status (JSON).",
]

/// Reject any argument left over for a command that takes none. These five
/// always-JSON read commands (`doctor`, `sensors`, `battery`, `displays`,
/// `permissions`) accept no options beyond `--help`/`-h`, which is handled
/// separately before this is called.
private func rejectUnexpectedArguments(_ args: [String], command: String) throws {
    for arg in args {
        throw TuneError.usage("\(command): unexpected argument '\(arg)'")
    }
}

/// Print `--help`/`-h` output for one of the always-JSON read commands.
private func emitAlwaysJSONCommandHelp(_ command: String) {
    emit("Usage: symtune \(command) [--json]")
    if let description = alwaysJSONCommandHelp[command] {
        emit("")
        emit(description)
        emit("--json is accepted for consistency with other read commands; it is a no-op here.")
    }
}

/// Run one of the five always-JSON read commands: honour `--help`/`-h`,
/// accept `--json` as a no-op (these commands already only have a machine
/// form, but the CLI-wide contract — issue #315 — says every read command
/// accepts `--json`, so it must not trip the unexpected-argument rejection
/// below), reject any other argument, then emit the JSON report.
private func runAlwaysJSONCommand(
    _ command: String,
    rest: [String],
    controller: TuneController,
    report: (TuneController) -> some Encodable
) throws {
    if rest.contains(where: { $0 == "--help" || $0 == "-h" }) {
        emitAlwaysJSONCommandHelp(command)
        return
    }
    let remaining = rest.filter { $0 != "--json" }
    try rejectUnexpectedArguments(remaining, command: command)
    try emitJSON(report(controller))
}

/// Read-only JSON commands with no subcommand parsing. Returns `false` when
/// the command is not one of them, so the main dispatcher keeps handling it.
func runReadCommand(_ command: String, rest: [String], controller: TuneController) throws -> Bool {
    switch command {
    case "doctor":
        try runAlwaysJSONCommand(command, rest: rest, controller: controller) { $0.capabilities() }
    case "sensors":
        try runAlwaysJSONCommand(command, rest: rest, controller: controller) { $0.sensorsReport() }
    case "battery":
        try runAlwaysJSONCommand(command, rest: rest, controller: controller) { $0.batteryReport() }
    case "displays":
        try runAlwaysJSONCommand(command, rest: rest, controller: controller) { $0.displaysReport() }
    case "permissions":
        try runAlwaysJSONCommand(command, rest: rest, controller: controller) { $0.permissions() }
    case "metrics":
        try runMetrics(rest, controller: controller)
    case "ai-usage":
        try runAIUsage(rest, controller: controller)
    case "processes", "top":
        try runProcesses(rest, controller: controller)
    default:
        return false
    }
    return true
}

/// `symtune processes` — which processes are using the most CPU or memory.
///
/// Argument parsing and table layout live in
/// ``ProcessListingPresentation`` so they are covered by unit tests; this
/// function is the I/O around them.
func runProcesses(_ args: [String], controller: TuneController) throws {
    let options = try ProcessListingPresentation.parseOptions(args)
    if options.wantsHelp {
        for line in ProcessListingPresentation.usageLines { emit(line) }
        return
    }

    // First sweep establishes the CPU baseline; without it every percentage
    // would be nil (or, worse, an average since boot).
    _ = controller.topProcesses(sortedBy: options.sortedBy, limit: options.limit)
    Thread.sleep(forTimeInterval: options.interval)
    let report = controller.topProcesses(sortedBy: options.sortedBy, limit: options.limit)

    if options.wantsJSON {
        try emitJSON(report)
        return
    }

    for line in ProcessListingPresentation.tableLines(for: report) { emit(line) }
    for note in report.notes {
        emitErr("note: \(note)")
    }
}

func runAIUsage(_ args: [String], controller: TuneController) throws {
    if args.contains(where: { $0 == "--help" || $0 == "-h" }) {
        emit("Usage: symtune ai-usage [--json]")
        emit("")
        emit("AI subscription/token usage per provider (OpenRouter, …). Read-only;")
        emit("no credentials are ever printed. --json emits the machine-readable")
        emit("form (same schema as the MCP get_ai_usage tool).")
        return
    }
    let wantsJSON = args.contains("--json")
    for arg in args where arg != "--json" {
        throw TuneError.usage("ai-usage: unexpected argument '\(arg)'")
    }
    let results = controller.aiUsageReport()
    if wantsJSON {
        try emitJSON(results)
        return
    }
    func fmt(_ value: Decimal?) -> String {
        value.map { String(format: "%.2f", NSDecimalNumber(decimal: $0).doubleValue) } ?? "—"
    }
    for result in results {
        if let snapshot = result.snapshot {
            emit("\(snapshot.providerID) (source: \(snapshot.source)):")
            for meter in snapshot.meters {
                let reset = meter.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "—"
                emit("  \(meter.label): \(fmt(meter.used)) / \(fmt(meter.limit)) \(meter.unit.unitLabel) (resets \(reset))")
            }
            if let balance = snapshot.balance {
                emit("  Balance: \(String(format: "%.2f", NSDecimalNumber(decimal: balance).doubleValue)) \(snapshot.currency ?? "")")
            }
        } else {
            emit("\(result.providerID): not set up (\(result.error ?? "unknown"))")
        }
    }
}
