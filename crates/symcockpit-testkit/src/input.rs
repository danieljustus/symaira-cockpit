//! Fakes for the input ports: no event tap, no actuator, no speaker.

use std::cell::{Cell, RefCell};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use symcockpit_contract::Error;
use symcockpit_core::input::{
    Access, ActionHook, FinderEnv, HapticBackend, HapticLevel, HapticPattern, InputProbe,
    InputSettings, RunningTap, SettingsStore, SoundBackend, Synthetic, TapHost,
};

/// System state for the Finder decision engine; every field can be changed mid-test.
pub struct FakeEnv {
    pub front: RefCell<Option<String>>,
    pub secure: Cell<bool>,
    pub change_count: Cell<i64>,
}

impl FakeEnv {
    pub fn new(front: &str) -> FakeEnv {
        FakeEnv {
            front: RefCell::new(Some(front.to_owned())),
            secure: Cell::new(false),
            change_count: Cell::new(100),
        }
    }

    /// Another app (or the posted ⌘C) changes the clipboard.
    pub fn clipboard_changes(&self) {
        self.change_count.set(self.change_count.get() + 1);
    }
}

impl FinderEnv for FakeEnv {
    fn frontmost_bundle_id(&self) -> Option<String> {
        self.front.borrow().clone()
    }
    fn secure_input_active(&self) -> bool {
        self.secure.get()
    }
    fn pasteboard_change_count(&self) -> i64 {
        self.change_count.get()
    }
}

/// A haptic backend stuck at one level; counts actuations that went through.
pub struct FakeHaptic {
    pub level: HapticLevel,
    pub actuations: Cell<u32>,
}

impl FakeHaptic {
    pub fn new(level: HapticLevel) -> FakeHaptic {
        FakeHaptic {
            level,
            actuations: Cell::new(0),
        }
    }
}

impl HapticBackend for FakeHaptic {
    fn probe(&self) -> HapticLevel {
        self.level.clone()
    }
    fn actuate(&self, _pattern: HapticPattern) -> Result<(), HapticLevel> {
        if self.level == HapticLevel::Available {
            self.actuations.set(self.actuations.get() + 1);
            Ok(())
        } else {
            Err(self.level.clone())
        }
    }
}

/// Records every WAV it is asked to play (by length), optionally failing.
#[derive(Default)]
pub struct FakeSound {
    pub played: RefCell<Vec<usize>>,
    pub fail: bool,
}

impl SoundBackend for FakeSound {
    fn play(&self, wav: &[u8]) -> Result<(), String> {
        if self.fail {
            return Err("no output device".into());
        }
        self.played.borrow_mut().push(wav.len());
        Ok(())
    }
}

/// In-memory settings that count writes.
#[derive(Default)]
pub struct MemorySettings {
    pub value: RefCell<InputSettings>,
    pub saves: Cell<u32>,
}

impl SettingsStore for MemorySettings {
    fn load(&self) -> Result<InputSettings, Error> {
        Ok(self.value.borrow().clone())
    }
    fn save(&self, settings: &InputSettings) -> Result<(), Error> {
        *self.value.borrow_mut() = settings.clone();
        self.saves.set(self.saves.get() + 1);
        Ok(())
    }
}

pub struct FakeProbe {
    pub access: Access,
    pub secure: bool,
}

impl InputProbe for FakeProbe {
    fn event_tap_access(&self) -> Access {
        self.access
    }
    fn secure_input_active(&self) -> bool {
        self.secure
    }
}

/// A tap host the test drives from outside: counts starts and stops, can refuse, and lets the
/// test fire the hook the way the real tap does after it replaced a key. Safe to share across
/// threads (the agent's feedback runs on another one).
#[derive(Clone, Default)]
pub struct FakeTapHost(Arc<TapState>);

#[derive(Default)]
struct TapState {
    starts: AtomicU32,
    stops: AtomicU32,
    refuse: Mutex<Option<Error>>,
    hook: Mutex<Option<ActionHook>>,
}

