// symcockpit — unified entrypoint for the cockpit tool family.
//
//   symcockpit tune <command>      thermals, brightness, power
//   symcockpit operate <command>   GUI automation (MCP server, doctor)
//   symcockpit scope <command>     ports, containers, MCP inventory
//   symcockpit version             all three component versions (JSON)
//
// Each subcommand delegates to the respective CLI library in the same
// process; exit codes propagate unchanged.

import Foundation
import SymOperateCore
import SymOperateCLI
import SymScopeCLI
import SymScopeCore
import SymTuneCore
import SymTuneCLI
import SymairaUpdateCheck

let usage = """
symcockpit — this machine: observability and control

Usage:
  symcockpit <family> <command> [options]

Families:
  tune       Thermals, brightness, power, battery (symtune feature set)
  operate    GUI automation: MCP server, doctor, permissions (symoperate)
  scope      Ports, containers, MCP inventory (symscope)

  version [--json] [--no-update-check]    symcockpit version plus the component versions
  help                This text

Examples:
  symcockpit scope scan
  symcockpit tune doctor
  symcockpit operate serve

symcockpit replaces the former symtune, symoperate and symscope binaries;
their commands are now the family subcommands above.
"""

/// The product version of symcockpit itself, as opposed to the versions of
/// the three families it dispatches to. Those keep their own numbering: they
/// were separately released tools before the repo consolidation, and their
/// version history stays meaningful to anyone migrating from them.
enum CockpitVersion {
    static let current = "0.5.1"
}

/// The version report, in the ecosystem's `version --json` shape: a `tool`,
/// its `version`, and the component families underneath.
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
            FamilyVersion(family: "operate", version: SymOperateVersion.current, schemaVersion: nil),
            FamilyVersion(family: "scope", version: Version.version, schemaVersion: 1),
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
    code = SymTuneMain.run(Array(args.dropFirst()))
case "operate":
    code = OperateMain.run(Array(args.dropFirst()))
case "scope":
    code = await ScopeMain.run(Array(args.dropFirst()))
case "version":
    let update = await checkForCockpitUpdateIfEnabled(args: args)
    if args.contains("--json") {
        print(try await cockpitVersionJSON(update: update))
    } else {
        var line = "symcockpit \(CockpitVersion.current) — tune \(TuneVersion.current), operate \(SymOperateVersion.current), scope \(Version.version)"
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
default:
    FileHandle.standardError.write(Data("symcockpit: unknown family '\(args[0])'\n\n".utf8))
    fputs(usage, stderr)
    code = 2
}

exit(code)
