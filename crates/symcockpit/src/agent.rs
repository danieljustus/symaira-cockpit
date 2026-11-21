//! `symcockpit agent --stdio`: the app's child process (architecture §5.1,
//! §8; wire format in docs/agent-protocol.md).
//!
//! JSON-RPC 2.0, one message per line. Stdout carries protocol frames only
//! (AGENTS.md: zero stdio pollution); logs go to stderr.
//!
//! The agent adds no behaviour of its own: `call` runs a register command
//! through the dispatch path of `tools/call` ([`mcp::Server::run_spec`]), so
//! the app can show nothing the CLI would contradict (R06). What it adds is
//! the app-specific policy around that path:
//!
//! - risk classes (§5.3): `read`, `reversible` and `human_only` run directly,
//!   `risky` only as a two-step plan (`core::plan`) that `confirm` executes;
//! - subscriptions: a command is sampled only while someone subscribed to it
//!   (Q04), at the interval of the current visibility;
//! - the parent check ([`macos::parent_check`]) before anything is served.
//!
//! One thread dispatches everything. The handler table is not `Send`, and
//! display enumeration needs the main thread (see `live`). A reader thread
//! only forwards stdin lines, and a signal thread forwards SIGTERM, to the
//! dispatch loop through one channel, so the loop sleeps until the next due
//! sample, a request or a signal and never polls.
//! shortcut: a slow command (`ai-usage` waits up to 30 s) delays every other
//! request and sample meanwhile; upgrade by moving samplers to threads once
//! handlers are `Send`.

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::io::{self, BufRead, Read, Write};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::time::{Duration, Instant};

use serde::de::DeserializeOwned;
use serde_json::{Map, Value, json};
use symcockpit_contract::agent_proto::{
    COMMAND_FAILED, CallParams, Capabilities, CommandInfo, ConfirmParams, DEFAULT_HIDDEN_MS,
    DEFAULT_VISIBLE_MS, HelloParams, HelloResult, INTERNAL_ERROR, INVALID_PARAMS, INVALID_REQUEST,
    MAX_INTERVAL_MS, MAX_SUBSCRIPTIONS, METHOD_NOT_FOUND, METHODS, MIN_INTERVAL_MS, NOT_READY,
    PARSE_ERROR, SubscribeParams, TOO_MANY_SUBSCRIPTIONS, UnsubscribeParams, VERSION_MISMATCH,
    VisibilityParams, command_error,
};
use symcockpit_contract::{CommandSpec, Error, Outcome, PROTOCOL_VERSION, Risk, commands, exit};
use symcockpit_core::plan::{
    Action, Clock, Engine, ItemResult, PlanStore, StoredPlan, SystemClock,
};
use symcockpit_macos::parent_check::{self, CodeSignature};

use crate::app::{App, Context};
use crate::{VERSION, mcp};

/// Commands that are not data: servers, help, a daemon. `call` refuses them
/// and `hello` does not list them.
const NOT_CALLABLE: [&str; 5] = ["serve", "help", "version", "ai-usage.serve", "fan.governor"];

/// Commands `subscribe` accepts: cheap, side-effect free reads. Owners of new
/// read areas add their live commands here.
const SUBSCRIBABLE: [&str; 10] = [
    "sensors",
    "battery",
    "displays",
    "metrics",
    "processes",
    "top",
    "status",
    "awake.status",
    "brightness.get",
    "fan.status",
];

/// The one risky command that already is the second step of a plan of its
/// own (storage cleanup): running it needs no further confirmation.
const OWN_CONFIRMATION: &str = "plan.confirm";

const PLAN_KIND: &str = "agent_command";
const ACTION: &str = "command";

/// The team of the signed app, baked in at build time (see `parent_check`).
const BAKED_TEAM: Option<&str> = option_env!("SYMCOCKPIT_TEAM_ID");

/// Debug builds only: skips the parent check so tests can drive the binary
/// over pipes. The release build does not contain the switch (tested in
/// `tests/agent_release.rs`).
#[cfg(debug_assertions)]
pub const TEST_SWITCH: &str = "SYMCOCKPIT_AGENT_SKIP_PARENT_CHECK";

#[cfg(debug_assertions)]
fn parent_check_skipped(env: &BTreeMap<String, String>) -> bool {
    env.get(TEST_SWITCH).is_some_and(|v| v == "1")
}

#[cfg(not(debug_assertions))]
fn parent_check_skipped(_env: &BTreeMap<String, String>) -> bool {
    false
}

// ------------------------------------------------------------------ ports

/// Runs one register command; the production implementation is the MCP path.
pub trait Dispatch {
    fn run(&self, spec: &'static CommandSpec, params: &Map<String, Value>) -> Result<Value, Error>;
}

impl Dispatch for mcp::Server<'_> {
    fn run(&self, spec: &'static CommandSpec, params: &Map<String, Value>) -> Result<Value, Error> {
        self.run_spec(spec, params)
    }
}

/// Milliseconds on a monotonic clock; a fake in tests.
pub trait Mono {
    fn now_ms(&self) -> u64;
}

pub struct RealMono(Instant);

impl RealMono {
    pub fn start() -> Self {
        Self(Instant::now())
    }
}

impl Mono for RealMono {
    fn now_ms(&self) -> u64 {
        u64::try_from(self.0.elapsed().as_millis()).unwrap_or(u64::MAX)
    }
}

// ------------------------------------------------------------------ plans

/// Plans live as long as the agent: a restarted app starts without stale
/// confirmations.
#[derive(Default)]
struct MemoryPlans(RefCell<HashMap<String, StoredPlan>>);

