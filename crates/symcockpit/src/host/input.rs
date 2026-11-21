//! Finder ⌘X / ⌘V and the click feedback (R60, R61), hosted by the agent.
//!
//! The CGEvent tap lives on the agent's main thread, whose run loop the agent spins while a tap
//! is installed (`agent::main`). The decision (Finder in front, no secure input, ⌘ only, every
//! other app untouched, a disabled tap switched back on) is `core::input::FinderCut`; this file
//! only decides *whether a tap exists*: when the user switched it on in the settings **and** the
//! Accessibility permission is there. Without the permission nothing is created and the state
//! says so (`permission`); no dialog is triggered, because the probe is the non-prompting one.
//! Switching it off, or the agent ending, drops the tap.
//!
//! After a replaced key the tap calls a hook; the hook posts a click to a small thread that plays
//! haptics and the material sound through the existing backends, honouring their own switches.
//! The tap's callback never waits for it.

use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};
use symcockpit_contract::Error;
use symcockpit_core::input::{
    Access, ActionHook, HapticBackend, InputProbe, RunningTap, SettingsStore, SoundBackend,
    TapHost, trigger,
};

use super::actor::{Actor, Service};

pub type MakeSettings = Arc<dyn Fn() -> Box<dyn SettingsStore> + Send + Sync>;

pub struct Feedback {
    pub haptic: Box<dyn HapticBackend>,
    pub sound: Box<dyn SoundBackend>,
}

pub type MakeFeedback = Arc<dyn Fn() -> Result<Feedback, Error> + Send + Sync>;

struct Click;

struct FeedbackService {
    backends: Result<Feedback, Error>,
    settings: Box<dyn SettingsStore>,
}

impl Service for FeedbackService {
    type Req = Click;
    type Resp = ();

