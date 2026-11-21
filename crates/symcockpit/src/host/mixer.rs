//! The per-app mixer (R44) as the agent hosts it: `audio mixer set` and the MCP-less
//! `audio.app-volume.set` reach this through [`MixerControl`] instead of failing with "no mixer
//! is running in this process".
//!
//! The pipeline is the one `audio mixer run` uses (`core::audio::mixer`): taps and aggregates
//! per app, a settled rebuild on a device change, every tap destroyed when the output goes away
//! or the mixer ends. What this file adds is the lifecycle: nothing exists until the first
//! non-identity setting, the follower thread runs only while an app is `active` or `pending`
//! (Q04), and `end` releases every app before the agent exits (EOF, SIGTERM) so no app is left
//! silent. A SIGKILLed agent cannot run any of this; that a private tap then dies with its
//! process is unverified on hardware (spike S4 never ran live).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::Duration;

use serde_json::{Value, json};
use symcockpit_contract::Error;
use symcockpit_core::audio::mixer::{
    AppMixer, AppSetting, AppStatus, LoopSummary, MixerControl, TapHal, run_loop,
};
use symcockpit_core::audio::{AudioHal, Scope};

pub struct MixerParts {
    pub tap: Arc<dyn TapHal>,
    pub audio: Arc<dyn AudioHal>,
}

pub type MakeMixer = Arc<dyn Fn() -> Result<MixerParts, Error> + Send + Sync>;

struct Runner {
    stop: Arc<AtomicBool>,
    join: JoinHandle<LoopSummary>,
}

struct State {
    mixer: Arc<Mutex<AppMixer>>,
    audio: Arc<dyn AudioHal>,
    runner: Option<Runner>,
}

fn lock(mixer: &Mutex<AppMixer>) -> MutexGuard<'_, AppMixer> {
    mixer.lock().unwrap_or_else(|e| e.into_inner())
}

impl State {
    fn start_runner(&mut self) {
        if self.runner.is_some() {
            return;
        }
        // The wanted output is known before the first app attaches.
        let output = self
            .audio
            .default_device(Scope::Output)
            .ok()
            .flatten()
            .and_then(|o| self.audio.device_uid(o).ok());
        lock(&self.mixer).on_default_output(output.as_deref());
        let stop = Arc::new(AtomicBool::new(false));
        let (mixer, audio, flag) = (
            Arc::clone(&self.mixer),
            Arc::clone(&self.audio),
            Arc::clone(&stop),
        );
        let join = std::thread::Builder::new()
            .name("symcockpit-mixer".into())
            .spawn(move || {
                run_loop(
                    &mixer,
                    &*audio,
                    &|| flag.load(Ordering::SeqCst),
                    &std::thread::sleep as &dyn Fn(Duration),
                )
            })
            .expect("the operating system can start a thread");
        self.runner = Some(Runner { stop, join });
    }

    /// Ends the follower thread; `run_loop` releases every app on its way out.
    fn stop_runner(&mut self) {
        let Some(runner) = self.runner.take() else {
            return;
        };
        runner.stop.store(true, Ordering::SeqCst);
        match runner.join.join() {
            Ok(summary) if !summary.teardown_errors.is_empty() => {
                eprintln!(
                    "symcockpit: mixer: cleanup failed: {:?}",
                    summary.teardown_errors
                );
            }
            Ok(_) => {}
            Err(_) => eprintln!("symcockpit: mixer: the follower thread panicked"),
        }
    }

    /// The follower is only needed while an app is attached or waiting for its audio object.
    fn stop_runner_if_idle(&mut self) {
        let busy = lock(&self.mixer)
            .status()
            .iter()
            .any(|s| matches!(s.state, "active" | "pending"));
        if !busy {
            self.stop_runner();
        }
    }
}

pub struct HostedMixer {
    make: MakeMixer,
    state: Mutex<Option<State>>,
    /// Set by `end`: a request that arrives afterwards must fail, not build a new pipeline that
    /// nobody would release.
    ended: AtomicBool,
}

impl HostedMixer {
    pub fn new(make: MakeMixer) -> Self {
        Self {
            make,
            state: Mutex::new(None),
            ended: AtomicBool::new(false),
        }
    }

