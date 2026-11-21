//! Commands of the storage cleanup area (R34, R35, R37, R04): cleanup by
//! catalog, duplicates, app uninstall and the generic plan commands.
//!
//! Creating a plan is `read` (nothing changes); confirming it is `risky`
//! (D10). MCP agents get only the `plan_*`, `find_duplicates`, `get_plan` and
//! `confirm_plan` tools; there is no `--yes` and no direct delete.
//! [`specs`] joins the register through [`super::all`].

use serde_json::{Value, json};

use crate::{CommandSpec, Risk};

fn object(properties: Value, required: &[&str]) -> Value {
    json!({"type": "object", "properties": properties, "required": required})
}

fn plan_id() -> Value {
    object(
        json!({"plan_id": {"type": "string", "description": "Id of a plan, as returned by a plan_* tool."}}),
        &["plan_id"],
    )
}

/// Cleanup categories of catalog version 1 (`symcockpit-core` checks that
/// this list equals its catalog).
pub const CLEAN_CATEGORIES: [&str; 4] = [
    "user_caches",
    "user_logs",
    "xcode_derived_data",
    "empty_trash",
];

pub fn specs() -> Vec<CommandSpec> {
    let spec = |name, cli_path, mcp_name, area, risk, input_schema| CommandSpec {
        name,
        cli_path,
        mcp_name,
        area,
        risk,
        input_schema,
    };
    let min_size = json!({"type": "integer", "minimum": 1, "description": "Ignore files smaller than this many bytes (default 1)."});
    vec![
        spec(
            "storage.clean",
            "storage clean",
            Some("plan_clean"),
            "storage",
            Risk::Read,
            object(
                json!({"categories": {
                    "type": "array",
                    "items": {"type": "string", "enum": CLEAN_CATEGORIES},
                    "description": "Catalog categories to scan; default: all except empty_trash."
                }}),
                &[],
            ),
        ),
        spec(
            "storage.duplicates",
            "storage duplicates",
            Some("find_duplicates"),
            "storage",
            Risk::Read,
            object(
                json!({"path": {"type": "string", "description": "Folder to scan."}, "min_size": min_size}),
                &["path"],
            ),
        ),
        spec(
            "storage.duplicates.remove",
            "storage duplicates remove",
            Some("plan_remove_duplicates"),
            "storage",
            Risk::Read,
            object(
                json!({
                    "path": {"type": "string", "description": "Folder that was scanned."},
                    "select": {
                        "type": "array",
                        "items": {"type": "string"},
                        "minItems": 1,
                        "description": "Files to move to the Trash; every group keeps at least one copy."
                    },
                    "min_size": min_size
                }),
                &["path", "select"],
            ),
        ),
        spec(
            "apps.uninstall",
            "apps uninstall",
            Some("plan_uninstall_app"),
            "apps",
            Risk::Read,
            object(
                json!({"app": {"type": "string", "description": "Path of the .app bundle or its bundle id."}}),
                &["app"],
            ),
        ),
        spec(
            "plan.show",
            "plan show",
            Some("get_plan"),
            "plan",
            Risk::Read,
            plan_id(),
        ),
        spec(
            "plan.confirm",
            "plan confirm",
            Some("confirm_plan"),
            "plan",
            Risk::Risky,
            plan_id(),
        ),
    ]
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;
    use crate::commands;

    #[test]
    fn only_confirmation_is_risky_and_every_tool_is_named() {
        for c in specs() {
            assert_eq!(
                c.risk == Risk::Risky,
                c.name == "plan.confirm",
                "{}",
                c.name
            );
            assert!(c.mcp_name.is_some(), "{}", c.name);
            assert_eq!(c.input_schema["type"], "object");
            for r in c.input_schema["required"].as_array().unwrap() {
                assert!(
                    c.input_schema["properties"]
                        .get(r.as_str().unwrap())
                        .is_some()
                );
            }
        }
    }
}
