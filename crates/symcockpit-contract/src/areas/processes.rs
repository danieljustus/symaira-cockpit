//! Ending a process (R12). Risky: an agent only gets `plan_kill_process`; the
//! kill itself runs when a human confirms the plan.

use serde_json::json;

use crate::{CommandSpec, Risk};

pub fn specs() -> Vec<CommandSpec> {
    vec![CommandSpec {
        name: "processes.kill",
        cli_path: "processes kill",
        mcp_name: Some("plan_kill_process"),
        area: "processes",
        risk: Risk::Risky,
        input_schema: json!({
            "type": "object",
            "properties": {"pid": {
                "type": "integer",
                "minimum": 2,
                "description": "Process id to end with SIGTERM. The plan records its start time and path; confirm_plan skips it if another process reused the id."
            }},
            "required": ["pid"]
        }),
    }]
}