    fn state(&self) -> MutexGuard<'_, Option<State>> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Periodic housekeeping: a follower with nothing to follow goes to sleep for good.
    pub fn idle_check(&self) {
        if let Some(state) = self.state().as_mut() {
            state.stop_runner_if_idle();
        }
    }

    /// Releases every app (their original sound returns) and ends the thread. Repeatable.
    pub fn end(&self) {
        self.ended.store(true, Ordering::SeqCst);
        if let Some(mut state) = self.state().take() {
            state.stop_runner();
            let leaked = lock(&state.mixer).release_all();
            if !leaked.is_empty() {
                eprintln!("symcockpit: mixer: cleanup failed: {leaked:?}");
            }
        }
    }

    pub fn running(&self) -> bool {
        self.state().as_ref().is_some_and(|s| s.runner.is_some())
    }

    pub fn status_json(&self) -> Value {
        json!({"running": self.running(), "apps": MixerControl::status(self).len()})
    }
}

impl MixerControl for HostedMixer {
    fn set_app_volume(&self, pid: i32, volume: f32, muted: bool) -> Result<AppStatus, Error> {
        let mut guard = self.state();
        if self.ended.load(Ordering::SeqCst) {
            return Err(Error::Failed("the mixer has ended with the agent".into()));
        }
        if guard.is_none() {
            let parts = (self.make)()?;
            *guard = Some(State {
                mixer: Arc::new(Mutex::new(AppMixer::new(parts.tap))),
                audio: parts.audio,
                runner: None,
            });
        }
        let state = guard.as_mut().expect("created above");
        let setting = AppSetting { volume, muted };
        if !setting.is_identity() {
            state.start_runner();
        }
        let result = lock(&state.mixer).set_app(pid, setting);
        state.stop_runner_if_idle();
        result
    }

    fn status(&self) -> Vec<AppStatus> {
        self.state()
            .as_ref()
            .map_or_else(Vec::new, |s| lock(&s.mixer).status())
    }
}

impl Drop for HostedMixer {
    fn drop(&mut self) {
        self.end();
    }
}

#[cfg(test)]
mod tests {
    use std::time::Instant;

    use symcockpit_testkit::audio::{FakeAudioHal, FakeTapHal, output_device, process};

    use super::*;

    struct Rig {
        mixer: HostedMixer,
        tap: Arc<FakeTapHal>,
        audio: Arc<FakeAudioHal>,
    }

    fn rig() -> Rig {
        let tap = Arc::new(FakeTapHal::new());
        tap.set_processes(vec![process(42, 7), process(43, 8)]);
        let audio = Arc::new(FakeAudioHal::new(vec![
            output_device("speakers"),
            output_device("monitor"),
        ]));
        audio.set_defaults(None, Some("speakers"));
        let (t, a) = (Arc::clone(&tap), Arc::clone(&audio));
        let mixer = HostedMixer::new(Arc::new(move || {
            Ok(MixerParts {
                tap: Arc::clone(&t) as Arc<dyn TapHal>,
                audio: Arc::clone(&a) as Arc<dyn AudioHal>,
            })
        }));
        Rig { mixer, tap, audio }
    }

