//! The unprivileged write commands, natively: `brightness set`, `extbright set`,
//! `dim`, `warmth`, `awake` (blocking), `profile save|load|delete` and the display
//! and keep-awake half of `restore`, for the CLI and for the MCP tools of the
//! same names (reversible, so MCP runs them directly: architecture 5.3).
//!
//! One [`TuneWriter`] lives per process, on the main thread (AppKit windows
//! need it). It is what restore-on-exit means here: [`shutdown`] runs when the
//! command ends, and in `serve` when the client goes away. As in v0.12 a
//! one-shot CLI command therefore applies its override and puts it back at
//! exit; only `serve`, `awake` and the Cockpit app hold overrides for a while.
//!
//! `restore` is split with the fan/charge area ([`restore`]): this module puts
//! back displays and keep-awake, then the caller runs that area's `restore`
//! handler (`crate::write`) for the SMC half; where none is wired (test apps)
//! the Swift core finishes the job.

use std::cell::RefCell;
use std::io::{self, BufRead, Read};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::{Arc, Once, OnceLock};
use std::time::{Duration, Instant, SystemTime};

use serde_json::{Map, Value, json};
use symcockpit_contract::Error;
use symcockpit_core::awake::{AwakeOptions, AwakeSubcommand, parse_awake_options};
use symcockpit_core::display_write::DisplayWriter;
use symcockpit_core::edr::EdrOverlay;
use symcockpit_core::gamma::GammaController;
use symcockpit_core::power::{KeepAwakeSession, KeepAwakeStatus};
use symcockpit_core::tune_write::{
    HistorySink, Limits, LogEvent, TuneWriter, WriterPorts, restore_from_record,
};
use symcockpit_macos::display::{DisplayServicesBrightness, LiveDisplays};
use symcockpit_macos::display_write::{
    CoreGraphicsGamma, LiveBrightnessSink, LiveDim, LiveEdr, LivePowerAssertions, process_alive,
    pump_run_loop, restore_on_signal,
};
use symcockpit_macos::system::running_as_root;
use symcockpit_store::state_perms::{Owner, owner_of_path, ownership_to_restore};
use symcockpit_store::{HistoryEvent, append_history_event};

use crate::app::{Context, Output};

/// `TuneVersion.current`: the Tune component baseline that profiles record as
/// their `version`, independent of the release version (`Version.swift`).
pub const PROFILE_VERSION: &str = "0.10.0";

/// A parsed unprivileged write.
#[derive(Clone, Debug, PartialEq)]
pub enum WriteOp {
    BrightnessSet(f64),
    ExtbrightSet(f64),
    DimSet(f64),
    DimReset,
    WarmthSet(f64),
    WarmthReset,
    Restore,
    ProfileSave(String),
    ProfileLoad(String),
    ProfileDelete(String),
    AwakeOff,
    /// Blocking: hold an assertion until the duration ends or a signal comes.
    Awake(AwakeOptions),
}

// ------------------------------------------------------------------- parsing

fn unexpected(command: &str, arg: &str) -> Error {
    Error::Usage(format!("{command}: unexpected argument '{arg}'"))
}

/// `rejectTrailingArguments`.
fn reject_trailing(args: &[String], after: usize, command: &str) -> Result<(), Error> {
    match args.get(after) {
        Some(extra) => Err(unexpected(command, extra)),
        None => Ok(()),
    }
}

/// `parseValue`: one number with an optional leading `set`.
fn parse_value(args: &[String], command: &str) -> Result<f64, Error> {
    let values = if args.first().is_some_and(|a| a == "set") {
        &args[1..]
    } else {
        args
    };
    reject_trailing(values, 1, command)?;
    let Some(arg) = values.first() else {
        return Err(Error::Usage(format!(
            "{command}: expected a numeric value, e.g. `symcockpit {command} set 1.4`"
        )));
    };
    match arg.parse::<f64>() {
        Ok(v) if v.is_finite() => Ok(v),
        Ok(_) => Err(Error::Usage("Value must be finite.".into())),
        Err(_) => Err(unexpected(command, arg)),
    }
}

/// `brightness <value>` / `brightness set <value>` (the `get` form is a read).
pub fn parse_brightness_set(rest: &[String]) -> Result<WriteOp, Error> {
    parse_value(rest, "brightness set").map(WriteOp::BrightnessSet)
}

pub fn parse_extbright(rest: &[String]) -> Result<WriteOp, Error> {
    parse_value(rest, "extbright set").map(WriteOp::ExtbrightSet)
}

