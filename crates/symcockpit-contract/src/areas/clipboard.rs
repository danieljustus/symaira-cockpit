//! Clipboard history commands (R73, D13). Only the human may read the history, and only in
//! the app; the CLI manages the feature but has no command that prints a clip. Every command
//! is `human_only`, none has an MCP name.

use serde_json::json;

use crate::{CommandSpec, Risk};

pub fn specs() -> Vec<CommandSpec> {
    let spec = |name, cli_path| CommandSpec {
        name,
        cli_path,
        mcp_name: None,
        area: "clipboard",
        risk: Risk::HumanOnly,
        input_schema: json!({"type": "object", "properties": {}, "required": []}),
    };
    vec![
        spec("clipboard.status", "clipboard status"),
        spec("clipboard.pause", "clipboard pause"),
        spec("clipboard.resume", "clipboard resume"),
        spec("clipboard.clear", "clipboard clear"),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands;

    #[test]
    fn exactly_status_pause_resume_clear_and_none_for_agents() {
        let names: Vec<_> = specs().iter().map(|s| s.cli_path).collect();
        assert_eq!(
            names,
            [
                "clipboard status",
                "clipboard pause",
                "clipboard resume",
                "clipboard clear"
            ]
        );
        for s in specs() {
            assert_eq!(s.risk, Risk::HumanOnly, "{}", s.name);
            assert!(s.mcp_name.is_none(), "{} must not be an MCP tool", s.name);
        }
    }

    #[test]
    fn no_tool_in_the_register_mentions_the_clipboard() {
        let all: Vec<_> = commands().iter().cloned().chain(specs()).collect();
        for s in &all {
            if let Some(tool) = s.mcp_name {
                assert!(
                    !tool.contains("clip") && !tool.contains("paste"),
                    "{tool} looks like a clipboard tool"
                );
            }
        }
    }

    #[test]
    fn the_register_carries_the_clipboard_commands() {
        // Uniqueness of names and paths across the register: registry tests.
        for s in specs() {
            assert!(commands().iter().any(|c| c.name == s.name), "{}", s.name);
        }
    }
}
