//! Volume and mute per app (R44) through process taps.
//!
//! Design (spike S4, patterns only): a private process tap with
//! `CATapMuted` silences the app's own output and captures it; a private
//! aggregate device (main device = the current default output, plus the tap)
//! runs an IOProc that scales the captured samples by the app's gain and writes
//! them to that output. The tap is therefore the only thing that can silence an
//! app, and every failure path ends by destroying it:
//!
//! * teardown order: stop, IOProc, aggregate, tap;
//! * any error while building or rebuilding destroys the tap too (fail open:
//!   the app is audible again at full volume);
//! * the default output changing rebuilds the aggregate and keeps the tap; the
//!   output vanishing, or the rebuild failing, releases every app;
//! * a gain of 1 and no mute needs no tap, so none is kept;
//! * [`AppMixer`] releases everything on drop, [`run_loop`] on stop.
//!
//! Not verified on hardware (S4 never ran live): that a private tap dies with
//! its process (SIGKILL), and the latency and channel layouts the IOProc meets.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering::Relaxed};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};
use symcockpit_contract::Error;

use super::hal::{AudioHal, HalError, Scope};

// ------------------------------------------------------------ signal path

/// Shared between the control side and the IOProc. All atomic: the IOProc
/// never locks.
pub struct Shared {
    volume: AtomicU32,
    muted: AtomicBool,
    callbacks: AtomicU64,
    bad_layout: AtomicU64,
}

impl Shared {
    pub fn new(volume: f32, muted: bool) -> Self {
        let s = Shared {
            volume: AtomicU32::new(0),
            muted: AtomicBool::new(muted),
            callbacks: AtomicU64::new(0),
            bad_layout: AtomicU64::new(0),
        };
        s.set_volume(volume);
        s
    }

    /// NaN becomes 0 (silence is the safe reading of garbage), the rest is clamped to 0..=1.
    pub fn set_volume(&self, v: f32) {
        let v = if v.is_nan() { 0.0 } else { v.clamp(0.0, 1.0) };
        self.volume.store(v.to_bits(), Relaxed);
    }

    pub fn set_muted(&self, muted: bool) {
        self.muted.store(muted, Relaxed);
    }

    /// The factor the IOProc applies.
    pub fn gain(&self) -> f32 {
        if self.muted.load(Relaxed) {
            0.0
        } else {
            f32::from_bits(self.volume.load(Relaxed))
        }
    }

    pub fn record_callback(&self, layout_ok: bool) {
        self.callbacks.fetch_add(1, Relaxed);
        if !layout_ok {
            self.bad_layout.fetch_add(1, Relaxed);
        }
    }

    /// (callbacks, callbacks that met a layout the IOProc cannot map)
    pub fn counters(&self) -> (u64, u64) {
        (self.callbacks.load(Relaxed), self.bad_layout.load(Relaxed))
    }
}

/// Scale interleaved f32 frames from `in_ch` to `out_ch` channels. Same count:
/// 1:1; to mono: mean; from mono: duplicate; otherwise shared channels are
/// copied and the rest is silence. Output frames without input are zeroed,
/// non-finite input becomes 0, the result is clamped to ±1.
pub fn scale_interleaved(
    input: &[f32],
    in_ch: usize,
    output: &mut [f32],
    out_ch: usize,
    gain: f32,
) {
    output.fill(0.0);
    if in_ch == 0 || out_ch == 0 {
        return;
    }
    let frames = (input.len() / in_ch).min(output.len() / out_ch);
    let clean = |s: f32| if s.is_finite() { s } else { 0.0 };
    for f in 0..frames {
        let i = &input[f * in_ch..(f + 1) * in_ch];
        let o = &mut output[f * out_ch..(f + 1) * out_ch];
        if out_ch == 1 {
            o[0] = i.iter().map(|s| clean(*s)).sum::<f32>() / in_ch as f32;
        } else if in_ch == 1 {
            o.fill(clean(i[0]));
        } else {
            for (d, s) in o.iter_mut().zip(i) {
                *d = clean(*s);
            }
        }
        for d in o.iter_mut() {
            *d = (*d * gain).clamp(-1.0, 1.0);
        }
    }
}

