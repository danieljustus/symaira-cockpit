//! Human input commands (R60, R61). Every one is `human_only`: the register
//! gives none of them an MCP name, so no agent profile can trigger them.

use serde_json::json;

use crate::{CommandSpec, Risk};

pub fn specs() -> Vec<CommandSpec> {
    let spec = |name, cli_path| CommandSpec {
        name,
        cli_path,
        mcp_name: None,
        area: "input",
        risk: Risk::HumanOnly,
        input_schema: json!({"type": "object", "properties": {}, "required": []}),
    };
    vec![
        spec("input.status", "input status"),
        spec("input.finder-cut", "input finder-cut"),
        spec("input.haptics.status", "input haptics status"),
        spec("input.haptics.test", "input haptics test"),
    ]
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

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

    #[test]
    fn names_are_unique_and_collide_with_nothing_in_the_register() {
        let existing = commands();
        let mut names = BTreeSet::new();
        for s in specs() {
            assert!(names.insert(s.name));
            assert!(
                existing
                    .iter()
                    .all(|e| e.name != s.name && e.cli_path != s.cli_path)
            );
        }
    }
}
