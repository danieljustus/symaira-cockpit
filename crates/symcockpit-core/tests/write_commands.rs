//! The CLI write commands against fakes: Swift-identical parsing and errors
//! (`SymCockpitMain.swift`), the safety order, the history trail, and the
//! plan variants. No SMC, no root, no real files outside a temp dir.

use symcockpit_contract::{Error, Outcome};
use symcockpit_core::fan::FanEnv;
use symcockpit_core::plan::Action;
use symcockpit_core::sensors::{FanProfile, FanSelection, FanSelectionSource};
use symcockpit_core::write_commands::{
    Command, Route, WriteAction, WriteEnv, charge_identity, execute, fan_identity, helper_action,
    log_outcome, parse_battery_limit, parse_fan, parse_restore, plan_item, reply_to_result, route,
    run_governor,
};
use symcockpit_helper_proto::{Action as HelperAction, ErrorKind, Reply};
use symcockpit_store::Config;
use symcockpit_store::smc_restore;
use symcockpit_testkit::battery::FakeBatterySource;
use symcockpit_testkit::smc::{FakeHost, FakeSmc};
use symcockpit_testkit::smc_write::{FakeClock, FakePowerUi, FakeSmcRw, battery_on_ac};

fn s(args: &[&str]) -> Vec<String> {
    args.iter().map(|a| (*a).to_owned()).collect()
}

fn usage(e: Result<Command, Error>) -> String {
    match e {
        Err(Error::Usage(m)) => m,
        other => panic!("expected a usage error, got {other:?}"),
    }
}

// -- parsing: the texts of SymCockpitMain.swift --------------------------------------

#[test]
fn fan_arguments_parse_like_swift() {
    assert_eq!(
        parse_fan(&s(&["set", "0.5"])).unwrap(),
        Command::FanSet(0.5)
    );
    // `set` is optional.
    assert_eq!(parse_fan(&s(&["0.5"])).unwrap(), Command::FanSet(0.5));
    assert_eq!(parse_fan(&s(&["auto"])).unwrap(), Command::FanAuto);
    assert_eq!(
        usage(parse_fan(&s(&["auto", "x"]))),
        "fan auto: unexpected argument 'x'"
    );
    assert_eq!(
        usage(parse_fan(&s(&[]))),
        "fan set: expected a numeric value, e.g. `symcockpit fan set set 1.4`"
    );
    assert_eq!(
        usage(parse_fan(&s(&["set"]))),
        "fan set: expected a numeric value, e.g. `symcockpit fan set set 1.4`"
    );
    assert_eq!(
        usage(parse_fan(&s(&["set", "fast"]))),
        "fan set: unexpected argument 'fast'"
    );
    assert_eq!(
        usage(parse_fan(&s(&["set", "0.5", "x"]))),
        "fan set: unexpected argument 'x'"
    );
    assert_eq!(usage(parse_fan(&s(&["nan"]))), "Value must be finite.");
    assert_eq!(
        usage(parse_fan(&s(&["set", "inf"]))),
        "Value must be finite."
    );
}

#[test]
fn governor_arguments_parse_like_swift() {
    assert_eq!(
        parse_fan(&s(&["governor"])).unwrap(),
        Command::FanGovernor { state: None }
    );
    assert_eq!(
        parse_fan(&s(&["governor", "--state", "/tmp/p.json"])).unwrap(),
        Command::FanGovernor {
            state: Some("/tmp/p.json".into())
        }
    );
    assert_eq!(
        usage(parse_fan(&s(&["governor", "x"]))),
        "fan governor: unexpected argument 'x'"
    );
    assert_eq!(
        usage(parse_fan(&s(&["governor", "--state"]))),
        "fan governor: --state requires a path."
    );
    assert_eq!(
        usage(parse_fan(&s(&["governor", "--state", "a", "b"]))),
        "fan governor: unexpected argument 'b'"
    );
}