impl PlanStore for MemoryPlans {
    fn insert(&self, plan: &StoredPlan) -> Result<(), Error> {
        self.0.borrow_mut().insert(plan.id.clone(), plan.clone());
        Ok(())
    }
    fn load(&self, id: &str) -> Result<Option<StoredPlan>, Error> {
        Ok(self.0.borrow().get(id).cloned())
    }
    fn claim(&self, id: &str, at: i64) -> Result<bool, Error> {
        let mut plans = self.0.borrow_mut();
        match plans.get_mut(id) {
            Some(plan) if plan.confirmed_at.is_none() => {
                plan.confirmed_at = Some(at);
                Ok(true)
            }
            _ => Ok(false),
        }
    }
    fn finish(&self, id: &str, results: &Value) -> Result<(), Error> {
        if let Some(plan) = self.0.borrow_mut().get_mut(id) {
            plan.results = Some(results.clone());
        }
        Ok(())
    }
}

/// The plan item that runs a register command on confirmation.
struct CommandAction<'a> {
    dispatch: &'a dyn Dispatch,
    last: RefCell<Option<Result<Value, Error>>>,
}

fn callable(name: &str) -> Option<&'static CommandSpec> {
    commands()
        .iter()
        .find(|c| c.name == name && !NOT_CALLABLE.contains(&c.name))
}

impl Action for CommandAction<'_> {
    fn kind(&self) -> &'static str {
        ACTION
    }

    fn still_valid(&self, item: &Value) -> Result<(), String> {
        match item["command"].as_str().and_then(callable) {
            Some(spec) if spec.risk == Risk::Risky => Ok(()),
            _ => Err("the command is unknown or no longer risky".into()),
        }
    }

    fn execute(&self, item: &Value) -> ItemResult {
        let spec = item["command"]
            .as_str()
            .and_then(callable)
            .expect("still_valid ran first");
        let params = item["params"].as_object().cloned().unwrap_or_default();
        let result = self.dispatch.run(spec, &params);
        let item_result = match &result {
            Ok(_) => ItemResult::new(Outcome::Confirmed, None),
            Err(e @ (Error::Unsupported(_) | Error::NotImplemented(_))) => {
                ItemResult::new(Outcome::Unsupported, Some(e.to_string()))
            }
            Err(e) => ItemResult::new(Outcome::Failed, Some(e.to_string())),
        };
        *self.last.borrow_mut() = Some(result);
        item_result
    }
}

// ---------------------------------------------------------------- session

struct Rpc {
    code: i64,
    message: String,
    data: Option<Value>,
}

impl Rpc {
    fn new(code: i64, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            data: None,
        }
    }

    fn params(message: impl Into<String>) -> Self {
        Self::new(INVALID_PARAMS, message)
    }

    fn command(error: &Error) -> Self {
        let v = command_error(error);
        Self {
            code: COMMAND_FAILED,
            message: error.to_string(),
            data: Some(v["data"].clone()),
        }
    }

    fn to_value(&self, id: &Value) -> Value {
        let mut error = json!({"code": self.code, "message": self.message});
        if let Some(data) = &self.data {
            error["data"] = data.clone();
        }
        json!({"jsonrpc": "2.0", "id": id, "error": error})
    }
}

fn ok(id: &Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

fn parse<T: DeserializeOwned>(params: Option<&Value>) -> Result<T, Rpc> {
    serde_json::from_value(params.cloned().unwrap_or_else(|| json!({})))
        .map_err(|e| Rpc::params(format!("invalid params: {e}")))
}

struct Subscription {
    spec: &'static CommandSpec,
    params: Map<String, Value>,
    visible_ms: u64,
    hidden_ms: u64,
    /// When it was last sampled (set by the first sample at subscribe time).
    last_ms: u64,
    seq: u64,
}

impl Subscription {
    fn due_ms(&self, visible: bool) -> u64 {
        self.last_ms
            + if visible {
                self.visible_ms
            } else {
                self.hidden_ms
            }
    }
}

/// The protocol state machine. Pure apart from the dispatch port and the two
/// clocks, so tests drive it with fakes and a counting dispatch.
pub struct Session<'a> {
    dispatch: &'a dyn Dispatch,
    mono: &'a dyn Mono,
    plan_clock: &'a dyn Clock,
    plans: MemoryPlans,
    ready: bool,
    visible: bool,
    next_id: u64,
    subs: BTreeMap<u64, Subscription>,
}

impl<'a> Session<'a> {
    pub fn new(dispatch: &'a dyn Dispatch, mono: &'a dyn Mono, plan_clock: &'a dyn Clock) -> Self {
        Self {
            dispatch,
            mono,
            plan_clock,
            plans: MemoryPlans::default(),
            ready: false,
            visible: true,
            next_id: 1,
            subs: BTreeMap::new(),
        }
    }

    pub fn subscription_count(&self) -> usize {
        self.subs.len()
    }

    /// When the next sample is due; `None` without subscribers, which is what
    /// lets the loop sleep (Q04).
    pub fn next_due_ms(&self) -> Option<u64> {
        self.subs.values().map(|s| s.due_ms(self.visible)).min()
    }

