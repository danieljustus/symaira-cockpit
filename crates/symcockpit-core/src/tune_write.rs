//! The unprivileged write surface of `TuneController`: brightness, extended
//! brightness, dim, warmth, profiles, keep-awake and the restore of display and
//! keep-awake overrides (the SMC half of `restore` belongs to the fan/charge
//! area: `writes::restore` in the binary crate calls its handler).
//!
//! Hard rules (tuning/AGENTS.md): every value is clamped through the safety
//! limits before it reaches a port, a non-finite value is refused first, and
//! whatever the process overrode is put back when it ends ([`Drop`]), when it
//! is interrupted, and — for the one override that outlives a process, the
//! backlight brightness — after a crash, from the persisted
//! [`DisplayRestoreRecord`] (Q05).

use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::SystemTime;

use serde_json::{Map, Value, json};
use symcockpit_contract::Error;
use symcockpit_store::{
    Config, DisplayRestoreRecord, Profile, clear_record, delete_profile, is_valid_profile_name,
    read_profile, read_record, write_profile, write_record,
};

use crate::ai_usage::redact;
use crate::awake::{AssertionToken, KeepAwakeCoordinator, PowerAssertionPort};
use crate::display_write::{BrightnessSink, DisplayWriter};
use crate::power::{KeepAwakeSession, KeepAwakeStatus, reference_date_seconds};

/// One history line, before the adapter stamps the time and appends it.
#[derive(Clone, Debug, PartialEq)]
pub struct LogEvent {
    pub action: &'static str,
    pub requested: Option<f64>,
    pub clamped: Option<f64>,
    pub applied: Option<f64>,
    pub success: bool,
    /// Already redacted.
    pub error: Option<String>,
}

/// Port: `HistoryService.logEvent`. Failing to log never fails a command.
pub trait HistorySink {
    fn log(&self, event: &LogEvent);
}

/// The safety clamps of `TuneConfig` that the write commands honour.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Limits {
    pub brightness: (f64, f64),
    pub dim: (f64, f64),
    pub extended: (f64, f64),
}

impl From<&Config> for Limits {
    fn from(c: &Config) -> Self {
        Self {
            brightness: (c.brightness_min, c.brightness_max),
            dim: (c.dim_min, c.dim_max),
            extended: (c.extended_brightness_min, c.extended_brightness_max),
        }
    }
}

/// `OverrideTracker`: what this process overrode and must put back.
#[derive(Default)]
struct Tracker {
    brightness: Option<f32>,
    warmth: Option<f32>,
    applied_warmth: f32,
    edr: Option<f64>,
    applied_edr: Option<f64>,
    /// An extended-brightness attempt captured the system headroom (Swift
    /// `saveOriginalEDRHeadroom`): the gamma table must be reset even when
    /// that attempt failed half way.
    edr_attempted: bool,
}

impl Tracker {
    fn has_overrides(&self) -> bool {
        self.brightness.is_some()
            || self.warmth.is_some()
            || self.edr.is_some()
            || self.edr_attempted
    }
}

/// Everything the write commands need, behind ports.
pub struct WriterPorts {
    pub display: DisplayWriter,
    pub power: Arc<dyn PowerAssertionPort>,
    pub history: Box<dyn HistorySink>,
    pub limits: Limits,
    pub data_dir: PathBuf,
    /// Running as root (state files are handed back to the data directory's user).
    pub is_root: bool,
    pub version: String,
    pub pid: u32,
    /// Whether a process is still running (`kill(pid, 0)`).
    pub process_alive: Box<dyn Fn(u32) -> bool>,
}

pub struct TuneWriter {
    ports: WriterPorts,
    tracker: RefCell<Tracker>,
    coordinator: KeepAwakeCoordinator,
    shut_down: Cell<bool>,
}

fn require_finite(value: f64) -> Result<(), Error> {
    if value.is_finite() {
        Ok(())
    } else {
        Err(Error::Usage("Value must be finite.".into()))
    }
}

impl TuneWriter {
    /// Consumes the record of a run that died before it could restore
    /// (SIGKILL, panic, power loss), before any new override can be applied.
    pub fn new(ports: WriterPorts) -> Self {
        let coordinator = KeepAwakeCoordinator::new(Box::new(SharedPort(Arc::clone(&ports.power))));
        let writer = Self {
            ports,
            tracker: RefCell::default(),
            coordinator,
            shut_down: Cell::new(false),
        };
        writer.consume_persisted_restore();
        writer
    }

