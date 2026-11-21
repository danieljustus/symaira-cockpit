//! Fan write path against a fake SMC (no hardware). Vectors:
//! tuning/Tests/SymCockpitCoreTests/{FanControlServiceTests, SMCWritePolicyTests,
//! FanGovernorTests, FanProfileTests, FanCoolTargetTests}.swift

use symcockpit_contract::Error;
use symcockpit_core::fan::*;
use symcockpit_core::governor::{self, Governor, Tick};
use symcockpit_core::sensors::{FanProfile, FanSelection, SensorReading, SensorReport};
use symcockpit_store::Config;
use symcockpit_testkit::smc::{FakeHost, FakeSmc};
use symcockpit_testkit::smc_write::{FakeClock, FakeSmcRw};

struct Rig {
    smc: FakeSmcRw,
    clock: FakeClock,
    host: FakeHost,
    config: Config,
}

impl Rig {
    /// One fan: firmware mode `mode`, target `target_rpm`, min 2000, max 8000, die `die`.
    fn new(die: f64, target_rpm: f32, mode: u8) -> Self {
        let smc = FakeSmc::new(true)
            .with_ui8("FNum", 1)
            .with_ui8("F0Md", mode)
            .with_flt("F0Ac", target_rpm)
            .with_flt("F0Tg", target_rpm)
            .with_flt("F0Mn", 2000.0)
            .with_flt("F0Mx", 8000.0)
            .with_flt("TCMz", die as f32)
            .with_ui8("Ftst", 0);
        Self {
            smc: FakeSmcRw::new(smc),
            clock: FakeClock::default(),
            host: FakeHost::default(),
            config: Config::default(),
        }
    }

    fn env(&self) -> FanEnv<'_> {
        FanEnv {
            smc: &self.smc,
            writer: &self.smc,
            host: &self.host,
            config: &self.config,
            clock: &self.clock,
        }
    }
}

// -- write policy ------------------------------------------------------------

#[test]
fn clamp_floors_at_the_soft_fan_floor() {
    assert_eq!(clamp_fan_fraction(0.0, 0.0, 1.0), FAN_SPEED_FLOOR);
    assert_eq!(clamp_fan_fraction(2.0, 0.0, 1.0), 1.0);
    assert_eq!(clamp_fan_fraction(0.5, 0.0, 1.0), 0.5);
    assert_eq!(clamp_fan_fraction(0.5, 0.6, 1.0), 0.6);
}

#[test]
fn target_rpm_is_floored_at_the_firmware_minimum() {
    let rig = Rig::new(50.0, 3000.0, 0);
    let env = rig.env();
    assert_eq!(target_rpm(&env, 0.5, 0).unwrap(), 4000.0);
    assert_eq!(
        target_rpm(&env, 0.15, 0).unwrap(),
        2000.0,
        "1200 rpm is below F0Mn"
    );
    assert_eq!(
        target_rpm(&env, 1.0, 1),
        Err(FanError::MaxRpmUnavailable(1))
    );
}

#[test]
fn set_fan_unlocks_switches_to_manual_and_writes_the_target() {
    let rig = Rig::new(50.0, 3000.0, 0);
    apply_fan(&rig.env(), 0.5).unwrap();
    assert_eq!(rig.smc.written_keys(), ["Ftst", "F0Md", "F0Tg"]);
    assert_eq!(rig.smc.get_ui8("Ftst"), Some(1));
    assert_eq!(rig.smc.get_ui8("F0Md"), Some(1));
    assert_eq!(rig.smc.get_flt("F0Tg"), Some(4000.0));
}

#[test]
fn set_fan_refusals() {
    // An unreachable SMC: the text of `FanControlService.applyFan`.
    let closed = FakeSmcRw::new(FakeSmc::closed());
    let (clock, host, config) = (FakeClock::default(), FakeHost::default(), Config::default());
    let env = FanEnv {
        smc: &closed,
        writer: &closed,
        host: &host,
        config: &config,
        clock: &clock,
    };
    assert_eq!(apply_fan(&env, 0.5), Err(FanError::NotAvailable));
    assert_eq!(
        apply_fan(&env, f64::NAN),
        Err(FanError::Usage("Value must be finite.".into()))
    );
    // No fans: a fanless Mac.
    let rig = Rig::new(50.0, 3000.0, 0);
    rig.smc.set_ui8("FNum", 0);
    assert_eq!(apply_fan(&rig.env(), 0.5), Err(FanError::NoFans));
    assert!(rig.smc.writes().is_empty());
}

