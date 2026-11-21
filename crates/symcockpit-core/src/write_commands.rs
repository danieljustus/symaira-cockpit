//! The privileged write commands of the CLI: `fan set|auto|governor`,
//! `battery-limit set|clear` and `restore` (`runFanSubcommand`,
//! `runBatteryLimitSubcommand`, `runWriteCommand` and the matching
//! `TuneController` methods of v0.12), plus the plan actions the MCP layer
//! confirms (`fan.set`, `fan.auto`, `battery-limit.set`, `battery-limit.clear`).
//!
//! Everything platform-facing arrives through [`WriteEnv`], so the parsing,
//! the safety order and the history trail are tested against fakes. Like
//! v0.12 the CLI never elevates by itself: without root the SMC write is
//! refused and the error carries exit code 3.

use std::cell::RefCell;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use symcockpit_contract::{Error, Outcome};
use symcockpit_store::history_log;
use symcockpit_store::state_perms::Owner;

use crate::battery::BatterySource;
use crate::charge_limit::{self, ChargeEnv, MacChargeLimit, Mechanism};
use crate::fan::{self, FanEnv, FanError, fan_count};
use crate::plan::{self, ItemResult};
use crate::restore::RestoreTracker;
use crate::sensors::{
    FanProfile, FanSelectionSource, read_charge_inhibit_state, read_fan_mode, read_fan_target_rpm,
};

/// One parsed write command.
#[derive(Clone, Debug, PartialEq)]
pub enum Command {
    FanSet(f64),
    FanAuto,
    /// `--state <path>`; `None` means the caller's default profile file.
    FanGovernor {
        state: Option<PathBuf>,
    },
    ChargeSet(i64),
    ChargeClear,
    Restore,
}

fn reject_trailing(args: &[String], after: usize, command: &str) -> Result<(), Error> {
    match args.get(after) {
        Some(extra) => Err(Error::Usage(format!(
            "{command}: unexpected argument '{extra}'"
        ))),
        None => Ok(()),
    }
}

/// `parseValue` / `parseInt`: one value with an optional leading `set`.
fn value_args<'a>(args: &'a [String], command: &str) -> Result<&'a [String], Error> {
    let values = if args.first().is_some_and(|a| a == "set") {
        &args[1..]
    } else {
        args
    };
    reject_trailing(values, 1, command)?;
    Ok(values)
}

fn parse_double(args: &[String], command: &str) -> Result<f64, Error> {
    let values = value_args(args, command)?;
    match values.first() {
        Some(arg) => {
            let value = arg
                .parse::<f64>()
                .map_err(|_| Error::Usage(format!("{command}: unexpected argument '{arg}'")))?;
            if value.is_finite() {
                Ok(value)
            } else {
                Err(Error::Usage("Value must be finite.".into()))
            }
        }
        None => Err(Error::Usage(format!(
            "{command}: expected a numeric value, e.g. `symcockpit {command} set 1.4`"
        ))),
    }
}

fn parse_int(args: &[String], command: &str) -> Result<i64, Error> {
    let values = value_args(args, command)?;
    match values.first() {
        Some(arg) => arg
            .parse::<i64>()
            .map_err(|_| Error::Usage(format!("{command}: unexpected argument '{arg}'"))),
        None => Err(Error::Usage(format!(
            "{command}: expected an integer value, e.g. `symcockpit {command} set 80`"
        ))),
    }
}

/// `fan` arguments that are neither a read nor a profile selection.
pub fn parse_fan(rest: &[String]) -> Result<Command, Error> {
    match rest.first().map(String::as_str) {
        Some("auto") => {
            reject_trailing(rest, 1, "fan auto")?;
            Ok(Command::FanAuto)
        }
        Some("governor") => {
            let args = &rest[1..];
            let Some(first) = args.first() else {
                return Ok(Command::FanGovernor { state: None });
            };
            if first != "--state" {
                return Err(Error::Usage(format!(
                    "fan governor: unexpected argument '{first}'"
                )));
            }
            let Some(path) = args.get(1) else {
                return Err(Error::Usage(
                    "fan governor: --state requires a path.".into(),
                ));
            };
            reject_trailing(args, 2, "fan governor")?;
            Ok(Command::FanGovernor {
                state: Some(PathBuf::from(path)),
            })
        }
        _ => parse_double(rest, "fan set").map(Command::FanSet),
    }
}

