//! Wire vocabulary of the app-agent protocol (`symcockpit agent --stdio`,
//! docs/agent-protocol.md): JSON-RPC 2.0, one message per line. Pure data.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use crate::{Error, Risk};

// Standard JSON-RPC codes.
pub const PARSE_ERROR: i64 = -32700;
pub const INVALID_REQUEST: i64 = -32600;
pub const METHOD_NOT_FOUND: i64 = -32601;
pub const INVALID_PARAMS: i64 = -32602;
pub const INTERNAL_ERROR: i64 = -32603;
// Protocol-specific codes (server-defined range).
/// A command ran and failed; `data.exit_code` carries the CLI exit class.
pub const COMMAND_FAILED: i64 = -32000;
/// `call` or `subscribe` before a successful `hello`.
pub const NOT_READY: i64 = -32002;
/// `hello` with a protocol version this agent does not speak.
pub const VERSION_MISMATCH: i64 = -32010;
/// Too many open subscriptions.
pub const TOO_MANY_SUBSCRIPTIONS: i64 = -32011;

pub const MAX_SUBSCRIPTIONS: usize = 32;
pub const MIN_INTERVAL_MS: u64 = 100;
pub const MAX_INTERVAL_MS: u64 = 3_600_000;
pub const DEFAULT_VISIBLE_MS: u64 = 1_000;
pub const DEFAULT_HIDDEN_MS: u64 = 10_000;

/// Every method a client may send, in documentation order.
pub const METHODS: [&str; 7] = [
    "hello",
    "call",
    "confirm",
    "subscribe",
    "unsubscribe",
    "set_visibility",
    "ping",
];

/// Methods only the app agent serves, in addition to [`METHODS`] (additive, no version bump).
/// None of them is a register command: the CLI and MCP have no name for them, so the human's
/// clipboard history cannot be read from either (R73, D13). `clipboard.*` are `human_only`.
pub const HOST_METHODS: [&str; 7] = [
    "clipboard.list",
    "clipboard.read",
    "clipboard.copy",
    "clipboard.delete",
    "clipboard.settings",
    "clipboard.configure",
    "services",
];

/// `hello` params.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct HelloParams {
    pub protocol_version: u32,
    #[serde(default)]
    pub client: Option<String>,
}

/// One register row as the app sees it.
#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub struct CommandInfo {
    pub name: String,
    pub risk: Risk,
    pub input_schema: Value,
}

/// What this agent can do beyond the register.
#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub struct Capabilities {
    pub methods: Vec<String>,
    /// Commands (topics) `subscribe` accepts.
    pub topics: Vec<String>,
    pub max_subscriptions: usize,
    pub min_interval_ms: u64,
    pub max_interval_ms: u64,
    pub default_interval_visible_ms: u64,
    pub default_interval_hidden_ms: u64,
}

/// `hello` result.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct HelloResult {
    pub protocol_version: u32,
    pub server_version: String,
    pub capabilities: Capabilities,
    pub commands: Vec<CommandInfo>,
}

/// `call` params.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct CallParams {
    pub command: String,
    #[serde(default)]
    pub params: Map<String, Value>,
}

/// `confirm` params: the id of a plan a `call` returned.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ConfirmParams {
    pub plan_id: String,
}

/// `subscribe` params; intervals default to 1 s visible and 10 s hidden.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct SubscribeParams {
    pub command: String,
    #[serde(default)]
    pub params: Map<String, Value>,
    #[serde(default = "visible_default")]
    pub interval_visible_ms: u64,
    #[serde(default = "hidden_default")]
    pub interval_hidden_ms: u64,
}

fn visible_default() -> u64 {
    DEFAULT_VISIBLE_MS
}

fn hidden_default() -> u64 {
    DEFAULT_HIDDEN_MS
}

impl SubscribeParams {
    /// The interval bounds; `Err` is the message of an `INVALID_PARAMS` error.
    pub fn validate(&self) -> Result<(), String> {
        for (name, ms) in [
            ("interval_visible_ms", self.interval_visible_ms),
            ("interval_hidden_ms", self.interval_hidden_ms),
        ] {
            if !(MIN_INTERVAL_MS..=MAX_INTERVAL_MS).contains(&ms) {
                return Err(format!(
                    "{name} must be between {MIN_INTERVAL_MS} and {MAX_INTERVAL_MS}"
                ));
            }
        }
        Ok(())
    }
}