#[test]
fn battery_limit_and_restore_arguments_parse_like_swift() {
    assert_eq!(
        parse_battery_limit(&s(&["set", "80"])).unwrap(),
        Command::ChargeSet(80)
    );
    assert_eq!(
        parse_battery_limit(&s(&["80"])).unwrap(),
        Command::ChargeSet(80)
    );
    assert_eq!(
        parse_battery_limit(&s(&["clear"])).unwrap(),
        Command::ChargeClear
    );
    assert_eq!(
        usage(parse_battery_limit(&s(&["clear", "x"]))),
        "battery-limit clear: unexpected argument 'x'"
    );
    assert_eq!(
        usage(parse_battery_limit(&s(&[]))),
        "battery-limit set: expected an integer value, e.g. `symcockpit battery-limit set set 80`"
    );
    assert_eq!(
        usage(parse_battery_limit(&s(&["set", "8.5"]))),
        "battery-limit set: unexpected argument '8.5'"
    );
    assert_eq!(
        usage(parse_battery_limit(&s(&["9223372036854775807"]))),
        "battery-limit: percent value is not a representable integer (got 9.223372036854776e+18)."
    );
    assert_eq!(parse_restore(&s(&[])).unwrap(), Command::Restore);
    assert_eq!(
        usage(parse_restore(&s(&["--help"]))),
        "restore: unexpected argument '--help'"
    );
}

// -- running -------------------------------------------------------------------------

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
    fn new(smc: FakeSmcRw) -> Self {
        Self {
            smc,
            clock: FakeClock::default(),
            host: FakeHost::default(),
            config: Config::default(),
            battery: battery_on_ac(true),
            mac: FakePowerUi::new(true),
            dir: tempfile::tempdir().unwrap(),
        }
    }

    fn data(&self) -> std::path::PathBuf {
        self.dir.path().join("data")
    }

    fn with<R>(&self, is_root: bool, f: impl FnOnce(&WriteEnv) -> R) -> R {
        let data = self.data();
        let now = || "2026-11-21T10:00:00Z".to_owned();
        let env = WriteEnv {
            fan: FanEnv {
                smc: &self.smc,
                writer: &self.smc,
                host: &self.host,
                config: &self.config,
                clock: &self.clock,
            },
            mac: Some(&self.mac),
            battery: &self.battery,
            data_dir: &data,
            owner: None,
            is_root,
            now: &now,
        };
        f(&env)
    }

    fn history(&self) -> Vec<serde_json::Value> {
        std::fs::read_to_string(self.data().join("history.ndjson"))
            .unwrap_or_default()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    }
}

fn two_fans() -> FakeSmcRw {
    FakeSmcRw::new(
        FakeSmc::new(true)
            .with_ui8("FNum", 2)
            .with_ui8("F0Md", 0)
            .with_ui8("F1Md", 0)
            .with_flt("F0Ac", 2500.0)
            .with_flt("F1Ac", 2500.0)
            .with_flt("F0Tg", 2500.0)
            .with_flt("F1Tg", 2500.0)
            .with_flt("F0Mn", 2000.0)
            .with_flt("F1Mn", 2000.0)
            .with_flt("F0Mx", 6000.0)
            .with_flt("F1Mx", 6000.0)
            .with_flt("TCMz", 60.0)
            .with_ui8("Ftst", 0),
    )
}

#[test]
fn fan_set_writes_records_the_original_first_and_logs() {
    let rig = Rig::new(two_fans());
    rig.with(true, |env| execute(env, &Command::FanSet(0.5)))
        .unwrap();
    assert_eq!(rig.smc.get_ui8("F0Md"), Some(1));
    assert_eq!(rig.smc.get_ui8("F1Md"), Some(1));
    // 0.5 of the 6000 rpm maximum (above the 2000 rpm firmware minimum)
    assert_eq!(rig.smc.get_flt("F0Tg"), Some(3000.0));
    // The record was written before the first change and carries both fans.
    let record = smc_restore::read(&rig.data())
        .expect("record")
        .expect("decodes");
    assert_eq!(record.fan_originals.len(), 2);
    let log = rig.history();
    assert_eq!(log.len(), 1);
    assert_eq!(log[0]["source"], "tune");
    assert_eq!(log[0]["payload"]["action"], "fan.set");
    assert_eq!(log[0]["payload"]["result"], "success");
    assert_eq!(log[0]["payload"]["requested_value"], 0.5);
}

#[test]
fn without_root_the_write_is_refused_with_swifts_permission_error() {
    let smc = two_fans();
    smc.reject_writes_to("F0Md");
    let rig = Rig::new(smc);
    let e = rig
        .with(false, |env| execute(env, &Command::FanSet(0.5)))
        .unwrap_err();
    assert_eq!(
        e,
        Error::Permission("SMC rejected manual mode for fan 0; run with sudo".into())
    );
    assert_eq!(e.exit_code(), 3);
    assert_eq!(rig.history()[0]["payload"]["result"], "failed");
}

