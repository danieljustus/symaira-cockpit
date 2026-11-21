//! Shared fixtures for the dispatcher and MCP tests. Everything runs against
//! an isolated home: no real configuration, history or hardware is read.

#![allow(dead_code)] // each test binary uses a different subset

use std::collections::BTreeMap;
use std::path::Path;

use serde_json::Value;
use symcockpit::app::{App, Handlers, OverridePort, Services};
use symcockpit::cli::{Action, Outcome, plan};
use symcockpit_store::Paths;
use symcockpit_testkit::symbrain::FakeSymbrain;

pub fn app(home: &Path) -> App {
    let env: BTreeMap<String, String> = [
        ("HOME", home.to_string_lossy().into_owned()),
        ("PATH", "/usr/bin:/bin".to_owned()),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_owned(), v))
    .collect();
    let lookup = |k: &str| env.get(k).cloned();
    App {
        paths: Paths::resolve(&lookup, home),
        env,
        handlers: Handlers::default(),
        services: Services {
            hardware: None,
            overrides: None,
            usage_runner: Box::new(FakeSymbrain::replying(
                r#"{"schema_version":1,"providers":[]}"#,
            )),
            vault_entry_paths: BTreeMap::new(),
            local_time: Box::new(|unix| format!("T{unix}")),
        },
        legacy: None,
    }
}

/// `tools/list` without the tools of the newer areas: what v0.12 listed. The
/// oracle fixture is compared with this, value for value.
pub fn v012_part(result: &Value) -> Value {
    let fixture: Value = serde_json::from_str(
        &std::fs::read_to_string(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../oracle/v0.12/cases/mcp-tools-list.json"),
        )
        .unwrap(),
    )
    .unwrap();
    let names: Vec<&str> = fixture["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    let kept: Vec<Value> = result["tools"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|t| names.contains(&t["name"].as_str().unwrap()))
        .cloned()
        .collect();
    serde_json::json!({"tools": kept})
}

pub fn args(list: &[&str]) -> Vec<String> {
    list.iter().map(|s| (*s).to_owned()).collect()
}

/// The outcome of a command answered natively; panics when it was forwarded.
pub fn done(app: &App, list: &[&str]) -> Outcome {
    match plan(app, &args(list)) {
        Action::Done(outcome) => outcome,
        Action::Forward => panic!("{list:?} was forwarded"),
        Action::Serve { .. } => panic!("{list:?} started the server"),
    }
}

pub fn forwarded(app: &App, list: &[&str]) -> bool {
    matches!(plan(app, &args(list)), Action::Forward)
}

pub struct Overrides(pub Value, pub bool);

impl OverridePort for Overrides {
    fn active_overrides(&self) -> Value {
        self.0.clone()
    }
    fn keep_awake_active(&self) -> bool {
        self.1
    }
}
