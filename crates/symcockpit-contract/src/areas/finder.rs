//! Finder context actions (R72): the vocabulary the FinderSync extension (writer) and the app
//! (consumer) share. The whole area is `human_only`: it has no CLI command, no MCP tool and
//! no agent-protocol method, so `specs()` is empty on purpose and a test keeps it so.

use crate::{CommandSpec, Risk};

/// Risk class of every Finder action (architecture 5.3).
pub const RISK: Risk = Risk::HumanOnly;

/// Version of the job file schema; a file with another version is rejected.
pub const JOB_VERSION: u32 = 1;

/// A job is valid for this long after its `created_at` (architecture 6.3).
pub const JOB_TTL_SECS: i64 = 60;

/// The only actions a job may name. The smallest set from RE/MouseBoost Pro (finder-dispatch,
/// dateioperationen, skriptbruecken) that is useful without a script engine: Copy Path, New
/// File and Open in Terminal. The extension's menu uses the same ids (checked by a core test).
pub const ACTIONS: [&str; 3] = ["copy_path", "new_file", "open_in_terminal"];

pub fn specs() -> Vec<CommandSpec> {
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands;

    #[test]
    fn finder_actions_have_no_cli_or_mcp_surface() {
        assert!(specs().is_empty());
        assert_eq!(RISK, Risk::HumanOnly);
        for s in commands() {
            assert_ne!(s.area, "finder", "{}", s.name);
            let exposed = s.mcp_name.unwrap_or("");
            for action in ACTIONS {
                assert!(!exposed.contains(action), "{exposed}");
            }
        }
    }
}