#[test]
fn thermal_gate_refuses_a_slowdown_but_never_a_speedup() {
    // Hot die, fans asked for 5000 rpm: 0.5 (= 4000) would slow them down.
    let rig = Rig::new(95.0, 5000.0, 1);
    assert_eq!(
        apply_fan(&rig.env(), 0.5),
        Err(FanError::ThermalEmergency(95.0))
    );
    assert!(
        rig.smc.writes().is_empty(),
        "nothing is written when refused"
    );
    // 1.0 (= 8000) asks for more air than the 5000 already requested: allowed.
    apply_fan(&rig.env(), 1.0).unwrap();
    assert_eq!(rig.smc.get_flt("F0Tg"), Some(8000.0));
    // Without a live target to compare against, the write stays gated.
    let no_target = FakeSmc::new(true)
        .with_ui8("FNum", 1)
        .with_ui8("F0Md", 1)
        .with_flt("F0Mn", 2000.0)
        .with_flt("F0Mx", 8000.0)
        .with_flt("TCMz", 95.0)
        .with_ui8("Ftst", 0);
    let rig = Rig {
        smc: FakeSmcRw::new(no_target),
        ..Rig::new(95.0, 5000.0, 1)
    };
    assert_eq!(
        apply_fan(&rig.env(), 1.0),
        Err(FanError::ThermalEmergency(95.0))
    );
    assert!(rig.smc.writes().is_empty());
}

#[test]
fn a_cool_mac_is_not_gated() {
    let rig = Rig::new(89.9, 5000.0, 1);
    apply_fan(&rig.env(), 0.5).unwrap();
}

#[test]
fn manual_mode_is_retried_with_backoff_and_then_refused() {
    let rig = Rig::new(50.0, 3000.0, 0);
    rig.smc.reject_writes_to("F0Md");
    assert_eq!(apply_fan(&rig.env(), 0.5), Err(FanError::ModeRejected(0)));
    // 10 attempts, 9 pauses: 50, 100, then 200 ms capped.
    assert_eq!(
        symcockpit_core::clock::Monotonic::now_ms(&rig.clock),
        50 + 100 + 7 * 200
    );
    let md = rig
        .smc
        .written_keys()
        .iter()
        .filter(|k| *k == "F0Md")
        .count();
    assert_eq!(md, 0, "rejected writes are not recorded");
}

#[test]
fn a_rejected_target_write_is_reported() {
    let rig = Rig::new(50.0, 3000.0, 0);
    rig.smc.reject_writes_to("F0Tg");
    assert_eq!(
        apply_fan(&rig.env(), 0.5),
        Err(FanError::TargetWriteFailed(0))
    );
}

#[test]
fn restore_auto_clears_mode_and_unlock_and_tries_every_key() {
    let rig = Rig::new(50.0, 3000.0, 1);
    rig.smc.set_ui8("Ftst", 1);
    restore_auto(&rig.env()).unwrap();
    assert_eq!(rig.smc.get_ui8("F0Md"), Some(APPLE_SILICON_AUTO_MODE));
    assert_eq!(rig.smc.get_ui8("Ftst"), Some(0));
    assert!(!has_software_override(&rig.env()));

    let rig = Rig::new(50.0, 3000.0, 1);
    rig.smc.set_ui8("Ftst", 1);
    rig.smc.reject_writes_to("F0Md");
    assert_eq!(
        restore_auto(&rig.env()),
        Err(FanError::RestoreWriteFailed("F0Md".into()))
    );
    assert_eq!(
        rig.smc.get_ui8("Ftst"),
        Some(0),
        "every key is tried after one fails"
    );
    rig.smc.set_ui8("FNum", 0);
    assert_eq!(restore_auto(&rig.env()), Err(FanError::NoFans));
}

#[test]
fn override_detection() {
    let rig = Rig::new(50.0, 3000.0, 0);
    assert!(!has_software_override(&rig.env()));
    rig.smc.set_ui8("Ftst", 1);
    assert!(has_software_override(&rig.env()));
    rig.smc.set_ui8("Ftst", 0);
    rig.smc.set_ui8("F0Md", 1);
    assert!(has_software_override(&rig.env()));
}

