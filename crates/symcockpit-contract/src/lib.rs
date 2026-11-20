//! Command register and wire vocabulary shared by CLI, MCP and the app
//! protocol (ADR 0001). Pure data: no I/O, no platform access.

mod registry;

pub use registry::{CommandSpec, commands};

use serde::{Deserialize, Serialize};

/// Version of the app-agent wire protocol, negotiated in the handshake.
pub const PROTOCOL_VERSION: u32 = 1;

/// Process exit codes; identical to `tuning/Sources/SymCockpitCore/ExitCode.swift`.
pub mod exit {
    pub const OK: u8 = 0;
    pub const ERROR: u8 = 1;
    /// Bad CLI flags or configuration file.
    pub const USAGE: u8 = 2;
    /// Missing macOS permission or privileged helper.
    pub const PERMISSION: u8 = 3;
    /// Capability not available on this hardware, or not implemented.
    pub const UNSUPPORTED: u8 = 4;
}

/// How an agent may trigger a command (architecture §5.3).
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Risk {
    Read,
    Reversible,
    Risky,
    HumanOnly,
}

/// Result of an action, reported as a post-condition rather than a call status.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    Confirmed,
    Unconfirmed,
    Failed,
    Unsupported,
    SkippedChanged,
}

/// Identifier of a two-step plan (plan, then confirm with the id).
#[derive(Clone, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct PlanId(pub String);

/// A planned risky action awaiting confirmation. Data only; planning logic
/// belongs to `symcockpit-core`. Timestamps are RFC 3339 UTC strings.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Plan {
    pub id: PlanId,
    pub created_at: String,
    pub expires_at: String,
    pub items: Vec<serde_json::Value>,
    /// Digest over the items; confirmation fails if the state changed.
    pub digest: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enums_serialize_as_snake_case() {
        assert_eq!(
            serde_json::to_string(&Risk::HumanOnly).unwrap(),
            "\"human_only\""
        );
        assert_eq!(
            serde_json::to_string(&Outcome::SkippedChanged).unwrap(),
            "\"skipped_changed\""
        );
        assert_eq!(
            serde_json::from_str::<Outcome>("\"unconfirmed\"").unwrap(),
            Outcome::Unconfirmed
        );
    }

    #[test]
    fn exit_codes_match_swift() {
        let src = include_str!("../../../tuning/Sources/SymCockpitCore/ExitCode.swift");
        for (name, code) in [
            ("ok", exit::OK),
            ("error", exit::ERROR),
            ("usage", exit::USAGE),
            ("permission", exit::PERMISSION),
            ("unsupported", exit::UNSUPPORTED),
        ] {
            assert!(
                src.contains(&format!("case {name} = {code}")),
                "{name} = {code}"
            );
        }
    }

    #[test]
    fn plan_round_trips() {
        let plan = Plan {
            id: PlanId("p1".into()),
            created_at: "2026-11-20T10:00:00Z".into(),
            expires_at: "2026-11-20T10:05:00Z".into(),
            items: vec![serde_json::json!({"action": "set_fan"})],
            digest: "abc".into(),
        };
        let json = serde_json::to_string(&plan).unwrap();
        assert!(json.contains("\"id\":\"p1\""));
        assert_eq!(serde_json::from_str::<Plan>(&json).unwrap(), plan);
    }
}