pub fn parse_battery_limit(rest: &[String]) -> Result<Command, Error> {
    if rest.first().is_some_and(|a| a == "clear") {
        reject_trailing(rest, 1, "battery-limit clear")?;
        return Ok(Command::ChargeClear);
    }
    let percent = parse_int(rest, "battery-limit set")?;
    // Swift hands the value on as a Double; Double(Int.max) is not an Int.
    // Only values that round up to 2^63 get here; Swift prints that as below.
    if percent as f64 >= 9.223_372_036_854_775_807e18 {
        return Err(Error::Usage(
            "battery-limit: percent value is not a representable integer (got 9.223372036854776e+18)."
                .into(),
        ));
    }
    Ok(Command::ChargeSet(percent))
}

pub fn parse_restore(rest: &[String]) -> Result<Command, Error> {
    reject_trailing(rest, 0, "restore")?;
    Ok(Command::Restore)
}

/// Everything a write touches.
pub struct WriteEnv<'a> {
    pub fan: FanEnv<'a>,
    pub mac: Option<&'a dyn MacChargeLimit>,
    pub battery: &'a dyn BatterySource,
    pub data_dir: &'a Path,
    /// Whom the files written under `data_dir` belong to (see `state_perms`).
    pub owner: Option<Owner>,
    pub is_root: bool,
    /// `YYYY-MM-DDTHH:MM:SSZ` of now, for the history trail.
    pub now: &'a dyn Fn() -> String,
}

impl WriteEnv<'_> {
    fn charge(&self) -> ChargeEnv<'_> {
        ChargeEnv {
            fan: &self.fan,
            mac: self.mac,
            battery: self.battery,
            config: self.fan.config,
        }
    }

    pub fn history(
        &self,
        action: &str,
        values: (Option<f64>, Option<f64>, Option<f64>),
        result: &Result<(), Error>,
    ) {
        let reason = result.as_ref().err().map(ToString::to_string);
        let now = (self.now)();
        let event = history_log::Event {
            timestamp: &now,
            action,
            requested: values.0,
            clamped: values.1,
            applied: values.2,
            result: if result.is_ok() { "success" } else { "failed" },
            error_reason: reason.as_deref(),
        };
        if let Err(e) = history_log::append(self.data_dir, self.owner, &event) {
            eprintln!("symtune: warning: failed to write history event: {e}");
        }
    }
}

fn fan_err(env: &WriteEnv, e: FanError) -> Error {
    e.into_error(env.is_root)
}

/// A tracker that has already consumed what a killed predecessor left
/// (`TuneController.init` does this before every command). Its warnings go
/// to stderr as `symtune: warning:` lines.
fn tracker(env: &WriteEnv) -> RestoreTracker {
    let mut tracker = RestoreTracker::new(env.data_dir, env.owner);
    for warning in tracker.consume_persisted(&env.fan).warnings {
        eprintln!("symtune: warning: {warning}");
    }
    tracker
}

fn save_fan_originals(env: &WriteEnv, tracker: &mut RestoreTracker) {
    for index in 0..fan_count(env.fan.smc) {
        tracker.save_fan_original(&env.fan, index);
    }
}

/// `TuneController.applyFan` without escalation.
pub fn fan_set(env: &WriteEnv, tracker: &mut RestoreTracker, fraction: f64) -> Result<(), Error> {
    let cfg = env.fan.config;
    let clamped = fan::clamp_fan_fraction(fraction, cfg.fan_fraction_min, cfg.fan_fraction_max);
    save_fan_originals(env, tracker);
    let result = fan::apply_fan(&env.fan, fraction).map_err(|e| fan_err(env, e));
    env.history(
        "fan.set",
        (
            Some(fraction),
            Some(clamped),
            result.is_ok().then_some(clamped),
        ),
        &result,
    );
    result
}

/// `TuneController.restoreFanAuto`.
pub fn fan_auto(env: &WriteEnv) -> Result<(), Error> {
    let result = fan::restore_auto(&env.fan).map_err(|e| fan_err(env, e));
    env.history("fan.auto", (None, None, None), &result);
    result
}

