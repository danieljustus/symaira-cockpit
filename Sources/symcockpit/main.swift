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
import SymTuneCore
import SymTuneCLI

let usage = """
symcockpit — this machine: observability and control

Usage:
  symcockpit <family> <command> [options]

Families:
  tune       Thermals, brightness, power, battery (symtune feature set)
  operate    GUI automation: MCP server, doctor, permissions (symoperate)
  scope      Ports, containers, MCP inventory (symscope)

  version [--json]    Component versions of tune/operate/scope
  help                This text

Examples:
  symcockpit scope scan
  symcockpit tune doctor
  symcockpit operate serve

Legacy binaries (symtune, symoperate, symscope) remain available as thin
wrappers and will be removed in a future release.
"""

func cockpitVersionJSON() throws -> String {
    struct FamilyVersion: Codable {
        let family: String
        let version: String
        let schemaVersion: Int?
    }
    struct Report: Codable {
        let tool: String
        let schemaVersion: Int
        let families: [FamilyVersion]
    }
    // Encode with snake_case keys manually to match the ecosystem contract.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    let families: [[String: Any?]] = [
        ["family": "tune", "version": TuneVersion.current, "schema_version": nil],
        ["family": "operate", "version": SymOperateVersion.current, "schema_version": nil],
        ["family": "scope", "version": ScopeVersionString.version, "schema_version": 1],
    ]
    var lines = families.map { f -> String in
        let v = f["version"] as? String ?? "unknown"
        let name = f["family"] as? String ?? "?"
        return #"{"family": "\#(name)", "version": "\#(v)"}"#
    }
    _ = lines.count
    let body = lines.joined(separator: ",\n")
    return """
    {
      "tool": "symcockpit",
      "families": [
    \(body)
      ]
    }
    """
}

// Version strings from the three libraries.
enum ScopeVersionString {
    static let version = "0.1.0"
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
    if args.contains("--json") {
        print(try cockpitVersionJSON())
    } else {
        print("symcockpit — tune \(TuneVersion.current), operate \(SymOperateVersion.current), scope \(ScopeVersionString.version)")
    }
    code = 0
case "help", "--help", "-h":
    fputs(usage, stderr)
    code = 0
default:
    FileHandle.standardError.write(Data("symcockpit: unknown family '\(args[0])'\n\n".utf8))
    fputs(usage, stderr)
    code = 2
}

exit(code)