    fn eventually(what: &str, check: impl Fn() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !check() {
            assert!(Instant::now() < deadline, "timed out waiting for: {what}");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn nothing_exists_until_the_first_real_setting() {
        let r = rig();
        assert!(r.mixer.status().is_empty() && !r.mixer.running());
        // Full volume without mute needs no tap and no follower thread.
        let status = r.mixer.set_app_volume(42, 1.0, false).unwrap();
        assert_eq!(status.state, "passthrough");
        assert!(!r.mixer.running());
        assert!(
            r.tap.log().iter().all(|l| !l.starts_with("create_tap")),
            "{:?}",
            r.tap.log()
        );
    }

    #[test]
    fn a_setting_attaches_a_tap_and_returning_to_full_volume_removes_it() {
        let r = rig();
        let status = r.mixer.set_app_volume(42, 0.5, false).unwrap();
        assert_eq!(status.state, "active");
        assert!(r.mixer.running());
        assert_eq!(r.tap.live_taps(), 1);
        // A running app changes its gain without a rebuild.
        r.mixer.set_app_volume(42, 0.25, false).unwrap();
        assert_eq!(r.tap.live_taps(), 1);
        let status = r.mixer.set_app_volume(42, 1.0, false).unwrap();
        assert_eq!(status.state, "passthrough");
        assert!(r.tap.live().is_empty(), "{:?}", r.tap.live());
        assert!(
            !r.mixer.running(),
            "nothing left to follow: the thread ends"
        );
    }

    #[test]
    fn a_changed_default_output_rebuilds_the_aggregate_and_keeps_the_tap() {
        let r = rig();
        r.mixer.set_app_volume(42, 0.5, false).unwrap();
        r.audio.set_defaults(None, Some("monitor"));
        r.audio.bump_epoch();
        eventually("the aggregate is rebuilt for the new output", || {
            r.tap
                .log()
                .iter()
                .filter(|l| l.starts_with("create_aggregate"))
                .count()
                == 2
        });
        assert_eq!(r.tap.live_taps(), 1);
        assert_eq!(r.mixer.status()[0].state, "active");
    }

    #[test]
    fn a_vanishing_output_releases_every_app_and_a_new_one_brings_them_back() {
        let r = rig();
        r.mixer.set_app_volume(42, 0.5, false).unwrap();
        r.mixer.set_app_volume(43, 0.0, true).unwrap();
        assert_eq!(r.tap.live_taps(), 2);
        r.audio.unplug("speakers");
        eventually("no app is left silenced without an output", || {
            r.tap.live().is_empty()
        });
        // The wanted settings are kept: with an output again, the apps are tapped again.
        r.audio.set_defaults(None, Some("monitor"));
        r.audio.bump_epoch();
        eventually("the settings are re-applied", || r.tap.live_taps() == 2);
    }

    #[test]
    fn ending_the_mixer_leaves_no_tap_and_no_thread() {
        let r = rig();
        r.mixer.set_app_volume(42, 0.5, false).unwrap();
        r.mixer.set_app_volume(43, 0.0, true).unwrap();
        r.mixer.end();
        assert!(r.tap.live().is_empty(), "{:?}", r.tap.live());
        assert!(!r.mixer.running() && r.mixer.status().is_empty());
        r.mixer.end(); // repeatable
    }

    #[test]
    fn a_request_after_the_end_fails_and_builds_nothing() {
        let r = rig();
        r.mixer.set_app_volume(42, 0.5, false).unwrap();
        r.mixer.end();
        let error = r.mixer.set_app_volume(42, 0.5, false).unwrap_err();
        assert!(error.to_string().contains("ended"), "{error}");
        assert!(r.tap.live().is_empty() && !r.mixer.running());
    }

    #[test]
    fn dropping_the_mixer_releases_every_app() {
        let r = rig();
        r.mixer.set_app_volume(42, 0.5, false).unwrap();
        let tap = Arc::clone(&r.tap);
        drop(r);
        assert!(tap.live().is_empty());
    }

    #[test]
    fn without_process_taps_the_answer_is_unsupported_and_no_thread_starts() {
        let r = rig();
        r.tap.set_unsupported();
        let error = r.mixer.set_app_volume(42, 0.5, false).unwrap_err();
        assert!(matches!(error, Error::Unsupported(_)), "{error:?}");
        assert!(
            !r.mixer.running(),
            "an unsupported system keeps no follower"
        );
        assert!(r.tap.live().is_empty());
    }

    #[test]
    fn a_failed_rebuild_never_leaves_an_app_silent() {
        let r = rig();
        r.mixer.set_app_volume(42, 0.5, false).unwrap();
        // The next aggregate cannot be created: the tap must go, the app is audible again.
        r.tap.fail("create_aggregate", 2);
        r.audio.set_defaults(None, Some("monitor"));
        r.audio.bump_epoch();
        eventually("the failed rebuild released the tap", || {
            r.tap.live().is_empty()
        });
    }

    #[test]
    fn an_unavailable_factory_is_reported_not_swallowed() {
        let mixer = HostedMixer::new(Arc::new(|| {
            Err(Error::Unsupported("per-app volume is disabled here".into()))
        }));
        let error = mixer.set_app_volume(1, 0.5, false).unwrap_err();
        assert!(error.to_string().contains("disabled"));
        assert!(mixer.status().is_empty());
    }
}