    /// The frames to write for one input line, in order.
    pub fn handle_line(&mut self, line: &str) -> Vec<Value> {
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            return vec![Rpc::new(PARSE_ERROR, "Parse error").to_value(&Value::Null)];
        };
        let Some(object) = value.as_object() else {
            return vec![Rpc::new(INVALID_REQUEST, "Invalid Request").to_value(&Value::Null)];
        };
        let id = object.get("id").cloned();
        let id_ok = matches!(
            &id,
            None | Some(Value::Null | Value::String(_) | Value::Number(_))
        );
        let method = object.get("method").and_then(Value::as_str);
        let version_ok = object.get("jsonrpc").and_then(Value::as_str) == Some("2.0");
        let (true, true, Some(method)) = (id_ok, version_ok, method) else {
            let id = id.filter(|_| id_ok).unwrap_or(Value::Null);
            return vec![
                Rpc::new(
                    INVALID_REQUEST,
                    "Invalid Request: expected jsonrpc 2.0 with a method",
                )
                .to_value(&id),
            ];
        };
        let mut frames = Vec::new();
        let outcome = self.route(method, object.get("params"), &mut frames);
        // A request without an id is a notification: handled, never answered.
        let Some(id) = id.filter(|id| !id.is_null()) else {
            return frames;
        };
        let response = match outcome {
            Ok(result) => ok(&id, result),
            Err(rpc) => rpc.to_value(&id),
        };
        // The response comes before the frames the request produced.
        frames.insert(0, response);
        frames
    }

    /// Samples every subscription that is due.
    pub fn tick(&mut self) -> Vec<Value> {
        let now = self.mono.now_ms();
        let due: Vec<u64> = self
            .subs
            .iter()
            .filter(|(_, s)| s.due_ms(self.visible) <= now)
            .map(|(id, _)| *id)
            .collect();
        let mut frames = Vec::new();
        for id in due {
            self.sample(id, &mut frames);
        }
        frames
    }

    fn route(
        &mut self,
        method: &str,
        params: Option<&Value>,
        frames: &mut Vec<Value>,
    ) -> Result<Value, Rpc> {
        match method {
            "ping" => return Ok(json!({})),
            "hello" => return self.hello(params),
            m if !METHODS.contains(&m) => {
                return Err(Rpc::new(METHOD_NOT_FOUND, format!("Method not found: {m}")));
            }
            _ if !self.ready => {
                return Err(Rpc::new(NOT_READY, "send hello first"));
            }
            _ => {}
        }
        match method {
            "call" => self.call(&parse(params)?),
            "confirm" => self.confirm(&parse::<ConfirmParams>(params)?),
            "subscribe" => self.subscribe(&parse(params)?, frames),
            "unsubscribe" => self.unsubscribe(&parse(params)?),
            _ => self.set_visibility(&parse(params)?, frames),
        }
    }

    fn hello(&mut self, params: Option<&Value>) -> Result<Value, Rpc> {
        let hello: HelloParams = parse(params)?;
        if hello.protocol_version != PROTOCOL_VERSION {
            let mut rpc = Rpc::new(
                VERSION_MISMATCH,
                format!(
                    "protocol version {} is not supported (this agent speaks {PROTOCOL_VERSION})",
                    hello.protocol_version
                ),
            );
            rpc.data =
                Some(json!({"supported": [PROTOCOL_VERSION], "requested": hello.protocol_version}));
            return Err(rpc);
        }
        self.ready = true;
        let register: Vec<&CommandSpec> = commands()
            .iter()
            .filter(|c| !NOT_CALLABLE.contains(&c.name))
            .collect();
        let result = HelloResult {
            protocol_version: PROTOCOL_VERSION,
            server_version: VERSION.to_owned(),
            capabilities: Capabilities {
                methods: METHODS.iter().map(|m| (*m).to_owned()).collect(),
                topics: register
                    .iter()
                    .filter(|c| c.risk == Risk::Read && SUBSCRIBABLE.contains(&c.name))
                    .map(|c| c.name.to_owned())
                    .collect(),
                max_subscriptions: MAX_SUBSCRIPTIONS,
                min_interval_ms: MIN_INTERVAL_MS,
                max_interval_ms: MAX_INTERVAL_MS,
                default_interval_visible_ms: DEFAULT_VISIBLE_MS,
                default_interval_hidden_ms: DEFAULT_HIDDEN_MS,
            },
            commands: register
                .iter()
                .map(|c| CommandInfo {
                    name: c.name.to_owned(),
                    risk: c.risk,
                    input_schema: c.input_schema.clone(),
                })
                .collect(),
        };
        serde_json::to_value(result).map_err(|e| Rpc::new(INTERNAL_ERROR, e.to_string()))
    }

    fn spec(name: &str) -> Result<&'static CommandSpec, Rpc> {
        callable(name).ok_or_else(|| Rpc::params(format!("unknown command '{name}'")))
    }

    fn call(&mut self, call: &CallParams) -> Result<Value, Rpc> {
        let spec = Self::spec(&call.command)?;
        if spec.risk == Risk::Risky && spec.name != OWN_CONFIRMATION {
            let engine = Engine::new(&self.plans, self.plan_clock);
            let item = json!({
                "action": ACTION,
                "target": spec.name,
                "command": spec.name,
                "params": call.params,
            });
            let plan = engine
                .create(PLAN_KIND, vec![item])
                .map_err(|e| Rpc::command(&e))?;
            return Ok(json!({
                "status": "confirmation_required",
                "command": spec.name,
                "risk": spec.risk,
                "plan": engine.plan_json(&plan),
            }));
        }
        let output = self
            .dispatch
            .run(spec, &call.params)
            .map_err(|e| Rpc::command(&e))?;
        Ok(json!({"status": "ok", "command": spec.name, "risk": spec.risk, "output": output}))
    }

    fn confirm(&mut self, confirm: &ConfirmParams) -> Result<Value, Rpc> {
        let action = CommandAction {
            dispatch: self.dispatch,
            last: RefCell::new(None),
        };
        let engine = Engine::new(&self.plans, self.plan_clock).register(&action);
        let report = engine
            .confirm(&confirm.plan_id)
            .map_err(|e| Rpc::command(&e))?;
        let mut result = report.to_json();
        match action.last.take() {
            Some(Ok(output)) => result["output"] = output,
            Some(Err(error)) => result["error"] = command_error(&error),
            None => {}
        }
        Ok(result)
    }

    fn subscribe(&mut self, sub: &SubscribeParams, frames: &mut Vec<Value>) -> Result<Value, Rpc> {
        sub.validate().map_err(Rpc::params)?;
        let spec = Self::spec(&sub.command)?;
        if spec.risk != Risk::Read || !SUBSCRIBABLE.contains(&spec.name) {
            return Err(Rpc::params(format!(
                "'{}' cannot be subscribed to",
                spec.name
            )));
        }
        if self.subs.len() >= MAX_SUBSCRIPTIONS {
            return Err(Rpc::new(
                TOO_MANY_SUBSCRIPTIONS,
                format!("at most {MAX_SUBSCRIPTIONS} subscriptions"),
            ));
        }
        let id = self.next_id;
        self.next_id += 1;
        self.subs.insert(
            id,
            Subscription {
                spec,
                params: sub.params.clone(),
                visible_ms: sub.interval_visible_ms,
                hidden_ms: sub.interval_hidden_ms,
                last_ms: 0,
                seq: 0,
            },
        );
        // The first value comes at once, after the response that names the id.
        let result = json!({
            "subscription_id": id,
            "command": spec.name,
            "interval_ms": if self.visible { sub.interval_visible_ms } else { sub.interval_hidden_ms },
        });
        self.sample(id, frames);
        Ok(result)
    }

    fn unsubscribe(&mut self, unsub: &UnsubscribeParams) -> Result<Value, Rpc> {
        if self.subs.remove(&unsub.subscription_id).is_none() {
            return Err(Rpc::params(format!(
                "no subscription {}",
                unsub.subscription_id
            )));
        }
        Ok(json!({"subscription_id": unsub.subscription_id, "active": self.subs.len()}))
    }

    fn set_visibility(
        &mut self,
        visibility: &VisibilityParams,
        frames: &mut Vec<Value>,
    ) -> Result<Value, Rpc> {
        self.visible = visibility.visible;
        // Becoming visible may make samples due at once.
        frames.extend(self.tick());
        Ok(json!({"visible": self.visible, "active": self.subs.len()}))
    }

    fn sample(&mut self, id: u64, frames: &mut Vec<Value>) {
        let Some(sub) = self.subs.get_mut(&id) else {
            return;
        };
        let outcome = self.dispatch.run(sub.spec, &sub.params);
        // Measured after the run: a slow command does not make itself due again.
        sub.last_ms = self.mono.now_ms();
        sub.seq += 1;
        let mut event = json!({
            "subscription_id": id,
            "command": sub.spec.name,
            "seq": sub.seq,
            "monotonic_ms": sub.last_ms,
        });
        let mut ended = false;
        match outcome {
            Ok(result) => event["result"] = result,
            Err(error) => {
                // A capability this Mac lacks will not appear by asking again.
                ended = matches!(error, Error::Unsupported(_) | Error::NotImplemented(_));
                event["error"] = command_error(&error);
            }
        }
        if ended {
            event["ended"] = json!(true);
            self.subs.remove(&id);
        }
        frames.push(json!({"jsonrpc": "2.0", "method": "event", "params": event}));
    }
}

