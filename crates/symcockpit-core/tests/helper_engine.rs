//! The helper's engine against a fake SMC and a fake clock: requests, the
//! heartbeat dead-man rule (R20, the crash case of architecture §6.2), the
//! lease, the stale-override recovery and the charge limit. No hardware.
//! Swift references: FanHelperEngine, HeartbeatWatchdog, FanStaleOverrideRecovery,
//! FanHelperIdleMonitor (tuning/Sources/SymCockpitHelperKit) and their tests.

use symcockpit_core::helper_engine::{Engine, StopReason, idle_should_exit, selection_action};
use symcockpit_core::sensors::{FanProfile, FanSelection};
use symcockpit_helper_proto::{Action, ErrorKind, GovernorProfile, Reply, Request};
use symcockpit_store::smc_restore;
use symcockpit_testkit::smc_write::{FakeClock, FakePorts, FakeSmcRw, battery_on_ac};

struct Rig {
    smc: FakeSmcRw,
    clock: FakeClock,
    engine: Engine,
    dir: tempfile::TempDir,
}

fn hot_fans(die: f32, mode: u8) -> FakeSmcRw {
    use symcockpit_testkit::smc::FakeSmc;
    FakeSmcRw::new(
        FakeSmc::new(true)
            .with_raw("#KEY", b"ui32", &3374u32.to_be_bytes())
            .with_ui8("FNum", 1)
            .with_ui8("F0Md", mode)
            .with_flt("F0Ac", 2500.0)
            .with_flt("F0Tg", 2500.0)
            .with_flt("F0Mn", 2000.0)
            .with_flt("F0Mx", 8000.0)
            .with_flt("TCMz", die)
            .with_ui8("Ftst", 0),
    )
}

impl Rig {
    fn new(smc: FakeSmcRw) -> Self {
        Self::with_ports(smc.clone(), |_| {})
    }

    fn with_ports(smc: FakeSmcRw, tweak: impl FnOnce(&mut FakePorts)) -> Self {
        let clock = FakeClock::default();
        let mut ports = FakePorts::new(smc.clone(), clock.clone());
        tweak(&mut ports);
        let dir = tempfile::tempdir().unwrap();
        let engine = Engine::new(
            Box::new(ports),
            &dir.path().join("root-data"),
            None,
            "0.12.2",
        );
        Self {
            smc,
            clock,
            engine,
            dir,
        }
    }

    fn ask(&mut self, action: Action) -> Reply {
        self.engine.handle(Request::new(action))
    }

    fn record(&self) -> Option<Result<smc_restore::Record, ()>> {
        smc_restore::read(&self.dir.path().join("root-data"))
    }

    /// One watchdog/scheduler step after `ms` of fake time.
    fn tick(&mut self, ms: u64) {
        self.clock.advance_ms(ms);
        self.engine.poll();
    }
}

fn start(profile: GovernorProfile) -> Action {
    Action::GovernorStart {
        profile,
        cool_target_celsius: None,
    }
}

fn kind(reply: &Reply) -> ErrorKind {
    match reply {
        Reply::Error { kind, .. } => *kind,
        other => panic!("expected an error, got {other:?}"),
    }
}

// -- selection routing -------------------------------------------------------

#[test]
fn a_selection_routes_to_the_helper_governor_it_needs() {
    // `system` stops the helper governor; either governed profile starts or
    // retargets it, carrying only a bounded Cool target for Cool.
    assert_eq!(
        selection_action(FanSelection::SYSTEM),
        Some(Action::GovernorStop)
    );
    assert_eq!(
        selection_action(FanSelection::new(FanProfile::Comfort, Some(62.5))),
        Some(Action::GovernorStart {
            profile: GovernorProfile::Comfort,
            cool_target_celsius: Some(62.5),
        })
    );
    assert_eq!(
        selection_action(FanSelection::new(FanProfile::Performance, Some(62.5))),
        Some(Action::GovernorStart {
            profile: GovernorProfile::Performance,
            cool_target_celsius: None,
        })
    );
    // A target change on Cool retargets the same governor with the new value.
    assert_eq!(
        selection_action(FanSelection::new(FanProfile::Comfort, Some(70.0))),
        Some(Action::GovernorStart {
            profile: GovernorProfile::Comfort,
            cool_target_celsius: Some(70.0),
        })
    );
    assert_eq!(
        selection_action(FanSelection::new(FanProfile::Comfort, Some(999.0))),
        Some(Action::GovernorStart {
            profile: GovernorProfile::Comfort,
            cool_target_celsius: Some(85.0),
        })
    );
}

