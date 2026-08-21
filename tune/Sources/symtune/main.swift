import Foundation
import SymTuneCore
import SymTuneMCP

let usage = """
symtune \(TuneVersion.current) — tune your Mac (thermals, brightness, power) from the CLI and for AI agents.

USAGE
  symtune <command> [options]

READ COMMANDS
  doctor                 Capabilities, host info, and recommendations (JSON).
  status [--json] [--watch [--interval <duration>]]
                         System health status snapshot (Score, overrides, sensors, battery).
  history [--json]       Write operations history log.
  sensors                Thermal pressure + (when available) temps/fan RPM (JSON).
  battery                Battery health: charge %, cycles, capacity, condition (JSON).
  displays               Displays with EDR headroom / extended-brightness capability (JSON).
  permissions            Permission & SMC write status (JSON).
  metrics [--json]       System metrics: CPU, memory, disk, network (JSON).
  processes [--sort cpu|memory] [--limit N] [--interval <seconds>] [--json]
                         Processes using the most CPU / memory (samples twice).
  ai-usage [--json]      AI subscription/token usage per provider (read-only).

POWER
  awake [--display] [--seconds N]
                         Blocking mode: prevent idle sleep until N seconds
                         elapse, or until Ctrl-C if --seconds is omitted.
                         --display also keeps the screen on.
  awake --for <duration>
                         Blocking mode: keep awake for a parsed duration
                         (e.g. 30m, 2h, 1.5h).
  awake --until HH:MM
                         Blocking mode: keep awake until the given time
                         (24-hour clock, e.g. 14:30).
  awake status           Print the current keep-awake session state as JSON.
  awake off              End the current keep-awake session.

WRITE COMMANDS
  brightness get                Read built-in display brightness (0.0–1.0)
  brightness set <0.0-1.0>     Built-in display brightness
  extbright set <1.0-1.6>     Extended/EDR brightness multiplier
  dim set <0.15-1.0>          Software dim overlay
  dim reset                   Remove all dim overlays
  warmth set <0.0-1.0>        Color temperature warmth (gamma)
  warmth reset                Reset warmth to neutral
  restore                     Restore all overrides to defaults
  fan set <0.0-1.0>           Fan speed fraction (requires sudo)
  fan auto                    Return fans to firmware automatic control
  battery-limit set <50-100>  Hold charge at target percent (requires sudo)
  battery-limit clear         Re-enable charging (requires sudo)
  profile save <name>         Save current settings as a profile
  profile load <name>         Apply a saved profile
  profile list                List saved profiles
  profile delete <name>       Delete a saved profile

PRIVILEGED SMC WRITES
  Fan and battery-limit commands write to the Apple SMC. They must be run as
  root, e.g. `sudo symtune fan set 0.5`. Values are clamped to safe ranges and
  original settings are restored on normal exit or Ctrl-C.

AGENTS
  serve                  Run the MCP server over stdio.

  version [--check-for-updates] | help

  --check-for-updates    Check GitHub for a newer version (writes notices to stderr, waits up to ~5s).
"""

func emitJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func emit(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

func emitErr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

func runVersion(checkForUpdates: Bool) {
    emit("symtune \(TuneVersion.current)")
    guard checkForUpdates else { return }
    // The explicitly requested check must actually print its notice before
    // the process exits: block until the detached check finishes, with a
    // bounded wait as a safety net (the checker itself times out after ~1s,
    // so the worst case adds ~1s for this flag).
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        if let info = await UpdateChecker.checkForUpdate(),
           info.updateAvailable,
           let url = info.downloadURL
        {
            emitErr("A new version (\(info.latestVersion)) is available. Download: \(url)")
        }
        done.signal()
    }
    _ = done.wait(timeout: .now() + 5)
}

/// Pull the first parseable Double out of the remaining args (accepts an
/// optional leading `set`), e.g. `extbright set 1.4` or `dim 0.5`.
func parseValue(_ args: [String], command: String) throws -> Double {
    for arg in args {
        if arg == "set" { continue }
        if let value = Double(arg) { return value }
        throw TuneError.usage("\(command): unexpected argument '\(arg)'")
    }
    throw TuneError.usage("\(command): expected a numeric value, e.g. `symtune \(command) set 1.4`")
}

func parseInt(_ args: [String], command: String) throws -> Int {
    for arg in args {
        if arg == "set" { continue }
        if let value = Int(arg) { return value }
        throw TuneError.usage("\(command): unexpected argument '\(arg)'")
    }
    throw TuneError.usage("\(command): expected an integer value, e.g. `symtune \(command) set 80`")
}