struct FakeRunning(Arc<TapState>);

impl RunningTap for FakeRunning {}

impl Drop for FakeRunning {
    fn drop(&mut self) {
        self.0.stops.fetch_add(1, Ordering::SeqCst);
        *self.0.hook.lock().unwrap() = None;
    }
}

impl FakeTapHost {
    pub fn refusing(error: Error) -> Self {
        let host = Self::default();
        host.refuse_with(Some(error));
        host
    }
    pub fn refuse_with(&self, error: Option<Error>) {
        *self.0.refuse.lock().unwrap() = error;
    }
    pub fn starts(&self) -> u32 {
        self.0.starts.load(Ordering::SeqCst)
    }
    pub fn stops(&self) -> u32 {
        self.0.stops.load(Ordering::SeqCst)
    }
    pub fn running(&self) -> bool {
        self.0.hook.lock().unwrap().is_some()
    }
    /// The tap replaced a key. Returns false when no tap is running.
    pub fn fire(&self, action: Synthetic) -> bool {
        let hook = self.0.hook.lock().unwrap().clone();
        hook.map(|hook| hook(action)).is_some()
    }
}

impl TapHost for FakeTapHost {
    fn start(&self, on_action: ActionHook) -> Result<Box<dyn RunningTap>, Error> {
        if let Some(error) = self.0.refuse.lock().unwrap().clone() {
            return Err(error);
        }
        self.0.starts.fetch_add(1, Ordering::SeqCst);
        *self.0.hook.lock().unwrap() = Some(on_action);
        Ok(Box::new(FakeRunning(Arc::clone(&self.0))))
    }
}

/// Actuations and played sounds, observable from the test thread.
#[derive(Clone, Default)]
pub struct SharedFeedback {
    pub actuations: Arc<AtomicU32>,
    pub sounds: Arc<AtomicU32>,
}

impl HapticBackend for SharedFeedback {
    fn probe(&self) -> HapticLevel {
        HapticLevel::Available
    }
    fn actuate(&self, _pattern: HapticPattern) -> Result<(), HapticLevel> {
        self.actuations.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }
}