// -- governor lifecycle ------------------------------------------------------------

#[test]
fn start_writes_the_record_first_then_governs_a_temperature_driven_target() {
    let mut rig = Rig::new(hot_fans(85.0, 0));
    assert_eq!(rig.ask(start(GovernorProfile::Comfort)), Reply::Ok);
    // The record is on disk before the first SMC write (there is none yet).
    assert!(rig.smc.writes().is_empty());
    assert!(
        matches!(rig.record(), Some(Ok(r)) if r.fan_originals.len() == 1 && r.fan_originals[0].mode == 0)
    );
    rig.tick(0);
    assert_eq!(rig.smc.get_ui8("F0Md"), Some(1));
    assert_eq!(
        rig.smc.get_flt("F0Tg"),
        Some(8000.0),
        "85 °C on Cool is flat out"
    );
    assert_eq!(
        rig.ask(Action::Status),
        Reply::Status {
            state: "governing".into(),
            detail: Some("comfort".into())
        }
    );
    // A cooler die lowers it at the bounded rate, never to a constant.
    rig.smc.set_flt("TCMz", 45.0);
    rig.tick(5_000);
    let after = rig.smc.get_flt("F0Tg").unwrap();
    assert!(after < 8000.0 && after > 2000.0, "{after}");
}

#[test]
fn stop_hands_the_fans_back_and_removes_the_record() {
    let mut rig = Rig::new(hot_fans(85.0, 0));
    rig.ask(start(GovernorProfile::Performance));
    rig.tick(0);
    assert_eq!(rig.ask(Action::GovernorStop), Reply::Ok);
    assert_eq!(rig.smc.get_ui8("F0Md"), Some(0));
    assert_eq!(rig.smc.get_flt("F0Tg"), Some(2500.0));
    assert_eq!(rig.smc.get_ui8("Ftst"), Some(0));
    assert!(rig.record().is_none());
    assert_eq!(rig.engine.last_stop(), Some(StopReason::Requested));
    assert_eq!(
        rig.ask(Action::Status),
        Reply::Status {
            state: "idle".into(),
            detail: Some("requested".into())
        }
    );
}

#[test]
fn start_while_governing_retargets_without_a_second_capture() {
    let mut rig = Rig::new(hot_fans(85.0, 0));
    rig.ask(start(GovernorProfile::Comfort));
    rig.tick(0);
    let writes_before = rig.smc.writes().len();
    assert_eq!(rig.ask(start(GovernorProfile::Performance)), Reply::Ok);
    assert_eq!(
        rig.ask(Action::Status),
        Reply::Status {
            state: "governing".into(),
            detail: Some("performance".into())
        }
    );
    assert_eq!(
        rig.smc.writes().len(),
        writes_before,
        "retargeting writes nothing by itself"
    );
    rig.ask(Action::GovernorStop);
    assert_eq!(
        rig.smc.get_ui8("F0Md"),
        Some(0),
        "the original mode 0 comes back, not a half-restored state"
    );
}

// -- the crash case: no heartbeat -> firmware control (R20) ------------------------------

#[test]
fn a_missing_heartbeat_restores_the_firmware_after_the_timeout() {
    let mut rig = Rig::new(hot_fans(85.0, 0));
    rig.ask(start(GovernorProfile::Comfort));
    rig.tick(0);
    assert_eq!(rig.smc.get_ui8("F0Md"), Some(1));
    // The app pings every 2 s: the run survives indefinitely.
    for _ in 0..10 {
        rig.tick(2_000);
        assert_eq!(
            rig.ask(Action::Heartbeat),
            Reply::Heartbeat { governing: true }
        );
    }
    assert_eq!(rig.smc.get_ui8("F0Md"), Some(1));
    // The app dies. Exactly the timeout is still fine ...
    rig.tick(7_000);
    assert!(
        rig.engine.is_governing(),
        "7000 ms is not 'more than' the timeout"
    );
    assert_eq!(rig.smc.get_ui8("F0Md"), Some(1));
    // ... one millisecond more hands the fans back and ends the governor.
    rig.tick(1);
    assert!(!rig.engine.is_governing());
    assert_eq!(rig.engine.last_stop(), Some(StopReason::HeartbeatTimeout));
    assert_eq!(rig.smc.get_ui8("F0Md"), Some(0));
    assert_eq!(rig.smc.get_flt("F0Tg"), Some(2500.0));
    assert_eq!(rig.smc.get_ui8("Ftst"), Some(0));
    assert!(rig.record().is_none(), "a clean restore clears the trail");
    // Nothing more is written afterwards.
    let n = rig.smc.writes().len();
    rig.tick(60_000);
    assert_eq!(rig.smc.writes().len(), n);
}