func runAwake(_ args: [String], controller: TuneController) throws {
    let options = try AwakeOptions.parseOptions(args)

    // Handle subcommands first.
    if let subcommand = options.subcommand {
        if subcommand == .status {
            try emitJSON(controller.keepAwakeSessionStatus())
        } else {
            controller.endKeepAwakeSession()
            try emitJSON(KeepAwakeSession.inactive)
        }
        return
    }

    let token = try controller.beginKeepAwake(reason: "symtune awake", preventDisplaySleep: options.preventDisplaySleep)
    defer { controller.endKeepAwake(token) }

    if let seconds = options.seconds {
        emitErr("symtune: holding wake assertion for \(seconds)s…")
        // Double-check: don't block beyond a reasonable maximum.
        let capped = min(seconds, 86_400) // 24 hours max
        if capped != seconds {
            emitErr("symtune: duration capped to 24 hours (86400s)")
        }
        Thread.sleep(forTimeInterval: capped)
    } else {
        emitErr("symtune: holding wake assertion (Ctrl-C to release)…")
        RunLoop.current.run()
    }
}

func runProfile(_ args: [String], controller: TuneController) throws {
    guard let subcommand = args.first else {
        throw TuneError.usage("profile: expected subcommand (save, load, list, delete).")
    }
    let rest = Array(args.dropFirst())

    switch subcommand {
    case "save":
        guard let name = rest.first else {
            throw TuneError.usage("profile save: expected a name.")
        }
        let brightness = try? controller.getBuiltinBrightness()
        let profile = try TuneProfile(
            name: name,
            brightness: brightness,
            dim: controller.getDimLevel(),
            warmth: controller.getWarmthLevel()
        )
        try controller.saveProfile(profile)
        try emitJSON(ProfileSaved(saved: name))
    case "load":
        guard let name = rest.first else {
            throw TuneError.usage("profile load: expected a name.")
        }
        let profile = try controller.loadProfile(name: name)
        try controller.applyProfile(profile)
        try emitJSON(ApplyResult(applied: true))
    case "list":
        let profiles = controller.listProfiles()
        try emitJSON(ProfileList(profiles: profiles))
    case "delete":
        guard let name = rest.first else {
            throw TuneError.usage("profile delete: expected a name.")
        }
        try controller.deleteProfile(name: name)
        try emitJSON(ApplyResult(applied: true))
    default:
        throw TuneError.usage("profile: unknown subcommand '\(subcommand)'.")
    }
}
func emitNDJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func runStatus(_ args: [String], controller: TuneController) throws {
    let options = try StatusOptions.parseOptions(args)

    if options.isWatch {
        while true {
            let report = controller.statusReport()
            try emitNDJSON(report)
            Thread.sleep(forTimeInterval: options.interval)
        }
    } else {
        let report = controller.statusReport()
        if options.isJson {
            try emitJSON(report)
        } else {
            emit("symtune health: \(report.healthScoreMsg) (Score: \(report.healthScore)/100)")
            emit("\nRecommendations:")
            for rec in report.recommendations {
                emit("- \(rec)")
            }
            emit("\nActive Overrides:")
            let o = report.activeOverrides
            var anyOverride = false
            if let b = o.brightness {
                emit("- Brightness: \(Int(b * 100))%")
                anyOverride = true
            }
            if let d = o.dim {
                emit("- Software Dim: \(Int(d * 100))%")
                anyOverride = true
            }
            if let w = o.warmth {
                emit("- Warmth: \(Int(w * 100))%")
                anyOverride = true
            }
            if let edr = o.edrBrightness {
                emit("- Extended EDR Brightness: \(String(format: "%.1f", edr))x")
                anyOverride = true
            }
            if let fan = o.fanFraction {
                emit("- Fan: \(Int(fan * 100))%")
                anyOverride = true
            }
            if let charge = o.chargeLimitPercent {
                var line = "- Charge Limit: \(charge)%"
                if let state = o.chargeLimitState {
                    line += " (\(state.rawValue))"
                }
                emit(line)
                anyOverride = true
            }
            if !anyOverride {
                emit("- None")
            }
        }
    }
}