#[test]
fn a_hot_mac_refuses_to_slow_the_fans_but_a_faster_target_goes_through() {
    let smc = two_fans();
    smc.set_flt("TCMz", 95.0);
    smc.set_flt("F0Tg", 5000.0);
    smc.set_flt("F1Tg", 5000.0);
    let rig = Rig::new(smc);
    let slower = rig
        .with(true, |env| execute(env, &Command::FanSet(0.2)))
        .unwrap_err();
    assert!(matches!(slower, Error::Permission(m) if m.contains("thermal emergency")));
    assert!(
        rig.smc.written_keys().iter().all(|k| !k.ends_with("Tg")),
        "nothing slowed"
    );
    rig.with(true, |env| execute(env, &Command::FanSet(1.0)))
        .unwrap();
    assert_eq!(rig.smc.get_flt("F0Tg"), Some(6000.0));
}

#[test]
fn fan_auto_hands_the_fans_back() {
    let rig = Rig::new(two_fans());
    rig.with(true, |env| execute(env, &Command::FanSet(0.5)))
        .unwrap();
    rig.with(true, |env| execute(env, &Command::FanAuto))
        .unwrap();
    assert_eq!(rig.smc.get_ui8("F0Md"), Some(0));
    assert_eq!(rig.smc.get_ui8("F1Md"), Some(0));
}

#[test]
fn restore_puts_back_what_a_killed_predecessor_left() {
    let rig = Rig::new(two_fans());
    rig.with(true, |env| execute(env, &Command::FanSet(0.5)))
        .unwrap();
    assert!(rig.data().join("smc-restore.json").exists());
    // The next process consumes the record on start; `restore` then has nothing left.
    rig.with(true, |env| execute(env, &Command::Restore))
        .unwrap();
    // Both fans were in firmware mode (0) before; only a manual original gets its target back.
    assert_eq!(rig.smc.get_ui8("F0Md"), Some(0));
    assert_eq!(rig.smc.get_ui8("F1Md"), Some(0));
    assert!(!rig.data().join("smc-restore.json").exists());
    let log = rig.history();
    assert_eq!(log.last().unwrap()["payload"]["action"], "restore");
}

#[test]
fn battery_limit_uses_the_smc_key_when_present_and_powerui_otherwise() {
    // SMC key present: inhibit through it, never PowerUI.
    let rig = Rig::new(FakeSmcRw::m4_pro_like().with_chte(false));
    rig.with(true, |env| execute(env, &Command::ChargeSet(80)))
        .unwrap();
    assert!(rig.smc.written_keys().contains(&"CHTE".to_owned()));
    assert!(rig.mac.calls().is_empty());
    rig.with(true, |env| execute(env, &Command::ChargeClear))
        .unwrap();
    assert_eq!(rig.history().len(), 2);

    // No key: the macOS limit, with a read-back; the write path is unproven live (S8).
    let rig = Rig::new(FakeSmcRw::m4_pro_like());
    rig.with(false, |env| execute(env, &Command::ChargeSet(80)))
        .unwrap();
    assert_eq!(rig.mac.state(), (true, 80));
    assert!(rig.smc.written_keys().is_empty());
    rig.with(false, |env| execute(env, &Command::ChargeClear))
        .unwrap();
    assert!(!rig.mac.state().0);
}

#[test]
fn battery_limit_without_any_mechanism_is_unsupported_exit_4() {
    let mut rig = Rig::new(FakeSmcRw::m4_pro_like());
    rig.mac = FakePowerUi::new(false);
    let e = rig
        .with(true, |env| execute(env, &Command::ChargeSet(80)))
        .unwrap_err();
    assert!(matches!(e, Error::Unsupported(_)), "{e:?}");
    assert_eq!(e.exit_code(), 4);
    assert!(rig.smc.written_keys().is_empty());
}

#[test]
fn a_battery_limit_that_does_not_read_back_is_not_success() {
    let mut rig = Rig::new(FakeSmcRw::m4_pro_like());
    rig.mac = FakePowerUi::new(true).ignoring_set_limit();
    let e = rig
        .with(false, |env| execute(env, &Command::ChargeSet(80)))
        .unwrap_err();
    assert!(
        matches!(e, Error::Failed(ref m) if m.contains("reads back")),
        "{e:?}"
    );
}

// -- the governor --------------------------------------------------------------------

struct Fixed(FanSelection);

impl FanSelectionSource for Fixed {
    fn selection(&self) -> FanSelection {
        self.0
    }
}

