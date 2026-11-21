//! Charge limit (mechanism by presence, read-back) and the restore record,
//! against fakes. Vectors: tuning/Tests/SymCockpitCoreTests/{ChargeLimitServiceTests,
//! SMCRestoreTrackerTests, SMCRestoreFileTests}.swift. S8 (macOS charge limit):
//! /Volumes/1TB_NVMe_SN850X/Dev/evidence/symaira-cockpit/cockpit2-spikes/S8/REPORT.md.

use std::os::unix::fs::PermissionsExt;

use symcockpit_contract::{Error, Outcome};
use symcockpit_core::charge_limit::{self, ChargeEnv, Mechanism, reconcile};
use symcockpit_core::fan::FanEnv;
use symcockpit_core::restore::RestoreTracker;
use symcockpit_core::sensors::ChargeLimitKeyFamily;
use symcockpit_store::Config;
use symcockpit_store::smc_restore::{self, FanOriginal, KeyFamily, Record};
use symcockpit_testkit::battery::FakeBatterySource;
use symcockpit_testkit::smc::{FakeHost, FakeSmc};
use symcockpit_testkit::smc_write::{FakeClock, FakePowerUi, FakeSmcRw, battery_on_ac};

struct Rig {
    smc: FakeSmcRw,
    clock: FakeClock,
    host: FakeHost,
    config: Config,
    battery: FakeBatterySource,
    mac: FakePowerUi,
    dir: tempfile::TempDir,
}

impl Rig {
    fn new(smc: FakeSmcRw, mac: FakePowerUi) -> Self {
        Self {
            smc,
            clock: FakeClock::default(),
            host: FakeHost::default(),
            config: Config::default(),
            battery: battery_on_ac(true),
            mac,
            dir: tempfile::tempdir().unwrap(),
        }
    }

    fn fan_env(&self) -> FanEnv<'_> {
        FanEnv {
            smc: &self.smc,
            writer: &self.smc,
            host: &self.host,
            config: &self.config,
            clock: &self.clock,
        }
    }

    fn tracker(&self) -> RestoreTracker {
        RestoreTracker::new(&self.dir.path().join("data"), None)
    }

    fn with<R>(&self, with_mac: bool, f: impl FnOnce(&ChargeEnv) -> R) -> R {
        let fan = self.fan_env();
        f(&ChargeEnv {
            fan: &fan,
            mac: with_mac.then_some(&self.mac as &dyn charge_limit::MacChargeLimit),
            battery: &self.battery,
            config: &self.config,
        })
    }
}

fn chte(inhibit: bool) -> FakeSmcRw {
    FakeSmcRw::m4_pro_like().with_chte(inhibit)
}

fn plain() -> FakeSmcRw {
    FakeSmcRw::m4_pro_like()
}

// -- the mechanism follows presence -------------------------------------------------

#[test]
fn the_mechanism_is_chosen_by_what_is_present_not_by_version() {
    let ui = || FakePowerUi::new(true);
    let pick = |smc: FakeSmcRw, mac: FakePowerUi, with_mac: bool| {
        let rig = Rig::new(smc, mac);
        rig.with(with_mac, |e| charge_limit::select(e.fan, e.mac))
    };
    // (a) an SMC key wins even when the macOS limit exists too.
    assert_eq!(
        pick(chte(false), ui(), true),
        Mechanism::Smc(ChargeLimitKeyFamily::Chte)
    );
    assert_eq!(
        pick(plain().with_ch0b(0), ui(), true),
        Mechanism::Smc(ChargeLimitKeyFamily::Ch0b)
    );
    // (b) no key, the macOS limit is supported.
    assert_eq!(pick(plain(), ui(), true), Mechanism::MacOs);
    // (c) neither.
    let m = pick(plain(), FakePowerUi::new(false), true);
    assert!(
        matches!(&m, Mechanism::Unsupported(d) if d.contains("Charge Limit")),
        "{m:?}"
    );
    assert!(
        matches!(pick(plain(), ui(), false), Mechanism::Unsupported(_)),
        "no PowerUI client at all"
    );
    // An unreachable SMC does not stop the macOS limit.
    assert_eq!(
        pick(FakeSmcRw::new(FakeSmc::closed()), ui(), true),
        Mechanism::MacOs
    );
    assert_eq!(pick(plain(), ui(), true).name(), "macos");
}

// -- SMC path -----------------------------------------------------------------

#[test]
fn smc_set_inhibits_with_chte_big_endian_and_reads_back() {
    let rig = Rig::new(chte(false), FakePowerUi::new(false));
    let mut tracker = rig.tracker();
    let result = rig
        .with(false, |e| charge_limit::set(e, &mut tracker, 80))
        .unwrap();
    assert_eq!(result.outcome, Outcome::Confirmed);
    let w = rig.smc.writes();
    assert_eq!(
        (w[0].key.as_str(), w[0].bytes.clone()),
        ("CHTE", vec![0, 0, 0, 1])
    );
    assert_eq!(w[0].data_type, *b"ui32");
}