impl SoundBackend for SharedFeedback {
    fn play(&self, _wav: &[u8]) -> Result<(), String> {
        self.sounds.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use symcockpit_core::input::*;

    use super::*;

    fn cmd(key: Key) -> TapEvent {
        TapEvent::Key(KeyEvent {
            key,
            modifiers: Modifiers::COMMAND,
        })
    }

    /// ⌘X in Finder, then the posted ⌘C lands on the clipboard and the adapter's poll sees it.
    fn cut_in_finder(engine: &mut FinderCut, env: &FakeEnv) {
        assert_eq!(
            engine.handle(cmd(Key::X), env),
            Action::Replace(Synthetic::Copy)
        );
        assert!(engine.is_waiting());
        env.clipboard_changes();
        engine.poll(env);
        assert!(engine.has_pending_cut() && !engine.is_waiting());
    }

    #[test]
    fn frontmost_gate_cut_works_only_in_finder() {
        for other in [
            "com.apple.Safari",
            "com.apple.dt.Xcode",
            "com.example.Editor",
        ] {
            let env = FakeEnv::new(other);
            let mut engine = FinderCut::default();
            assert_eq!(
                engine.handle(cmd(Key::X), &env),
                Action::PassThrough,
                "{other}"
            );
            assert_eq!(
                engine.handle(cmd(Key::V), &env),
                Action::PassThrough,
                "{other}"
            );
            assert!(!engine.has_pending_cut());
        }
        let nobody = FakeEnv {
            front: Default::default(),
            ..FakeEnv::new("")
        };
        assert_eq!(
            FinderCut::default().handle(cmd(Key::X), &nobody),
            Action::PassThrough
        );
    }

    #[test]
    fn finder_cut_then_paste_moves() {
        let env = FakeEnv::new(FINDER_BUNDLE_ID);
        let mut engine = FinderCut::default();
        cut_in_finder(&mut engine, &env);
        assert_eq!(
            engine.handle(cmd(Key::V), &env),
            Action::Replace(Synthetic::MoveHere)
        );
        assert!(!engine.has_pending_cut(), "one cut moves once");
        assert_eq!(engine.handle(cmd(Key::V), &env), Action::PassThrough);
    }

    #[test]
    fn paste_elsewhere_passes_through_and_keeps_the_cut() {
        let env = FakeEnv::new(FINDER_BUNDLE_ID);
        let mut engine = FinderCut::default();
        cut_in_finder(&mut engine, &env);
        *env.front.borrow_mut() = Some("com.apple.Safari".into());
        assert_eq!(engine.handle(cmd(Key::V), &env), Action::PassThrough);
        *env.front.borrow_mut() = Some(FINDER_BUNDLE_ID.into());
        assert_eq!(
            engine.handle(cmd(Key::V), &env),
            Action::Replace(Synthetic::MoveHere)
        );
    }

    #[test]
    fn another_copy_cancels_the_pending_cut() {
        let env = FakeEnv::new(FINDER_BUNDLE_ID);
        let mut engine = FinderCut::default();
        cut_in_finder(&mut engine, &env);
        env.clipboard_changes(); // the user copies something else, e.g. from a context menu
        assert_eq!(engine.handle(cmd(Key::V), &env), Action::PassThrough);
    }

    #[test]
    fn cut_that_never_reached_the_clipboard_does_not_move() {
        let env = FakeEnv::new(FINDER_BUNDLE_ID);
        let mut engine = FinderCut::default();
        assert_eq!(
            engine.handle(cmd(Key::X), &env),
            Action::Replace(Synthetic::Copy)
        );
        // Nothing was selected: the clipboard did not change, the adapter gives up waiting.
        engine.poll(&env);
        assert!(engine.is_waiting());
        engine.abandon_waiting();
        env.clipboard_changes(); // a later, unrelated copy must not arm the cut
        assert_eq!(engine.handle(cmd(Key::V), &env), Action::PassThrough);
        assert!(!engine.has_pending_cut());
    }

    #[test]
    fn secure_input_and_other_modifiers_pass_through() {
        let env = FakeEnv::new(FINDER_BUNDLE_ID);
        let mut engine = FinderCut::default();
        env.secure.set(true);
        assert_eq!(engine.handle(cmd(Key::X), &env), Action::PassThrough);
        env.secure.set(false);
        for mods in [
            Modifiers {
                shift: true,
                ..Modifiers::COMMAND
            },
            Modifiers {
                option: true,
                ..Modifiers::COMMAND
            },
            Modifiers {
                control: true,
                ..Modifiers::COMMAND
            },
            Modifiers::default(),
        ] {
            let ev = TapEvent::Key(KeyEvent {
                key: Key::X,
                modifiers: mods,
            });
            assert_eq!(engine.handle(ev, &env), Action::PassThrough, "{mods:?}");
        }
        assert_eq!(engine.handle(cmd(Key::Other), &env), Action::PassThrough);
    }

    #[test]
    fn disabled_tap_is_re_enabled_and_forgets_the_cut() {
        let env = FakeEnv::new(FINDER_BUNDLE_ID);
        let mut engine = FinderCut::default();
        cut_in_finder(&mut engine, &env);
        for reason in [DisabledReason::Timeout, DisabledReason::UserInput] {
            assert_eq!(
                engine.handle(TapEvent::Disabled(reason), &env),
                Action::ReEnableTap
            );
        }
        assert_eq!(engine.handle(cmd(Key::V), &env), Action::PassThrough);
    }

    fn settings(haptics: bool, sound: bool) -> InputSettings {
        InputSettings {
            haptics,
            sound,
            ..InputSettings::default()
        }
    }

    #[test]
    fn haptic_failure_levels_keep_the_sound_and_the_settings() {
        let levels = [
            HapticLevel::FrameworkMissing,
            HapticLevel::SymbolMissing("MTActuatorOpen".into()),
            HapticLevel::NoDevice,
            HapticLevel::OpenFailed,
            HapticLevel::ActuationFailed,
        ];
        let mut names = std::collections::BTreeSet::new();
        for level in levels {
            let store = MemorySettings::default();
            *store.value.borrow_mut() = settings(true, true);
            let before = store.value.borrow().clone();
            let (haptic, sound) = (FakeHaptic::new(level.clone()), FakeSound::default());
            let report = trigger(&store.load().unwrap(), false, &haptic, &sound);
            assert_eq!(report.haptic.status, level.name());
            assert_eq!(report.haptic.detail.as_deref(), level.detail());
            assert!(report.sound.is_ok(), "sound keeps playing: {level:?}");
            assert_eq!(sound.played.borrow().len(), 1);
            assert!(report.degraded);
            assert_eq!(haptic.actuations.get(), 0);
            // The command path reports the same without touching the settings.
            let v = input_haptics_test_json(&store, &haptic, &sound).unwrap();
            assert_eq!(v["haptic"]["status"], level.name());
            assert_eq!(store.saves.get(), 0, "the test command never saves");
            assert_eq!(*store.value.borrow(), before, "{level:?}");
            assert!(names.insert(level.name()), "every level has its own name");
        }
    }

    #[test]
    fn healthy_haptics_fire_both_channels_and_disabled_ones_are_skipped() {
        let (haptic, sound) = (
            FakeHaptic::new(HapticLevel::Available),
            FakeSound::default(),
        );
        let report = trigger(&settings(true, true), false, &haptic, &sound);
        assert!(report.haptic.is_ok() && report.sound.is_ok() && !report.degraded);
        let report = trigger(&settings(false, false), false, &haptic, &sound);
        assert_eq!(report.haptic.status, "skipped_disabled");
        assert!(!report.degraded);
        assert_eq!(
            (haptic.actuations.get(), sound.played.borrow().len()),
            (1, 1)
        );
        let report = trigger(&settings(false, false), true, &haptic, &sound);
        assert!(
            report.haptic.is_ok() && report.sound.is_ok(),
            "force ignores the switches"
        );
    }

    #[test]
    fn a_failing_sound_does_not_stop_the_haptic() {
        let haptic = FakeHaptic::new(HapticLevel::Available);
        let sound = FakeSound {
            fail: true,
            ..Default::default()
        };
        let report = trigger(&settings(true, true), false, &haptic, &sound);
        assert!(report.haptic.is_ok());
        assert_eq!(report.sound.status, "failed");
        assert!(report.degraded);
    }

    #[test]
    fn finder_cut_command_persists_only_that_switch() {
        let store = MemorySettings::default();
        *store.value.borrow_mut() = settings(true, false);
        input_finder_cut_json(&store, true).unwrap();
        assert_eq!(
            *store.value.borrow(),
            InputSettings {
                finder_cut: true,
                ..settings(true, false)
            }
        );
    }

    #[test]
    fn json_shapes_match_the_snapshots() {
        let store = MemorySettings::default();
        let probe = FakeProbe {
            access: Access::Denied,
            secure: false,
        };
        let haptic = FakeHaptic::new(HapticLevel::SymbolMissing("MTActuatorOpen".into()));
        let sound = FakeSound::default();
        let checks = [
            (
                "input.status",
                input_status_json(&store, &probe, &haptic).unwrap(),
            ),
            (
                "input.finder-cut",
                input_finder_cut_json(&store, true).unwrap(),
            ),
            (
                "input.haptics.status",
                input_haptics_status_json(&store, &haptic).unwrap(),
            ),
            (
                "input.haptics.test",
                input_haptics_test_json(&store, &haptic, &sound).unwrap(),
            ),
        ];
        for (id, value) in &checks {
            crate::snapshot::check("input", id, value);
        }
    }
}