// ----------------------------------------------------------------- the port

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Tap {
    pub id: u32,
    pub uid: String,
}

/// An audio-producing process as the HAL lists it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AudioProcess {
    pub object: u32,
    pub pid: i32,
    pub bundle_id: Option<String>,
    pub running_output: bool,
}

/// Opaque handle to a created IOProc (the live adapter owns what it points to).
pub type IoHandle = usize;

pub trait TapHal: Send + Sync {
    /// Process taps need macOS 14.2 or later.
    fn supported(&self) -> bool;
    fn processes(&self) -> Result<Vec<AudioProcess>, HalError>;
    fn create_tap(&self, process_object: u32) -> Result<Tap, HalError>;
    fn create_aggregate(&self, output_uid: &str, tap_uid: &str) -> Result<u32, HalError>;
    fn create_ioproc(&self, aggregate: u32, shared: Arc<Shared>) -> Result<IoHandle, HalError>;
    fn start(&self, aggregate: u32, io: IoHandle) -> Result<(), HalError>;
    fn stop(&self, aggregate: u32, io: IoHandle) -> Result<(), HalError>;
    fn destroy_ioproc(&self, aggregate: u32, io: IoHandle) -> Result<(), HalError>;
    fn destroy_aggregate(&self, aggregate: u32) -> Result<(), HalError>;
    fn destroy_tap(&self, tap: u32) -> Result<(), HalError>;
}

// -------------------------------------------------------- one app's pipeline

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum State {
    Idle,
    Active { device_uid: String },
    Failed,
    Stopped,
}

/// The tap/aggregate/IOProc pipeline of one app.
pub struct Mixer {
    hal: Arc<dyn TapHal>,
    shared: Arc<Shared>,
    state: State,
    tap: Option<Tap>,
    aggregate: Option<u32>,
    io: Option<IoHandle>,
    started: bool,
}

impl Mixer {
    pub fn new(hal: Arc<dyn TapHal>, shared: Arc<Shared>) -> Self {
        Mixer {
            hal,
            shared,
            state: State::Idle,
            tap: None,
            aggregate: None,
            io: None,
            started: false,
        }
    }

    pub fn state(&self) -> &State {
        &self.state
    }

    pub fn tap_id(&self) -> Option<u32> {
        self.tap.as_ref().map(|t| t.id)
    }

    pub fn aggregate_id(&self) -> Option<u32> {
        self.aggregate
    }

    pub fn start(&mut self, process_object: u32, out_uid: &str) -> Result<(), String> {
        if self.state != State::Idle {
            return Err("start is only valid in state Idle".into());
        }
        match self.hal.create_tap(process_object) {
            Ok(t) => self.tap = Some(t),
            Err(e) => {
                self.state = State::Failed;
                return Err(e.to_string());
            }
        }
        self.build(out_uid)
    }

    /// The default output changed: rebuild the aggregate, keep the tap.
    /// Any failure releases the app (tap destroyed).
    pub fn on_default_output_changed(&mut self, new_uid: &str) -> Result<bool, String> {
        match &self.state {
            State::Active { device_uid } if device_uid == new_uid => return Ok(false),
            State::Active { .. } => {}
            _ => return Ok(false),
        }
        let mut errs = Vec::new();
        self.teardown_aggregate(&mut errs);
        if !errs.is_empty() {
            // A leftover would be overwritten by the rebuild and leak: tear down everything.
            self.teardown_all(&mut errs);
            self.state = State::Failed;
            return Err(format!("teardown before rebuild: {}", errs.join("; ")));
        }
        self.build(new_uid)?;
        Ok(true)
    }