/// `TuneController.applyChargeLimit`: the mechanism is chosen by presence,
/// AC power is required on the SMC path, the original is recorded before the
/// first write and the state is read back.
pub fn charge_set(env: &WriteEnv, tracker: &mut RestoreTracker, percent: i64) -> Result<(), Error> {
    let cfg = env.fan.config;
    let clamped = percent.clamp(cfg.charge_limit_min, cfg.charge_limit_max);
    let result = charge_limit::set(&env.charge(), tracker, percent).and_then(|r| r.into_result());
    env.history(
        "battery-limit.set",
        (
            Some(percent as f64),
            Some(clamped as f64),
            result.is_ok().then_some(clamped as f64),
        ),
        &result,
    );
    result
}

/// `TuneController.clearChargeLimit`.
pub fn charge_clear(env: &WriteEnv) -> Result<(), Error> {
    let result = charge_limit::clear(&env.charge()).and_then(|r| r.into_result());
    env.history("battery-limit.clear", (None, None, None), &result);
    result
}

/// `TuneController.restoreAll` in a fresh process: whatever a predecessor
/// left is put back (done by [`tracker`]), then anything this process holds.
pub fn restore_all(env: &WriteEnv, tracker: &mut RestoreTracker) -> Result<(), Error> {
    tracker.restore_all(&env.fan);
    let result = Ok(());
    env.history("restore", (None, None, None), &result);
    result
}

/// Run one non-governor command. The governor is a long-running loop; see
/// [`run_governor`].
pub fn execute(env: &WriteEnv, command: &Command) -> Result<(), Error> {
    let mut tracker = tracker(env);
    match command {
        Command::FanSet(v) => fan_set(env, &mut tracker, *v),
        Command::FanAuto => fan_auto(env),
        Command::ChargeSet(p) => charge_set(env, &mut tracker, *p),
        Command::ChargeClear => charge_clear(env),
        Command::Restore => restore_all(env, &mut tracker),
        Command::FanGovernor { .. } => Err(Error::Failed(
            "the fan governor runs through run_governor".into(),
        )),
    }
}

/// `TuneController.runFanGovernor`: the temperature-tracking loop in this
/// process until the stored profile becomes `system` or `should_continue`
/// says no. Needs root. `say` receives the stderr lines.
pub fn run_governor(
    env: &WriteEnv,
    state: &Path,
    selection: &dyn FanSelectionSource,
    should_continue: &dyn Fn() -> bool,
    say: &mut dyn FnMut(String),
) -> Result<(), Error> {
    if !env.is_root {
        return Err(Error::Permission(
            "the fan governor writes the SMC and must run as root — start it with `sudo symcockpit fan governor`, or use the cockpit's fan control, which elevates for you"
                .into(),
        ));
    }
    let selected = selection.selection();
    say(format!(
        "fan governor: profile '{}' from {}",
        selected.profile.as_str(),
        state.display()
    ));
    if let Some(target) = fan::effective_cool_target(&selected) {
        say(format!(
            "fan governor: Cool target {target:.0}°C average cluster temperature"
        ));
    }
    if selected.profile == FanProfile::System {
        say("fan governor: nothing to do — the fan control is on its default position, so the firmware curve is left alone. Select 'comfort' or 'performance' first (`symcockpit fan profile comfort`).".into());
        return Ok(());
    }
    let mut tracker = tracker(env);
    save_fan_originals(env, &mut tracker);
    let mut lines = Vec::new();
    let result = crate::governor::run(
        &env.fan,
        &|| selection.selection(),
        should_continue,
        &mut |temperature, applied| {
            if let (Some(t), Some(a)) = (temperature, applied) {
                lines.push(format!("fan governor: die {t:.1}°C -> {:.0}%", a * 100.0));
            }
        },
    );
    for line in lines {
        say(line);
    }
    // The loop handed the fans back itself; the record has nothing left to undo.
    tracker.forget_fans();
    result.map_err(|e| fan_err(env, e))
}

// ---------------------------------------------------------------------------
// Through the privileged helper (XPC)
// ---------------------------------------------------------------------------

/// Where a command is carried out.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Route {
    /// This process writes (root, or refused with exit 3).
    Direct,
    /// The running helper writes; fall back to [`Route::Direct`] only when it cannot be reached.
    Helper,
}

