//! The v0.12 command set: every CLI command and every MCP tool the Swift
//! binary ships, with its risk class and MCP input schema.
//!
//! One entry per CLI command path; `mcp_name` is set when v0.12 also exposes
//! it as an MCP tool. Risky tools keep their v0.12 MCP names for compatibility
//! (they move behind `plan_*`/`confirm_plan` in a later stage).

use std::sync::LazyLock;

use serde::Serialize;
use serde_json::{Value, json};

use crate::Risk;

/// One command: how it is called on the CLI, whether and how agents see it,
/// and how dangerous it is.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct CommandSpec {
    /// Canonical identifier (dotted: `brightness.set`).
    pub name: &'static str,
    /// CLI words after `symcockpit`, e.g. `brightness set`.
    pub cli_path: &'static str,
    /// MCP tool name, `None` when agents cannot call it.
    pub mcp_name: Option<&'static str>,
    /// Functional area: `monitor`, `tune` or `system`.
    pub area: &'static str,
    pub risk: Risk,
    /// JSON Schema of the MCP tool arguments, exactly as v0.12 lists it.
    pub input_schema: Value,
}

/// The whole register, in a stable order.
pub fn commands() -> &'static [CommandSpec] {
    static COMMANDS: LazyLock<Vec<CommandSpec>> = LazyLock::new(build);
    &COMMANDS
}

fn object(properties: Value, required: &[&str]) -> Value {
    json!({"type": "object", "properties": properties, "required": required})
}

fn no_args() -> Value {
    object(json!({}), &[])
}

fn ranged(arg: &str, kind: &str, min: Value, max: Value) -> Value {
    object(
        json!({arg: {"type": kind, "minimum": min, "maximum": max}}),
        &[arg],
    )
}

fn named() -> Value {
    object(json!({"name": {"type": "string"}}), &["name"])
}