// ------------------------------------------------------------------- loop

/// What the dispatch loop waits for.
pub enum Input {
    Line(String),
    /// A line over [`MAX_LINE`]: the stream cannot be trusted any more.
    TooLong,
    Eof,
    Terminate,
}

const MAX_LINE: usize = 4 * 1024 * 1024;

/// Writes one frame per line and flushes it; `false` once the peer is gone.
fn emit(out: &mut impl Write, frames: &[Value]) -> bool {
    frames
        .iter()
        .all(|f| writeln!(out, "{f}").and_then(|()| out.flush()).is_ok())
}

/// Serves until end of input, SIGTERM or a closed stdout. Returns the exit code.
pub fn run_loop(
    session: &mut Session,
    mono: &dyn Mono,
    inputs: &mpsc::Receiver<Input>,
    out: &mut impl Write,
) -> u8 {
    loop {
        let input = match session.next_due_ms() {
            None => inputs.recv().map_err(|_| RecvTimeoutError::Disconnected),
            Some(due) => {
                inputs.recv_timeout(Duration::from_millis(due.saturating_sub(mono.now_ms())))
            }
        };
        let frames = match input {
            Ok(Input::Line(line)) if line.trim().is_empty() => continue,
            Ok(Input::Line(line)) => session.handle_line(line.trim()),
            Err(RecvTimeoutError::Timeout) => session.tick(),
            Ok(Input::TooLong) => {
                eprintln!("symcockpit: agent: input line over {MAX_LINE} bytes");
                return exit::ERROR;
            }
            Ok(Input::Eof | Input::Terminate) | Err(RecvTimeoutError::Disconnected) => {
                return exit::OK;
            }
        };
        if !emit(out, &frames) {
            // The app went away.
            return exit::OK;
        }
    }
}

fn spawn_stdin_reader(tx: mpsc::Sender<Input>) {
    std::thread::spawn(move || {
        let stdin = io::stdin();
        let mut stdin = stdin.lock();
        loop {
            let mut line = Vec::new();
            let read = (&mut stdin)
                .take(MAX_LINE as u64 + 1)
                .read_until(b'\n', &mut line);
            let input = match read {
                Ok(0) | Err(_) => Input::Eof,
                Ok(_) if line.len() > MAX_LINE => Input::TooLong,
                Ok(_) => Input::Line(String::from_utf8_lossy(&line).into_owned()),
            };
            let last = !matches!(input, Input::Line(_));
            if tx.send(input).is_err() || last {
                return;
            }
        }
    });
}