/// `unsubscribe` params.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct UnsubscribeParams {
    pub subscription_id: u64,
}

/// `set_visibility` params.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct VisibilityParams {
    pub visible: bool,
}

/// The CLI exit class of a command error, as a stable word.
pub fn error_class(error: &Error) -> &'static str {
    match error {
        Error::Usage(_) | Error::Config(_) => "usage",
        Error::Permission(_) => "permission",
        Error::Unsupported(_) | Error::NotImplemented(_) => "unsupported",
        Error::Failed(_) => "error",
    }
}

/// The JSON-RPC `error` object of a failed command: the message the CLI would
/// print after `symcockpit: `, plus the exit class in `data`.
pub fn command_error(error: &Error) -> Value {
    json!({
        "code": COMMAND_FAILED,
        "message": error.to_string(),
        "data": {"exit_code": error.exit_code(), "class": error_class(error)},
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_errors_carry_the_exit_class() {
        let e = command_error(&Error::Usage("bad".into()));
        assert_eq!(e["code"], COMMAND_FAILED);
        assert_eq!(e["message"], "bad");
        assert_eq!(e["data"], json!({"exit_code": 2, "class": "usage"}));
        let e = command_error(&Error::Permission("no".into()));
        assert_eq!(e["data"], json!({"exit_code": 3, "class": "permission"}));
        assert_eq!(e["message"], "permission error: no");
        let e = command_error(&Error::NotImplemented("x".into()));
        assert_eq!(e["data"], json!({"exit_code": 4, "class": "unsupported"}));
    }

    #[test]
    fn subscribe_defaults_and_bounds() {
        let p: SubscribeParams = serde_json::from_value(json!({"command": "metrics"})).unwrap();
        assert_eq!(
            (p.interval_visible_ms, p.interval_hidden_ms),
            (1000, 10_000)
        );
        assert!(p.validate().is_ok());
        let low = SubscribeParams {
            interval_visible_ms: 10,
            ..p.clone()
        };
        assert!(low.validate().unwrap_err().contains("interval_visible_ms"));
        let high = SubscribeParams {
            interval_hidden_ms: MAX_INTERVAL_MS + 1,
            ..p
        };
        assert!(high.validate().unwrap_err().contains("interval_hidden_ms"));
    }

    #[test]
    fn hello_requires_the_version_and_ignores_unknown_fields() {
        assert!(
            serde_json::from_value::<HelloParams>(json!({"protocol_version": 1, "x": 1})).is_ok()
        );
        assert!(serde_json::from_value::<HelloParams>(json!({"client": "a"})).is_err());
    }

    #[test]
    fn hello_result_round_trips() {
        let result = HelloResult {
            protocol_version: crate::PROTOCOL_VERSION,
            server_version: "0.0.0".into(),
            capabilities: Capabilities {
                methods: vec!["hello".into()],
                topics: vec!["metrics".into()],
                max_subscriptions: MAX_SUBSCRIPTIONS,
                min_interval_ms: MIN_INTERVAL_MS,
                max_interval_ms: MAX_INTERVAL_MS,
                default_interval_visible_ms: DEFAULT_VISIBLE_MS,
                default_interval_hidden_ms: DEFAULT_HIDDEN_MS,
            },
            commands: vec![CommandInfo {
                name: "fan.set".into(),
                risk: Risk::Risky,
                input_schema: json!({"type": "object"}),
            }],
        };
        let text = serde_json::to_string(&result).unwrap();
        assert!(text.contains("\"risk\":\"risky\""));
        let back: HelloResult = serde_json::from_str(&text).unwrap();
        assert_eq!(back.commands, result.commands);
        assert_eq!(back.capabilities, result.capabilities);
    }

    #[test]
    fn every_method_is_listed_once() {
        let set: std::collections::BTreeSet<_> = METHODS.iter().chain(&HOST_METHODS).collect();
        assert_eq!(set.len(), METHODS.len() + HOST_METHODS.len());
    }

    #[test]
    fn no_host_method_is_a_register_command_or_tool() {
        for method in HOST_METHODS {
            for spec in crate::commands() {
                assert_ne!(
                    spec.name, method,
                    "{method} would be reachable as a command"
                );
                assert_ne!(
                    spec.cli_path.replace(' ', "."),
                    method,
                    "{method} has a CLI path"
                );
                assert_ne!(spec.mcp_name, Some(method), "{method} is a tool");
            }
        }
    }
}