#[test]
fn errors_map_to_the_swift_texts_and_exit_codes() {
    let cases: [(FanError, bool, &str, u8); 9] = [
        (
            FanError::NotAvailable,
            true,
            "permission error: SMC not available — fan control requires a real Mac",
            3,
        ),
        (
            FanError::NoFans,
            true,
            "unsupported: SMC reports no fans; fan control is unavailable",
            4,
        ),
        (
            FanError::ModeRejected(1),
            false,
            "permission error: SMC rejected manual mode for fan 1; run with sudo",
            3,
        ),
        (
            FanError::TargetWriteFailed(0),
            true,
            "permission error: SMC rejected target RPM for fan 0",
            3,
        ),
        (
            FanError::RestoreWriteFailed("F0Md".into()),
            true,
            "SMC rejected F0Md while returning the fans to firmware control; they may still be forced",
            1,
        ),
        (
            FanError::RestoreWriteFailed("F0Md".into()),
            false,
            "permission error: returning the fans to firmware control needs root (SMC rejected F0Md); run with sudo",
            3,
        ),
        (
            FanError::ThermalEmergency(91.5),
            true,
            "permission error: thermal emergency at 91.5°C; refusing write",
            3,
        ),
        (
            FanError::ThermalEmergency(95.0),
            true,
            "permission error: thermal emergency at 95.0°C; refusing write",
            3,
        ),
        (
            FanError::MaxRpmUnavailable(2),
            true,
            "unsupported: SMC did not report maximum RPM for fan 2",
            4,
        ),
    ];
    for (error, root, text, code) in cases {
        let e: Error = error.into_error(root);
        assert_eq!((e.to_string().as_str(), e.exit_code()), (text, code));
    }
}

// -- curves and the control law ----------------------------------------------

fn report(temps: &[(&str, f64)]) -> SensorReport {
    SensorReport {
        thermal_pressure: "nominal".into(),
        smc_supported: true,
        temperatures: temps
            .iter()
            .map(|(k, c)| SensorReading {
                key: (*k).into(),
                label: (*k).into(),
                celsius: *c,
            })
            .collect(),
        fans: vec![],
        notes: vec![],
    }
}

#[test]
fn profiles_are_temperature_dependent_and_the_right_one_is_more_aggressive() {
    assert!(profile_curve(FanProfile::System).is_none());
    let comfort = profile_curve(FanProfile::Comfort).unwrap();
    let performance = profile_curve(FanProfile::Performance).unwrap();
    for c in (30..=95).map(f64::from) {
        assert!(
            performance.fraction(c) >= comfort.fraction(c) - 1e-12,
            "{c}"
        );
    }
    // Never a constant speed: idle is quiet, a hot die is flat out.
    for curve in [&comfort, &performance] {
        assert!(curve.fraction(30.0) < 0.4);
        assert_eq!(curve.fraction(95.0), 1.0);
        assert!(curve.fraction(50.0) < curve.fraction(70.0));
    }
    assert_eq!(comfort.fraction(65.0), 0.60);
    assert!((comfort.fraction(70.0) - 0.69).abs() < 1e-12);
}

#[test]
fn governing_temperature_prefers_die_sensors() {
    assert_eq!(
        governing_temperature(&report(&[("TCMz", 60.0), ("Ta0P", 90.0)])),
        Some(60.0)
    );
    assert_eq!(
        governing_temperature(&report(&[("TCMz", 60.0), ("TRDX", 70.0)])),
        Some(70.0)
    );
    assert_eq!(
        governing_temperature(&report(&[("Ta0P", 40.0), ("Tp01", 45.0)])),
        Some(45.0)
    );
    assert_eq!(governing_temperature(&report(&[])), None);
}

#[test]
fn cool_target_curve_reaches_full_speed_at_the_target() {
    let c = cool_target_curve(70.0);
    assert_eq!(c.fraction(70.0), 1.0);
    assert_eq!(c.fraction(30.0), 0.30);
    assert_eq!(
        cool_target_curve(85.0),
        profile_curve(FanProfile::Comfort).unwrap()
    );
    assert_eq!(cool_target_curve(f64::NAN), cool_target_curve(85.0));
    assert_eq!(cool_target_curve(10.0), cool_target_curve(50.0));
}

#[test]
fn a_target_never_reduces_cooling_and_only_cool_uses_it() {
    let base = target_fraction(FanProfile::Comfort, Some(50.0), None, None).unwrap();
    let hot_cluster =
        target_fraction(FanProfile::Comfort, Some(50.0), Some(60.0), Some(70.0)).unwrap();
    assert!(hot_cluster > base);
    assert_eq!(hot_cluster, 1.0);
    // A cool cluster adds nothing; a missing average is today's curve.
    assert_eq!(
        target_fraction(FanProfile::Comfort, Some(50.0), Some(60.0), Some(10.0)),
        Some(base)
    );
    assert_eq!(
        target_fraction(FanProfile::Comfort, Some(50.0), Some(60.0), None),
        Some(base)
    );
    // Max ignores it; System has no fraction.
    let perf = target_fraction(FanProfile::Performance, Some(50.0), None, None);
    assert_eq!(
        target_fraction(FanProfile::Performance, Some(50.0), Some(60.0), Some(70.0)),
        perf
    );
    assert_eq!(
        target_fraction(FanProfile::System, Some(90.0), Some(60.0), Some(90.0)),
        None
    );
}