#[test]
fn the_governor_needs_root_and_says_what_it_read() {
    let rig = Rig::new(two_fans());
    let comfort = Fixed(FanSelection::new(FanProfile::Comfort, Some(70.0)));
    let mut lines = Vec::new();
    let denied = rig.with(false, |env| {
        run_governor(env, "/p.json".as_ref(), &comfort, &|| false, &mut |l| {
            lines.push(l)
        })
    });
    assert!(matches!(denied, Err(Error::Permission(m)) if m.contains("must run as root")));
    assert!(rig.smc.written_keys().is_empty());

    rig.with(true, |env| {
        run_governor(env, "/p.json".as_ref(), &comfort, &|| false, &mut |l| {
            lines.push(l)
        })
    })
    .unwrap();
    assert_eq!(lines[0], "fan governor: profile 'comfort' from /p.json");
    assert_eq!(
        lines[1],
        "fan governor: Cool target 70°C average cluster temperature"
    );

    let mut system_lines = Vec::new();
    rig.with(true, |env| {
        run_governor(
            env,
            "/p.json".as_ref(),
            &Fixed(FanSelection::SYSTEM),
            &|| true,
            &mut |l| system_lines.push(l),
        )
    })
    .unwrap();
    assert!(system_lines[1].starts_with("fan governor: nothing to do"));
    assert!(
        rig.smc.written_keys().is_empty(),
        "system position never writes"
    );
}

#[test]
fn the_governor_tracks_the_temperature_and_hands_the_fans_back() {
    let rig = Rig::new(two_fans());
    rig.smc.set_flt("TCMz", 80.0);
    let ticks = std::cell::Cell::new(0);
    let mut lines = Vec::new();
    rig.with(true, |env| {
        run_governor(
            env,
            "/p.json".as_ref(),
            &Fixed(FanSelection::new(FanProfile::Performance, None)),
            &|| {
                ticks.set(ticks.get() + 1);
                ticks.get() <= 2
            },
            &mut |l| lines.push(l),
        )
    })
    .unwrap();
    assert!(
        lines.iter().any(|l| l.starts_with("fan governor: die ")),
        "{lines:?}"
    );
    assert_eq!(
        rig.smc.get_ui8("F0Md"),
        Some(0),
        "fans are back under firmware control"
    );
    assert!(!rig.data().join("smc-restore.json").exists());
}

// -- plan variants (MCP) -------------------------------------------------------------

#[test]
fn plan_items_carry_the_identity_and_are_revalidated_on_confirm() {
    let rig = Rig::new(two_fans());
    let item = rig
        .with(true, |env| plan_item(env, &Command::FanSet(0.5)))
        .expect("fan set is plannable");
    assert_eq!(item["action"], "fan.set");
    assert_eq!(item["target"], "fans");
    assert!(rig.smc.written_keys().is_empty(), "planning writes nothing");

    // Unchanged: valid, executes, reads back as confirmed.
    let result = rig.with(true, |env| {
        let action = WriteAction::new(env, "fan.set");
        assert_eq!(action.still_valid(&item), Ok(()));
        action.execute(&item)
    });
    assert_eq!(result.outcome, Outcome::Confirmed, "{:?}", result.detail);
    assert_eq!(rig.smc.get_flt("F0Tg"), Some(3000.0));

    // The fans changed since the plan was made: skipped.
    rig.smc.set_flt("F0Tg", 3500.0);
    rig.with(true, |env| {
        assert!(WriteAction::new(env, "fan.set").still_valid(&item).is_err());
    });
    assert_ne!(
        rig.with(true, |env| fan_identity(&env.fan)),
        item["identity"]
    );

    assert!(
        rig.with(true, |env| plan_item(env, &Command::Restore))
            .is_none()
    );
    assert!(
        rig.with(true, |env| plan_item(
            env,
            &Command::FanGovernor { state: None }
        ))
        .is_none()
    );
}

#[test]
fn a_charge_plan_is_confirmed_by_the_readback_and_skipped_when_the_state_moved() {
    let rig = Rig::new(FakeSmcRw::m4_pro_like().with_chte(false));
    let item = rig
        .with(true, |env| plan_item(env, &Command::ChargeSet(80)))
        .unwrap();
    assert_eq!(item["identity"]["mechanism"], "smc");
    let result = rig.with(true, |env| {
        WriteAction::new(env, "battery-limit.set").execute(&item)
    });
    assert_eq!(result.outcome, Outcome::Confirmed, "{:?}", result.detail);
    // The inhibit is on now: the plan, made against "not inhibited", no longer describes the world.
    assert!(
        rig.with(true, |env| {
            WriteAction::new(env, "battery-limit.set").still_valid(&item)
        })
        .is_err()
    );
    let identity = rig.with(true, |env| {
        charge_identity(&symcockpit_core::charge_limit::ChargeEnv {
            fan: &env.fan,
            mac: env.mac,
            battery: env.battery,
            config: env.fan.config,
        })
    });
    assert_ne!(identity, item["identity"]);
}