/// `dim set <v>` / `dim reset` (`--help` is answered before this runs).
pub fn parse_dim(rest: &[String]) -> Result<WriteOp, Error> {
    if rest.first().is_some_and(|a| a == "reset") {
        reject_trailing(rest, 1, "dim reset")?;
        return Ok(WriteOp::DimReset);
    }
    parse_value(rest, "dim set").map(WriteOp::DimSet)
}

pub fn parse_warmth(rest: &[String]) -> Result<WriteOp, Error> {
    if rest.first().is_some_and(|a| a == "reset") {
        reject_trailing(rest, 1, "warmth reset")?;
        return Ok(WriteOp::WarmthReset);
    }
    parse_value(rest, "warmth set").map(WriteOp::WarmthSet)
}

pub fn parse_restore(rest: &[String]) -> Result<WriteOp, Error> {
    reject_trailing(rest, 0, "restore")?;
    Ok(WriteOp::Restore)
}

/// `profile save|load|delete <name>`; the trailing-argument check is the caller's.
pub fn parse_profile(subcommand: &str, rest: &[String]) -> Result<WriteOp, Error> {
    let name = |what: &str| {
        rest.first()
            .cloned()
            .ok_or_else(|| Error::Usage(format!("profile {what}: expected a name.")))
    };
    match subcommand {
        "save" => name("save").map(WriteOp::ProfileSave),
        "load" => name("load").map(WriteOp::ProfileLoad),
        "delete" => name("delete").map(WriteOp::ProfileDelete),
        other => Err(Error::Usage(format!(
            "profile: unknown subcommand '{other}'."
        ))),
    }
}

/// `awake [--display] [--seconds N] [--for D] [--until HH:MM]` and `awake off`
/// (`awake status` is a read and never gets here).
pub fn parse_awake(rest: &[String]) -> Result<WriteOp, Error> {
    let now = jiff::Zoned::now();
    let now_unix = now.timestamp().as_millisecond() as f64 / 1000.0;
    let today_at = |hour: u32, minute: u32| {
        let at = now
            .with()
            .hour(i8::try_from(hour).ok()?)
            .minute(i8::try_from(minute).ok()?)
            .second(0)
            .subsec_nanosecond(0)
            .build()
            .ok()?;
        Some(at.timestamp().as_second() as f64)
    };
    let options = parse_awake_options(rest, now_unix, &today_at)?;
    Ok(match options.subcommand {
        Some(AwakeSubcommand::Off) => WriteOp::AwakeOff,
        // `status` is routed to the read path before parsing.
        Some(AwakeSubcommand::Status) | None => WriteOp::Awake(options),
    })
}

// ------------------------------------------------------------ the one writer

thread_local! {
    static WRITER: RefCell<Option<Rc<TuneWriter>>> = const { RefCell::new(None) };
}

/// Puts a writer in place of the live one (tests: fakes only).
pub fn install(writer: TuneWriter) {
    WRITER.with(|w| *w.borrow_mut() = Some(Rc::new(writer)));
}

fn existing() -> Option<Rc<TuneWriter>> {
    WRITER.with(|w| w.borrow().clone())
}

/// Restore-on-exit: puts back everything this process overrode and drops the
/// writer. Called once the command (or `serve`) is over; idempotent.
pub fn shutdown() {
    if let Some(writer) = WRITER.with(|w| w.borrow_mut().take()) {
        writer.shutdown();
    }
}

/// The display half of `ActiveOverrides` (`status`); empty while no write ran.
pub fn active_override_fields() -> Map<String, Value> {
    existing().map(|w| w.active_overrides()).unwrap_or_default()
}

pub fn keep_awake_active() -> bool {
    existing().is_some_and(|w| w.keep_awake_active())
}

/// `awake status` / `keep_awake_status`: the session of this process, which is
/// inactive until a write started one (v0.12 keeps no state file).
pub struct SessionView;

impl KeepAwakeStatus for SessionView {
    fn status(&self) -> KeepAwakeSession {
        existing().map_or_else(
            || KeepAwakeSession::inactive(SystemTime::now()),
            |w| w.session_status(),
        )
    }
}

struct FileHistory {
    file: PathBuf,
    owner: Option<Owner>,
}