fn spawn_signal_watcher(tx: mpsc::Sender<Input>) {
    match symcockpit_macos::signal::terminate_pipe() {
        Ok(mut pipe) => {
            std::thread::spawn(move || {
                let mut byte = [0u8; 1];
                if pipe.read(&mut byte).is_ok_and(|n| n > 0) {
                    let _ = tx.send(Input::Terminate);
                }
            });
        }
        // Without it SIGTERM still ends the process, only not through the loop.
        Err(e) => eprintln!("symcockpit: agent: no signal handler: {e}"),
    }
}

// ------------------------------------------------------------------- main

/// The parent check, or the reason to refuse. The switch exists in debug
/// builds only.
pub fn gate(
    env: &BTreeMap<String, String>,
    sig: &dyn CodeSignature,
    baked_team: Option<&str>,
) -> Result<(), String> {
    if parent_check_skipped(env) {
        eprintln!("symcockpit: agent: parent check skipped (debug build, test switch set)");
        return Ok(());
    }
    parent_check::check_parent(sig, baked_team).map_err(|e| e.to_string())
}

/// `symcockpit agent --stdio [--data-dir <path>]`; `args` follow `agent`.
pub fn main(app: &App, args: &[String]) -> u8 {
    let mut stdio = false;
    let mut data_dir_override = None;
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--stdio" => stdio = true,
            "--data-dir" => match rest.next() {
                Some(path) => data_dir_override = Some(std::path::PathBuf::from(path)),
                None => return usage("--data-dir: expected a path"),
            },
            other => return usage(&format!("unknown argument '{other}'")),
        }
    }
    if !stdio {
        return usage("only --stdio is supported");
    }
    if let Err(reason) = gate(&app.env, &parent_check::SystemSignature, BAKED_TEAM) {
        eprintln!("symcockpit: agent: {reason}");
        eprintln!("symcockpit: agent: this command is started by Symaira Cockpit.app, not by hand");
        return exit::PERMISSION;
    }
    let env_lookup = |key: &str| app.env.get(key).cloned();
    let loaded = symcockpit_store::Config::load(&app.paths, &env_lookup);
    for warning in &loaded.warnings {
        eprintln!("symcockpit: {warning}");
    }
    let data_dir = data_dir_override
        .clone()
        .unwrap_or_else(|| app.paths.data_dir.clone());
    let ctx = Context {
        config: &loaded.config,
        paths: &app.paths,
        data_dir: &data_dir,
        data_dir_override: data_dir_override.as_deref(),
        env: &app.env,
        services: &app.services,
    };
    let server = mcp::Server::new(app, &ctx);
    let mono = RealMono::start();
    let mut session = Session::new(&server, &mono, &SystemClock);
    let (tx, rx) = mpsc::channel();
    spawn_stdin_reader(tx.clone());
    spawn_signal_watcher(tx);
    run_loop(&mut session, &mono, &rx, &mut io::stdout().lock())
}