    fn handle(&mut self, Click: Click) {
        let (Ok(backends), Ok(settings)) = (&self.backends, self.settings.load()) else {
            return;
        };
        // A failing channel is reported by `input haptics test`; here it must not matter.
        let _ = trigger(&settings, false, &*backends.haptic, &*backends.sound);
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TapState {
    Off,
    Running,
    /// The Accessibility permission is missing; the text says where to grant it.
    Permission(String),
    Unsupported(String),
    Failed(String),
}

pub struct InputService {
    tap: Box<dyn TapHost>,
    probe: Box<dyn InputProbe>,
    settings: MakeSettings,
    feedback_make: MakeFeedback,
    running: Option<Box<dyn RunningTap>>,
    feedback: Option<Arc<Actor<FeedbackService>>>,
    state: TapState,
}

impl InputService {
    pub fn new(
        tap: Box<dyn TapHost>,
        probe: Box<dyn InputProbe>,
        settings: MakeSettings,
        feedback: MakeFeedback,
    ) -> Self {
        Self {
            tap,
            probe,
            settings,
            feedback_make: feedback,
            running: None,
            feedback: None,
            state: TapState::Off,
        }
    }

    pub fn state(&self) -> &TapState {
        &self.state
    }

    /// True while a tap is installed: the main thread must then spin its run loop.
    pub fn spinning(&self) -> bool {
        self.running.is_some()
    }

    fn hook(&mut self) -> ActionHook {
        let (make_settings, make_feedback) =
            (Arc::clone(&self.settings), Arc::clone(&self.feedback_make));
        let feedback = Arc::clone(self.feedback.get_or_insert_with(|| {
            Arc::new(Actor::spawn("symcockpit-click-feedback", move || {
                FeedbackService {
                    backends: make_feedback(),
                    settings: make_settings(),
                }
            }))
        }));
        Arc::new(move |_action| feedback.post(Click))
    }

    /// Brings the tap in line with the setting and the permission. Cheap; safe to call often.
    pub fn reconcile(&mut self) {
        let wanted = (self.settings)()
            .load()
            .map(|s| s.finder_cut)
            .unwrap_or(false);
        if !wanted {
            // Dropping the handle disables the tap and removes it from the run loop.
            self.running = None;
            self.state = TapState::Off;
            return;
        }
        if self.running.is_some() {
            return;
        }
        if self.probe.event_tap_access() == Access::Denied {
            self.state = TapState::Permission(
                "Accessibility access is not granted (System Settings > Privacy & Security)".into(),
            );
            return;
        }
        let hook = self.hook();
        match self.tap.start(hook) {
            Ok(tap) => {
                self.running = Some(tap);
                self.state = TapState::Running;
            }
            Err(Error::Permission(m)) => self.state = TapState::Permission(m),
            Err(Error::Unsupported(m) | Error::NotImplemented(m)) => {
                self.state = TapState::Unsupported(m);
            }
            Err(e) => self.state = TapState::Failed(e.to_string()),
        }
    }

    /// Removes the tap and ends the feedback thread.
    pub fn end(&mut self) {
        self.running = None;
        self.state = TapState::Off;
        if let Some(feedback) = self.feedback.take() {
            feedback.stop();
        }
    }

    pub fn status_json(&self) -> Value {
        let (state, detail) = match &self.state {
            TapState::Off => ("off", None),
            TapState::Running => ("running", None),
            TapState::Permission(m) => ("permission", Some(m)),
            TapState::Unsupported(m) => ("unsupported", Some(m)),
            TapState::Failed(m) => ("failed", Some(m)),
        };
        json!({"finder_cut": state, "detail": detail})
    }
}

impl Drop for InputService {
    fn drop(&mut self) {
        self.end();
    }
}

/// How long the agent's run-loop spin may last before it looks at its channel again.
pub const SPIN_SLICE: Duration = Duration::from_millis(500);

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::rc::Rc;
    use std::sync::atomic::Ordering;
    use std::time::Instant;

    use symcockpit_core::input::{InputSettings, Synthetic};
    use symcockpit_macos::input::JsonFileSettings;
    use symcockpit_testkit::input::{FakeTapHost, SharedFeedback};

    use super::*;

    struct Probe(Rc<Cell<Access>>);

    impl InputProbe for Probe {
        fn event_tap_access(&self) -> Access {
            self.0.get()
        }
        fn secure_input_active(&self) -> bool {
            false
        }
    }

    struct Rig {
        _tmp: tempfile::TempDir,
        file: std::path::PathBuf,
        service: InputService,
        tap: FakeTapHost,
        feedback: SharedFeedback,
        access: Rc<Cell<Access>>,
    }

    fn rig() -> Rig {
        let tmp = tempfile::tempdir().unwrap();
        let file = tmp.path().join("input.json");
        let tap = FakeTapHost::default();
        let feedback = SharedFeedback::default();
        let access = Rc::new(Cell::new(Access::Granted));
        let path = file.clone();
        let backends = feedback.clone();
        let service = InputService::new(
            Box::new(tap.clone()),
            Box::new(Probe(Rc::clone(&access))),
            Arc::new(move || Box::new(JsonFileSettings::new(&path))),
            Arc::new(move || {
                Ok(Feedback {
                    haptic: Box::new(backends.clone()),
                    sound: Box::new(backends.clone()),
                })
            }),
        );
        Rig {
            _tmp: tmp,
            file,
            service,
            tap,
            feedback,
            access,
        }
    }

    fn set(rig: &Rig, f: impl FnOnce(&mut InputSettings)) {
        let store = JsonFileSettings::new(&rig.file);
        let mut s = store.load().unwrap();
        f(&mut s);
        store.save(&s).unwrap();
    }

    fn eventually(what: &str, check: impl Fn() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !check() {
            assert!(Instant::now() < deadline, "timed out waiting for: {what}");
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn nothing_is_installed_until_the_user_switches_it_on() {
        let mut r = rig();
        r.service.reconcile();
        assert_eq!((r.tap.starts(), r.service.spinning()), (0, false));
        assert_eq!(r.service.state(), &TapState::Off);
    }

    #[test]
    fn switching_on_installs_one_tap_and_switching_off_removes_it() {
        let mut r = rig();
        set(&r, |s| s.finder_cut = true);
        r.service.reconcile();
        r.service.reconcile();
        assert_eq!(r.tap.starts(), 1, "reconciling twice installs one tap");
        assert!(r.service.spinning() && r.tap.running());
        assert_eq!(r.service.state(), &TapState::Running);
        set(&r, |s| s.finder_cut = false);
        r.service.reconcile();
        assert_eq!((r.tap.stops(), r.service.spinning()), (1, false));
        assert!(!r.tap.running());
        assert_eq!(r.service.state(), &TapState::Off);
    }

    #[test]
    fn ending_the_service_removes_the_tap() {
        let mut r = rig();
        set(&r, |s| s.finder_cut = true);
        r.service.reconcile();
        r.service.end();
        assert_eq!(r.tap.stops(), 1);
        // Dropping after `end` must not remove it twice.
        drop(r.service);
        assert_eq!(r.tap.stops(), 1);
    }

    #[test]
    fn without_the_accessibility_permission_no_tap_is_attempted_and_the_state_says_why() {
        let mut r = rig();
        r.access.set(Access::Denied);
        set(&r, |s| s.finder_cut = true);
        r.service.reconcile();
        assert_eq!(r.tap.starts(), 0, "no attempt, so no permission dialog");
        let TapState::Permission(text) = r.service.state().clone() else {
            panic!("{:?}", r.service.state());
        };
        assert!(text.contains("Accessibility"));
        assert_eq!(r.service.status_json()["finder_cut"], "permission");
        // The permission arrives later: the next reconcile installs the tap.
        r.access.set(Access::Granted);
        r.service.reconcile();
        assert_eq!(r.service.state(), &TapState::Running);
    }

    #[test]
    fn a_refused_tap_is_a_named_state_and_the_setting_stays_on() {
        let mut r = rig();
        r.tap.refuse_with(Some(Error::Permission(
            "cannot create the event tap".into(),
        )));
        set(&r, |s| s.finder_cut = true);
        r.service.reconcile();
        assert!(matches!(r.service.state(), TapState::Permission(_)));
        r.tap.refuse_with(Some(Error::Unsupported("tests".into())));
        r.service.reconcile();
        assert!(matches!(r.service.state(), TapState::Unsupported(_)));
        assert!(JsonFileSettings::new(&r.file).load().unwrap().finder_cut);
    }

    #[test]
    fn a_replaced_key_plays_the_click_through_the_enabled_channels_only() {
        let mut r = rig();
        set(&r, |s| {
            s.finder_cut = true;
            s.haptics = true;
            s.sound = true;
        });
        r.service.reconcile();
        assert!(r.tap.fire(Synthetic::Copy));
        eventually("haptic and sound", || {
            r.feedback.actuations.load(Ordering::SeqCst) == 1
                && r.feedback.sounds.load(Ordering::SeqCst) == 1
        });
        // The sound alone: a later click leaves the haptic count where it is.
        set(&r, |s| s.haptics = false);
        assert!(r.tap.fire(Synthetic::MoveHere));
        eventually("the sound only", || {
            r.feedback.sounds.load(Ordering::SeqCst) == 2
        });
        assert_eq!(r.feedback.actuations.load(Ordering::SeqCst), 1);
        // Both off: the tap still works, nothing clicks.
        set(&r, |s| s.sound = false);
        assert!(r.tap.fire(Synthetic::Copy));
        r.service.end(); // joins the feedback thread: every posted click was handled
        assert_eq!(r.feedback.sounds.load(Ordering::SeqCst), 2);
    }
}