impl HistorySink for FileHistory {
    fn log(&self, event: &LogEvent) {
        let stamped = HistoryEvent {
            timestamp: jiff::Timestamp::now()
                .strftime("%Y-%m-%dT%H:%M:%SZ")
                .to_string(),
            action: event.action.to_owned(),
            requested_value: event.requested,
            clamped_value: event.clamped,
            applied_value: event.applied,
            result: if event.success { "success" } else { "failed" }.to_owned(),
            error_reason: event.error.clone(),
        };
        if let Err(e) = append_history_event(&self.file, &stamped, self.owner) {
            // Swift's text; a lost history line never fails the command.
            eprintln!("symtune: warning: failed to write history event: {e}");
        }
    }
}

/// Where the interrupt handler finds the record of this process's brightness override.
static INTERRUPT_TARGET: OnceLock<(PathBuf, u32)> = OnceLock::new();
static ARMED: Once = Once::new();

/// Restore-on-interrupt, armed at start for `serve` and every write: SIGINT/SIGTERM put the brightness back from
/// the record and end the process with status 0, as the Swift handlers do. With
/// nothing overridden yet the interrupt just ends the process.
pub fn arm_interrupt_restore() {
    ARMED.call_once(|| {
        restore_on_signal(|| {
            if let Some((dir, pid)) = INTERRUPT_TARGET.get() {
                let _ =
                    restore_from_record(dir, &LiveBrightnessSink::new(), &|owner| owner == *pid);
            }
        });
    });
}

fn build_live(ctx: &Context) -> Result<TuneWriter, Error> {
    let gamma = Rc::new(GammaController::new(Box::new(CoreGraphicsGamma)));
    let display = DisplayWriter::new(
        Box::new(LiveDisplays::new()?),
        Box::new(DisplayServicesBrightness::new()),
        Box::new(LiveBrightnessSink::new()),
        gamma.clone(),
        EdrOverlay::new(gamma, Box::new(LiveEdr::new()?)),
        Box::new(LiveDim::new()?),
    );
    let (data_dir, pid, is_root) = (
        ctx.data_dir.to_path_buf(),
        std::process::id(),
        running_as_root(),
    );
    let writer = TuneWriter::new(WriterPorts {
        display,
        power: Arc::new(LivePowerAssertions),
        history: Box::new(FileHistory {
            file: data_dir.join("history.ndjson"),
            owner: ownership_to_restore(&data_dir, is_root, &owner_of_path, None),
        }),
        limits: Limits::from(ctx.config),
        data_dir: data_dir.clone(),
        is_root,
        version: PROFILE_VERSION.to_owned(),
        pid,
        process_alive: Box::new(process_alive),
    });
    let _ = INTERRUPT_TARGET.set((data_dir, pid));
    Ok(writer)
}

fn writer(ctx: &Context) -> Result<Rc<TuneWriter>, Error> {
    if let Some(w) = existing() {
        return Ok(w);
    }
    crate::hardware_writes_blocked()?;
    let writer = Rc::new(build_live(ctx)?);
    WRITER.with(|w| *w.borrow_mut() = Some(writer.clone()));
    Ok(writer)
}

// ------------------------------------------------------------------- running

/// Swift's `Double.description`, for the messages that interpolate a duration.
/// shortcut: exponent forms are approximated; durations are far from them.
fn swift_description(value: f64) -> String {
    let magnitude = value.abs();
    if value == 0.0 || (1e-4..1e16).contains(&magnitude) {
        format!("{value:?}")
    } else {
        let text = format!("{value:e}");
        let (mantissa, exponent) = text.split_once('e').unwrap_or((&text, "0"));
        let exponent: i32 = exponent.parse().unwrap_or(0);
        format!(
            "{mantissa}e{}{:02}",
            if exponent < 0 { '-' } else { '+' },
            exponent.abs()
        )
    }
}

/// Holds the assertion until `options.seconds` elapse (capped at 24 hours) or
/// forever; a signal ends the process from its own thread (see `build_live`).
fn run_awake(
    writer: &TuneWriter,
    options: &AwakeOptions,
    sleep: &dyn Fn(Duration),
) -> Result<(), Error> {
    let token = writer.begin_assertion("symcockpit awake", options.prevent_display_sleep)?;
    match options.seconds {
        Some(seconds) => {
            eprintln!(
                "symcockpit: holding wake assertion for {}s…",
                swift_description(seconds)
            );
            let capped = seconds.min(86_400.0);
            if capped != seconds {
                eprintln!("symcockpit: duration capped to 24 hours (86400s)");
            }
            let end = Instant::now() + Duration::from_secs_f64(capped);
            while let Some(left) = end
                .checked_duration_since(Instant::now())
                .filter(|l| !l.is_zero())
            {
                sleep(left.min(Duration::from_millis(100)));
            }
        }
        None => {
            eprintln!("symcockpit: holding wake assertion (Ctrl-C to release)…");
            loop {
                sleep(Duration::from_millis(100));
            }
        }
    }
    drop(token);
    Ok(())
}