fn usage(message: &str) -> u8 {
    eprintln!("symcockpit: agent: {message}\nusage: symcockpit agent --stdio [--data-dir <path>]");
    exit::USAGE
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;

    use super::*;

    /// Time and call log shared by the fakes.
    struct Fake {
        now: Cell<u64>,
        calls: RefCell<Vec<String>>,
        fail_with: RefCell<Option<Error>>,
    }

    impl Fake {
        fn new() -> Self {
            Self {
                now: Cell::new(0),
                calls: RefCell::new(Vec::new()),
                fail_with: RefCell::new(None),
            }
        }
    }

    impl Mono for Fake {
        fn now_ms(&self) -> u64 {
            self.now.get()
        }
    }

    impl Dispatch for Fake {
        fn run(
            &self,
            spec: &'static CommandSpec,
            params: &Map<String, Value>,
        ) -> Result<Value, Error> {
            self.calls.borrow_mut().push(format!(
                "{} {}",
                spec.name,
                Value::Object(params.clone())
            ));
            match self.fail_with.borrow().clone() {
                Some(e) => Err(e),
                None => Ok(json!({"ran": spec.name, "n": self.calls.borrow().len()})),
            }
        }
    }

    struct FixedClock(Cell<i64>);
    impl Clock for FixedClock {
        fn now(&self) -> i64 {
            self.0.get()
        }
    }

    fn rpc(method: &str, id: u64, params: Value) -> String {
        json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}).to_string()
    }

    fn hello(s: &mut Session) -> Value {
        s.handle_line(&rpc("hello", 1, json!({"protocol_version": 1})))
            .remove(0)
    }

    #[test]
    fn hello_reports_version_capabilities_and_the_register() {
        let fake = Fake::new();
        let clock = FixedClock(Cell::new(1000));
        let mut s = Session::new(&fake, &fake, &clock);
        let r = hello(&mut s);
        assert_eq!(r["id"], 1);
        let result = &r["result"];
        assert_eq!(result["protocol_version"], PROTOCOL_VERSION);
        assert_eq!(result["server_version"], VERSION);
        let caps = &result["capabilities"];
        assert_eq!(caps["default_interval_visible_ms"], 1000);
        assert_eq!(caps["default_interval_hidden_ms"], 10_000);
        let topics: Vec<&str> = caps["topics"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t.as_str().unwrap())
            .collect();
        assert!(topics.contains(&"metrics") && !topics.contains(&"fan.set"));
        let names: Vec<&str> = result["commands"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["name"].as_str().unwrap())
            .collect();
        assert!(names.contains(&"fan.set") && !names.contains(&"serve"));
        assert!(fake.calls.borrow().is_empty(), "hello measures nothing");
    }

    #[test]
    fn a_wrong_protocol_version_is_a_defined_error_and_leaves_the_agent_not_ready() {
        let fake = Fake::new();
        let clock = FixedClock(Cell::new(0));
        let mut s = Session::new(&fake, &fake, &clock);
        let r = s.handle_line(&rpc("hello", 7, json!({"protocol_version": 99})));
        assert_eq!(r[0]["error"]["code"], VERSION_MISMATCH);
        assert_eq!(
            r[0]["error"]["data"],
            json!({"supported": [1], "requested": 99})
        );
        let r = s.handle_line(&rpc("call", 8, json!({"command": "metrics"})));
        assert_eq!(r[0]["error"]["code"], NOT_READY);
        assert!(fake.calls.borrow().is_empty());
    }

    #[test]
    fn framing_errors_have_the_json_rpc_codes() {
        let fake = Fake::new();
        let clock = FixedClock(Cell::new(0));
        let mut s = Session::new(&fake, &fake, &clock);
        assert_eq!(s.handle_line("garbage")[0]["error"]["code"], PARSE_ERROR);
        assert_eq!(s.handle_line("[1]")[0]["error"]["code"], INVALID_REQUEST);
        assert_eq!(
            s.handle_line(r#"{"id":1,"method":"ping"}"#)[0]["error"]["code"],
            INVALID_REQUEST,
            "jsonrpc 2.0 is required"
        );
        assert_eq!(
            s.handle_line(&rpc("nope", 2, json!({})))[0]["error"]["code"],
            METHOD_NOT_FOUND
        );
        let r = s.handle_line(&rpc("hello", 3, json!({"client": "x"})));
        assert_eq!(r[0]["error"]["code"], INVALID_PARAMS);
        // A string id comes back as given; a notification gets no answer.
        let r = s.handle_line(r#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#);
        assert_eq!(r[0], json!({"jsonrpc": "2.0", "id": "abc", "result": {}}));
        assert!(
            s.handle_line(r#"{"jsonrpc":"2.0","method":"ping"}"#)
                .is_empty()
        );
    }

    #[test]
    fn read_reversible_and_human_only_commands_run_directly_through_the_dispatch() {
        let fake = Fake::new();
        let clock = FixedClock(Cell::new(0));
        let mut s = Session::new(&fake, &fake, &clock);
        hello(&mut s);
        let r = s.handle_line(&rpc("call", 2, json!({"command": "metrics"})));
        assert_eq!(r[0]["result"]["status"], "ok");
        assert_eq!(r[0]["result"]["risk"], "read");
        assert_eq!(r[0]["result"]["output"]["ran"], "metrics");
        let r = s.handle_line(&rpc(
            "call",
            3,
            json!({"command": "dim.set", "params": {"value": 0.5}}),
        ));
        assert_eq!(r[0]["result"]["risk"], "reversible");
        assert_eq!(
            *fake.calls.borrow(),
            vec![
                "metrics {}".to_owned(),
                "dim.set {\"value\":0.5}".to_owned()
            ]
        );
        // The register of this build has no human_only command yet; the rule
        // is the absence of a gate, which the risky test below contrasts.
        let r = s.handle_line(&rpc("call", 4, json!({"command": "nope"})));
        assert_eq!(r[0]["error"]["code"], INVALID_PARAMS);
        let r = s.handle_line(&rpc("call", 5, json!({"command": "serve"})));
        assert_eq!(r[0]["error"]["code"], INVALID_PARAMS);
    }

    #[test]
    fn a_command_error_keeps_its_exit_class() {
        let fake = Fake::new();
        let clock = FixedClock(Cell::new(0));
        let mut s = Session::new(&fake, &fake, &clock);
        hello(&mut s);
        *fake.fail_with.borrow_mut() =
            Some(Error::Permission("Bluetooth access was not granted".into()));
        let r = s.handle_line(&rpc("call", 2, json!({"command": "metrics"})));
        let e = &r[0]["error"];
        assert_eq!(e["code"], COMMAND_FAILED);
        assert_eq!(
            e["message"],
            "permission error: Bluetooth access was not granted"
        );
        assert_eq!(e["data"], json!({"exit_code": 3, "class": "permission"}));
    }

    #[test]
    fn a_risky_command_is_only_planned_until_it_is_confirmed() {
        let fake = Fake::new();
        let clock = FixedClock(Cell::new(1_000));
        let mut s = Session::new(&fake, &fake, &clock);
        hello(&mut s);
        let r = s.handle_line(&rpc(
            "call",
            2,
            json!({"command": "fan.set", "params": {"fraction": 0.7}}),
        ));
        let result = &r[0]["result"];
        assert_eq!(result["status"], "confirmation_required");
        assert_eq!(result["plan"]["state"], "pending");
        assert_eq!(result["plan"]["items"][0]["command"], "fan.set");
        assert_eq!(
            result["plan"]["items"][0]["params"],
            json!({"fraction": 0.7})
        );
        assert!(fake.calls.borrow().is_empty(), "planning changes nothing");
        let id = result["plan"]["id"].as_str().unwrap().to_owned();

        let r = s.handle_line(&rpc("confirm", 3, json!({"plan_id": id})));
        assert_eq!(r[0]["result"]["status"], "confirmed");
        assert_eq!(r[0]["result"]["output"]["ran"], "fan.set");
        assert_eq!(
            *fake.calls.borrow(),
            vec!["fan.set {\"fraction\":0.7}".to_owned()]
        );

        // A plan is confirmed once.
        let r = s.handle_line(&rpc("confirm", 4, json!({"plan_id": id})));
        assert_eq!(r[0]["error"]["code"], COMMAND_FAILED);
        assert!(
            r[0]["error"]["message"]
                .as_str()
                .unwrap()
                .contains("already confirmed")
        );
        assert_eq!(fake.calls.borrow().len(), 1);
    }

    #[test]
    fn an_expired_or_unknown_plan_is_refused_without_running_anything() {
        let fake = Fake::new();
        let clock = FixedClock(Cell::new(1_000));
        let mut s = Session::new(&fake, &fake, &clock);
        hello(&mut s);
        let r = s.handle_line(&rpc("call", 2, json!({"command": "restore"})));
        let id = r[0]["result"]["plan"]["id"].as_str().unwrap().to_owned();
        clock.0.set(1_000 + symcockpit_core::plan::PLAN_TTL_SECS);
        let r = s.handle_line(&rpc("confirm", 3, json!({"plan_id": id})));
        assert!(
            r[0]["error"]["message"]
                .as_str()
                .unwrap()
                .contains("expired")
        );
        let r = s.handle_line(&rpc("confirm", 4, json!({"plan_id": "pl_unknown"})));
        assert_eq!(r[0]["error"]["code"], COMMAND_FAILED);
        assert!(fake.calls.borrow().is_empty());
    }

    #[test]
    fn a_failing_confirmed_command_reports_failed_with_the_error() {
        let fake = Fake::new();
        let clock = FixedClock(Cell::new(0));
        let mut s = Session::new(&fake, &fake, &clock);
        hello(&mut s);
        let r = s.handle_line(&rpc("call", 2, json!({"command": "battery-limit.clear"})));
        let id = r[0]["result"]["plan"]["id"].as_str().unwrap().to_owned();
        *fake.fail_with.borrow_mut() = Some(Error::Permission("needs root".into()));
        let r = s.handle_line(&rpc("confirm", 3, json!({"plan_id": id})));
        assert_eq!(r[0]["result"]["status"], "failed");
        assert_eq!(r[0]["result"]["error"]["data"]["class"], "permission");
        assert_eq!(
            r[0]["result"]["results"][0]["detail"],
            "permission error: needs root"
        );
    }

    fn event(frame: &Value) -> &Value {
        assert_eq!(frame["method"], "event");
        assert!(frame.get("id").is_none(), "events are notifications");
        &frame["params"]
    }

    #[test]
    fn nothing_is_sampled_without_a_subscriber() {
        let fake = Fake::new();
        let clock = FixedClock(Cell::new(0));
        let mut s = Session::new(&fake, &fake, &clock);
        hello(&mut s);
        assert_eq!(s.next_due_ms(), None);
        fake.now.set(3_600_000);
        assert!(s.tick().is_empty());
        assert!(fake.calls.borrow().is_empty());
    }

    #[test]
    fn a_subscription_samples_at_the_visible_interval_and_stops_on_unsubscribe() {
        let fake = Fake::new();
        let clock = FixedClock(Cell::new(0));
        let mut s = Session::new(&fake, &fake, &clock);
        hello(&mut s);
        fake.now.set(5_000);
        let r = s.handle_line(&rpc("subscribe", 2, json!({"command": "metrics"})));
        assert_eq!(r[0]["result"]["subscription_id"], 1);
        assert_eq!(r[0]["result"]["interval_ms"], 1000);
        // The first value follows the response at once.
        assert_eq!(
            (
                event(&r[1])["seq"].as_u64(),
                event(&r[1])["monotonic_ms"].as_u64()
            ),
            (Some(1), Some(5_000))
        );
        assert_eq!(s.next_due_ms(), Some(6_000));
        fake.now.set(5_999);
        assert!(s.tick().is_empty());
        fake.now.set(6_000);
        let frames = s.tick();
        assert_eq!(frames.len(), 1);
        assert_eq!(event(&frames[0])["seq"], 2);
        assert_eq!(event(&frames[0])["result"]["ran"], "metrics");
        assert_eq!(s.next_due_ms(), Some(7_000));

        let r = s.handle_line(&rpc("unsubscribe", 3, json!({"subscription_id": 1})));
        assert_eq!(r[0]["result"], json!({"subscription_id": 1, "active": 0}));
        assert_eq!(s.next_due_ms(), None);
        fake.now.set(60_000);
        assert!(s.tick().is_empty());
        assert_eq!(
            fake.calls.borrow().len(),
            2,
            "no measurement after unsubscribe"
        );
        let r = s.handle_line(&rpc("unsubscribe", 4, json!({"subscription_id": 1})));
        assert_eq!(r[0]["error"]["code"], INVALID_PARAMS);
    }

    #[test]
    fn hidden_slows_the_cadence_and_visible_catches_up_at_once() {
        let fake = Fake::new();
        let clock = FixedClock(Cell::new(0));
        let mut s = Session::new(&fake, &fake, &clock);
        hello(&mut s);
        s.handle_line(&rpc(
            "subscribe",
            2,
            json!({"command": "sensors", "interval_visible_ms": 200, "interval_hidden_ms": 2000}),
        ));
        assert_eq!(s.next_due_ms(), Some(200));
        let r = s.handle_line(&rpc("set_visibility", 3, json!({"visible": false})));
        assert_eq!(r[0]["result"]["visible"], false);
        assert_eq!(r.len(), 1, "nothing due yet");
        assert_eq!(s.next_due_ms(), Some(2000));
        fake.now.set(1_999);
        assert!(s.tick().is_empty());
        fake.now.set(2_000);
        assert_eq!(s.tick().len(), 1);
        // Visible again after more than one visible interval: sampled in the reply.
        fake.now.set(2_500);
        let r = s.handle_line(&rpc("set_visibility", 4, json!({"visible": true})));
        assert_eq!(r.len(), 2);
        assert_eq!(event(&r[1])["seq"], 3);
    }

    #[test]
    fn subscribe_validates_topic_interval_and_count() {
        let fake = Fake::new();
        let clock = FixedClock(Cell::new(0));
        let mut s = Session::new(&fake, &fake, &clock);
        hello(&mut s);
        for params in [
            json!({"command": "fan.set"}),
            json!({"command": "history"}),
            json!({"command": "nope"}),
            json!({"command": "metrics", "interval_visible_ms": 5}),
            json!({"command": "metrics", "interval_hidden_ms": 99_999_999}),
        ] {
            let r = s.handle_line(&rpc("subscribe", 2, params.clone()));
            assert_eq!(r[0]["error"]["code"], INVALID_PARAMS, "{params}");
        }
        assert!(fake.calls.borrow().is_empty());
        for _ in 0..MAX_SUBSCRIPTIONS {
            let r = s.handle_line(&rpc("subscribe", 3, json!({"command": "battery"})));
            assert!(r[0]["result"].is_object());
        }
        let r = s.handle_line(&rpc("subscribe", 4, json!({"command": "battery"})));
        assert_eq!(r[0]["error"]["code"], TOO_MANY_SUBSCRIPTIONS);
    }

    #[test]
    fn a_failing_sample_is_an_error_event_and_an_unsupported_one_ends_the_subscription() {
        let fake = Fake::new();
        let clock = FixedClock(Cell::new(0));
        let mut s = Session::new(&fake, &fake, &clock);
        hello(&mut s);
        *fake.fail_with.borrow_mut() = Some(Error::Permission("no".into()));
        let r = s.handle_line(&rpc("subscribe", 2, json!({"command": "displays"})));
        assert_eq!(event(&r[1])["error"]["data"]["class"], "permission");
        assert!(event(&r[1]).get("ended").is_none());
        assert_eq!(s.subscription_count(), 1);
        *fake.fail_with.borrow_mut() = Some(Error::Unsupported("no display".into()));
        fake.now.set(1_000);
        let frames = s.tick();
        assert_eq!(event(&frames[0])["ended"], true);
        assert_eq!(s.subscription_count(), 0);
        assert_eq!(s.next_due_ms(), None);
    }

    #[test]
    fn the_loop_ends_on_eof_and_on_terminate_and_reports_a_closed_output() {
        let fake = Fake::new();
        let clock = FixedClock(Cell::new(0));
        for last in [Input::Eof, Input::Terminate] {
            let mut s = Session::new(&fake, &fake, &clock);
            let (tx, rx) = mpsc::channel();
            tx.send(Input::Line(rpc("hello", 1, json!({"protocol_version": 1}))))
                .unwrap();
            tx.send(Input::Line("  ".into())).unwrap();
            tx.send(Input::Line(rpc("ping", 2, json!({})))).unwrap();
            tx.send(last).unwrap();
            let mut out = Vec::new();
            assert_eq!(run_loop(&mut s, &fake, &rx, &mut out), exit::OK);
            assert_eq!(String::from_utf8(out).unwrap().lines().count(), 2);
        }
        struct Closed;
        impl Write for Closed {
            fn write(&mut self, _: &[u8]) -> io::Result<usize> {
                Err(io::ErrorKind::BrokenPipe.into())
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        let mut s = Session::new(&fake, &fake, &clock);
        let (tx, rx) = mpsc::channel();
        tx.send(Input::Line(rpc("ping", 1, json!({})))).unwrap();
        assert_eq!(run_loop(&mut s, &fake, &rx, &mut Closed), exit::OK);
        tx.send(Input::TooLong).unwrap();
        assert_eq!(run_loop(&mut s, &fake, &rx, &mut Vec::new()), exit::ERROR);
    }

    // ---------------------------------------------------------- parent gate

    struct Sig(Result<(), String>);
    impl CodeSignature for Sig {
        fn parent_pid(&self) -> u32 {
            7
        }
        fn satisfies(&self, _: u32, _: &str) -> Result<(), String> {
            self.0.clone()
        }
    }

    #[test]
    fn the_gate_asks_the_signature_and_the_switch_exists_in_debug_builds_only() {
        let none = BTreeMap::new();
        let on = BTreeMap::from([(
            "SYMCOCKPIT_AGENT_SKIP_PARENT_CHECK".to_owned(),
            "1".to_owned(),
        )]);
        let team = Some("ABCDE12345");
        assert!(gate(&none, &Sig(Ok(())), team).is_ok());
        assert!(
            gate(&none, &Sig(Err("unsigned".into())), team)
                .unwrap_err()
                .contains("unsigned")
        );
        assert!(
            gate(&none, &Sig(Ok(())), None)
                .unwrap_err()
                .contains("no team identifier")
        );
        let skipped = gate(&on, &Sig(Err("unsigned".into())), team);
        assert_eq!(skipped.is_ok(), cfg!(debug_assertions));
        // Only the exact value counts.
        let off = BTreeMap::from([(
            "SYMCOCKPIT_AGENT_SKIP_PARENT_CHECK".to_owned(),
            "0".to_owned(),
        )]);
        assert!(gate(&off, &Sig(Err("unsigned".into())), team).is_err());
    }
}
