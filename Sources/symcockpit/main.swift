// symcockpit — unified entrypoint for the cockpit tool family.
//
//   symcockpit <command>           thermals, brightness, power
//   symcockpit version             the Tune component version (JSON)
//
// Direct commands and the deprecated tune prefix delegate to the same library.

import Foundation
import SymCockpitVersion
import SymTuneCore
import SymTuneCLI
import SymairaUpdateCheck

let usage = """
symcockpit — this machine: hardware and system tuning

Usage:
  symcockpit <command> [options]

Commands:
  sensors, battery, displays, metrics, status, processes, top
  awake, brightness, extbright, dim, warmth, restore, profile
  fan, battery-limit, ai-usage, doctor, permissions, history, serve

  version [--json] [--no-update-check]    symcockpit version plus the component versions
  --version, -V                           aliases for `symcockpit version`
  help                This text

Examples:
  symcockpit doctor

symcockpit provides the tune command tree; operate and scope moved to
Symaira Brain as optional modules. The legacy dispatcher commands are removed.

The legacy `symcockpit tune <command>` spelling remains available with a
deprecation warning through Cockpit v0.9. Use direct commands instead.

"""

/// The version report, in the ecosystem's `version --json` shape: a `tool`,
/// its `version`, and the Tune component underneath.
func cockpitVersionJSON(update: CockpitUpdateReport? = nil) async throws -> String {
    struct FamilyVersion: Encodable {
        let family: String
        let version: String
        let schemaVersion: Int?

        enum CodingKeys: String, CodingKey {
            case family
            case version
            case schemaVersion = "schema_version"
        }
    }
    struct Report: Encodable {
        let tool: String
        let version: String
        let schemaVersion: Int
        let families: [FamilyVersion]
        let update: CockpitUpdateReport

        enum CodingKeys: String, CodingKey {
            case tool
            case version
            case schemaVersion = "schema_version"
            case families
            case update
        }
    }

    let resolvedUpdate: CockpitUpdateReport
    if let update {
        resolvedUpdate = update
    } else {
        resolvedUpdate = await checkForCockpitUpdateIfEnabled()
    }

    let report = Report(
        tool: "symcockpit",
        version: CockpitVersion.current,
        schemaVersion: 1,
        families: [
            FamilyVersion(family: "tune", version: TuneVersion.current, schemaVersion: nil),
        ],
        update: resolvedUpdate
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    return String(decoding: data, as: UTF8.self)
}

let args = Array(CommandLine.arguments.dropFirst())

guard args.first != nil else {
    fputs(usage, stderr)
    exit(2)
}

let code: Int32
switch args[0] {
case "tune":
    FileHandle.standardError.write(Data("symcockpit: 'tune' is deprecated; use 'symcockpit <command>' directly (supported through v0.9).\n".utf8))
    code = SymTuneMain.run(Array(args.dropFirst()))
case "version", "--version", "-V":
    let update = await checkForCockpitUpdateIfEnabled(args: args)
    if args.contains("--json") {
        print(try await cockpitVersionJSON(update: update))
    } else {
        var line = "symcockpit \(CockpitVersion.current) — tune \(TuneVersion.current)"
        switch update.status {
        case "available":
            if let latest = update.latestVersion { line += " — update available: \(latest)" }
        case "unavailable":
            line += " — update check unavailable"
        case "skipped":
            line += " — update check skipped"
        default:
            line += " — up to date"
        }
        print(line)
    }
    code = 0
case "help", "--help", "-h":
    FileHandle.standardOutput.write(Data(usage.utf8))
    code = 0
case "operate", "scope":
    // PB-2026-09-09: these families moved to Symaira Brain as optional
    // modules. Legacy callers get a dedicated migration hint and exit 4
    // (unsupported) instead of the generic unknown-family usage exit 2.
    FileHandle.standardError.write(Data("""

        symcockpit: '\(args[0])' moved to Symaira Brain as an optional module.
        Install it from a Brain checkout:
          symbrain setup --from-source <brain-checkout> --modules \(args[0])

        symcockpit now ships only the tune command tree (thermals, power,
        display, brightness). See docs/product-boundaries.md (PB-2026-09-09).

        """.utf8))
    code = 4
default:
    if tuneDirectAliases.contains(args[0]) {
        code = SymTuneMain.run(args)
    } else {
        FileHandle.standardError.write(Data("symcockpit: unknown family '\(args[0])'\n\n".utf8))
        fputs(usage, stderr)
        code = 2
    }
}

exit(code)
