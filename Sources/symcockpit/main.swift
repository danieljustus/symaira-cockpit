// symcockpit — unified entrypoint for the cockpit tool family.
//
//   symcockpit <command>           thermals, brightness, power
//   symcockpit version             the Cockpit version (JSON)
//
// Direct commands delegate to the tuning library; the removed `tune` prefix
// prints a migration hint.

import Foundation
import SymCockpitVersion
import SymCockpitCLI
import SymCockpitCore
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

symcockpit covers this machine's thermals, power, display and brightness.
Operate and Scope moved to Symaira Brain as optional modules; the legacy
dispatcher commands are removed.

The `symcockpit tune <command>` prefix was removed in v0.12 after its
deprecation window (v0.8 and v0.9); run `symcockpit <command>` directly.

"""

/// The version report, in the ecosystem's `version --json` shape: a `tool`
/// and its `version`. Cockpit ships no sub-families, so `families` is empty.
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
        families: [],
        update: resolvedUpdate
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    return String(decoding: data, as: UTF8.self)
}

// The tuning package cannot know the shipped CLI version; tell it, so a stale
// root-owned copy is refused before elevation and reported by `doctor` (#409).
PrivilegedElevation.setExpectedVersion(CockpitVersion.current)

let args = Array(CommandLine.arguments.dropFirst())

guard args.first != nil else {
    fputs(usage, stderr)
    exit(2)
}

let code: Int32
switch args[0] {
case "tune":
    // PB-2026-09-09: the prefix was deprecated through v0.9 and removed in
    // v0.12. Name the direct command instead of a generic usage error.
    let direct = (["symcockpit"] + args.dropFirst()).joined(separator: " ")
    let suggestion = args.count > 1 ? direct : "symcockpit <command>"
    FileHandle.standardError.write(Data("symcockpit: the 'tune' prefix was removed; run '\(suggestion)' instead.\n".utf8))
    code = 2
case "version", "--version", "-V":
    let update = await checkForCockpitUpdateIfEnabled(args: args)
    if args.contains("--json") {
        print(try await cockpitVersionJSON(update: update))
    } else {
        var line = "symcockpit \(CockpitVersion.current)"
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

        symcockpit now ships hardware and system tuning only (thermals, power,
        display, brightness). See docs/product-boundaries.md (PB-2026-09-09).

        """.utf8))
    code = 4
default:
    if tuneDirectAliases.contains(args[0]) {
        code = SymCockpitMain.run(args)
    } else {
        FileHandle.standardError.write(Data("symcockpit: unknown family '\(args[0])'\n\n".utf8))
        fputs(usage, stderr)
        code = 2
    }
}

exit(code)
