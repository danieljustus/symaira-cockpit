//! The long-lived services only the app agent can hold (wave 2D-S): clipboard capture and the
//! human's access to it, the per-app mixer, Finder jobs, the Finder-cut event tap with click
//! feedback, and the BLE session. One-shot commands (`symcockpit …`) and `serve` never build a
//! [`Host`]: without one, `audio mixer set`, `ble connect` and friends answer `unsupported`, and
//! the clipboard history has no door at all.
//!
//! Lifecycle: the agent builds the host after the parent check and ends it on EOF, SIGTERM or a
//! closed stdout, in that order releasing every app's audio tap, closing BLE connections,
//! removing the event tap and joining the threads. Nothing runs for a feature the user has not
//! switched on (Q04): the clipboard thread does not exist while capture is off or paused, the
//! tap does not exist without the setting and the permission, the mixer follower runs only with
//! an app to follow, and BLE and Finder jobs do nothing without a request or a job.
//!
//! Threads (architecture §10): the dispatch thread is the agent's main thread and keeps the
//! run loop for the tap; each of clipboard, BLE, Finder jobs and click feedback is an
//! [`actor`] thread that owns its non-`Send` objects; the mixer has its follower thread.
//! Platform access comes in through [`Platform`] only, so tests run on fakes.

pub mod actor;
pub mod ble;
pub mod clipboard;
pub mod input;
pub mod jobs;
pub mod live;
pub mod mixer;

use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};
use symcockpit_contract::Error;
use symcockpit_core::audio::mixer::MixerControl;
use symcockpit_core::clipboard::SettingsStore as _;
use symcockpit_core::input::{InputProbe, TapHost};
use symcockpit_db::clipboard::{JsonSettings, dir_in};

use ble::BleHandle;
use clipboard::{ClipboardHandle, Req as ClipReq};
use input::InputService;
use jobs::JobsHandle;
use mixer::HostedMixer;

/// Everything platform-specific the services need. Production: [`live::platform`].
pub struct Platform {
    pub clipboard: clipboard::MakeParts,
    pub mixer: mixer::MakeMixer,
    pub finder: jobs::MakePlatform,
    pub central: ble::MakeCentral,
    pub tap: Box<dyn TapHost>,
    pub probe: Box<dyn InputProbe>,
    pub input_settings: input::MakeSettings,
    pub feedback: input::MakeFeedback,
    /// The main run loop; `None` where there is none to spin (tests).
    pub run_loop: Option<Arc<dyn RunLoop>>,
}

/// The agent's main run loop, spun while a tap is installed.
pub trait RunLoop: Send + Sync {
    /// Makes a running or future `run_for` return; callable from any thread.
    fn wake(&self);
    /// Spins the run loop (tap callbacks included) until woken or `limit`.
    fn run_for(&self, limit: Duration);
}

pub struct HostConfig {
    /// Where the clipboard directory lives (`--data-dir` or the XDG data directory).
    pub data_dir: PathBuf,
    /// The Finder jobs directory in the app group container; `None` without the app.
    pub finder_jobs_dir: Option<PathBuf>,
    pub intervals: Intervals,
}

#[derive(Clone, Copy)]
pub struct Intervals {
    pub clipboard: Duration,
    pub jobs: Duration,
    pub ble: Duration,
    /// How often settings changed behind the agent's back (the CLI writes the same files) are
    /// noticed. Reading two small files; not a measurement.
    pub reconcile: Duration,
}

impl Default for Intervals {
    fn default() -> Self {
        Self {
            clipboard: clipboard::POLL,
            jobs: jobs::POLL,
            ble: ble::POLL,
            reconcile: Duration::from_secs(5),
        }
    }
}

/// What the register handlers reach for in the agent's process. Built once by the [`Host`].
pub struct Shared {
    pub mixer: Arc<HostedMixer>,
    pub ble: Arc<BleHandle>,
}

thread_local! {
    /// Set on the agent's dispatch thread for the life of the host. Handlers run on that
    /// thread, so a handler sees the host exactly when it runs inside the agent.
    static CURRENT: RefCell<Option<Rc<Shared>>> = const { RefCell::new(None) };
}