    /// On error everything is destroyed, the tap last, so the original sound returns.
    fn build(&mut self, out_uid: &str) -> Result<(), String> {
        match self.build_inner(out_uid) {
            Ok(()) => {
                self.state = State::Active {
                    device_uid: out_uid.to_owned(),
                };
                Ok(())
            }
            Err(e) => {
                let mut errs = Vec::new();
                self.teardown_all(&mut errs);
                self.state = State::Failed;
                Err(if errs.is_empty() {
                    e
                } else {
                    format!("{e}; cleanup: {}", errs.join("; "))
                })
            }
        }
    }

    fn build_inner(&mut self, out_uid: &str) -> Result<(), String> {
        let tap_uid = self.tap.as_ref().ok_or("no tap")?.uid.clone();
        let agg = self
            .hal
            .create_aggregate(out_uid, &tap_uid)
            .map_err(|e| e.to_string())?;
        self.aggregate = Some(agg);
        let io = self
            .hal
            .create_ioproc(agg, self.shared.clone())
            .map_err(|e| e.to_string())?;
        self.io = Some(io);
        self.hal.start(agg, io).map_err(|e| e.to_string())?;
        self.started = true;
        Ok(())
    }

    /// Stop, IOProc, aggregate. An error does not end the sequence; a resource
    /// whose teardown failed stays registered so a later `stop` retries it.
    fn teardown_aggregate(&mut self, errs: &mut Vec<String>) {
        if let (true, Some(a), Some(io)) = (self.started, self.aggregate, self.io) {
            match self.hal.stop(a, io) {
                Ok(()) => self.started = false,
                Err(e) => errs.push(format!("stop: {e}")),
            }
        }
        if let (Some(a), Some(io)) = (self.aggregate, self.io) {
            match self.hal.destroy_ioproc(a, io) {
                Ok(()) => self.io = None,
                Err(e) => errs.push(format!("destroy_ioproc: {e}")),
            }
        }
        if let Some(a) = self.aggregate {
            match self.hal.destroy_aggregate(a) {
                Ok(()) => self.aggregate = None,
                Err(e) => errs.push(format!("destroy_aggregate: {e}")),
            }
        }
    }

    fn teardown_all(&mut self, errs: &mut Vec<String>) {
        self.teardown_aggregate(errs);
        if let Some(t) = &self.tap {
            match self.hal.destroy_tap(t.id) {
                Ok(()) => self.tap = None,
                Err(e) => errs.push(format!("destroy_tap: {e}")),
            }
        }
    }

    /// Repeatable. Returns the teardown errors (empty: everything is gone).
    pub fn stop(&mut self) -> Vec<String> {
        let mut errs = Vec::new();
        self.teardown_all(&mut errs);
        if self.state != State::Failed {
            self.state = State::Stopped;
        }
        errs
    }
}

impl Drop for Mixer {
    fn drop(&mut self) {
        self.stop();
    }
}

// ------------------------------------------------------------ all apps

/// What the user asked for one app, independent of whether a tap runs.
#[derive(Clone, Debug, PartialEq)]
pub struct AppSetting {
    pub volume: f32,
    pub muted: bool,
}

impl AppSetting {
    /// Nothing to change: the app plays untouched, no tap needed.
    pub fn is_identity(&self) -> bool {
        !self.muted && self.volume >= 1.0
    }
}

struct Entry {
    setting: AppSetting,
    shared: Arc<Shared>,
    mixer: Option<Mixer>,
    last_error: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct AppStatus {
    pub pid: i32,
    pub volume: f32,
    pub muted: bool,
    /// `active`, `pending` (no audio object yet or no output), `passthrough`
    /// (identity setting, no tap) or `failed`.
    pub state: &'static str,
    pub detail: Option<String>,
}

impl AppStatus {
    pub fn to_json(&self) -> Value {
        let mut v = json!({"pid": self.pid, "volume": self.volume, "muted": self.muted, "state": self.state});
        if let Some(d) = &self.detail {
            v["detail"] = json!(d);
        }
        v
    }
}

/// Wanted settings for any number of apps, reconciled against what is running.
pub struct AppMixer {
    hal: Arc<dyn TapHal>,
    apps: BTreeMap<i32, Entry>,
    output_uid: Option<String>,
}

impl AppMixer {
    pub fn new(hal: Arc<dyn TapHal>) -> Self {
        AppMixer {
            hal,
            apps: BTreeMap::new(),
            output_uid: None,
        }
    }

