//! Fakes for the display write, power assertion and history ports, and the
//! behaviour tests of the unprivileged write surface (`TuneWriter`).
//!
//! Nothing here reaches a display, a gamma table, an overlay or a power
//! assertion: every call is recorded in [`Hardware`] and nothing else happens.

use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::{Arc, Mutex};

use symcockpit_contract::Error;
use symcockpit_core::awake::{PowerAssertionPort, PowerAssertionType};
use symcockpit_core::display::{BrightnessSource, DisplayEnumerator, ScreenSnapshot};
use symcockpit_core::display_write::{BrightnessSink, DimOverlayPort, DisplayWriter};
use symcockpit_core::edr::{EdrOverlay, EdrPlatform, EdrTrigger};
use symcockpit_core::gamma::{GammaController, GammaIo, GammaRamp};
use symcockpit_core::tune_write::{HistorySink, Limits, LogEvent, TuneWriter, WriterPorts};

use crate::display::sample_builtin;

/// Everything the fake hardware was asked to do, in order.
#[derive(Default)]
pub struct Hardware {
    pub calls: RefCell<Vec<String>>,
    pub brightness: Cell<f64>,
    pub fail_brightness_set: Cell<bool>,
    pub fail_gamma_write: Cell<bool>,
    pub no_screens: Cell<bool>,
    pub headroom: Cell<f64>,
    pub dim_shown: Cell<Option<f32>>,
}

impl Hardware {
    pub fn new() -> Rc<Self> {
        let hw = Rc::new(Self::default());
        hw.brightness.set(0.5);
        hw.headroom.set(2.0);
        hw
    }

    pub fn calls(&self) -> Vec<String> {
        self.calls.borrow().clone()
    }

    fn note(&self, call: impl Into<String>) {
        self.calls.borrow_mut().push(call.into());
    }
}

struct Screens(Rc<Hardware>);
impl DisplayEnumerator for Screens {
    fn enumerate_screens(&self) -> Vec<ScreenSnapshot> {
        if self.0.no_screens.get() {
            vec![]
        } else {
            vec![sample_builtin()]
        }
    }
}
struct Reader(Rc<Hardware>);
impl BrightnessSource for Reader {
    fn brightness(&self, _: u32) -> Result<f64, Error> {
        Ok(self.0.brightness.get())
    }
}
struct Sink(Rc<Hardware>);
impl BrightnessSink for Sink {
    fn set_brightness(&self, display_id: u32, value: f32) -> Result<(), Error> {
        if self.0.fail_brightness_set.get() {
            return Err(Error::Failed("brightness refused".into()));
        }
        self.0.note(format!("brightness {display_id} {value}"));
        self.0.brightness.set(f64::from(value));
        Ok(())
    }
}
struct Dim(Rc<Hardware>);
impl DimOverlayPort for Dim {
    fn show(&self, opacity: f32) {
        self.0.note(format!("dim.show {opacity}"));
        self.0.dim_shown.set(Some(opacity));
    }
    fn hide(&self) {
        self.0.note("dim.hide");
        self.0.dim_shown.set(None);
    }
}
struct Gamma(Rc<Hardware>);
impl GammaIo for Gamma {
    fn read_ramp(&self, _: u32, n: usize) -> Option<GammaRamp> {
        Some(GammaRamp::identity(n))
    }
    fn write_ramp(&self, ramp: &GammaRamp, id: u32) -> bool {
        self.0.note(format!(
            "gamma.write {id} blue_max={}",
            ramp.blue[ramp.blue.len() - 1]
        ));
        !self.0.fail_gamma_write.get()
    }
    fn restore_system_ramps(&self) {
        self.0.note("gamma.restore");
    }
}
struct Edr(Rc<Hardware>);
struct Trigger(Rc<Hardware>);
impl EdrTrigger for Trigger {
    fn render(&self) {
        self.0.note("edr.render");
    }
    fn remove(&self) {
        self.0.note("edr.remove");
    }
}
impl EdrPlatform for Edr {
    fn headroom(&self, _: u32) -> Option<f64> {
        Some(self.0.headroom.get())
    }
    fn create_trigger(&self, _: u32) -> Option<Box<dyn EdrTrigger>> {
        self.0.note("edr.create");
        Some(Box::new(Trigger(self.0.clone())))
    }
}

