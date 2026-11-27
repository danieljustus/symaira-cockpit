//! Wire protocol of the privileged helper (architecture §5.2, §8).
//!
//! One request is one JSON object `{"version": 1, "action": "...", ...}`, one
//! reply is one JSON object. The transport (XPC) only moves the bytes; this
//! crate owns what they mean. The surface is deliberately closed:
//!
//! - a profile by name plus one bounded temperature, never a raw SMC key;
//! - a fan fraction with a *lease*, so a fixed target cannot outlive its owner;
//! - no way to disable firmware protection.
//!
//! A request with an unknown action or another protocol version is answered
//! with an error and never reaches the engine ([`decode_request`]).

pub mod signing;

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Version negotiated by `hello`; a request with another number is refused.
pub const PROTOCOL_VERSION: u32 = 1;

/// Launchd label, Mach service name and code-signing identifier of the helper
/// (grandfathered identity, never rename: it would orphan approved helpers).
pub const HELPER_IDENTIFIER: &str = "com.symaira.symtune-helper";
/// Bundle identifier and code-signing identifier of `Symaira Cockpit.app`.
pub const APP_IDENTIFIER: &str = "com.symaira.cockpit";
/// Code-signing identifier of the bundled `symcockpit` agent/CLI inside the
/// app. It is a client of the same helper as the app itself.
pub const AGENT_IDENTIFIER: &str = "com.symaira.cockpit.symcockpit";

/// The app pings the helper this often while it governs (§6.2).
pub const HEARTBEAT_INTERVAL_MS: u64 = 2_000;
/// No heartbeat for more than this hands the fans back: three missed pings
/// (3 x 2 s) plus one second of slack, as in the Swift helper.
pub const HEARTBEAT_TIMEOUT_MS: u64 = 7_000;
/// How often the helper compares the last heartbeat with the timeout.
pub const WATCHDOG_CHECK_MS: u64 = 1_000;
/// Longest lease a fixed fan target may ask for.
pub const MAX_LEASE_MS: u64 = 3_600_000;

/// The two governed positions; `system` is `governor_stop`.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GovernorProfile {
    Comfort,
    Performance,
}

/// What a client may ask for.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum Action {
    /// Version handshake; the reply carries the helper's protocol version.
    Hello,
    /// Hold a fixed fraction for `lease_ms`, then return to the firmware.
    FanSetTarget {
        fraction: f64,
        lease_ms: u64,
    },
    /// Hand every fan back to the firmware now.
    FanSetAuto,
    /// Start the governor on a profile, or retarget a running one.
    GovernorStart {
        profile: GovernorProfile,
        cool_target_celsius: Option<f64>,
    },
    GovernorStop,
    /// Liveness ping of the governor's owner.
    Heartbeat,
    /// Undo every override (fans, charge limit) from the restore record.
    SmcRestore,
    /// SMC charge limit: `Some(percent)` inhibits at 50..=100, `None` clears.
    ChargeLimitSmc {
        percent: Option<i64>,
    },
    /// `idle` | `governing` | `failed` plus a detail.
    Status,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Request {
    pub version: u32,
    #[serde(flatten)]
    pub action: Action,
}

impl Request {
    pub fn new(action: Action) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            action,
        }
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorKind {
    /// Bad request: unknown action or version, malformed or out-of-range value.
    Usage,
    /// The helper refused for a safety reason (thermal gate, no AC power).
    Permission,
    /// This Mac cannot do it (no fans, no charge-limit key).
    Unsupported,
    /// The write returned, but reading the state back showed something else (Q01).
    Unconfirmed,
    Failed,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "reply", rename_all = "snake_case")]
pub enum Reply {
    Hello {
        version: u32,
        helper_version: String,
    },
    Ok,
    Heartbeat {
        governing: bool,
    },
    Status {
        state: String,
        detail: Option<String>,
    },
    Error {
        kind: ErrorKind,
        message: String,
    },
}

impl Reply {
    pub fn error(kind: ErrorKind, message: impl Into<String>) -> Self {
        Self::Error {
            kind,
            message: message.into(),
        }
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }

