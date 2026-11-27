//! Shared fixtures for the dispatcher and MCP tests. Everything runs against
//! an isolated home: no real configuration, history or hardware is read.

#![allow(dead_code)] // each test binary uses a different subset

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::rc::Rc;

use serde_json::Value;
use symcockpit::app::{App, Context, FanControl, Handlers, OverridePort, ReleaseSource, Services};
use symcockpit::cli::{Action, Outcome, plan};
use symcockpit_store::Paths;
use symcockpit_testkit::symbrain::FakeSymbrain;

/// A release source that was never asked: tests that expect no request fail loudly.
pub struct NoNetwork;

impl ReleaseSource for NoNetwork {
    fn latest(&self) -> symcockpit_core::update_check::Fetched {
        panic!("a test reached the network")
    }
}

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
            fan_control: Some(Box::new(FakeFanControl::default())),
            usage_runner: Box::new(FakeSymbrain::replying(
                r#"{"schema_version":1,"providers":[]}"#,
            )),
            vault_entry_paths: BTreeMap::new(),
            local_time: Box::new(|unix| format!("T{unix}")),
            enabled_ai_providers: Box::new(BTreeSet::new),
            release_source: Box::new(NoNetwork),
            stdout_is_terminal: false,
        },
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

/// The outcome of a command answered in one go; panics when it started a long-running one.
pub fn done(app: &App, list: &[&str]) -> Outcome {
    match plan(app, &args(list)) {
        Action::Done(outcome) => outcome,
        Action::Serve { .. } => panic!("{list:?} started the server"),
        Action::StatusWatch { .. } | Action::AiUsageServe { .. } => {
            panic!("{list:?} started a loop")
        }
    }
}

/// Whether the command has no native handler in this app: exit 4 and the message of
/// `unsupported`, the whole of what is left of the old hand-over to Swift.
pub fn unavailable(app: &App, list: &[&str]) -> bool {
    match plan(app, &args(list)) {
        Action::Done(o) => o.code == 4 && o.stderr.contains("is not available in this build"),
        _ => false,
    }
}

pub struct Overrides(pub Value, pub bool);

/// Counts hand-backs without ever touching an SMC.
#[derive(Clone, Default)]
pub struct FanControlCounter(pub std::rc::Rc<Cell<usize>>);

impl FanControlCounter {
    pub fn count(&self) -> usize {
        self.0.get()
    }
}

#[derive(Default)]
pub struct FakeFanControl {
    pub software_override: bool,
    pub elevation_error: Option<String>,
    pub restore_error: Option<String>,
    pub counter: FanControlCounter,
    /// Every governor route the agent/CLI asked for, without touching XPC.
    pub routed: Rc<RefCell<Vec<symcockpit_core::sensors::FanSelection>>>,
}

impl FanControl for FakeFanControl {
    fn has_software_override(&self) -> bool {
        self.software_override
    }

    fn restore_auto(&self, _: &Context) -> Result<(), symcockpit_contract::Error> {
        self.counter.0.set(self.counter.0.get() + 1);
        match &self.restore_error {
            Some(reason) => Err(symcockpit_contract::Error::Failed(reason.clone())),
            None => Ok(()),
        }
    }

    fn check_elevation(&self, _: &Context) -> Result<(), symcockpit_contract::Error> {
        match &self.elevation_error {
            Some(reason) => Err(symcockpit_contract::Error::Permission(reason.clone())),
            None => Ok(()),
        }
    }

    fn route_selection(
        &self,
        _: &Context,
        selection: symcockpit_core::sensors::FanSelection,
    ) -> Result<(), symcockpit_contract::Error> {
        self.routed.borrow_mut().push(selection);
        Ok(())
    }
}

impl OverridePort for Overrides {
    fn active_overrides(&self) -> Value {
        self.0.clone()
    }
    fn keep_awake_active(&self) -> bool {
        self.1
    }
}