    fn consume_persisted_restore(&self) {
        let sink = DisplayWriterSink(&self.ports.display);
        let own = self.ports.pid;
        let alive = &self.ports.process_alive;
        if let Err(e) = restore_from_record(&self.ports.data_dir, &sink, &|pid| {
            pid != own && !alive(pid)
        }) {
            eprintln!("symcockpit: warning: {e}");
        }
    }

    // ------------------------------------------------------------- history

    fn log(
        &self,
        action: &'static str,
        values: Option<(f64, f64, Option<f64>)>,
        result: Result<(), &Error>,
    ) {
        let (requested, clamped, applied) =
            values.map_or((None, None, None), |(r, c, a)| (Some(r), Some(c), a));
        self.ports.history.log(&LogEvent {
            action,
            requested,
            clamped,
            applied,
            success: result.is_ok(),
            error: result.err().map(|e| redact(&e.to_string())),
        });
    }

    /// Runs one logged write: `values` = (requested, clamped).
    fn logged(
        &self,
        action: &'static str,
        values: Option<(f64, f64)>,
        body: impl FnOnce() -> Result<(), Error>,
    ) -> Result<(), Error> {
        match body() {
            Ok(()) => {
                self.log(action, values.map(|(r, c)| (r, c, Some(c))), Ok(()));
                Ok(())
            }
            Err(e) => {
                self.log(action, values.map(|(r, c)| (r, c, None)), Err(&e));
                Err(e)
            }
        }
    }

    // --------------------------------------------------------------- writes

    pub fn builtin_brightness(&self) -> Result<f64, Error> {
        self.ports.display.builtin_brightness()
    }

    pub fn apply_builtin_brightness(&self, value: f64) -> Result<(), Error> {
        require_finite(value)?;
        let (min, max) = self.ports.limits.brightness;
        let clamped = value.clamp(min, max);
        self.logged("brightness.set", Some((value, clamped)), || {
            let original = self.ports.display.builtin_brightness().ok();
            self.ports.display.set_builtin_brightness(clamped as f32)?;
            if let Some(original) = original {
                self.save_brightness(original as f32);
            }
            Ok(())
        })
    }

    /// Remembers the brightness from before the first override, in memory and
    /// on disk (the record is what a later run restores from after a crash).
    fn save_brightness(&self, original: f32) {
        let first = self.tracker.borrow().brightness.is_none();
        if !first {
            return;
        }
        self.tracker.borrow_mut().brightness = Some(original);
        let Some(display_id) = self.ports.display.builtin_display_id_or_none() else {
            return;
        };
        let record = DisplayRestoreRecord {
            pid: self.ports.pid,
            display_id,
            brightness: f64::from(original),
        };
        if let Err(e) = write_record(&self.ports.data_dir, &record, self.ports.is_root) {
            eprintln!(
                "symcockpit: warning: could not record the original brightness (a crash would leave it changed): {e}"
            );
        }
    }

    pub fn apply_extended_brightness(&self, value: f64) -> Result<(), Error> {
        require_finite(value)?;
        let (min, max) = self.ports.limits.extended;
        let clamped = value.clamp(min, max);
        self.logged("extbright.set", Some((value, clamped)), || {
            if self.ports.display.builtin_display_id_or_none().is_some() {
                self.tracker.borrow_mut().edr_attempted = true;
            }
            self.ports.display.apply_extended_brightness(clamped)?;
            let mut tracker = self.tracker.borrow_mut();
            tracker.applied_edr = Some(clamped);
            tracker.edr.get_or_insert(clamped);
            Ok(())
        })
    }

    pub fn apply_dim(&self, value: f64) -> Result<(), Error> {
        require_finite(value)?;
        let (min, max) = self.ports.limits.dim;
        let clamped = value.clamp(min, max);
        self.ports.display.apply_dim(clamped as f32);
        self.log("dim.set", Some((value, clamped, Some(clamped))), Ok(()));
        Ok(())
    }

    pub fn reset_dim(&self) {
        self.ports.display.reset_dim();
        self.log("dim.reset", None, Ok(()));
    }

    pub fn apply_warmth(&self, value: f64) -> Result<(), Error> {
        require_finite(value)?;
        let clamped = value.clamp(0.0, 1.0);
        self.logged("warmth.set", Some((value, clamped)), || {
            self.ports.display.apply_warmth(clamped as f32)?;
            self.save_warmth(clamped as f32);
            Ok(())
        })
    }