func runHistory(_ args: [String], controller: TuneController) throws {
    let options = try HistoryOptions.parseOptions(args)

    let events = controller.getHistory(limit: options.limit)
    if options.isJson {
        try emitJSON(events)
    } else {
        if events.isEmpty {
            emit("No history events recorded.")
            return
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"

        emit(String(format: "%-20@ %-16@ %-10@ %-10@ %-10@ %-10@ %@",
                    "Timestamp" as NSString,
                    "Action" as NSString,
                    "Requested" as NSString,
                    "Clamped" as NSString,
                    "Applied" as NSString,
                    "Result" as NSString,
                    "Reason/Error" as NSString))
        emit(String(repeating: "-", count: 90))
        for event in events {
            let req = event.requestedValue != nil ? String(format: "%.2f", event.requestedValue!) : "n/a"
            let clm = event.clampedValue != nil ? String(format: "%.2f", event.clampedValue!) : "n/a"
            let app = event.appliedValue != nil ? String(format: "%.2f", event.appliedValue!) : "n/a"
            let err = event.errorReason ?? ""
            emit(String(format: "%-20@ %-16@ %-10@ %-10@ %-10@ %-10@ %@",
                        df.string(from: event.timestamp) as NSString,
                        event.action as NSString,
                        req as NSString,
                        clm as NSString,
                        app as NSString,
                        event.result as NSString,
                        err as NSString))
        }
    }
}

func runMetrics(_ args: [String], controller: TuneController) throws {
    if args.contains(where: { $0 == "--help" || $0 == "-h" }) {
        emit("Usage: symtune metrics [--json]")
        emit("")
        emit("Print system metrics: CPU utilization, memory pressure, disk usage,")
        emit("and network throughput. All values are read-only snapshots.")
        emit("--json is accepted for consistency with other read commands; it is a no-op here.")
        return
    }
    // metrics only has a machine (JSON) form; --json is accepted as a no-op
    // so it isn't rejected as an unexpected argument (issue #315).
    for arg in args where arg != "--json" {
        throw TuneError.usage("metrics: unexpected argument '\(arg)'")
    }
    try emitJSON(controller.metricsReport())
}

// MARK: - Write command framework (driven by WriteCommand.all)

/// Lookup table from CLI prefix (e.g. "brightness set") to WriteCommand descriptor.
private let writeCommandByPrefix: [String: WriteCommand] = {
    Dictionary(uniqueKeysWithValues: WriteCommand.all.map { ($0.cliPrefix, $0) })
}()

/// Run a write command through its descriptor, parse the value from the
/// remaining CLI args, apply it, and emit a JSON result.
private func runWriteCommand(_ cmd: WriteCommand, rest: [String], controller: TuneController) throws {
    if cmd.isContinuous {
        if cmd.valueType == .integer {
            let value = try parseInt(rest, command: cmd.cliPrefix)
            try cmd.apply(controller, Double(value))
        } else {
            let value = try parseValue(rest, command: cmd.cliPrefix)
            try cmd.apply(controller, value)
        }
    } else {
        try cmd.apply(controller, 0)
    }
    try emitJSON(ApplyResult(applied: true))
}

/// Dispatch to the appropriate command handler and run it.
/// Separated from runMain to keep cyclomatic complexity under the lint threshold.
private func dispatchCommand(_ command: String, rest: [String], controller: TuneController) throws -> Int32? {
    switch command {
    case "serve":
        // Long-lived stdio process: watch for wake events so a configured
        // charge limit is re-asserted after sleep (Apple Silicon).
        controller.startWakeMonitoring()
        try TuneMCPServer(controller: controller).run()
    case "status":
        try runStatus(rest, controller: controller)
    case "history":
        try runHistory(rest, controller: controller)
    case "awake":
        try runAwake(rest, controller: controller)
    case "brightness":
        if rest.first == "get" || rest.isEmpty {
            let brightness = try controller.getBuiltinBrightness()
            try emitJSON(BrightnessReadback(brightness: brightness))
        } else if let cmd = writeCommandByPrefix["brightness set"] {
            try runWriteCommand(cmd, rest: rest, controller: controller)
        } else {
            throw TuneError.usage("brightness: expected 'get' or 'set <value>'.")
        }
    case "extbright":
        if let cmd = writeCommandByPrefix["extbright set"] {
            try runWriteCommand(cmd, rest: rest, controller: controller)
        } else {
            throw TuneError.usage("extbright: expected 'set <value>'.")
        }
    case "dim":
        try runDimSubcommand(rest, controller: controller)
    case "warmth":
        try runWarmthSubcommand(rest, controller: controller)
    case "restore":
        if let cmd = writeCommandByPrefix["restore"] {
            try runWriteCommand(cmd, rest: rest, controller: controller)
        }
    case "profile":
        try runProfile(rest, controller: controller)
    case "fan":
        try runFanSubcommand(rest, controller: controller)
    case "battery-limit":
        try runBatteryLimitSubcommand(rest, controller: controller)
    case "version", "--version", "-v":
        runVersion(checkForUpdates: rest.contains("--check-for-updates"))
    case "help", "--help", "-h":
        emit(usage)
    default:
        return nil // unknown
    }
    return ExitCode.ok.rawValue
}

private func runDimSubcommand(_ rest: [String], controller: TuneController) throws {
    if rest.contains(where: { $0 == "--help" || $0 == "-h" }) {
        emit("Usage: symtune dim set <0.15-1.0>")
        emit("       symtune dim reset")
    } else if rest.first == "reset", let cmd = writeCommandByPrefix["dim reset"] {
        try runWriteCommand(cmd, rest: rest, controller: controller)
    } else if let cmd = writeCommandByPrefix["dim set"] {
        try runWriteCommand(cmd, rest: rest, controller: controller)
    } else {
        throw TuneError.usage("dim: expected 'set <value>' or 'reset'.")
    }
}

private func runWarmthSubcommand(_ rest: [String], controller: TuneController) throws {
    if rest.contains(where: { $0 == "--help" || $0 == "-h" }) {
        emit("Usage: symtune warmth set <0.0-1.0>")
        emit("       symtune warmth reset")
    } else if rest.first == "reset", let cmd = writeCommandByPrefix["warmth reset"] {
        try runWriteCommand(cmd, rest: rest, controller: controller)
    } else if let cmd = writeCommandByPrefix["warmth set"] {
        try runWriteCommand(cmd, rest: rest, controller: controller)
    } else {
        throw TuneError.usage("warmth: expected 'set <value>' or 'reset'.")
    }
}

private func runFanSubcommand(_ rest: [String], controller: TuneController) throws {
    if rest.contains(where: { $0 == "--help" || $0 == "-h" }) {
        emit("Usage: symtune fan set <0.0-1.0>")
        emit("       symtune fan auto")
    } else if rest.first == "auto" {
        try controller.restoreFanAuto()
        try emitJSON(ApplyResult(applied: true))
    } else if let cmd = writeCommandByPrefix["fan set"] {
        try runWriteCommand(cmd, rest: rest, controller: controller)
    } else {
        throw TuneError.usage("fan: expected 'set <value>' or 'auto'.")
    }
}

private func runBatteryLimitSubcommand(_ rest: [String], controller: TuneController) throws {
    if rest.contains(where: { $0 == "--help" || $0 == "-h" }) {
        emit("Usage: symtune battery-limit set <50-100>")
        emit("       symtune battery-limit clear")
    } else if rest.first == "clear", let cmd = writeCommandByPrefix["battery-limit clear"] {
        try runWriteCommand(cmd, rest: rest, controller: controller)
    } else if let cmd = writeCommandByPrefix["battery-limit set"] {
        try runWriteCommand(cmd, rest: rest, controller: controller)
    } else {
        throw TuneError.usage("battery-limit: expected 'set <value>' or 'clear'.")
    }
}

func runMain() -> Int32 {
    guard let command = CommandLine.arguments.dropFirst().first else {
        emit(usage)
        return ExitCode.ok.rawValue
    }
    let rest = Array(CommandLine.arguments.dropFirst(2))
    let controller = TuneController(config: ConfigPaths().loadConfig())

    let result: Int32
    do {
        if try runReadCommand(command, rest: rest, controller: controller) {
            result = ExitCode.ok.rawValue
        } else if let code = try dispatchCommand(command, rest: rest, controller: controller) {
            result = code
        } else {
            emitErr("symtune: unknown command '\(command)'")
            emit(usage)
            return ExitCode.usage.rawValue
        }
    } catch let error as TuneError {
        emitErr("symtune: \(error.description)")
        return error.exitCode
    } catch {
        result = handleNonTuneError(error)
    }
    return result
}

/// Handle a non-TuneError by building a structured error report and
/// writing it to stderr.
private func handleNonTuneError(_ error: Error) -> Int32 {
    let debug = ProcessInfo.processInfo.environment["SYMTUNE_DEBUG"] != nil
    emitErr("symtune: \(redactedErrorLine(for: error, debug: debug))")
    return ExitCode.error.rawValue
}

exit(runMain())