#[test]
fn three_governor_ticks_without_a_temperature_hand_the_fans_back() {
    let mut rig = Rig::new(hot_fans(85.0, 0));
    rig.ask(start(GovernorProfile::Performance));
    rig.tick(0);
    assert_eq!(rig.smc.get_ui8("F0Md"), Some(1));
    rig.smc.set_ui8("TCMz", 0); // implausible: no reading
    for _ in 0..3 {
        rig.ask(Action::Heartbeat);
        rig.tick(5_000);
    }
    assert!(!rig.engine.is_governing());
    assert_eq!(rig.engine.last_stop(), Some(StopReason::GovernorFinished));
    assert_eq!(rig.smc.get_ui8("F0Md"), Some(0));
    match rig.ask(Action::Status) {
        Reply::Status { state, detail } => {
            assert_eq!(state, "failed");
            assert!(detail.unwrap().contains("no die temperature"));
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn an_invalidated_connection_and_sigterm_restore_too() {
    for end in [0, 1] {
        let mut rig = Rig::new(hot_fans(85.0, 0));
        rig.ask(start(GovernorProfile::Comfort));
        rig.tick(0);
        if end == 0 {
            rig.engine.connection_invalidated();
            assert_eq!(
                rig.engine.last_stop(),
                Some(StopReason::ConnectionInvalidated)
            );
        } else {
            rig.engine.terminate();
            assert_eq!(rig.engine.last_stop(), Some(StopReason::Terminated));
        }
        assert_eq!(rig.smc.get_ui8("F0Md"), Some(0));
        assert!(rig.record().is_none());
    }
}

#[test]
fn the_helper_dying_mid_run_leaves_a_record_the_next_helper_applies() {
    let mut rig = Rig::new(hot_fans(85.0, 0));
    rig.ask(start(GovernorProfile::Comfort));
    rig.tick(0);
    assert_eq!(rig.smc.get_ui8("F0Md"), Some(1));
    // SIGKILL: the engine is gone without running anything; the hardware stays forced.
    let smc = rig.smc.clone();
    let dir = rig.dir;
    drop(rig.engine);
    assert_eq!(smc.get_ui8("F0Md"), Some(1));
    // A fresh helper at launch (before serving XPC): the record wins.
    let ports = FakePorts::new(smc.clone(), FakeClock::default());
    let mut next = Engine::new(
        Box::new(ports),
        &dir.path().join("root-data"),
        None,
        "0.12.2",
    );
    next.recover_stale();
    assert_eq!(smc.get_ui8("F0Md"), Some(0));
    assert_eq!(smc.get_ui8("Ftst"), Some(0));
    assert!(smc_restore::read(&dir.path().join("root-data")).is_none());
}

// -- stale recovery -----------------------------------------------------------------------

#[test]
fn a_fresh_helper_recovers_forced_fans_unless_the_standalone_governor_holds_them() {
    // Forced fans, no record (an older helper): the stale-override recovery.
    let smc = hot_fans(50.0, 1);
    smc.set_ui8("Ftst", 1);
    let mut rig = Rig::new(smc);
    rig.engine.recover_stale();
    assert_eq!(rig.smc.get_ui8("F0Md"), Some(0));
    assert_eq!(rig.smc.get_ui8("Ftst"), Some(0));

    // The osascript path's `fan governor` process owns them: hands off.
    let smc = hot_fans(50.0, 1);
    smc.set_ui8("Ftst", 1);
    let mut rig = Rig::with_ports(smc, |p| p.legacy_governor = true);
    rig.engine.recover_stale();
    assert!(rig.smc.writes().is_empty());
    assert_eq!(rig.smc.get_ui8("F0Md"), Some(1));

    // Nothing forced: nothing written.
    let mut rig = Rig::new(hot_fans(50.0, 0));
    rig.engine.recover_stale();
    assert!(rig.smc.writes().is_empty());
}

#[test]
fn an_explicit_stop_with_nothing_running_also_recovers_forced_fans() {
    let smc = hot_fans(50.0, 1);
    smc.set_ui8("Ftst", 1);
    let mut rig = Rig::new(smc);
    assert_eq!(rig.ask(Action::FanSetAuto), Reply::Ok);
    assert_eq!(rig.smc.get_ui8("F0Md"), Some(0));
}

#[test]
fn smc_restore_applies_a_record_and_clears_everything() {
    let mut rig = Rig::new(hot_fans(85.0, 0));
    rig.ask(start(GovernorProfile::Comfort));
    rig.tick(0);
    assert_eq!(rig.ask(Action::SmcRestore), Reply::Ok);
    assert_eq!(rig.smc.get_ui8("F0Md"), Some(0));
    assert!(rig.record().is_none());
    assert!(!rig.engine.is_governing());
}

// -- parameters are checked by the helper (Q02) ---------------------------------------------

#[test]
fn bad_parameters_are_refused_before_anything_is_written() {
    let mut rig = Rig::new(hot_fans(50.0, 0));
    let r = rig.ask(Action::GovernorStart {
        profile: GovernorProfile::Comfort,
        cool_target_celsius: Some(f64::NAN),
    });
    assert_eq!(kind(&r), ErrorKind::Usage);
    for (fraction, lease) in [
        (f64::NAN, 1000),
        (0.5, 0),
        (0.5, 3_600_001),
        (f64::INFINITY, 1000),
    ] {
        let r = rig.ask(Action::FanSetTarget {
            fraction,
            lease_ms: lease,
        });
        assert_eq!(kind(&r), ErrorKind::Usage, "{fraction} {lease}");
    }
    for p in [49, 101, -1, i64::MAX] {
        assert_eq!(
            kind(&rig.ask(Action::ChargeLimitSmc { percent: Some(p) })),
            ErrorKind::Usage
        );
    }
    assert!(rig.smc.writes().is_empty());
    assert!(rig.record().is_none());
}

#[test]
fn a_cool_target_is_clamped_and_only_cool_uses_it() {
    // Die 50 °C, hot cluster: a 10 °C target clamps to 50 °C and runs the fans flat out.
    let smc = hot_fans(50.0, 0);
    for k in ["Tp01", "Tp02", "Tp03"] {
        smc.set_flt(k, 70.0);
    }
    let mut rig = Rig::new(smc);
    rig.ask(Action::GovernorStart {
        profile: GovernorProfile::Comfort,
        cool_target_celsius: Some(10.0),
    });
    rig.tick(0);
    assert_eq!(rig.smc.get_flt("F0Tg"), Some(8000.0));
}

// -- fixed target with a lease ------------------------------------------------------------

#[test]
fn a_fixed_target_lives_for_its_lease_and_never_longer() {
    let mut rig = Rig::new(hot_fans(50.0, 0));
    assert_eq!(
        rig.ask(Action::FanSetTarget {
            fraction: 0.5,
            lease_ms: 10_000
        }),
        Reply::Ok
    );
    assert_eq!(rig.smc.get_flt("F0Tg"), Some(4000.0));
    assert_eq!(rig.smc.get_ui8("F0Md"), Some(1));
    rig.tick(9_999);
    assert!(rig.engine.is_governing());
    rig.tick(1);
    assert!(!rig.engine.is_governing());
    assert_eq!(rig.engine.last_stop(), Some(StopReason::LeaseExpired));
    assert_eq!(rig.smc.get_ui8("F0Md"), Some(0));
    assert_eq!(rig.smc.get_flt("F0Tg"), Some(2500.0));
    assert!(rig.record().is_none());
}

#[test]
fn a_fixed_target_cannot_slow_the_fans_on_a_hot_mac() {
    // Fans at 5000 rpm on a 95 °C die: 0.3 (2400 rpm) is a slowdown, refused with Permission.
    let smc = hot_fans(95.0, 1);
    smc.set_flt("F0Tg", 5000.0);
    let mut rig = Rig::new(smc);
    let r = rig.ask(Action::FanSetTarget {
        fraction: 0.3,
        lease_ms: 1000,
    });
    assert_eq!(kind(&r), ErrorKind::Permission);
    assert!(rig.smc.writes().is_empty());
    assert!(rig.record().is_none());
    // Speeding up is never refused.
    assert_eq!(
        rig.ask(Action::FanSetTarget {
            fraction: 1.0,
            lease_ms: 1000
        }),
        Reply::Ok
    );
}

#[test]
fn a_fixed_target_that_does_not_hold_is_given_up() {
    let mut rig = Rig::new(hot_fans(50.0, 0));
    rig.ask(Action::FanSetTarget {
        fraction: 0.5,
        lease_ms: 3_600_000,
    });
    rig.smc.forget_writes_to("F0Tg");
    rig.smc.set_flt("F0Tg", 2000.0);
    for _ in 0..3 {
        rig.tick(5_000);
    }
    assert!(!rig.engine.is_governing());
    assert_eq!(rig.engine.last_stop(), Some(StopReason::GovernorFinished));
    assert_eq!(rig.smc.get_ui8("F0Md"), Some(0));
}

// -- charge limit through the helper -----------------------------------------------------------

#[test]
fn charge_limit_set_and_clear_through_the_helper_read_back() {
    let mut rig = Rig::new(hot_fans(50.0, 0).with_chte(false));
    assert_eq!(
        rig.ask(Action::ChargeLimitSmc { percent: Some(80) }),
        Reply::Ok
    );
    assert_eq!(rig.smc.get("CHTE").unwrap().bytes, [0, 0, 0, 1]);
    assert!(
        matches!(rig.record(), Some(Ok(r)) if r.charge_inhibit == Some(false)),
        "original saved first"
    );
    assert_eq!(rig.ask(Action::ChargeLimitSmc { percent: None }), Reply::Ok);
    assert_eq!(rig.smc.get("CHTE").unwrap().bytes, [0, 0, 0, 0]);
    // SmcRestore undoes a pending limit too.
    rig.ask(Action::ChargeLimitSmc { percent: Some(80) });
    assert_eq!(rig.ask(Action::SmcRestore), Reply::Ok);
    assert_eq!(rig.smc.get("CHTE").unwrap().bytes, [0, 0, 0, 0]);
    assert!(rig.record().is_none());
}

#[test]
fn charge_limit_refusals_and_unconfirmed() {
    // No SMC key: the helper has no mechanism (the macOS limit lives in the user's agent).
    let mut rig = Rig::new(hot_fans(50.0, 0));
    assert_eq!(
        kind(&rig.ask(Action::ChargeLimitSmc { percent: Some(80) })),
        ErrorKind::Unsupported
    );
    // On battery: refused by the safety policy.
    let mut rig = Rig::with_ports(hot_fans(50.0, 0).with_chte(false), |p| {
        p.battery = battery_on_ac(false)
    });
    assert_eq!(
        kind(&rig.ask(Action::ChargeLimitSmc { percent: Some(80) })),
        ErrorKind::Permission
    );
    // Accepted but not kept: unconfirmed (Q01).
    let smc = hot_fans(50.0, 0).with_chte(false);
    smc.forget_writes_to("CHTE");
    let mut rig = Rig::new(smc);
    assert_eq!(
        kind(&rig.ask(Action::ChargeLimitSmc { percent: Some(80) })),
        ErrorKind::Unconfirmed
    );
}

// -- small things --------------------------------------------------------------------------------

#[test]
fn hello_and_heartbeat_when_idle() {
    let mut rig = Rig::new(hot_fans(50.0, 0));
    assert_eq!(
        rig.ask(Action::Hello),
        Reply::Hello {
            version: 1,
            helper_version: "0.12.2".into()
        }
    );
    assert_eq!(
        rig.ask(Action::Heartbeat),
        Reply::Heartbeat { governing: false }
    );
    assert_eq!(
        rig.ask(Action::Status),
        Reply::Status {
            state: "idle".into(),
            detail: None
        }
    );
}

#[test]
fn the_idle_exit_rule_matches_swift() {
    // FanHelperIdleMonitor.shouldExit
    assert!(idle_should_exit(false, false, 5_000, 5_000));
    assert!(!idle_should_exit(false, false, 4_999, 5_000));
    assert!(!idle_should_exit(true, false, 60_000, 5_000));
    assert!(!idle_should_exit(false, true, 60_000, 5_000));
}