/// Fake power port: assertion ids count up from 100.
#[derive(Default)]
pub struct FakePower {
    pub created: Mutex<Vec<(PowerAssertionType, String)>>,
    pub released: Mutex<Vec<u32>>,
    pub fail: Mutex<bool>,
}
impl PowerAssertionPort for FakePower {
    fn create(&self, kind: PowerAssertionType, reason: &str) -> Result<u32, Error> {
        if *self.fail.lock().unwrap() {
            return Err(Error::Failed(
                "Failed to create power assertion (IOReturn -1).".into(),
            ));
        }
        let mut created = self.created.lock().unwrap();
        created.push((kind, reason.to_owned()));
        Ok(99 + u32::try_from(created.len()).unwrap())
    }
    fn release(&self, id: u32) {
        self.released.lock().unwrap().push(id);
    }
}

/// Records history events instead of writing a file.
#[derive(Default)]
pub struct RecordingHistory(pub Rc<RefCell<Vec<LogEvent>>>);
impl HistorySink for RecordingHistory {
    fn log(&self, event: &LogEvent) {
        self.0.borrow_mut().push(event.clone());
    }
}

pub struct Rig {
    pub writer: TuneWriter,
    pub hw: Rc<Hardware>,
    pub power: Arc<FakePower>,
    pub history: Rc<RefCell<Vec<LogEvent>>>,
    pub dir: PathBuf,
}

/// What a [`Rig`] recorded, once its writer has moved elsewhere.
pub struct Observers {
    pub hw: Rc<Hardware>,
    pub power: Arc<FakePower>,
    pub history: Rc<RefCell<Vec<LogEvent>>>,
    pub dir: PathBuf,
}

impl Rig {
    /// The writer (to install or drop) and the observers of its fakes.
    pub fn split(self) -> (TuneWriter, Observers) {
        let Rig {
            writer,
            hw,
            power,
            history,
            dir,
        } = self;
        (
            writer,
            Observers {
                hw,
                power,
                history,
                dir,
            },
        )
    }
}

/// A writer on fakes with its state under `dir` (a temp directory).
pub fn rig_with(
    dir: &Path,
    hw: Rc<Hardware>,
    alive: impl Fn(u32) -> bool + 'static,
    pid: u32,
) -> Rig {
    let power = Arc::new(FakePower::default());
    let history = Rc::new(RefCell::new(Vec::new()));
    let gamma = Rc::new(GammaController::new(Box::new(Gamma(hw.clone()))));
    let display = DisplayWriter::new(
        Box::new(Screens(hw.clone())),
        Box::new(Reader(hw.clone())),
        Box::new(Sink(hw.clone())),
        gamma.clone(),
        EdrOverlay::new(gamma, Box::new(Edr(hw.clone()))),
        Box::new(Dim(hw.clone())),
    );
    let writer = TuneWriter::new(WriterPorts {
        display,
        power: power.clone(),
        history: Box::new(RecordingHistory(history.clone())),
        limits: Limits {
            brightness: (0.0, 1.0),
            dim: (0.15, 1.0),
            extended: (1.0, 1.6),
        },
        data_dir: dir.to_path_buf(),
        is_root: false,
        version: "0.12.2".into(),
        pid,
        process_alive: Box::new(alive),
    });
    Rig {
        writer,
        hw,
        power,
        history,
        dir: dir.to_path_buf(),
    }
}