#[test]
fn the_restore_record_exists_before_the_first_charge_write() {
    let rig = Rig::new(chte(false), FakePowerUi::new(false));
    let mut tracker = rig.tracker();
    // A failing write leaves the record behind: it was written first.
    rig.smc.reject_writes_to("CHTE");
    let err = rig
        .with(false, |e| charge_limit::set(e, &mut tracker, 80))
        .unwrap_err();
    assert_eq!(err.exit_code(), 1);
    assert!(
        err.to_string().contains("ChargeLimitError error 2"),
        "{err}"
    );
    let read = smc_restore::read(&rig.dir.path().join("data"))
        .unwrap()
        .unwrap();
    assert_eq!(read.charge_key_family, Some(KeyFamily::Chte));
    assert_eq!(read.charge_inhibit, Some(false));
    assert!(rig.smc.writes().is_empty());
}

#[test]
fn set_reports_unconfirmed_when_the_read_back_differs() {
    let rig = Rig::new(chte(false), FakePowerUi::new(false));
    rig.smc.forget_writes_to("CHTE"); // accepted, not kept
    let r = rig
        .with(false, |e| charge_limit::set(e, &mut rig.tracker(), 80))
        .unwrap();
    assert_eq!(r.outcome, Outcome::Unconfirmed);
    assert!(r.detail.as_deref().unwrap().contains("reads back inhibit"));
    assert_eq!(r.into_result().unwrap_err().exit_code(), 1);
}

#[test]
fn set_needs_ac_power_and_a_key() {
    let mut rig = Rig::new(chte(false), FakePowerUi::new(false));
    rig.battery = battery_on_ac(false);
    let err = rig
        .with(false, |e| charge_limit::set(e, &mut rig.tracker(), 80))
        .unwrap_err();
    assert_eq!(
        err,
        Error::Permission("charge limit requires AC power and SMC write access".into())
    );
    assert!(rig.smc.writes().is_empty());
    assert!(
        !rig.dir.path().join("data").exists(),
        "refused before anything is saved"
    );

    // No key anywhere: a hardware limit (#420), exit 4, nothing written or saved.
    let rig = Rig::new(plain(), FakePowerUi::new(false));
    let err = rig
        .with(false, |e| charge_limit::set(e, &mut rig.tracker(), 80))
        .unwrap_err();
    assert_eq!(err.exit_code(), 4);
    assert!(err.to_string().contains("macOS 27"));
    assert!(rig.smc.writes().is_empty());
}

#[test]
fn ch0b_writes_both_keys_and_clear_writes_the_detected_family() {
    let rig = Rig::new(plain().with_ch0b(0), FakePowerUi::new(false));
    let mut t = rig.tracker();
    let r = rig
        .with(false, |e| charge_limit::set(e, &mut t, 80))
        .unwrap();
    assert_eq!(r.outcome, Outcome::Confirmed);
    assert_eq!(
        (rig.smc.get_ui8("CH0B"), rig.smc.get_ui8("CH0C")),
        (Some(2), Some(2))
    );
    let r = rig.with(false, charge_limit::clear).unwrap();
    assert_eq!(r.outcome, Outcome::Confirmed);
    assert_eq!(
        (rig.smc.get_ui8("CH0B"), rig.smc.get_ui8("CH0C")),
        (Some(0), Some(0))
    );
}

#[test]
fn clear_failures_and_unconfirmed() {
    let rig = Rig::new(chte(true), FakePowerUi::new(false));
    rig.smc.reject_writes_to("CHTE");
    let err = rig.with(false, charge_limit::clear).unwrap_err();
    assert!(
        err.to_string().contains("ChargeLimitError error 3"),
        "{err}"
    );
    let rig = Rig::new(chte(true), FakePowerUi::new(false));
    rig.smc.forget_writes_to("CHTE");
    assert_eq!(
        rig.with(false, charge_limit::clear).unwrap().outcome,
        Outcome::Unconfirmed
    );
    let rig = Rig::new(chte(true), FakePowerUi::new(false));
    assert_eq!(
        rig.with(false, charge_limit::clear).unwrap().outcome,
        Outcome::Confirmed
    );
    assert_eq!(rig.smc.get("CHTE").unwrap().bytes, [0, 0, 0, 0]);
}

#[test]
fn the_percent_is_clamped_by_the_configured_range_not_trusted() {
    // Clamping changes nothing on the SMC path (it inhibits), but the macOS
    // limit shows it: 20 % clamps to 50 %, which that path then refuses.
    let rig = Rig::new(plain(), FakePowerUi::new(true));
    let r = rig
        .with(true, |e| charge_limit::set(e, &mut rig.tracker(), 20))
        .unwrap();
    assert_eq!(r.outcome, Outcome::Unsupported);
    assert!(
        rig.mac.calls().is_empty(),
        "nothing is sent to PowerUI below 80"
    );
}

