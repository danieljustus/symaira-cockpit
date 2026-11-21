//! Human input commands (R60, R61). Every one is `human_only`: the register
//! gives none of them an MCP name, so no agent profile can trigger them.

use serde_json::json;

use crate::{CommandSpec, Risk};

pub fn specs() -> Vec<CommandSpec> {
    let spec = |name, cli_path, input_schema| CommandSpec {
        name,
        cli_path,
        mcp_name: None,
        area: "input",
        risk: Risk::HumanOnly,
        input_schema,
    };
    let none = || json!({"type": "object", "properties": {}, "required": []});
    vec![
        spec("input.status", "input status", none()),
        spec(
            "input.finder-cut",
            "input finder-cut",
            json!({
                "type": "object",
                "properties": {"state": {"type": "string", "enum": ["on", "off"]}},
                "required": ["state"]
            }),
        ),
        spec("input.haptics.status", "input haptics status", none()),
        spec("input.haptics.test", "input haptics test", none()),
    ]
}

#[cfg(test)]
mod tests {

    use super::*;
    use crate::commands;

    #[test]
    fn no_mcp_tool_for_input() {
        let specs = specs();
        assert!(!specs.is_empty());
        for s in &specs {
            assert_eq!(s.risk, Risk::HumanOnly, "{}", s.name);
            assert!(
                s.mcp_name.is_none(),
                "{} must not be exposed to agents",
                s.name
            );
            assert_eq!(s.area, "input");
        }
    }

    #[test]
    fn nothing_in_the_register_exposes_input_or_haptics_to_agents() {
        // Registry plus this area: no MCP name may mention input, haptics or Finder cut.
        let all: Vec<_> = commands().iter().cloned().chain(specs()).collect();
        for s in all
            .iter()
            .filter(|s| s.area == "input" || s.name.starts_with("input."))
        {
            assert!(s.mcp_name.is_none(), "{}", s.name);
        }
        for name in all.iter().filter_map(|s| s.mcp_name) {
            for word in ["input", "haptic", "finder", "keystroke"] {
                assert!(!name.contains(word), "{name} looks like an input tool");
            }
        }
    }
}