    pub fn reset_warmth(&self) -> Result<(), Error> {
        self.logged("warmth.reset", None, || {
            self.ports.display.reset_warmth()?;
            // Keep the tracked value in step, or the readout would keep the old shift.
            self.save_warmth(0.0);
            Ok(())
        })
    }

    fn save_warmth(&self, value: f32) {
        let mut tracker = self.tracker.borrow_mut();
        tracker.applied_warmth = value;
        tracker.warmth.get_or_insert(value);
    }

    pub fn dim_level(&self) -> f64 {
        f64::from(self.ports.display.dim_level())
    }

    pub fn warmth_level(&self) -> f64 {
        f64::from(self.tracker.borrow().applied_warmth)
    }

    /// `ActiveOverrides` as JSON (absent keys mean "not active"): the display
    /// half. The fan and charge-limit keys are added by their own area.
    pub fn active_overrides(&self) -> Map<String, Value> {
        let mut out = Map::new();
        let (has_brightness, edr) = {
            let t = self.tracker.borrow();
            (t.brightness.is_some(), t.edr.and(t.applied_edr))
        };
        if has_brightness && let Ok(b) = self.builtin_brightness() {
            out.insert("brightness".into(), json!(b));
        }
        let dim = self.dim_level();
        if dim < 1.0 {
            out.insert("dim".into(), json!(dim));
        }
        let warmth = self.warmth_level();
        if warmth > 0.0 {
            out.insert("warmth".into(), json!(warmth));
        }
        if let Some(edr) = edr {
            out.insert("edr_brightness".into(), json!(edr));
        }
        out
    }

    // -------------------------------------------------------------- restore

    /// The display half of `restoreAll`: what this process overrode, then the
    /// dim overlay. No SMC and no history line: the caller runs the fan/charge
    /// area's `restore` handler, which logs the restore.
    pub fn restore_displays(&self) {
        self.restore_tracked();
        self.ports.display.reset_dim();
    }

    fn restore_tracked(&self) {
        let tracker = std::mem::take(&mut *self.tracker.borrow_mut());
        if tracker.has_overrides() {
            self.ports.display.restore_display_overrides(
                tracker.brightness,
                tracker.warmth.is_some() || tracker.edr_attempted,
            );
            clear_record(&self.ports.data_dir);
        }
    }

    /// Process end (`deinit`): idempotent, silent, no history line.
    pub fn shutdown(&self) {
        if self.shut_down.replace(true) {
            return;
        }
        self.coordinator.end();
        self.restore_displays();
        self.ports.display.remove_extended();
    }

    // ------------------------------------------------------------ keep-awake

    /// The blocking `symcockpit awake` assertion (released on drop).
    pub fn begin_assertion(
        &self,
        reason: &str,
        prevent_display_sleep: bool,
    ) -> Result<AssertionToken, Error> {
        AssertionToken::begin(Arc::clone(&self.ports.power), reason, prevent_display_sleep)
    }

    /// The MCP `keep_awake` session (lives as long as this process).
    pub fn begin_session(
        &self,
        duration: Option<f64>,
        prevent_display_sleep: bool,
        reason: &str,
    ) -> Result<KeepAwakeSession, Error> {
        self.coordinator
            .begin(duration, prevent_display_sleep, reason)
    }

    pub fn end_session(&self) -> KeepAwakeSession {
        self.coordinator.end();
        KeepAwakeSession::inactive(SystemTime::now())
    }

    pub fn session_status(&self) -> KeepAwakeSession {
        self.coordinator.status()
    }

    pub fn keep_awake_active(&self) -> bool {
        self.coordinator.is_active()
    }

    // -------------------------------------------------------------- profiles

    /// `profile save` / `save_profile`: the settings as this process sees them.
    pub fn save_profile(&self, name: &str) -> Result<(), Error> {
        if !is_valid_profile_name(name) {
            return Err(Error::Usage(format!(
                "Invalid profile name: '{name}'. Profile names may only contain letters, digits, hyphens, and underscores."
            )));
        }
        let now = reference_date_seconds(SystemTime::now());
        let profile = Profile {
            name: name.to_owned(),
            brightness: self.builtin_brightness().ok(),
            dim: Some(self.dim_level()),
            warmth: Some(self.warmth_level()),
            version: Some(self.ports.version.clone()),
            created_at: now,
            updated_at: now,
        };
        let result = write_profile(&self.ports.data_dir, &profile, self.ports.is_root)
            .map_err(|e| Error::Failed(e.to_string()));
        self.log("profile.save", None, result.as_ref().map(|_| ()));
        result
    }