// -- macOS path (fake PowerUI; the real setters are unproven, S8 write test pending) ----

#[test]
fn macos_limit_enables_sets_and_reads_back() {
    let rig = Rig::new(plain(), FakePowerUi::new(true));
    let r = rig
        .with(true, |e| charge_limit::set(e, &mut rig.tracker(), 85))
        .unwrap();
    assert_eq!(r.outcome, Outcome::Confirmed);
    assert_eq!(rig.mac.calls(), ["enable", "set_limit 85"]);
    assert_eq!(rig.mac.state(), (true, 85));
    assert!(rig.smc.writes().is_empty(), "no SMC write on this path");
    assert!(
        !rig.dir.path().join("data").exists(),
        "no root restore record for the user-level limit"
    );

    let r = rig.with(true, charge_limit::clear).unwrap();
    assert_eq!(r.outcome, Outcome::Confirmed);
    assert!(!rig.mac.state().0);
}

#[test]
fn macos_limit_boundaries_and_failures() {
    for (pct, want) in [
        (80, Outcome::Confirmed),
        (100, Outcome::Confirmed),
        (79, Outcome::Unsupported),
    ] {
        let rig = Rig::new(plain(), FakePowerUi::new(true));
        let r = rig
            .with(true, |e| charge_limit::set(e, &mut rig.tracker(), pct))
            .unwrap();
        assert_eq!(r.outcome, want, "{pct}");
    }
    // The setter returned success but the limit did not change: unconfirmed (Q01).
    let rig = Rig::new(plain(), FakePowerUi::new(true).ignoring_set_limit());
    let r = rig
        .with(true, |e| charge_limit::set(e, &mut rig.tracker(), 85))
        .unwrap();
    assert_eq!(r.outcome, Outcome::Unconfirmed);
    assert!(r.detail.unwrap().contains("limit = Some(100)"));
    // An error from the client is a failure, nothing is claimed.
    let rig = Rig::new(plain(), FakePowerUi::new(true).failing_enable());
    let err = rig
        .with(true, |e| charge_limit::set(e, &mut rig.tracker(), 85))
        .unwrap_err();
    assert!(matches!(err, Error::Failed(m) if m.contains("code=4")));
    assert_eq!(
        rig.mac.calls(),
        ["enable"],
        "set_limit is not tried after a failed enable"
    );
}

#[test]
fn unsupported_everywhere_is_exit_4() {
    let rig = Rig::new(plain(), FakePowerUi::new(false));
    assert_eq!(
        rig.with(true, charge_limit::clear).unwrap_err().exit_code(),
        4
    );
}

// -- hysteresis (long-lived process) ----------------------------------------------------

#[test]
fn reconcile_reasserts_after_wake_and_releases_below_the_band() {
    let rig = Rig::new(chte(false), FakePowerUi::new(false));
    // At or above the target and not inhibited (lapsed on wake): re-assert.
    assert!(rig.with(false, |e| reconcile(e, 80, Some(80))));
    assert_eq!(rig.smc.get("CHTE").unwrap().bytes, [0, 0, 0, 1]);
    // Inside the band (75..80): keep the state.
    assert!(!rig.with(false, |e| reconcile(e, 80, Some(77))));
    // At 75 (target - hysteresis 5): release.
    assert!(rig.with(false, |e| reconcile(e, 80, Some(75))));
    assert_eq!(rig.smc.get("CHTE").unwrap().bytes, [0, 0, 0, 0]);
    // No reading: nothing.
    assert!(!rig.with(false, |e| reconcile(e, 80, None)));
}

// -- restore record ------------------------------------------------------------------------

fn fan_rig(mode: u8, target: f32) -> Rig {
    let smc = FakeSmcRw::new(
        FakeSmc::new(true)
            .with_ui8("FNum", 1)
            .with_ui8("F0Md", mode)
            .with_flt("F0Tg", target)
            .with_flt("F0Mn", 2000.0)
            .with_flt("F0Mx", 8000.0)
            .with_ui8("Ftst", 0),
    );
    Rig::new(smc, FakePowerUi::new(false))
}