    pub fn from_json(text: &str) -> Result<Self, String> {
        serde_json::from_str(text).map_err(|e| format!("unreadable helper reply: {e}"))
    }
}

/// Parses one request. Anything the helper does not know is an error reply
/// the caller sends back as is; it never reaches the engine.
pub fn decode_request(text: &str) -> Result<Request, Reply> {
    let value: Value = serde_json::from_str(text)
        .map_err(|_| Reply::error(ErrorKind::Usage, "request is not valid JSON"))?;
    match value.get("version").and_then(Value::as_u64) {
        Some(v) if v == u64::from(PROTOCOL_VERSION) => {}
        Some(v) => {
            return Err(Reply::error(
                ErrorKind::Usage,
                format!("unsupported protocol version {v} (helper speaks {PROTOCOL_VERSION})"),
            ));
        }
        None => return Err(Reply::error(ErrorKind::Usage, "request has no version")),
    }
    serde_json::from_value(value.clone()).map_err(|_| {
        let name = value.get("action").and_then(Value::as_str).unwrap_or("?");
        // Known action with a bad payload and unknown action read alike on
        // purpose: the caller only learns which action was refused.
        Reply::error(
            ErrorKind::Usage,
            format!("unknown or malformed action '{name}'"),
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kind_of(reply: Reply) -> ErrorKind {
        match reply {
            Reply::Error { kind, .. } => kind,
            other => panic!("expected an error, got {other:?}"),
        }
    }

    #[test]
    fn every_action_round_trips() {
        let actions = [
            Action::Hello,
            Action::FanSetTarget {
                fraction: 0.5,
                lease_ms: 60_000,
            },
            Action::FanSetAuto,
            Action::GovernorStart {
                profile: GovernorProfile::Comfort,
                cool_target_celsius: Some(70.0),
            },
            Action::GovernorStart {
                profile: GovernorProfile::Performance,
                cool_target_celsius: None,
            },
            Action::GovernorStop,
            Action::Heartbeat,
            Action::SmcRestore,
            Action::ChargeLimitSmc { percent: Some(80) },
            Action::ChargeLimitSmc { percent: None },
            Action::Status,
        ];
        for action in actions {
            let json = Request::new(action.clone()).to_json();
            assert_eq!(decode_request(&json).unwrap().action, action, "{json}");
        }
    }

    #[test]
    fn wire_form_is_stable() {
        assert_eq!(
            Request::new(Action::Heartbeat).to_json(),
            r#"{"version":1,"action":"heartbeat"}"#
        );
        assert_eq!(
            Request::new(Action::FanSetTarget {
                fraction: 0.5,
                lease_ms: 1000
            })
            .to_json(),
            r#"{"version":1,"action":"fan_set_target","fraction":0.5,"lease_ms":1000}"#
        );
    }

    #[test]
    fn unknown_action_and_version_are_refused() {
        for bad in [
            r#"{"version":1,"action":"write_smc_key","key":"F0Md"}"#,
            r#"{"version":1,"action":"fan_set_target","fraction":"fast","lease_ms":1}"#,
            r#"{"version":1}"#,
        ] {
            assert_eq!(kind_of(decode_request(bad).unwrap_err()), ErrorKind::Usage);
        }
        let other = decode_request(r#"{"version":2,"action":"hello"}"#).unwrap_err();
        assert!(matches!(&other, Reply::Error { message, .. } if message.contains("version 2")));
        assert_eq!(
            kind_of(decode_request(r#"{"action":"hello"}"#).unwrap_err()),
            ErrorKind::Usage
        );
        assert_eq!(
            kind_of(decode_request("not json").unwrap_err()),
            ErrorKind::Usage
        );
    }

    #[test]
    fn replies_round_trip() {
        for reply in [
            Reply::Ok,
            Reply::Hello {
                version: 1,
                helper_version: "0.12.2".into(),
            },
            Reply::Heartbeat { governing: true },
            Reply::Status {
                state: "idle".into(),
                detail: None,
            },
            Reply::error(ErrorKind::Permission, "thermal emergency"),
        ] {
            assert_eq!(Reply::from_json(&reply.to_json()).unwrap(), reply);
        }
    }
}