/// Root writes itself. Without root the helper takes what it can do: the
/// fan commands, the SMC charge limit and the restore. The governor loop
/// runs in its own process, and the macOS charge limit is not an SMC write
/// (the helper does not offer it), so both stay direct.
pub fn route(env: &WriteEnv, command: &Command) -> Route {
    if env.is_root {
        return Route::Direct;
    }
    match command {
        Command::FanGovernor { .. } => Route::Direct,
        Command::ChargeSet(_) | Command::ChargeClear => {
            match charge_limit::select(&env.fan, env.mac) {
                Mechanism::Smc(_) => Route::Helper,
                _ => Route::Direct,
            }
        }
        _ => Route::Helper,
    }
}

/// The typed helper request for `command` (a fixed fraction gets the longest
/// lease, as the direct write holds until `fan auto`/`restore`).
pub fn helper_action(command: &Command) -> Option<symcockpit_helper_proto::Action> {
    use symcockpit_helper_proto::{Action, MAX_LEASE_MS};
    Some(match command {
        Command::FanSet(fraction) => Action::FanSetTarget {
            fraction: *fraction,
            lease_ms: MAX_LEASE_MS,
        },
        Command::FanAuto => Action::FanSetAuto,
        Command::ChargeSet(percent) => Action::ChargeLimitSmc {
            percent: Some(*percent),
        },
        Command::ChargeClear => Action::ChargeLimitSmc { percent: None },
        Command::Restore => Action::SmcRestore,
        Command::FanGovernor { .. } => return None,
    })
}

/// A helper reply as the CLI's result; the texts are the helper's own.
pub fn reply_to_result(reply: symcockpit_helper_proto::Reply) -> Result<(), Error> {
    use symcockpit_helper_proto::{ErrorKind, Reply};
    match reply {
        Reply::Ok => Ok(()),
        Reply::Error { kind, message } => Err(match kind {
            ErrorKind::Usage => Error::Usage(message),
            ErrorKind::Permission => Error::Permission(message),
            ErrorKind::Unsupported => Error::Unsupported(message),
            ErrorKind::Unconfirmed | ErrorKind::Failed => Error::Failed(message),
        }),
        other => Err(Error::Failed(format!("unexpected helper reply: {other:?}"))),
    }
}

/// The history line for a command the helper carried out (the helper keeps
/// no user history).
pub fn log_outcome(env: &WriteEnv, command: &Command, result: &Result<(), Error>) {
    let cfg = env.fan.config;
    let ok = result.is_ok();
    let (action, values) = match command {
        Command::FanSet(f) => {
            let clamped = fan::clamp_fan_fraction(*f, cfg.fan_fraction_min, cfg.fan_fraction_max);
            ("fan.set", (Some(*f), Some(clamped), ok.then_some(clamped)))
        }
        Command::FanAuto => ("fan.auto", (None, None, None)),
        Command::ChargeSet(p) => {
            let clamped = (*p).clamp(cfg.charge_limit_min, cfg.charge_limit_max) as f64;
            (
                "battery-limit.set",
                (Some(*p as f64), Some(clamped), ok.then_some(clamped)),
            )
        }
        Command::ChargeClear => ("battery-limit.clear", (None, None, None)),
        Command::Restore => ("restore", (None, None, None)),
        Command::FanGovernor { .. } => return,
    };
    env.history(action, values, result);
}

// ---------------------------------------------------------------------------
// Plan variants (MCP): identity = the current mode / target / limit.
// ---------------------------------------------------------------------------

/// What `fan set`/`fan auto` depend on: every fan's mode and target RPM.
pub fn fan_identity(env: &FanEnv) -> Value {
    let fans: Vec<Value> = (0..fan_count(env.smc))
        .map(|i| {
            json!({
                "mode": read_fan_mode(env.smc, i as u8),
                "target_rpm": read_fan_target_rpm(env.smc, i as u8),
            })
        })
        .collect();
    json!({ "fans": fans })
}

/// What the charge limit depends on: the mechanism and its current state.
pub fn charge_identity(env: &ChargeEnv) -> Value {
    let mechanism = charge_limit::select(env.fan, env.mac);
    let state = match &mechanism {
        Mechanism::Smc(_) => json!({ "inhibit": read_charge_inhibit_state(env.fan.smc) }),
        Mechanism::MacOs => env.mac.map_or(
            Value::Null,
            |m| json!({ "enabled": m.is_enabled(), "limit": m.limit() }),
        ),
        Mechanism::Unsupported(_) => Value::Null,
    };
    json!({ "mechanism": mechanism.name(), "state": state })
}