#[test]
fn the_fan_original_is_persisted_0600_before_anything_changes() {
    let rig = fan_rig(1, 2500.0);
    let mut t = rig.tracker();
    t.save_fan_original(&rig.fan_env(), 0);
    let path = t.record_path();
    assert_eq!(
        std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    let record = smc_restore::read(&rig.dir.path().join("data"))
        .unwrap()
        .unwrap();
    assert_eq!(
        record,
        Record {
            version: 1,
            architecture: "arm64".into(),
            charge_key_family: None,
            fan_originals: vec![FanOriginal {
                fan_index: 0,
                mode: 1,
                target_rpm: 2500.0
            }],
            fs_bitmask: None,
            charge_inhibit: None,
        }
    );
    assert!(rig.smc.writes().is_empty());
}

#[test]
fn restore_all_writes_the_original_mode_and_target_and_clears_the_trail() {
    let rig = fan_rig(1, 2500.0);
    let mut t = rig.tracker();
    t.save_fan_original(&rig.fan_env(), 0);
    rig.smc.set_ui8("F0Md", 1);
    rig.smc.set_flt("F0Tg", 6000.0);
    rig.smc.set_ui8("Ftst", 1);
    t.restore_all(&rig.fan_env());
    assert_eq!(
        rig.smc.get_flt("F0Tg"),
        Some(2500.0),
        "target restored for a forced original"
    );
    assert_eq!(rig.smc.get_ui8("F0Md"), Some(1));
    assert_eq!(rig.smc.get_ui8("Ftst"), Some(0));
    assert!(!t.record_path().exists());

    // Original mode 0 (firmware): only the mode goes back, no target write.
    let rig = fan_rig(0, 2100.0);
    let mut t = rig.tracker();
    t.save_fan_original(&rig.fan_env(), 0);
    t.restore_all(&rig.fan_env());
    assert_eq!(rig.smc.written_keys(), ["F0Md", "Ftst"]);
}

#[test]
fn restore_all_without_a_save_is_a_no_op() {
    let rig = fan_rig(0, 2000.0);
    let mut t = rig.tracker();
    t.restore_all(&rig.fan_env());
    assert!(rig.smc.writes().is_empty());
}

#[test]
fn a_leftover_charge_record_is_applied_at_the_next_start_and_removed() {
    // A killed process: the inhibit was off when captured, the hardware is still inhibited.
    let rig = Rig::new(chte(true), FakePowerUi::new(false));
    let dir = rig.dir.path().join("data");
    smc_restore::write(
        &dir,
        &Record {
            version: 1,
            architecture: "arm64".into(),
            charge_key_family: Some(KeyFamily::Chte),
            fan_originals: vec![],
            fs_bitmask: None,
            charge_inhibit: Some(false),
        },
        None,
    )
    .unwrap();
    let out = rig.tracker().consume_persisted(&rig.fan_env());
    assert!(out.applied && out.warnings.is_empty());
    assert_eq!(rig.smc.get("CHTE").unwrap().bytes, [0, 0, 0, 0]);
    assert!(smc_restore::read(&dir).is_none());
}

#[test]
fn leftovers_that_cannot_be_trusted_are_discarded_without_a_write() {
    let rig = Rig::new(chte(true), FakePowerUi::new(false));
    let dir = rig.dir.path().join("data");
    std::fs::create_dir_all(&dir).unwrap();
    // Corrupt.
    std::fs::write(smc_restore::path_in(&dir), b"{nope").unwrap();
    let out = rig.tracker().consume_persisted(&rig.fan_env());
    assert_eq!(out.warnings, ["discarding unreadable SMC restore file"]);
    assert!(!out.applied && smc_restore::read(&dir).is_none());
    // Another architecture.
    let mut stale = Record {
        version: 1,
        architecture: "x86_64".into(),
        charge_key_family: Some(KeyFamily::Chte),
        fan_originals: vec![],
        fs_bitmask: None,
        charge_inhibit: Some(false),
    };
    smc_restore::write(&dir, &stale, None).unwrap();
    let out = rig.tracker().consume_persisted(&rig.fan_env());
    assert_eq!(
        out.warnings,
        ["ignoring stale SMC restore file (architecture/version mismatch)"]
    );
    // A key family this Mac no longer has: the fans part applies, the charge part is skipped.
    stale.architecture = "arm64".into();
    stale.charge_key_family = Some(KeyFamily::Ch0b);
    smc_restore::write(&dir, &stale, None).unwrap();
    let out = rig.tracker().consume_persisted(&rig.fan_env());
    assert_eq!(
        out.warnings,
        ["skipping SMC charge restore (recorded key family no longer matches)"]
    );
    assert!(rig.smc.writes().is_empty());
    assert!(smc_restore::read(&dir).is_none());
}

#[test]
fn nothing_is_consumed_without_a_reachable_smc() {
    let rig = Rig::new(FakeSmcRw::new(FakeSmc::closed()), FakePowerUi::new(false));
    let dir = rig.dir.path().join("data");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(smc_restore::path_in(&dir), b"{nope").unwrap();
    assert!(!rig.tracker().consume_persisted(&rig.fan_env()).applied);
    assert!(
        smc_restore::path_in(&dir).exists(),
        "the file stays for a start that can use it"
    );
}