/// The live mixer, when running inside the agent.
pub fn mixer() -> Option<Arc<dyn MixerControl>> {
    CURRENT.with(|c| {
        c.borrow()
            .as_ref()
            .map(|s| Arc::clone(&s.mixer) as Arc<dyn MixerControl>)
    })
}

/// The live BLE session, when running inside the agent.
pub fn ble() -> Option<Arc<BleHandle>> {
    CURRENT.with(|c| c.borrow().as_ref().map(|s| Arc::clone(&s.ble)))
}

/// Keeps the host visible to the handlers of this thread; dropping it removes it again.
pub struct Installed(());

impl Drop for Installed {
    fn drop(&mut self) {
        CURRENT.with(|c| *c.borrow_mut() = None);
    }
}

/// What the agent's session and loop need from a host.
pub trait AgentHost {
    /// An agent method of `HOST_METHODS`.
    fn call(&self, method: &str, params: &Map<String, Value>) -> Result<Value, Error>;
    /// A register command ran: settings it may have changed take effect now.
    fn after_call(&self, command: &str);
    /// Until the host wants `tick`; `None`: not before the next request.
    fn due_in(&self) -> Option<Duration>;
    fn tick(&self);
    /// A tap is installed: the main thread must spin its run loop instead of blocking.
    fn spinning(&self) -> bool;
    fn spin(&self, limit: Duration);
}

pub struct Host {
    cfg: HostConfig,
    platform: PlatformParts,
    shared: Rc<Shared>,
    clipboard: RefCell<Option<Arc<ClipboardHandle>>>,
    clip_settings: JsonSettings,
    jobs: Option<JobsHandle>,
    input: RefCell<InputService>,
    last_reconcile: Cell<Instant>,
    ended: Cell<bool>,
}

/// The parts of [`Platform`] the host keeps after building the services.
struct PlatformParts {
    clipboard: clipboard::MakeParts,
    run_loop: Option<Arc<dyn RunLoop>>,
}

impl Host {
    /// Starts what must run from the first moment (Finder jobs, when the app gave a
    /// directory); everything else starts when the user's settings or a request ask for it.
    pub fn start(platform: Platform, cfg: HostConfig) -> Self {
        let Platform {
            clipboard,
            mixer,
            finder,
            central,
            tap,
            probe,
            input_settings,
            feedback,
            run_loop,
        } = platform;
        let jobs = cfg
            .finder_jobs_dir
            .clone()
            .map(|dir| JobsHandle::spawn(dir, finder, cfg.intervals.jobs));
        let shared = Rc::new(Shared {
            mixer: Arc::new(HostedMixer::new(mixer)),
            ble: Arc::new(BleHandle::spawn(central, cfg.intervals.ble)),
        });
        let host = Self {
            clip_settings: JsonSettings::new(&dir_in(&cfg.data_dir)),
            platform: PlatformParts {
                clipboard,
                run_loop,
            },
            input: RefCell::new(InputService::new(tap, probe, input_settings, feedback)),
            shared,
            clipboard: RefCell::new(None),
            jobs,
            cfg,
            last_reconcile: Cell::new(Instant::now()),
            ended: Cell::new(false),
        };
        host.reconcile();
        host
    }

    /// Makes the mixer and the BLE session visible to the handlers of this thread.
    pub fn install(&self) -> Installed {
        CURRENT.with(|c| *c.borrow_mut() = Some(Rc::clone(&self.shared)));
        Installed(())
    }

    /// The handle that wakes the main run loop after another thread queued input.
    pub fn waker(&self) -> Option<Arc<dyn RunLoop>> {
        self.platform.run_loop.clone()
    }

    fn clipboard_handle(&self) -> Arc<ClipboardHandle> {
        Arc::clone(self.clipboard.borrow_mut().get_or_insert_with(|| {
            Arc::new(ClipboardHandle::spawn(
                dir_in(&self.cfg.data_dir),
                Arc::clone(&self.platform.clipboard),
                self.cfg.intervals.clipboard,
            ))
        }))
    }