#[test]
fn an_unsupported_charge_plan_reports_unsupported() {
    let mut rig = Rig::new(FakeSmcRw::m4_pro_like());
    rig.mac = FakePowerUi::new(false);
    let item = rig
        .with(true, |env| plan_item(env, &Command::ChargeSet(80)))
        .unwrap();
    let result = rig.with(true, |env| {
        WriteAction::new(env, "battery-limit.set").execute(&item)
    });
    assert_eq!(result.outcome, Outcome::Unsupported);
}

// -- routing and the helper ---------------------------------------------------------

#[test]
fn root_writes_itself_and_without_root_the_helper_takes_the_smc_work() {
    let rig = Rig::new(FakeSmcRw::m4_pro_like().with_chte(false));
    let routes = |root: bool| {
        rig.with(root, |env| {
            [
                Command::FanSet(0.5),
                Command::FanAuto,
                Command::ChargeSet(80),
                Command::ChargeClear,
                Command::Restore,
                Command::FanGovernor { state: None },
            ]
            .map(|c| route(env, &c))
        })
    };
    assert_eq!(routes(true), [Route::Direct; 6]);
    assert_eq!(
        routes(false),
        [
            Route::Helper,
            Route::Helper,
            Route::Helper,
            Route::Helper,
            Route::Helper,
            Route::Direct
        ]
    );
    // No SMC charge key: the macOS limit is not the helper's job.
    let rig = Rig::new(FakeSmcRw::m4_pro_like());
    rig.with(false, |env| {
        assert_eq!(route(env, &Command::ChargeSet(80)), Route::Direct);
        assert_eq!(route(env, &Command::FanSet(0.5)), Route::Helper);
    });
}

#[test]
fn commands_map_to_typed_helper_requests_and_replies_to_swift_errors() {
    assert_eq!(
        helper_action(&Command::FanSet(0.5)),
        Some(HelperAction::FanSetTarget {
            fraction: 0.5,
            lease_ms: 3_600_000
        })
    );
    assert_eq!(
        helper_action(&Command::FanAuto),
        Some(HelperAction::FanSetAuto)
    );
    assert_eq!(
        helper_action(&Command::ChargeSet(80)),
        Some(HelperAction::ChargeLimitSmc { percent: Some(80) })
    );
    assert_eq!(
        helper_action(&Command::ChargeClear),
        Some(HelperAction::ChargeLimitSmc { percent: None })
    );
    assert_eq!(
        helper_action(&Command::Restore),
        Some(HelperAction::SmcRestore)
    );
    assert_eq!(helper_action(&Command::FanGovernor { state: None }), None);

    assert_eq!(reply_to_result(Reply::Ok), Ok(()));
    let error = |kind| reply_to_result(Reply::error(kind, "m")).unwrap_err();
    assert_eq!(error(ErrorKind::Permission).exit_code(), 3);
    assert_eq!(error(ErrorKind::Unsupported).exit_code(), 4);
    assert_eq!(error(ErrorKind::Usage).exit_code(), 2);
    assert_eq!(error(ErrorKind::Unconfirmed).exit_code(), 1);
    assert_eq!(error(ErrorKind::Failed).exit_code(), 1);
    assert!(reply_to_result(Reply::Heartbeat { governing: true }).is_err());
}

#[test]
fn a_command_the_helper_carried_out_still_lands_in_the_users_history() {
    let rig = Rig::new(two_fans());
    rig.with(false, |env| {
        log_outcome(env, &Command::FanSet(0.5), &Ok(()));
        log_outcome(
            env,
            &Command::ChargeSet(80),
            &Err(Error::Permission("no".into())),
        );
    });
    let log = rig.history();
    assert_eq!(log[0]["payload"]["applied_value"], 0.5);
    assert_eq!(log[1]["payload"]["result"], "failed");
    assert_eq!(log[1]["payload"]["clamped_value"], 80);
    assert!(log[1]["payload"].get("applied_value").is_none());
}
