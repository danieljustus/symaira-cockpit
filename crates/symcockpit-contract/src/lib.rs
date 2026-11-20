//! Command register and wire vocabulary shared by CLI, MCP and the app
//! protocol (ADR 0001). Pure data: no I/O, no platform access.

mod registry;

/// Command specs per functional area; the coordinator appends each `specs()` to the register.
pub mod areas {
    pub mod bluetooth;
    pub mod input;
}

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

/// Domain error shared by every area; mirrors `TuneError` in
/// `tuning/Sources/SymCockpitCore/Errors.swift` (cases, messages, exit codes).
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Error {
    Usage(String),
    Config(String),
    Permission(String),
    Unsupported(String),
    NotImplemented(String),
    Failed(String),
}

impl Error {
    pub fn exit_code(&self) -> u8 {
        match self {
            Error::Usage(_) | Error::Config(_) => exit::USAGE,
            Error::Permission(_) => exit::PERMISSION,
            Error::Unsupported(_) | Error::NotImplemented(_) => exit::UNSUPPORTED,
            Error::Failed(_) => exit::ERROR,
        }
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Usage(m) | Error::Failed(m) => f.write_str(m),
            Error::Config(m) => write!(f, "config error: {m}"),
            Error::Permission(m) => write!(f, "permission error: {m}"),
            Error::Unsupported(m) => write!(f, "unsupported: {m}"),
            Error::NotImplemented(m) => write!(f, "not implemented: {m}"),
        }
    }
}

impl std::error::Error for Error {}

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
    fn errors_match_swift_messages_and_exit_codes() {
        let src = include_str!("../../../tuning/Sources/SymCockpitCore/Errors.swift");
        for (err, prefix, code) in [
            (Error::Usage("m".into()), "", exit::USAGE),
            (Error::Config("m".into()), "config error: ", exit::USAGE),
            (
                Error::Permission("m".into()),
                "permission error: ",
                exit::PERMISSION,
            ),
            (
                Error::Unsupported("m".into()),
                "unsupported: ",
                exit::UNSUPPORTED,
            ),
            (
                Error::NotImplemented("m".into()),
                "not implemented: ",
                exit::UNSUPPORTED,
            ),
            (Error::Failed("m".into()), "", exit::ERROR),
        ] {
            assert_eq!(err.to_string(), format!("{prefix}m"));
            assert_eq!(err.exit_code(), code);
            if !prefix.is_empty() {
                assert!(
                    src.contains(&format!("\"{prefix}\\(message)\"")),
                    "{prefix}"
                );
            }
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