// -- governor decisions ---------------------------------------------------------

fn sel(p: FanProfile) -> FanSelection {
    FanSelection::new(p, None)
}

#[test]
fn next_fraction_vectors() {
    use governor::*;
    let comfort = profile_curve(FanProfile::Comfort).unwrap();
    assert_eq!(
        next_fraction_for_profile(FanProfile::System, Some(95.0), None),
        None
    );
    assert_eq!(
        next_fraction_for_profile(FanProfile::System, Some(95.0), Some(0.4)),
        None
    );
    assert_eq!(
        next_fraction_for_profile(FanProfile::Comfort, Some(75.0), None),
        Some(comfort.fraction(75.0))
    );
    // Up at once, down at a bounded rate.
    assert_eq!(
        next_fraction_for_profile(FanProfile::Comfort, Some(85.0), Some(0.30)),
        Some(1.0)
    );
    let down = next_fraction_for_profile(FanProfile::Comfort, Some(40.0), Some(1.0)).unwrap();
    assert!((down - (1.0 - MAX_DECREASE_PER_TICK)).abs() < 1e-12);
    // Never overshoots the target on the way down.
    let target = comfort.fraction(74.0);
    let landed = next_fraction_for_profile(
        FanProfile::Comfort,
        Some(74.0),
        Some(target + MAX_DECREASE_PER_TICK / 2.0),
    )
    .unwrap();
    assert!((landed - target).abs() < 1e-12);
    // Inside the deadband nothing is written.
    assert_eq!(
        next_fraction_for_profile(
            FanProfile::Comfort,
            Some(65.0),
            Some(comfort.fraction(65.0))
        ),
        None
    );
    // No reading is not "cold".
    assert_eq!(
        next_fraction_for_profile(FanProfile::Performance, None, Some(0.8)),
        Some(0.8)
    );
    assert_eq!(
        next_fraction_for_profile(FanProfile::Performance, None, None),
        None
    );
    // The Cool target feeds the same logic; Max and System ignore it.
    let with_target = FanSelection::new(FanProfile::Comfort, Some(60.0));
    assert_eq!(
        next_fraction(&with_target, Some(50.0), Some(70.0), Some(0.3)),
        Some(1.0)
    );
    let max = FanSelection::new(FanProfile::Performance, Some(60.0));
    assert_eq!(
        next_fraction(&max, Some(50.0), Some(70.0), None),
        next_fraction_for_profile(FanProfile::Performance, Some(50.0), None)
    );
}

// -- governor loop ----------------------------------------------------------------

fn run_ticks(
    rig: &Rig,
    profile: impl Fn(usize) -> FanProfile,
    ticks: usize,
    mut on_tick: impl FnMut(usize),
) -> Result<usize, FanError> {
    let count = std::cell::Cell::new(0usize);
    let result = governor::run(
        &rig.env(),
        &|| sel(profile(count.get())),
        &|| count.get() < ticks,
        &mut |_, _| {
            count.set(count.get() + 1);
            on_tick(count.get());
        },
    );
    result.map(|()| count.get())
}

#[test]
fn loop_exits_when_the_profile_returns_to_system() {
    let rig = Rig::new(85.0, 2000.0, 1);
    let n = run_ticks(
        &rig,
        |t| {
            if t < 3 {
                FanProfile::Comfort
            } else {
                FanProfile::System
            }
        },
        20,
        |_| {},
    )
    .unwrap();
    assert_eq!(n, 3);
}

#[test]
fn loop_writes_the_target_and_restores_the_original_on_exit() {
    let rig = Rig::new(85.0, 2500.0, 1);
    run_ticks(&rig, |_| FanProfile::Performance, 2, |_| {}).unwrap();
    let writes = rig.smc.writes();
    assert!(writes.iter().any(|w| w.key == "F0Tg"));
    // The last target written is the captured original; the mode is the captured one.
    assert_eq!(rig.smc.get_flt("F0Tg"), Some(2500.0));
    assert_eq!(rig.smc.get_ui8("F0Md"), Some(1));
    assert_eq!(
        rig.smc.get_ui8("Ftst"),
        Some(0),
        "no diagnostic unlock outlives the run"
    );
}

#[test]
fn the_system_position_writes_nothing() {
    let rig = Rig::new(85.0, 2000.0, 1);
    run_ticks(&rig, |_| FanProfile::System, 5, |_| {}).unwrap();
    assert!(rig.smc.writes().is_empty());
}

