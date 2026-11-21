//! Command specs of the storage health area: NVMe SMART, speed test, space analysis
//! (R30 to R33). [`specs`] joins the register through
//! [`super::all`].

use serde_json::{Value, json};

use crate::{CommandSpec, Risk};

/// Largest test file an agent may request through MCP, in MiB (2^20 bytes).
pub const MCP_SPEEDTEST_MAX_MIB: u64 = 1024;
/// Default test file size, in MiB.
pub const SPEEDTEST_DEFAULT_MIB: u64 = 256;

fn object(properties: Value, required: &[&str]) -> Value {
    json!({"type": "object", "properties": properties, "required": required})
}

pub fn specs() -> Vec<CommandSpec> {
    let spec = |name, cli_path, mcp_name, risk, input_schema| CommandSpec {
        name,
        cli_path,
        mcp_name: Some(mcp_name),
        area: "storage",
        risk,
        input_schema,
    };
    vec![
        // MCP never records: the tool stays read-only. The CLI records by default.
        spec(
            "storage.health",
            "storage health",
            "get_storage_health",
            Risk::Read,
            object(json!({}), &[]),
        ),
        spec(
            "storage.health.history",
            "storage health history",
            "get_storage_health_history",
            Risk::Read,
            object(
                json!({
                    "limit": {
                        "type": "integer",
                        "description": "How many measurements to return, newest first (1–1000, default 20).",
                        "minimum": 1,
                        "maximum": 1000
                    },
                    "device": {
                        "type": "string",
                        "description": "Device key as printed by get_storage_health (`location:model`); default all."
                    }
                }),
                &[],
            ),
        ),
        spec(
            "storage.speedtest",
            "storage speedtest",
            "run_speedtest",
            Risk::Reversible,
            object(
                json!({
                    "path": {
                        "type": "string",
                        "description": "Directory to test; must be under the home directory or /Volumes (default: home)."
                    },
                    "size_mib": {
                        "type": "integer",
                        "description": "Test file size in MiB (2^20 bytes), 1–1024, default 256.",
                        "minimum": 1,
                        "maximum": MCP_SPEEDTEST_MAX_MIB
                    },
                    "cache_mode": {
                        "type": "string",
                        "enum": ["uncached", "cached"],
                        "description": "uncached (default) asks the OS to bypass its file cache (F_NOCACHE)."
                    }
                }),
                &[],
            ),
        ),
        spec(
            "storage.space",
            "storage space",
            "analyze_space",
            Risk::Read,
            object(
                json!({
                    "path": {"type": "string", "description": "Directory to analyze."},
                    "depth": {
                        "type": "integer",
                        "description": "Levels of the tree to return (1–16, default 2).",
                        "minimum": 1,
                        "maximum": 16
                    },
                    "limit": {
                        "type": "integer",
                        "description": "Largest children kept per directory (1–200, default 10).",
                        "minimum": 1,
                        "maximum": 200
                    }
                }),
                &["path"],
            ),
        ),
    ]
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::*;
    use crate::commands;

    #[test]
    fn risks_and_exposure() {
        let risk = |n: &str| specs().into_iter().find(|c| c.name == n).unwrap().risk;
        assert_eq!(risk("storage.health"), Risk::Read);
        assert_eq!(risk("storage.health.history"), Risk::Read);
        assert_eq!(risk("storage.space"), Risk::Read);
        assert_eq!(risk("storage.speedtest"), Risk::Reversible);
        assert!(
            specs()
                .iter()
                .all(|c| c.mcp_name.is_some() && c.risk != Risk::HumanOnly)
        );
    }

    #[test]
    fn schemas_are_objects_with_declared_required_properties() {
        for c in specs() {
            assert_eq!(c.input_schema["type"], "object", "{}", c.name);
            for r in c.input_schema["required"].as_array().unwrap() {
                assert!(
                    c.input_schema["properties"]
                        .get(r.as_str().unwrap())
                        .is_some()
                );
            }
        }
        let speed = specs()
            .into_iter()
            .find(|c| c.name == "storage.speedtest")
            .unwrap();
        assert_eq!(
            speed.input_schema["properties"]["size_mib"]["maximum"],
            MCP_SPEEDTEST_MAX_MIB
        );
    }
}