/// Runs one write for the CLI. `Ok(None)`: the display half is done and the
/// rest belongs to the Swift core (forward).
pub fn run_cli(ctx: &Context, op: &WriteOp) -> Result<Option<Output>, Error> {
    match op {
        WriteOp::AwakeOff => {
            // Ends this process's session, if it has one; a fresh process has none.
            let session = existing().map_or_else(
                || KeepAwakeSession::inactive(SystemTime::now()),
                |w| w.end_session(),
            );
            Ok(Some(Output::Json(
                serde_json::to_value(session).map_err(|e| Error::Failed(e.to_string()))?,
            )))
        }
        WriteOp::Awake(options) => {
            run_awake(&*writer(ctx)?, options, &std::thread::sleep)?;
            Ok(Some(Output::text("")))
        }
        WriteOp::Restore => restore(ctx, || Ok(None)),
        other => run_op(&*writer(ctx)?, other).map(Some),
    }
}

/// `restore` (`restoreAll`): the display and keep-awake overrides here, then
/// the SMC half `smc` (the fan/charge area's handler, which also writes the
/// history line). `Ok(None)` from `smc`: not wired, the Swift core finishes.
pub fn restore(
    ctx: &Context,
    smc: impl FnOnce() -> Result<Option<Output>, Error>,
) -> Result<Option<Output>, Error> {
    writer(ctx)?.restore_displays();
    smc()
}

fn run_op(w: &TuneWriter, op: &WriteOp) -> Result<Output, Error> {
    match op {
        WriteOp::BrightnessSet(v) => w.apply_builtin_brightness(*v)?,
        WriteOp::ExtbrightSet(v) => w.apply_extended_brightness(*v)?,
        WriteOp::DimSet(v) => w.apply_dim(*v)?,
        WriteOp::DimReset => w.reset_dim(),
        WriteOp::WarmthSet(v) => w.apply_warmth(*v)?,
        WriteOp::WarmthReset => w.reset_warmth()?,
        WriteOp::ProfileSave(name) => {
            w.save_profile(name)?;
            return Ok(Output::Json(json!({"saved": name})));
        }
        WriteOp::ProfileLoad(name) => w.load_profile(name)?,
        WriteOp::ProfileDelete(name) => w.delete_profile(name)?,
        WriteOp::Restore | WriteOp::AwakeOff | WriteOp::Awake(_) => {
            return Err(Error::Failed("not a plain write".into()));
        }
    }
    Ok(Output::Json(json!({"applied": true})))
}

/// An MCP write tool by register name. `Ok(None)`: not one of these (or, for
/// `restore`, the Swift core must finish the SMC half).
pub fn run_tool(
    ctx: &Context,
    name: &str,
    arguments: &Map<String, Value>,
) -> Result<Option<Value>, Error> {
    let number = |key: &str| crate::mcp::require_double(arguments, key);
    let profile_name = || {
        arguments
            .get("name")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| Error::Usage(format!("{} requires a name.", tool_name(name))))
    };
    let op = match name {
        "brightness.set" => WriteOp::BrightnessSet(number("value")?),
        "extbright.set" => WriteOp::ExtbrightSet(number("value")?),
        "dim.set" => WriteOp::DimSet(number("value")?),
        "dim.reset" => WriteOp::DimReset,
        "warmth.set" => WriteOp::WarmthSet(number("value")?),
        "warmth.reset" => WriteOp::WarmthReset,
        "profile.save" => WriteOp::ProfileSave(profile_name()?),
        "profile.load" => WriteOp::ProfileLoad(profile_name()?),
        "profile.delete" => WriteOp::ProfileDelete(profile_name()?),
        "awake" => return keep_awake(ctx, arguments).map(Some),
        _ => return Ok(None),
    };
    Ok(Some(match run_op(&*writer(ctx)?, &op)? {
        Output::Json(v) | Output::Report { value: v, .. } => v,
        Output::Text { .. } => json!({"applied": true}),
    }))
}

fn tool_name(register_name: &str) -> &'static str {
    match register_name {
        "profile.save" => "save_profile",
        "profile.load" => "load_profile",
        _ => "delete_profile",
    }
}