pub fn rig(dir: &Path) -> Rig {
    rig_with(dir, Hardware::new(), |_| false, 4242)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use symcockpit_store::{DisplayRestoreRecord, read_profiles, read_record, write_record};

    fn actions(rig: &Rig) -> Vec<(&'static str, bool)> {
        rig.history
            .borrow()
            .iter()
            .map(|e| (e.action, e.success))
            .collect()
    }

    // Vectors: ControllerControlRegressionTests.swift
    #[test]
    fn restore_clears_dim_warmth_brightness_and_allows_another_override() {
        let tmp = tempfile::tempdir().unwrap();
        let r = rig(tmp.path());
        r.writer.apply_dim(0.4).unwrap();
        r.writer.apply_warmth(0.6).unwrap();
        r.writer.apply_builtin_brightness(0.8).unwrap();
        r.writer.restore_all();
        assert_eq!(r.writer.dim_level(), 1.0);
        assert_eq!(r.writer.warmth_level(), 0.0);
        assert!(r.writer.active_overrides().is_empty());
        assert_eq!(
            r.hw.brightness.get(),
            0.5,
            "the original brightness is back"
        );
        r.writer.apply_warmth(0.3).unwrap();
        r.writer.restore_all();
        assert_eq!(r.writer.warmth_level(), 0.0);
        assert_eq!(
            read_record(tmp.path()).unwrap(),
            None,
            "no record outlives a restore"
        );
    }

    #[test]
    fn rejected_display_writes_do_not_become_active_overrides() {
        let tmp = tempfile::tempdir().unwrap();
        let r = rig(tmp.path());
        r.hw.fail_brightness_set.set(true);
        r.hw.fail_gamma_write.set(true);
        assert!(r.writer.apply_builtin_brightness(0.8).is_err());
        assert!(r.writer.apply_warmth(0.6).is_err());
        assert!(r.writer.apply_extended_brightness(1.3).is_err());
        assert!(r.writer.active_overrides().is_empty());
        assert_eq!(r.writer.warmth_level(), 0.0);
        assert_eq!(read_record(tmp.path()).unwrap(), None);
        assert_eq!(
            actions(&r),
            [
                ("brightness.set", false),
                ("warmth.set", false),
                ("extbright.set", false)
            ]
        );
        // A failed EDR attempt still resets the gamma table on restore.
        r.hw.calls.borrow_mut().clear();
        r.writer.restore_all();
        assert!(r.hw.calls().contains(&"gamma.restore".to_owned()));
    }

    #[test]
    fn a_rejected_update_keeps_the_last_successful_value() {
        let tmp = tempfile::tempdir().unwrap();
        let r = rig(tmp.path());
        r.writer.apply_warmth(0.2).unwrap();
        r.writer.apply_extended_brightness(1.1).unwrap();
        r.hw.fail_gamma_write.set(true);
        assert!(r.writer.apply_warmth(0.8).is_err());
        assert!(r.writer.apply_extended_brightness(1.5).is_err());
        assert!((r.writer.warmth_level() - 0.2).abs() < 1e-6);
        // The EDR request itself updated, but the gamma boost kept the last value.
        assert!(r.writer.active_overrides().contains_key("edr_brightness"));
    }

    #[test]
    fn non_finite_requests_are_usage_errors_before_any_write() {
        let tmp = tempfile::tempdir().unwrap();
        let r = rig(tmp.path());
        for value in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            for result in [
                r.writer.apply_builtin_brightness(value),
                r.writer.apply_warmth(value),
                r.writer.apply_dim(value),
                r.writer.apply_extended_brightness(value),
            ] {
                assert_eq!(result, Err(Error::Usage("Value must be finite.".into())));
            }
        }
        assert!(r.hw.calls().is_empty());
        assert!(r.history.borrow().is_empty());
    }

    #[test]
    fn values_are_clamped_through_the_limits_and_logged_requested_vs_clamped() {
        let tmp = tempfile::tempdir().unwrap();
        let r = rig(tmp.path());
        r.writer.apply_builtin_brightness(2.0).unwrap();
        r.writer.apply_dim(0.0).unwrap();
        r.writer.apply_extended_brightness(9.0).unwrap();
        r.writer.apply_warmth(-1.0).unwrap();
        assert_eq!(r.hw.brightness.get(), 1.0);
        assert!(
            (r.writer.dim_level() - 0.15).abs() < 1e-6,
            "dim floor keeps the screen visible"
        );
        let log = r.history.borrow();
        assert_eq!(log[0].requested, Some(2.0));
        assert_eq!((log[0].clamped, log[0].applied), (Some(1.0), Some(1.0)));
        assert_eq!(log[2].clamped, Some(1.6));
    }

    #[test]
    fn dim_one_removes_the_overlay_and_is_not_an_active_override() {
        let tmp = tempfile::tempdir().unwrap();
        let r = rig(tmp.path());
        r.writer.apply_dim(0.5).unwrap();
        assert_eq!(r.hw.dim_shown.get(), Some(0.5));
        assert_eq!(r.writer.active_overrides()["dim"], json!(0.5));
        r.writer.apply_dim(1.0).unwrap();
        assert_eq!(r.hw.dim_shown.get(), None);
        assert!(r.writer.active_overrides().is_empty());
        r.writer.apply_dim(0.4).unwrap();
        r.writer.reset_dim();
        assert_eq!(r.writer.dim_level(), 1.0);
        assert_eq!(actions(&r).last(), Some(&("dim.reset", true)));
    }

    #[test]
    fn active_overrides_report_what_status_needs() {
        let tmp = tempfile::tempdir().unwrap();
        let r = rig(tmp.path());
        r.writer.apply_builtin_brightness(0.8).unwrap();
        r.writer.apply_warmth(0.3).unwrap();
        r.writer.apply_extended_brightness(1.4).unwrap();
        r.writer.apply_dim(0.4).unwrap();
        let o = r.writer.active_overrides();
        assert_eq!(
            o["brightness"],
            json!(f64::from(0.8_f32)),
            "the live reading, a Float"
        );
        assert_eq!(o["warmth"], json!(f64::from(0.3_f32)));
        assert_eq!(o["dim"], json!(f64::from(0.4_f32)));
        assert_eq!(o["edr_brightness"], json!(1.4));
        r.writer.reset_warmth().unwrap();
        assert!(!r.writer.active_overrides().contains_key("warmth"));
    }

    #[test]
    fn extended_brightness_without_a_builtin_display_is_unsupported() {
        let tmp = tempfile::tempdir().unwrap();
        let r = rig(tmp.path());
        r.hw.no_screens.set(true);
        let err = r.writer.apply_extended_brightness(1.2).unwrap_err();
        assert_eq!(
            err,
            Error::Unsupported("No built-in display detected.".into())
        );
        assert_eq!(err.exit_code(), 4);
        assert!(r.writer.apply_builtin_brightness(0.5).is_err());
        assert!(
            r.writer.apply_dim(0.5).is_ok(),
            "the overlay covers every screen and needs no builtin"
        );
    }

    // ---- restore-on-exit, interruption and crash (Q05)

    #[test]
    fn dropping_the_writer_restores_everything_and_the_record() {
        let tmp = tempfile::tempdir().unwrap();
        let hw = Hardware::new();
        {
            let r = rig_with(tmp.path(), hw.clone(), |_| false, 4242);
            r.writer.apply_builtin_brightness(0.9).unwrap();
            r.writer.apply_warmth(0.5).unwrap();
            r.writer.apply_dim(0.5).unwrap();
            r.writer.apply_extended_brightness(1.3).unwrap();
            assert!(read_record(tmp.path()).unwrap().is_some());
        }
        assert_eq!(hw.brightness.get(), 0.5);
        assert_eq!(hw.dim_shown.get(), None);
        assert!(hw.calls().contains(&"gamma.restore".to_owned()));
        assert!(hw.calls().contains(&"edr.remove".to_owned()));
        assert_eq!(read_record(tmp.path()).unwrap(), None);
    }

    #[test]
    fn the_record_holds_the_brightness_from_before_the_first_override_only() {
        let tmp = tempfile::tempdir().unwrap();
        let r = rig(tmp.path());
        r.writer.apply_builtin_brightness(0.9).unwrap();
        r.writer.apply_builtin_brightness(0.2).unwrap();
        assert_eq!(
            read_record(tmp.path()).unwrap(),
            Some(DisplayRestoreRecord {
                pid: 4242,
                display_id: 1,
                brightness: 0.5
            })
        );
        std::mem::forget(r.writer); // a crash: no Drop, no restore
    }

    #[test]
    fn a_crashed_runs_brightness_is_restored_at_the_next_start() {
        let tmp = tempfile::tempdir().unwrap();
        write_record(
            tmp.path(),
            &DisplayRestoreRecord {
                pid: 777,
                display_id: 1,
                brightness: 0.4,
            },
            false,
        )
        .unwrap();
        let hw = Hardware::new();
        hw.brightness.set(1.0);
        // The owner (777) is gone: the next start puts the brightness back.
        let _r = rig_with(tmp.path(), hw.clone(), |pid| pid != 777, 4242);
        assert_eq!(hw.calls(), ["brightness 1 0.4"]);
        assert_eq!(hw.brightness.get(), f64::from(0.4_f32));
        assert_eq!(read_record(tmp.path()).unwrap(), None);
    }

    #[test]
    fn a_live_owners_record_is_left_alone() {
        let tmp = tempfile::tempdir().unwrap();
        let record = DisplayRestoreRecord {
            pid: 777,
            display_id: 1,
            brightness: 0.4,
        };
        write_record(tmp.path(), &record, false).unwrap();
        let hw = Hardware::new();
        let _r = rig_with(tmp.path(), hw.clone(), |_| true, 4242);
        assert!(hw.calls().is_empty());
        assert_eq!(read_record(tmp.path()).unwrap(), Some(record));
    }

    #[test]
    fn a_failed_recovery_keeps_the_record_for_the_next_start() {
        let tmp = tempfile::tempdir().unwrap();
        let record = DisplayRestoreRecord {
            pid: 777,
            display_id: 1,
            brightness: 0.4,
        };
        write_record(tmp.path(), &record, false).unwrap();
        let hw = Hardware::new();
        hw.fail_brightness_set.set(true);
        let _r = rig_with(tmp.path(), hw, |_| false, 4242);
        assert_eq!(read_record(tmp.path()).unwrap(), Some(record));
        std::fs::write(tmp.path().join("display-restore.json"), "garbage").unwrap();
        let _r2 = rig_with(tmp.path(), Hardware::new(), |_| false, 4242);
        assert_eq!(
            read_record(tmp.path()).unwrap(),
            None,
            "garbage is discarded, not trusted"
        );
    }

    #[test]
    fn the_signal_path_restores_from_the_record_without_the_writer() {
        let tmp = tempfile::tempdir().unwrap();
        let r = rig(tmp.path());
        r.writer.apply_builtin_brightness(0.9).unwrap();
        let hw = Hardware::new();
        symcockpit_core::tune_write::restore_from_record(tmp.path(), &Sink(hw.clone()), &|_| true)
            .unwrap();
        assert_eq!(hw.calls(), ["brightness 1 0.5"]);
        assert_eq!(read_record(tmp.path()).unwrap(), None);
        std::mem::forget(r.writer);
    }

    #[test]
    fn restore_runs_the_registered_smc_hook() {
        let tmp = tempfile::tempdir().unwrap();
        let r = rig(tmp.path());
        let hits = Rc::new(Cell::new(0));
        assert!(!r.writer.has_smc_restore());
        let h = hits.clone();
        r.writer
            .set_smc_restore(Box::new(move || h.set(h.get() + 1)));
        r.writer.restore_all();
        assert_eq!(hits.get(), 1);
        drop(r);
        assert_eq!(hits.get(), 2, "restore-on-exit covers the SMC too");
    }

    // ---- keep awake

    #[test]
    fn the_blocking_assertion_is_released_when_dropped() {
        let tmp = tempfile::tempdir().unwrap();
        let r = rig(tmp.path());
        let token = r.writer.begin_assertion("symcockpit awake", true).unwrap();
        assert_eq!(
            r.power.created.lock().unwrap().as_slice(),
            [(
                PowerAssertionType::PreventDisplaySleep,
                "symcockpit awake".to_owned()
            )]
        );
        drop(token);
        assert_eq!(r.power.released.lock().unwrap().as_slice(), [100]);
        *r.power.fail.lock().unwrap() = true;
        assert_eq!(
            r.writer.begin_assertion("x", false).err(),
            Some(Error::Failed(
                "Failed to create power assertion (IOReturn -1).".into()
            ))
        );
    }

    #[test]
    fn a_session_is_reported_and_ended_and_dropped_with_the_process() {
        let tmp = tempfile::tempdir().unwrap();
        let r = rig(tmp.path());
        assert!(!r.writer.keep_awake_active());
        let s = r
            .writer
            .begin_session(None, false, "symcockpit MCP keep_awake")
            .unwrap();
        assert!(s.active && r.writer.keep_awake_active());
        assert_eq!(r.writer.session_status(), s);
        assert!(!r.writer.end_session().active);
        assert!(!r.writer.keep_awake_active());
        r.writer.begin_session(Some(3600.0), true, "again").unwrap();
        let power = r.power.clone();
        drop(r);
        assert_eq!(
            power.released.lock().unwrap().len(),
            2,
            "both assertions released"
        );
    }

    // ---- profiles

    #[test]
    fn profiles_save_load_and_delete_round_trip_without_touching_other_files() {
        let tmp = tempfile::tempdir().unwrap();
        let r = rig(tmp.path());
        r.writer.apply_warmth(0.4).unwrap();
        r.writer.apply_dim(0.6).unwrap();
        r.writer.save_profile("evening").unwrap();
        let saved = &read_profiles(tmp.path())[0];
        assert_eq!(saved.name, "evening");
        assert_eq!(saved.brightness, Some(0.5));
        assert_eq!(saved.dim, Some(f64::from(0.6_f32)));
        assert_eq!(saved.warmth, Some(f64::from(0.4_f32)));
        assert_eq!(saved.version.as_deref(), Some("0.12.2"));

        r.writer.restore_all();
        assert_eq!(r.writer.dim_level(), 1.0);
        r.writer.load_profile("evening").unwrap();
        assert!((r.writer.dim_level() - 0.6).abs() < 1e-6);
        assert!((r.writer.warmth_level() - 0.4).abs() < 1e-6);

        r.writer.delete_profile("evening").unwrap();
        r.writer.delete_profile("evening").unwrap();
        assert!(read_profiles(tmp.path()).is_empty());
        let log: Vec<_> = actions(&r)
            .into_iter()
            .map(|(a, _)| a)
            .filter(|a| a.starts_with("profile"))
            .collect();
        assert_eq!(
            log,
            [
                "profile.save",
                "profile.load",
                "profile.delete",
                "profile.delete"
            ]
        );
    }

    #[test]
    fn profile_names_are_validated_with_the_swift_messages() {
        let tmp = tempfile::tempdir().unwrap();
        let r = rig(tmp.path());
        for bad in ["", "../x", "a/b", "a b", "a..b"] {
            assert_eq!(
                r.writer.save_profile(bad),
                Err(Error::Usage(format!(
                    "Invalid profile name: '{bad}'. Profile names may only contain letters, digits, hyphens, and underscores."
                )))
            );
            for result in [r.writer.load_profile(bad), r.writer.delete_profile(bad)] {
                assert_eq!(
                    result,
                    Err(Error::Usage(format!("Invalid profile name: '{bad}'.")))
                );
            }
        }
        assert!(
            r.history.borrow().is_empty(),
            "a rejected name logs nothing"
        );
        assert!(std::fs::read_dir(tmp.path()).unwrap().next().is_none());
    }

    #[test]
    fn loading_a_missing_profile_is_a_structured_non_tune_error() {
        let tmp = tempfile::tempdir().unwrap();
        let r = rig(tmp.path());
        let Err(Error::Failed(line)) = r.writer.load_profile("nope") else {
            panic!("expected a failure")
        };
        let report: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(report["error"], "NSError");
        assert_eq!(
            report["message"],
            "The file “profile-nope.json” couldn’t be opened because there is no such file."
        );
        assert_eq!(report["message"], report["localized"]);
    }

    #[test]
    fn loading_a_profile_applies_it_through_the_clamps() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(
            tmp.path().join("profile-wild.json"),
            "{\"name\":\"wild\",\"createdAt\":1,\"updatedAt\":1,\"brightness\":7,\"dim\":0.01,\"warmth\":3}",
        )
        .unwrap();
        let r = rig(tmp.path());
        r.writer.load_profile("wild").unwrap();
        assert_eq!(r.hw.brightness.get(), 1.0);
        assert!((r.writer.dim_level() - 0.15).abs() < 1e-6);
        assert!((r.writer.warmth_level() - 1.0).abs() < 1e-6);
    }
}