    /// Record the wanted setting and reconcile. A running app changes its
    /// gain without a rebuild.
    pub fn set_app(&mut self, pid: i32, setting: AppSetting) -> Result<AppStatus, Error> {
        if !setting.volume.is_finite() || !(0.0..=1.0).contains(&setting.volume) {
            return Err(Error::Usage("volume must be between 0 and 1".into()));
        }
        if !self.hal.supported() {
            return Err(Error::Unsupported(
                "per-app volume needs process taps (macOS 14.2 or later)".into(),
            ));
        }
        let entry = self.apps.entry(pid).or_insert_with(|| Entry {
            setting: setting.clone(),
            shared: Arc::new(Shared::new(setting.volume, setting.muted)),
            mixer: None,
            last_error: None,
        });
        entry.setting = setting.clone();
        entry.shared.set_volume(setting.volume);
        entry.shared.set_muted(setting.muted);
        entry.last_error = None; // an explicit request retries a failed app
        let processes = self.hal.processes()?;
        self.reconcile_with(&processes);
        Ok(self.status_of(pid).expect("entry was just inserted"))
    }

    /// Stop touching an app: its original sound returns.
    pub fn release_app(&mut self, pid: i32) -> Vec<String> {
        match self.apps.remove(&pid) {
            Some(mut e) => e.mixer.as_mut().map_or_else(Vec::new, Mixer::stop),
            None => Vec::new(),
        }
    }

    /// Tell the mixer which output is the system default now. `None` means
    /// there is none (device unplugged, no default): every tap is destroyed so
    /// no app stays silent; the wanted settings are kept and re-applied when an
    /// output exists again.
    pub fn on_default_output(&mut self, uid: Option<&str>) -> Vec<String> {
        let mut errors = Vec::new();
        self.output_uid = uid.map(str::to_owned);
        match uid {
            None => {
                for e in self.apps.values_mut() {
                    if let Some(m) = &mut e.mixer {
                        let errs = m.stop();
                        if errs.is_empty() {
                            e.mixer = None;
                        }
                        // else it stays; `reconcile` retries the teardown
                        errors.extend(errs);
                    }
                }
            }
            Some(uid) => {
                for (pid, e) in &mut self.apps {
                    let Some(m) = e.mixer.as_mut() else { continue };
                    if let Err(err) = m.on_default_output_changed(uid) {
                        // The rebuild failed: the pipeline destroyed its tap, app is audible.
                        errors.push(format!("pid {pid}: {err}"));
                        e.last_error = Some(err);
                        // The failed pipeline stays until `reconcile` has proven it empty.
                    }
                }
                if let Ok(p) = self.hal.processes() {
                    self.reconcile_with(&p);
                }
            }
        }
        errors
    }

    /// Attach pending apps whose process now has an audio object, drop apps whose
    /// process is gone, release apps whose setting became the identity.
    pub fn reconcile(&mut self) -> Result<(), Error> {
        let processes = self.hal.processes()?;
        self.reconcile_with(&processes);
        Ok(())
    }