    /// `profile load` / `load_profile`: reads, then applies brightness, dim and warmth.
    pub fn load_profile(&self, name: &str) -> Result<(), Error> {
        let profile = self.read_profile(name)?;
        let result = (|| {
            if let Some(b) = profile.brightness {
                self.apply_builtin_brightness(b)?;
            }
            if let Some(d) = profile.dim {
                self.apply_dim(d)?;
            }
            if let Some(w) = profile.warmth {
                self.apply_warmth(w)?;
            }
            Ok(())
        })();
        self.log("profile.load", None, result.as_ref().map(|_| ()));
        result
    }

    fn read_profile(&self, name: &str) -> Result<Profile, Error> {
        if !is_valid_profile_name(name) {
            return Err(Error::Usage(format!("Invalid profile name: '{name}'.")));
        }
        read_profile(&self.ports.data_dir, name).map_err(|e| {
            // Swift lets the Foundation error through: it is not a TuneError,
            // so the CLI prints its structured report and exits 1.
            let message = if e.kind() == std::io::ErrorKind::NotFound {
                format!("The file “profile-{name}.json” couldn’t be opened because there is no such file.")
            } else {
                format!("The data couldn’t be read because it is missing or malformed ({e}).")
            };
            let kind = if e.kind() == std::io::ErrorKind::NotFound { "NSError" } else { "DecodingError" };
            // Key order as the v0.12 binary printed it (a plain `JSONEncoder`, no sorting).
            let text = Value::String(redact(&message)).to_string();
            Error::Failed(format!(
                "{{\"message\":{text},\"localized\":{text},\"error\":\"{kind}\"}}"
            ))
        })
    }

    pub fn delete_profile(&self, name: &str) -> Result<(), Error> {
        if !is_valid_profile_name(name) {
            return Err(Error::Usage(format!("Invalid profile name: '{name}'.")));
        }
        let result =
            delete_profile(&self.ports.data_dir, name).map_err(|e| Error::Failed(e.to_string()));
        self.log("profile.delete", None, result.as_ref().map(|_| ()));
        result
    }

    // ------------------------------------------------------------- run loop

    /// Whether the caller must keep a run loop turning for the display layer.
    pub fn needs_pump(&self) -> bool {
        self.ports.display.needs_pump()
    }

    /// Whether an overlay is on screen, so the caller must keep the run loop turning.
    pub fn needs_overlay_run_loop(&self) -> bool {
        self.ports.display.has_overlay()
    }

    pub fn pump(&self, now: std::time::Instant) {
        self.ports.display.pump(now);
    }

    pub fn reassert(&self) {
        self.ports.display.reassert();
    }

    pub fn data_dir(&self) -> &Path {
        &self.ports.data_dir
    }
}

impl Drop for TuneWriter {
    fn drop(&mut self) {
        self.shutdown();
    }
}

impl KeepAwakeStatus for TuneWriter {
    fn status(&self) -> KeepAwakeSession {
        self.session_status()
    }
}

struct SharedPort(Arc<dyn PowerAssertionPort>);

impl PowerAssertionPort for SharedPort {
    fn create(&self, kind: crate::awake::PowerAssertionType, reason: &str) -> Result<u32, Error> {
        self.0.create(kind, reason)
    }
    fn release(&self, id: u32) {
        self.0.release(id);
    }
}

struct DisplayWriterSink<'a>(&'a DisplayWriter);

impl BrightnessSink for DisplayWriterSink<'_> {
    fn set_brightness(&self, display_id: u32, value: f32) -> Result<(), Error> {
        self.0.set_brightness_on(display_id, value)
    }
}

/// Puts the brightness back from the persisted record when its owner is gone
/// (`owner_gone`). Used at start (a crashed run) and by the signal handler
/// (this very process, `|_| true`). The record stays when the write fails so
/// the next start retries; an undecodable one is discarded.
pub fn restore_from_record(
    data_dir: &Path,
    sink: &dyn BrightnessSink,
    owner_gone: &dyn Fn(u32) -> bool,
) -> Result<(), Error> {
    let record = match read_record(data_dir) {
        Ok(Some(record)) => record,
        Ok(None) => return Ok(()),
        Err(_) => {
            clear_record(data_dir);
            return Ok(());
        }
    };
    if !owner_gone(record.pid) {
        return Ok(());
    }
    sink.set_brightness(record.display_id, record.brightness as f32)
        .map_err(|e| {
            Error::Failed(format!(
                "could not restore the brightness after an earlier run: {e}"
            ))
        })?;
    clear_record(data_dir);
    Ok(())
}