/// The plan item for one command, carrying the identity it was planned
/// against. `None` for commands that are not plannable.
pub fn plan_item(env: &WriteEnv, command: &Command) -> Option<Value> {
    let (action, target, args, identity) = match command {
        Command::FanSet(f) => (
            "fan.set",
            "fans",
            json!({"fraction": f}),
            fan_identity(&env.fan),
        ),
        Command::FanAuto => ("fan.auto", "fans", json!({}), fan_identity(&env.fan)),
        Command::ChargeSet(p) => (
            "battery-limit.set",
            "battery",
            json!({"percent": p}),
            charge_identity(&env.charge()),
        ),
        Command::ChargeClear => (
            "battery-limit.clear",
            "battery",
            json!({}),
            charge_identity(&env.charge()),
        ),
        Command::FanGovernor { .. } | Command::Restore => return None,
    };
    Some(json!({
        "action": action,
        "target": target,
        "args": args,
        "identity": identity,
    }))
}

/// Executes the four planned write kinds. A plan is confirmed once, so each
/// action re-reads the identity first (`still_valid`) and reads the result
/// back (Q01): a write that does not hold is `unconfirmed`.
pub struct WriteAction<'a> {
    pub env: &'a WriteEnv<'a>,
    pub kind: &'static str,
    tracker: RefCell<Option<RestoreTracker>>,
}

impl<'a> WriteAction<'a> {
    pub fn new(env: &'a WriteEnv<'a>, kind: &'static str) -> Self {
        Self {
            env,
            kind,
            tracker: RefCell::new(None),
        }
    }

    fn identity_now(&self) -> Value {
        if self.kind.starts_with("fan.") {
            fan_identity(&self.env.fan)
        } else {
            charge_identity(&self.env.charge())
        }
    }

    fn command_of(&self, item: &Value) -> Result<Command, String> {
        let args = item.get("args").cloned().unwrap_or(Value::Null);
        match self.kind {
            "fan.set" => args["fraction"]
                .as_f64()
                .filter(|f| f.is_finite())
                .map(Command::FanSet)
                .ok_or_else(|| "fan.set: missing fraction".to_owned()),
            "fan.auto" => Ok(Command::FanAuto),
            "battery-limit.set" => args["percent"]
                .as_i64()
                .map(Command::ChargeSet)
                .ok_or_else(|| "battery-limit.set: missing percent".to_owned()),
            _ => Ok(Command::ChargeClear),
        }
    }
}

impl plan::Action for WriteAction<'_> {
    fn kind(&self) -> &'static str {
        self.kind
    }

    fn still_valid(&self, item: &Value) -> Result<(), String> {
        if item.get("identity") == Some(&self.identity_now()) {
            Ok(())
        } else {
            Err("the fans or the charge limit changed since the plan was made".into())
        }
    }

    fn execute(&self, item: &Value) -> ItemResult {
        let command = match self.command_of(item) {
            Ok(c) => c,
            Err(e) => return ItemResult::new(Outcome::Failed, e),
        };
        let mut guard = self.tracker.borrow_mut();
        let tracker = guard.get_or_insert_with(|| tracker(self.env));
        let applied = match &command {
            Command::FanSet(v) => fan_set(self.env, tracker, *v),
            Command::FanAuto => fan_auto(self.env),
            Command::ChargeSet(p) => charge_set(self.env, tracker, *p),
            _ => charge_clear(self.env),
        };
        match applied {
            Err(Error::Unsupported(detail)) => ItemResult::new(Outcome::Unsupported, detail),
            Err(e) => ItemResult::new(Outcome::Failed, e.to_string()),
            Ok(()) => self.read_back(&command),
        }
    }
}

impl WriteAction<'_> {
    /// The write returned: does the hardware say the same?
    fn read_back(&self, command: &Command) -> ItemResult {
        let env = self.env;
        let held = match command {
            Command::FanSet(v) => fan::holds_applied_state(&env.fan, *v),
            Command::FanAuto => !fan::has_software_override(&env.fan),
            // The charge paths read their state back themselves (`charge_limit::set`/`clear`).
            _ => true,
        };
        if held {
            ItemResult::new(Outcome::Confirmed, None)
        } else {
            ItemResult::new(
                Outcome::Unconfirmed,
                "the write returned, but the fans do not read back as asked".to_owned(),
            )
        }
    }
}