    fn reconcile_with(&mut self, processes: &[AudioProcess]) {
        let out = self.output_uid.clone();
        let hal = self.hal.clone();
        let gone: Vec<i32> = self
            .apps
            .iter()
            .filter(|(pid, e)| e.mixer.is_some() && !processes.iter().any(|p| p.pid == **pid))
            .map(|(p, _)| *p)
            .collect();
        for pid in gone {
            self.release_app(pid);
        }
        for (pid, e) in &mut self.apps {
            if let Some(m) = &mut e.mixer
                && matches!(m.state(), State::Failed | State::Stopped)
                && m.stop().is_empty()
            {
                e.mixer = None; // fully torn down; keep `last_error` so it is not restarted blindly
            }
            if e.setting.is_identity() {
                if let Some(m) = &mut e.mixer {
                    m.stop();
                }
                e.mixer = None;
                continue;
            }
            if e.mixer.is_some() || e.last_error.is_some() {
                continue;
            }
            let (Some(out), Some(p)) = (out.as_deref(), processes.iter().find(|p| p.pid == *pid))
            else {
                continue; // pending
            };
            let mut m = Mixer::new(hal.clone(), e.shared.clone());
            match m.start(p.object, out) {
                Ok(()) => e.mixer = Some(m),
                Err(err) => e.last_error = Some(err),
            }
        }
    }

    fn status_of(&self, pid: i32) -> Option<AppStatus> {
        let e = self.apps.get(&pid)?;
        let (state, detail) = match (&e.mixer, &e.last_error) {
            (Some(m), _) if matches!(m.state(), State::Failed | State::Stopped) => {
                ("failed", e.last_error.clone())
            }
            (Some(_), _) => ("active", None),
            (None, Some(err)) => ("failed", Some(err.clone())),
            (None, None) if e.setting.is_identity() => ("passthrough", None),
            (None, None) => ("pending", None),
        };
        Some(AppStatus {
            pid,
            volume: e.setting.volume,
            muted: e.setting.muted,
            state,
            detail,
        })
    }

    pub fn status(&self) -> Vec<AppStatus> {
        self.apps
            .keys()
            .filter_map(|p| self.status_of(*p))
            .collect()
    }

    /// Destroy every tap. Returns the errors of teardown steps that failed.
    pub fn release_all(&mut self) -> Vec<String> {
        let pids: Vec<i32> = self.apps.keys().copied().collect();
        pids.into_iter().flat_map(|p| self.release_app(p)).collect()
    }
}

impl Drop for AppMixer {
    fn drop(&mut self) {
        self.release_all();
    }
}

/// How the library API for the app agent (and the MCP tool
/// `set_audio_app_volume`) reaches a running mixer.
pub trait MixerControl: Send + Sync {
    fn set_app_volume(&self, pid: i32, volume: f32, muted: bool) -> Result<AppStatus, Error>;
    fn status(&self) -> Vec<AppStatus>;
}

impl MixerControl for Mutex<AppMixer> {
    fn set_app_volume(&self, pid: i32, volume: f32, muted: bool) -> Result<AppStatus, Error> {
        let mut m = self.lock().unwrap_or_else(|e| e.into_inner());
        m.set_app(pid, AppSetting { volume, muted })
    }