#[test]
fn a_short_temperature_gap_is_held_through() {
    let rig = Rig::new(85.0, 2000.0, 1);
    let die = rig.smc.get("TCMz").unwrap();
    let n = run_ticks(
        &rig,
        |_| FanProfile::Performance,
        6,
        |tick| {
            // Readings vanish for the ticks just short of the bound, then return.
            let missing = tick < governor::MAX_CONSECUTIVE_MISSING_TEMPERATURES as usize;
            if missing {
                rig.smc.set_raw("TCMz", b"ui8 ", &[0]); // 0 °C is implausible: not a reading
            } else {
                rig.smc.set_raw("TCMz", &die.data_type, &die.bytes);
            }
        },
    )
    .unwrap();
    assert_eq!(n, 6);
}

#[test]
fn a_lasting_temperature_gap_hands_the_fans_back() {
    let rig = Rig::new(85.0, 2500.0, 1);
    let err = run_ticks(
        &rig,
        |_| FanProfile::Performance,
        20,
        |_| {
            rig.smc.set_raw("TCMz", b"ui8 ", &[0]);
        },
    )
    .unwrap_err();
    assert!(
        matches!(&err, FanError::Failed(m) if m.contains("no die temperature")),
        "{err:?}"
    );
    assert_eq!(err.into_error(true).exit_code(), 1);
    assert_eq!(
        rig.smc.get_flt("F0Tg"),
        Some(2500.0),
        "restored to what was found"
    );
    assert_eq!(rig.smc.get_ui8("Ftst"), Some(0));
}

#[test]
fn the_firmware_taking_the_fans_back_is_noticed_and_reasserted() {
    // Firmware mode 3 at the start, so the restore on exit cannot pass for a re-assert.
    let rig = Rig::new(85.0, 2000.0, 3);
    run_ticks(
        &rig,
        |_| FanProfile::Performance,
        4,
        |tick| {
            if tick == 1 {
                rig.smc.set_ui8("F0Md", 3);
                rig.smc.clear_writes();
            }
        },
    )
    .unwrap();
    assert!(
        rig.smc
            .writes()
            .iter()
            .any(|w| w.key == "F0Md" && w.bytes == [1]),
        "the manual mode was written again"
    );
}

#[test]
fn a_state_that_will_not_hold_ends_the_governor() {
    let rig = Rig::new(85.0, 2500.0, 1);
    let n = std::cell::Cell::new(0usize);
    let err = governor::run(
        &rig.env(),
        &|| sel(FanProfile::Performance),
        &|| n.get() < 20,
        &mut |_, _| {
            n.set(n.get() + 1);
            if n.get() == 1 {
                // After the first tick the firmware ignores every target write.
                rig.smc.forget_writes_to("F0Tg");
                rig.smc.set_flt("F0Tg", 2000.0);
            }
        },
    )
    .unwrap_err();
    assert!(
        matches!(&err, FanError::Failed(m) if m.contains("did not hold")),
        "{err:?}"
    );
    assert_eq!(n.get(), governor::MAX_CONSECUTIVE_UNVERIFIED_TICKS as usize);
}

#[test]
fn a_governor_that_never_wrote_restores_nothing() {
    let rig = Rig::new(85.0, 2000.0, 1);
    let mut g = Governor::default();
    assert_eq!(g.tick(&rig.env(), &sel(FanProfile::System)), Ok(Tick::Stop));
    g.finish(&rig.env());
    assert!(rig.smc.writes().is_empty());
    assert!(!g.has_overridden());
}

#[test]
fn the_cool_target_raises_the_fans_for_a_hot_cluster_under_a_cool_die() {
    // Die 50 °C, cluster rows 70 °C: with a 60 °C target the fans run flat out.
    let rig = Rig::new(50.0, 2000.0, 1);
    for k in ["Tp01", "Tp02", "Tp03"] {
        rig.smc.set_flt(k, 70.0);
    }
    let selection = FanSelection::new(FanProfile::Comfort, Some(60.0));
    let mut g = Governor::default();
    // Cluster rows count only when the chip table lists them: M4 does.
    let tick = g.tick(&rig.env(), &selection).unwrap();
    let plain = Governor::default()
        .tick(&rig.env(), &sel(FanProfile::Comfort))
        .unwrap();
    let (
        Tick::Ran {
            applied: Some(with),
            ..
        },
        Tick::Ran {
            applied: Some(without),
            ..
        },
    ) = (tick, plain)
    else {
        panic!("both ticks write");
    };
    assert!(with > without, "{with} vs {without}");
}