    /// Brings every service in line with the settings on disk: starts what the user switched
    /// on, stops what they switched off. Cheap; runs at start, after a command that can change
    /// settings, and every few seconds for changes made by the CLI.
    pub fn reconcile(&self) {
        self.last_reconcile.set(Instant::now());
        let capturing = self.clip_settings.load().is_ok_and(|s| s.capturing());
        let existing = self.clipboard.borrow().clone();
        match (capturing, existing) {
            (true, _) => {
                let _ = self.clipboard_handle().call(ClipReq::Reconcile);
            }
            // Off or paused: an existing thread drops its poller and sleeps.
            (false, Some(handle)) => {
                let _ = handle.call(ClipReq::Reconcile);
            }
            (false, None) => {}
        }
        self.input.borrow_mut().reconcile();
        self.shared.mixer.idle_check();
    }

    fn services(&self) -> Value {
        let clipboard = match self.clipboard.borrow().as_ref() {
            Some(handle) => handle
                .call(ClipReq::Status)
                .unwrap_or_else(|e| json!({"state": "failed", "last_error": e.to_string()})),
            None => {
                let s = self.clip_settings.load().unwrap_or_default();
                json!({"state": "off", "enabled": s.enabled, "paused": s.paused})
            }
        };
        let ble = self
            .shared
            .ble
            .run("ble.session", &Map::new())
            .unwrap_or_else(|e| json!({"error": e.to_string()}));
        json!({
            "clipboard": clipboard,
            "mixer": self.shared.mixer.status_json(),
            "finder_jobs": self.jobs.as_ref().map_or(json!({"state": "off"}), JobsHandle::status),
            "input_tap": self.input.borrow().status_json(),
            "ble": ble,
        })
    }

    /// Releases everything, in the order that keeps nothing silent or captured: apps first, then
    /// the tap, BLE, jobs and clipboard. Repeatable; also what dropping the host does.
    pub fn end(&self) {
        if self.ended.replace(true) {
            return;
        }
        self.shared.mixer.end();
        self.input.borrow_mut().end();
        self.shared.ble.stop();
        if let Some(jobs) = &self.jobs {
            jobs.stop();
        }
        if let Some(clipboard) = self.clipboard.borrow().as_ref() {
            clipboard.stop();
        }
    }

    fn clipboard_call(&self, method: &str, params: &Map<String, Value>) -> Result<Value, Error> {
        let id = || -> Result<String, Error> {
            params
                .get("id")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .ok_or_else(|| Error::Usage("missing argument 'id'".into()))
        };
        let req = match method {
            "clipboard.list" => ClipReq::List {
                limit: params
                    .get("limit")
                    .and_then(Value::as_u64)
                    .map_or(100, |n| n as usize),
            },
            "clipboard.read" => ClipReq::Read { id: id()? },
            "clipboard.copy" => ClipReq::Copy { id: id()? },
            "clipboard.delete" => ClipReq::Delete { id: id()? },
            "clipboard.settings" => ClipReq::Settings,
            _ => ClipReq::Configure(params.clone()),
        };
        let configure = matches!(req, ClipReq::Configure(_));
        let result = self.clipboard_handle().call(req);
        if configure {
            self.input.borrow_mut().reconcile();
        }
        result
    }
}

impl AgentHost for Host {
    fn call(&self, method: &str, params: &Map<String, Value>) -> Result<Value, Error> {
        match method {
            "services" => Ok(self.services()),
            m if m.starts_with("clipboard.") => self.clipboard_call(m, params),
            other => Err(Error::Failed(format!("{other}: no handler"))),
        }
    }

    fn after_call(&self, command: &str) {
        if command.starts_with("clipboard.") || command.starts_with("input.") {
            self.reconcile();
        }
    }

    fn due_in(&self) -> Option<Duration> {
        Some(
            self.cfg
                .intervals
                .reconcile
                .saturating_sub(self.last_reconcile.get().elapsed()),
        )
    }

    fn tick(&self) {
        if self.last_reconcile.get().elapsed() >= self.cfg.intervals.reconcile {
            self.reconcile();
        }
    }

    fn spinning(&self) -> bool {
        self.platform.run_loop.is_some() && self.input.borrow().spinning()
    }

    fn spin(&self, limit: Duration) {
        if let Some(run_loop) = &self.platform.run_loop {
            run_loop.run_for(limit);
        }
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        self.end();
    }
}