    fn status(&self) -> Vec<AppStatus> {
        self.lock().unwrap_or_else(|e| e.into_inner()).status()
    }
}

// --------------------------------------------------------------- run loop

const TICK: Duration = Duration::from_millis(50);
/// Device changes arrive in bursts (default input and output, then streams);
/// wait this many quiet ticks before rebuilding.
const SETTLE_TICKS: u32 = 6;
const RECONCILE_TICKS: u32 = 20;

#[derive(Debug, Default, Eq, PartialEq)]
pub struct LoopSummary {
    pub output_changes: u32,
    pub teardown_errors: Vec<String>,
    pub events: Vec<String>,
}

/// Drive the mixer until `stop` returns true: follow default-output changes,
/// attach pending apps, then release every app. The release also runs when
/// the output cannot be read (fail open).
pub fn run_loop(
    mixer: &Mutex<AppMixer>,
    audio: &dyn AudioHal,
    stop: &dyn Fn() -> bool,
    sleep: &dyn Fn(Duration),
) -> LoopSummary {
    let mut summary = LoopSummary::default();
    let lock = || mixer.lock().unwrap_or_else(|e| e.into_inner());
    let current_output = || -> Option<String> {
        audio
            .default_device(Scope::Output)
            .ok()
            .flatten()
            .and_then(|o| audio.device_uid(o).ok())
    };
    lock().on_default_output(current_output().as_deref());
    let mut seen = audio.change_epoch();
    let mut settle: Option<u32> = None;
    let mut ticks = 0u32;
    while !stop() {
        sleep(TICK);
        ticks += 1;
        let epoch = audio.change_epoch();
        if epoch != seen {
            seen = epoch;
            settle = Some(0);
        }
        if let Some(n) = settle {
            if n >= SETTLE_TICKS {
                settle = None;
                let out = current_output();
                let errs = lock().on_default_output(out.as_deref());
                summary.output_changes += 1;
                summary.events.push(match &out {
                    Some(_) => "default output changed; mixer followed".to_owned(),
                    None => "no default output; all apps released".to_owned(),
                });
                summary.teardown_errors.extend(errs);
            } else {
                settle = Some(n + 1);
            }
        }
        if ticks.is_multiple_of(RECONCILE_TICKS) {
            let _ = lock().reconcile();
        }
    }
    summary.teardown_errors.extend(lock().release_all());
    summary
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(input: &[f32], in_ch: usize, out_len: usize, out_ch: usize, gain: f32) -> Vec<f32> {
        let mut out = vec![9.0; out_len];
        scale_interleaved(input, in_ch, &mut out, out_ch, gain);
        out
    }

    #[test]
    fn stereo_gain_identity_and_silence() {
        assert_eq!(
            run(&[0.8, -0.4, 0.2, 0.0], 2, 4, 2, 0.5),
            [0.4, -0.2, 0.1, 0.0]
        );
        let i = [0.3, -0.7, 0.1, 0.9];
        assert_eq!(run(&i, 2, 4, 2, 1.0), i);
        assert_eq!(run(&i, 2, 4, 2, 0.0), [0.0; 4]);
    }

    #[test]
    fn output_is_clamped_and_non_finite_input_is_silence() {
        assert_eq!(run(&[1.0, -1.0], 2, 2, 2, 2.0), [1.0, -1.0]);
        assert_eq!(run(&[f32::NAN, f32::INFINITY], 2, 2, 2, 1.0), [0.0, 0.0]);
    }

    #[test]
    fn channel_mapping() {
        assert!((run(&[0.4, 0.2], 2, 1, 1, 0.5)[0] - 0.15).abs() < 1e-6);
        assert_eq!(run(&[0.5, -0.5], 1, 4, 2, 1.0), [0.5, 0.5, -0.5, -0.5]);
        assert_eq!(
            run(&[0.5, 0.25], 2, 6, 6, 1.0),
            [0.5, 0.25, 0.0, 0.0, 0.0, 0.0]
        );
        assert_eq!(
            run(&[0.5, 0.5], 2, 6, 2, 1.0),
            [0.5, 0.5, 0.0, 0.0, 0.0, 0.0]
        );
        assert_eq!(run(&[0.1], 0, 2, 2, 1.0), [0.0, 0.0]);
        assert_eq!(run(&[0.1], 1, 2, 0, 1.0), [0.0, 0.0]);
    }

    #[test]
    fn gain_is_sanitised_and_mute_wins() {
        let s = Shared::new(0.5, false);
        s.set_volume(2.0);
        assert_eq!(s.gain(), 1.0);
        s.set_volume(-1.0);
        assert_eq!(s.gain(), 0.0);
        s.set_volume(f32::NAN);
        assert_eq!(s.gain(), 0.0);
        s.set_volume(0.7);
        s.set_muted(true);
        assert_eq!(s.gain(), 0.0);
        s.set_muted(false);
        assert_eq!(s.gain(), 0.7);
    }

    #[test]
    fn identity_setting_needs_no_tap() {
        assert!(
            AppSetting {
                volume: 1.0,
                muted: false
            }
            .is_identity()
        );
        assert!(
            !AppSetting {
                volume: 1.0,
                muted: true
            }
            .is_identity()
        );
        assert!(
            !AppSetting {
                volume: 0.9,
                muted: false
            }
            .is_identity()
        );
    }
}