/// `KeepAwakeTool.invoke`: the session lives in this (serve) process.
fn keep_awake(ctx: &Context, arguments: &Map<String, Value>) -> Result<Value, Error> {
    let flag = |key: &str| arguments.get(key).and_then(Value::as_bool).unwrap_or(false);
    let session = if flag("enabled") {
        crate::mcp::validate_duration(arguments.get("duration_seconds"))?;
        let duration = arguments.get("duration_seconds").and_then(Value::as_f64);
        writer(ctx)?.begin_session(
            duration,
            flag("prevent_display_sleep"),
            "symcockpit MCP keep_awake",
        )?
    } else {
        existing().map_or_else(
            || KeepAwakeSession::inactive(SystemTime::now()),
            |w| w.end_session(),
        )
    };
    serde_json::to_value(session).map_err(|e| Error::Failed(e.to_string()))
}

// --------------------------------------------------------------- serve input

/// Stdin for `serve` that keeps the main run loop turning while a dim window or
/// the extended-brightness layer is up (they are only composited while it
/// runs). A reader thread owns the blocking `read`; `fill_buf` waits for its
/// chunks in short slices, pumping in between, so every tool call still runs
/// on the main thread. Without overlays it simply blocks.
pub struct PumpedStdin {
    chunks: Receiver<Vec<u8>>,
    buffer: Vec<u8>,
    position: usize,
}

impl PumpedStdin {
    pub fn spawn() -> Self {
        // Bounded: a client flooding stdin waits, as with a plain blocking read.
        let (tx, rx) = mpsc::sync_channel(16);
        std::thread::spawn(move || {
            let mut stdin = io::stdin().lock();
            let mut chunk = vec![0_u8; 64 * 1024];
            // EOF or an error ends the stream: the sender is dropped.
            while let Ok(n) = stdin.read(&mut chunk) {
                if n == 0 || tx.send(chunk[..n].to_vec()).is_err() {
                    break;
                }
            }
        });
        Self {
            chunks: rx,
            buffer: Vec::new(),
            position: 0,
        }
    }

    fn wants_run_loop() -> bool {
        existing().is_some_and(|w| w.needs_overlay_run_loop())
    }
}

impl Read for PumpedStdin {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        let available = self.fill_buf()?;
        let n = available.len().min(out.len());
        out[..n].copy_from_slice(&available[..n]);
        self.consume(n);
        Ok(n)
    }
}

impl BufRead for PumpedStdin {
    fn fill_buf(&mut self) -> io::Result<&[u8]> {
        while self.position >= self.buffer.len() {
            let overlay = Self::wants_run_loop();
            let slice = if overlay {
                Duration::from_millis(20)
            } else {
                Duration::from_secs(3600)
            };
            match self.chunks.recv_timeout(slice) {
                Ok(chunk) => {
                    self.buffer = chunk;
                    self.position = 0;
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => {
                    self.buffer.clear();
                    self.position = 0;
                    break;
                }
            }
            if let Some(w) = existing() {
                w.pump(Instant::now());
            }
            if overlay {
                pump_run_loop(0.0);
            }
        }
        Ok(&self.buffer[self.position..])
    }

    fn consume(&mut self, amount: usize) {
        self.position = (self.position + amount).min(self.buffer.len());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_profile_version_is_the_swift_tune_component_version() {
        let swift = include_str!("../../../tuning/Sources/SymCockpitCore/Version.swift");
        assert!(swift.contains(&format!("current = \"{PROFILE_VERSION}\"")));
    }

    #[test]
    fn swift_double_descriptions() {
        for (value, text) in [
            (1800.0, "1800.0"),
            (0.5, "0.5"),
            (0.0, "0.0"),
            (86_400.0, "86400.0"),
            (1e20, "1e+20"),
            (1.5e-7, "1.5e-07"),
        ] {
            assert_eq!(swift_description(value), text);
        }
    }

    #[test]
    fn values_parse_like_swift_double() {
        let a = |v: &[&str]| v.iter().map(ToString::to_string).collect::<Vec<_>>();
        assert_eq!(parse_value(&a(&["set", "0.5"]), "x"), Ok(0.5));
        assert_eq!(parse_value(&a(&["0.5"]), "x"), Ok(0.5));
        assert_eq!(parse_value(&a(&["set", ".5"]), "x"), Ok(0.5));
        assert_eq!(parse_value(&a(&["1e-1"]), "x"), Ok(0.1));
        assert!(parse_value(&a(&["0,5"]), "x").is_err());
    }
}