fn build() -> Vec<CommandSpec> {
    use Risk::{Read, Reversible, Risky};
    let spec = |name, cli_path, mcp_name, area, risk, input_schema| CommandSpec {
        name,
        cli_path,
        mcp_name,
        area,
        risk,
        input_schema,
    };
    vec![
        // Read commands.
        spec(
            "doctor",
            "doctor",
            Some("get_capabilities"),
            "system",
            Read,
            no_args(),
        ),
        spec(
            "sensors",
            "sensors",
            Some("get_sensors"),
            "monitor",
            Read,
            no_args(),
        ),
        spec(
            "battery",
            "battery",
            Some("get_battery"),
            "monitor",
            Read,
            no_args(),
        ),
        spec(
            "displays",
            "displays",
            Some("list_displays"),
            "monitor",
            Read,
            no_args(),
        ),
        spec(
            "permissions",
            "permissions",
            None,
            "system",
            Read,
            no_args(),
        ),
        spec(
            "metrics",
            "metrics",
            Some("get_system_metrics"),
            "monitor",
            Read,
            no_args(),
        ),
        spec(
            "processes",
            "processes",
            Some("get_top_processes"),
            "monitor",
            Read,
            object(
                json!({
                    "sort_by": {
                        "type": "string",
                        "description": "Ranking key: 'cpu' (default), 'memory' or 'gpu'."
                    },
                    "limit": {
                        "type": "integer",
                        "description": "How many processes to return (1–50).",
                        "minimum": 1,
                        "maximum": 50
                    }
                }),
                &[],
            ),
        ),
        spec("top", "top", None, "monitor", Read, no_args()),
        spec(
            "ai-usage",
            "ai-usage",
            Some("get_ai_usage"),
            "monitor",
            Read,
            no_args(),
        ),
        spec(
            "ai-usage.serve",
            "ai-usage serve",
            None,
            "monitor",
            Read,
            no_args(),
        ),
        spec(
            "status",
            "status",
            Some("get_status"),
            "monitor",
            Read,
            no_args(),
        ),
        spec(
            "history",
            "history",
            Some("get_history"),
            "system",
            Read,
            object(
                json!({"limit": {
                    "type": "integer",
                    "description": "Maximum number of events to return (default 100)."
                }}),
                &[],
            ),
        ),
        spec(
            "brightness.get",
            "brightness get",
            Some("get_brightness"),
            "tune",
            Read,
            no_args(),
        ),
        spec(
            "awake.status",
            "awake status",
            Some("keep_awake_status"),
            "tune",
            Read,
            no_args(),
        ),
        spec(
            "profile.list",
            "profile list",
            Some("list_profiles"),
            "tune",
            Read,
            no_args(),
        ),
        spec("fan.status", "fan status", None, "tune", Read, no_args()),
        spec("serve", "serve", None, "system", Read, no_args()),
        spec("version", "version", None, "system", Read, no_args()),
        spec("help", "help", None, "system", Read, no_args()),
        // Reversible: reset on exit or by their own inverse command.
        spec(
            "brightness.set",
            "brightness set",
            Some("set_brightness"),
            "tune",
            Reversible,
            ranged("value", "number", json!(0), json!(1)),
        ),
        spec(
            "extbright.set",
            "extbright set",
            Some("set_extended_brightness"),
            "tune",
            Reversible,
            ranged("value", "number", json!(1), json!(1.6)),
        ),
        spec(
            "dim.set",
            "dim set",
            Some("set_dim"),
            "tune",
            Reversible,
            ranged("value", "number", json!(0.15), json!(1)),
        ),
        spec(
            "dim.reset",
            "dim reset",
            Some("reset_dim"),
            "tune",
            Reversible,
            no_args(),
        ),
        spec(
            "warmth.set",
            "warmth set",
            Some("set_warmth"),
            "tune",
            Reversible,
            ranged("value", "number", json!(0), json!(1)),
        ),
        spec(
            "warmth.reset",
            "warmth reset",
            Some("reset_warmth"),
            "tune",
            Reversible,
            no_args(),
        ),
        spec(
            "awake",
            "awake",
            Some("keep_awake"),
            "tune",
            Reversible,
            object(
                json!({
                    "enabled": {
                        "type": "boolean",
                        "description": "Set to true to start a session, false to end it."
                    },
                    "prevent_display_sleep": {
                        "type": "boolean",
                        "description": "When true, also prevent display sleep."
                    },
                    "duration_seconds": {
                        "type": "number",
                        "description": "Optional session duration in seconds, between 0 and 86400 (24 hours). Omit for an indefinite session.",
                        "minimum": 0,
                        "maximum": 86400
                    }
                }),
                &["enabled"],
            ),
        ),
        spec(
            "awake.off",
            "awake off",
            None,
            "tune",
            Reversible,
            no_args(),
        ),
        spec(
            "profile.save",
            "profile save",
            Some("save_profile"),
            "tune",
            Reversible,
            named(),
        ),
        spec(
            "profile.load",
            "profile load",
            Some("load_profile"),
            "tune",
            Reversible,
            named(),
        ),
        spec(
            "profile.delete",
            "profile delete",
            Some("delete_profile"),
            "tune",
            Reversible,
            named(),
        ),
        // Risky: fans, charging and the global restore.
        spec(
            "restore",
            "restore",
            Some("restore"),
            "tune",
            Risky,
            no_args(),
        ),
        spec(
            "fan.set",
            "fan set",
            Some("set_fan"),
            "tune",
            Risky,
            ranged("fraction", "number", json!(0), json!(1)),
        ),
        spec("fan.auto", "fan auto", None, "tune", Risky, no_args()),
        spec("fan.profile", "fan profile", None, "tune", Risky, no_args()),
        spec("fan.target", "fan target", None, "tune", Risky, no_args()),
        spec(
            "fan.governor",
            "fan governor",
            None,
            "tune",
            Risky,
            no_args(),
        ),
        spec(
            "battery-limit.set",
            "battery-limit set",
            Some("set_charge_limit"),
            "tune",
            Risky,
            ranged("percent", "integer", json!(50), json!(100)),
        ),
        spec(
            "battery-limit.clear",
            "battery-limit clear",
            Some("clear_charge_limit"),
            "tune",
            Risky,
            no_args(),
        ),
    ]
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::*;

    /// MCP tool names of v0.12, in registration order. Source of truth:
    /// `tuning/Sources/SymCockpitMCP/TuneTools.swift` (`defaultTools`, lines 56-73,
    /// each tool's `let name`) followed by the `mcpName` of every entry in
    /// `tuning/Sources/SymCockpitCore/WriteCommand.swift` (`WriteCommand.all`,
    /// lines 77-203). Confirmed against `symcockpit serve` `tools/list` (26 tools).
    const V012_MCP_TOOLS: [&str; 26] = [
        "get_capabilities",
        "get_sensors",
        "get_battery",
        "list_displays",
        "get_system_metrics",
        "get_top_processes",
        "get_ai_usage",
        "keep_awake",
        "keep_awake_status",
        "get_brightness",
        "save_profile",
        "load_profile",
        "list_profiles",
        "delete_profile",
        "get_status",
        "get_history",
        "set_brightness",
        "set_extended_brightness",
        "set_dim",
        "reset_dim",
        "set_warmth",
        "reset_warmth",
        "restore",
        "set_fan",
        "set_charge_limit",
        "clear_charge_limit",
    ];

    /// Top-level CLI commands of v0.12: `CockpitCommandMap.directTuneCommands`
    /// plus `version`/`help` in `Sources/symcockpit/CommandMap.swift` and `main.swift`.
    const V012_CLI_COMMANDS: [&str; 23] = [
        "sensors",
        "battery",
        "displays",
        "metrics",
        "ai-usage",
        "processes",
        "top",
        "status",
        "awake",
        "brightness",
        "extbright",
        "dim",
        "warmth",
        "restore",
        "profile",
        "fan",
        "battery-limit",
        "doctor",
        "permissions",
        "serve",
        "history",
        "version",
        "help",
    ];

    #[test]
    fn mcp_names_and_cli_paths_are_unique() {
        let mut mcp = BTreeSet::new();
        let mut cli = BTreeSet::new();
        let mut names = BTreeSet::new();
        for c in commands() {
            assert!(names.insert(c.name), "duplicate name {}", c.name);
            assert!(cli.insert(c.cli_path), "duplicate cli_path {}", c.cli_path);
            if let Some(m) = c.mcp_name {
                assert!(mcp.insert(m), "duplicate mcp_name {m}");
            }
        }
    }

    #[test]
    fn human_only_commands_have_no_mcp_name() {
        for c in commands().iter().filter(|c| c.risk == Risk::HumanOnly) {
            assert!(c.mcp_name.is_none(), "{} is human_only but exposed", c.name);
        }
    }

    #[test]
    fn register_holds_exactly_the_v012_mcp_tools() {
        let got: Vec<_> = commands().iter().filter_map(|c| c.mcp_name).collect();
        let want: BTreeSet<_> = V012_MCP_TOOLS.into_iter().collect();
        assert_eq!(got.len(), want.len());
        assert_eq!(got.into_iter().collect::<BTreeSet<_>>(), want);
    }

    #[test]
    fn register_covers_every_v012_cli_command() {
        let top: BTreeSet<_> = commands()
            .iter()
            .filter_map(|c| c.cli_path.split(' ').next())
            .collect();
        assert_eq!(top, V012_CLI_COMMANDS.into_iter().collect::<BTreeSet<_>>());
    }

    #[test]
    fn mcp_names_match_the_swift_sources() {
        // Guards the constant above against drift while the Swift core lives;
        // delete with it when the Swift sources are retired.
        let tools = include_str!("../../../tuning/Sources/SymCockpitMCP/TuneTools.swift");
        let writes = include_str!("../../../tuning/Sources/SymCockpitCore/WriteCommand.swift");
        let quoted = |line: &str, prefix: &str| {
            line.trim()
                .strip_prefix(prefix)
                .and_then(|r| r.split('"').next())
                .map(str::to_owned)
        };
        let mut from_swift: Vec<String> = tools
            .lines()
            .filter_map(|l| quoted(l, "let name = \""))
            .collect();
        from_swift.extend(writes.lines().filter_map(|l| quoted(l, "mcpName: \"")));
        let mut want: Vec<String> = V012_MCP_TOOLS.iter().map(|s| (*s).to_owned()).collect();
        from_swift.sort();
        want.sort();
        assert_eq!(from_swift, want);
    }

    #[test]
    fn risks_follow_the_plan() {
        let risk = |n: &str| commands().iter().find(|c| c.name == n).unwrap().risk;
        for n in ["sensors", "status", "history", "fan.status"] {
            assert_eq!(risk(n), Risk::Read, "{n}");
        }
        for n in [
            "brightness.set",
            "extbright.set",
            "warmth.set",
            "dim.set",
            "awake",
            "profile.load",
        ] {
            assert_eq!(risk(n), Risk::Reversible, "{n}");
        }
        for n in [
            "fan.set",
            "battery-limit.set",
            "battery-limit.clear",
            "restore",
        ] {
            assert_eq!(risk(n), Risk::Risky, "{n}");
        }
    }

    #[test]
    fn schemas_are_objects_with_declared_required_properties() {
        for c in commands() {
            let s = &c.input_schema;
            assert_eq!(s["type"], "object", "{}", c.name);
            for r in s["required"].as_array().unwrap() {
                assert!(
                    s["properties"].get(r.as_str().unwrap()).is_some(),
                    "{}",
                    c.name
                );
            }
        }
    }
}
