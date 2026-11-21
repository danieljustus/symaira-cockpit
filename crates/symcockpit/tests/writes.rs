//! The unprivileged write commands through the real CLI planner and MCP
//! server, on the fake display, power and history ports of `symcockpit-testkit`.
//! No display, gamma table, overlay or power assertion is ever touched (Q07).

mod common;

use common::{app, done, forwarded};
use serde_json::{Value, json};
use symcockpit::app::{App, Context, OverridePort};
use symcockpit::live::LiveOverrides;
use symcockpit::mcp::Server;
use symcockpit_store::Config;
use symcockpit_testkit::smc::FakeSmc;
use symcockpit_testkit::tune_write::{Observers, rig};

struct Env {
    tmp: tempfile::TempDir,
    app: App,
    rig: Observers,
}

/// An app and a fake-backed writer installed for this test's thread.
fn env() -> Env {
    let tmp = tempfile::tempdir().unwrap();
    let mut app = app(tmp.path());
    // The production wiring of `awake.status` (see `live::wire`), on the same session view.
    app.handlers.register("awake.status", |_, _| {
        Ok(symcockpit::app::Output::Json(
            symcockpit_core::power::awake_status_json(&symcockpit::writes::SessionView)?,
        ))
    });
    let (writer, observers) = rig(&app.paths.data_dir).split();
    symcockpit::writes::install(writer);
    Env {
        tmp,
        app,
        rig: observers,
    }
}

fn json_of(stdout: &str) -> Value {
    serde_json::from_str(stdout).unwrap()
}

fn mcp(env: &Env, tool: &str, arguments: Value) -> Value {
    let config = Config::default();
    let ctx = Context {
        config: &config,
        paths: &env.app.paths,
        data_dir: &env.app.paths.data_dir,
        data_dir_override: None,
        env: &env.app.env,
        services: &env.app.services,
    };
    let line = json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":tool,"arguments":arguments}}).to_string();
    Server::new(&env.app, &ctx).handle_line(&line).unwrap()
}

fn text(response: &Value) -> &str {
    assert_eq!(response["result"]["isError"], false, "{response}");
    response["result"]["content"][0]["text"].as_str().unwrap()
}

#[test]
fn usage_errors_match_swift_text_and_exit_code() {
    let e = env();
    for (line, message) in [
        (
            &["brightness", "set"][..],
            "brightness set: expected a numeric value, e.g. `symcockpit brightness set set 1.4`",
        ),
        (
            &["brightness", "set", "1", "2"],
            "brightness set: unexpected argument '2'",
        ),
        (
            &["brightness", "loud"],
            "brightness set: unexpected argument 'loud'",
        ),
        (&["brightness", "set", "nan"], "Value must be finite."),
        (&["brightness", "set", "inf"], "Value must be finite."),
        (
            &["extbright"],
            "extbright set: expected a numeric value, e.g. `symcockpit extbright set set 1.4`",
        ),
        (
            &["dim"],
            "dim set: expected a numeric value, e.g. `symcockpit dim set set 1.4`",
        ),
        (
            &["dim", "reset", "now"],
            "dim reset: unexpected argument 'now'",
        ),
        (
            &["warmth", "reset", "now"],
            "warmth reset: unexpected argument 'now'",
        ),
        (&["restore", "now"], "restore: unexpected argument 'now'"),
        (&["profile", "save"], "profile save: expected a name."),
        (&["profile", "load"], "profile load: expected a name."),
        (&["profile", "delete"], "profile delete: expected a name."),
        (
            &["profile", "save", "a", "b"],
            "profile save: unexpected argument 'b'",
        ),
        (
            &["profile", "rename", "a"],
            "profile: unknown subcommand 'rename'.",
        ),
        (&["awake", "--bogus"], "awake: unknown option '--bogus'."),
        (
            &["awake", "--seconds", "-1"],
            "awake --seconds requires a number that is finite and non-negative.",
        ),
        (
            &["awake", "--for"],
            "awake --for requires a duration, e.g. 30m, 2h.",
        ),
        (
            &["awake", "--until", "25:00"],
            "awake --until: expected HH:MM (24-hour), got '25:00'.",
        ),
    ] {
        let o = done(&e.app, line);
        assert_eq!(
            (o.stderr.as_str(), o.code, o.stdout.as_str()),
            (format!("symcockpit: {message}\n").as_str(), 2, ""),
            "{line:?}"
        );
    }
    assert!(
        e.rig.hw.calls().is_empty(),
        "a rejected command touches nothing"
    );
    assert!(e.rig.history.borrow().is_empty());
}

#[test]
fn write_families_keep_their_help_text() {
    let e = env();
    assert_eq!(
        done(&e.app, &["dim", "--help"]).stdout,
        symcockpit::help::write_family("dim").unwrap()
    );
    assert_eq!(
        done(&e.app, &["warmth", "reset", "-h"]).stdout,
        symcockpit::help::write_family("warmth").unwrap()
    );
}

#[test]
fn display_writes_print_applied_and_land_on_the_ports() {
    let e = env();
    for line in [
        &["brightness", "set", "0.8"][..],
        &["brightness", "0.7"],
        &["extbright", "set", "1.3"],
        &["dim", "set", "0.5"],
        &["dim", "0.4"],
        &["warmth", "set", "0.25"],
        &["warmth", "reset"],
        &["dim", "reset"],
    ] {
        let o = done(&e.app, line);
        assert_eq!(
            (o.stdout.as_str(), o.stderr.as_str(), o.code),
            ("{\n  \"applied\" : true\n}\n", "", 0),
            "{line:?}"
        );
    }
    let calls = e.rig.hw.calls();
    assert!(calls.contains(&"brightness 1 0.8".to_owned()));
    assert!(calls.contains(&"brightness 1 0.7".to_owned()));
    assert!(calls.contains(&"edr.create".to_owned()));
    assert!(calls.contains(&"dim.show 0.5".to_owned()));
    let actions: Vec<&str> = e.rig.history.borrow().iter().map(|h| h.action).collect();
    assert_eq!(
        actions,
        [
            "brightness.set",
            "brightness.set",
            "extbright.set",
            "dim.set",
            "dim.set",
            "warmth.set",
            "warmth.reset",
            "dim.reset"
        ]
    );
}

#[test]
fn out_of_range_values_are_clamped_not_rejected() {
    let e = env();
    done(&e.app, &["brightness", "set", "5"]);
    done(&e.app, &["dim", "set", "0"]);
    assert_eq!(e.rig.hw.brightness.get(), 1.0);
    assert!(
        e.rig
            .history
            .borrow()
            .iter()
            .all(|h| h.clamped.is_some() && h.success)
    );
}

#[test]
fn a_failing_display_write_is_exit_1_with_the_message() {
    let e = env();
    e.rig.hw.fail_brightness_set.set(true);
    let o = done(&e.app, &["brightness", "set", "0.3"]);
    assert_eq!(
        (o.stderr.as_str(), o.code),
        ("symcockpit: brightness refused\n", 1)
    );
    assert!(!e.rig.history.borrow()[0].success);
}

#[test]
fn a_display_command_without_a_builtin_display_is_exit_4() {
    let e = env();
    e.rig.hw.no_screens.set(true);
    let o = done(&e.app, &["extbright", "set", "1.2"]);
    assert_eq!(
        (o.stderr.as_str(), o.code),
        (
            "symcockpit: unsupported: No built-in display detected.\n",
            4
        )
    );
}

#[test]
fn restore_without_an_smc_part_restores_displays_then_forwards() {
    let e = env();
    done(&e.app, &["dim", "set", "0.5"]);
    assert!(forwarded(&e.app, &["restore"]));
    assert_eq!(
        e.rig.hw.dim_shown.get(),
        None,
        "the display half ran before the hand-over"
    );
    assert!(
        e.rig.history.borrow().iter().all(|h| h.action != "restore"),
        "Swift logs the restore"
    );
}

#[test]
fn restore_with_an_smc_part_is_fully_native() {
    let tmp = tempfile::tempdir().unwrap();
    let mut app = app(tmp.path());
    let (writer, r) = rig(&app.paths.data_dir).split();
    symcockpit::writes::install(writer);
    done(&app, &["dim", "set", "0.6"]);
    // The fan/charge area's `restore` handler is the SMC half (it also writes
    // the history line).
    let hits = std::rc::Rc::new(std::cell::Cell::new(0));
    let h = hits.clone();
    app.handlers.register("restore", move |_, req| {
        assert!(matches!(
            req.params,
            symcockpit::app::Params::Write(symcockpit_core::write_commands::Command::Restore)
        ));
        h.set(h.get() + 1);
        Ok(symcockpit::app::Output::Json(json!({"applied": true})))
    });
    let o = done(&app, &["restore"]);
    assert_eq!(
        (o.stdout.as_str(), o.code),
        ("{\n  \"applied\" : true\n}\n", 0)
    );
    assert_eq!(hits.get(), 1, "the SMC half ran once");
    assert!(
        r.history.borrow().iter().all(|h| h.action != "restore"),
        "the SMC half logs the restore, not the display half"
    );
}

#[test]
fn profiles_round_trip_through_the_cli() {
    let e = env();
    done(&e.app, &["dim", "set", "0.6"]);
    let saved = done(&e.app, &["profile", "save", "night"]);
    assert_eq!(json_of(&saved.stdout), json!({"saved": "night"}));
    let list = done(&e.app, &["profile", "list"]);
    assert_eq!(json_of(&list.stdout)["profiles"][0]["name"], "night");
    done(&e.app, &["dim", "reset"]);
    assert_eq!(
        json_of(&done(&e.app, &["profile", "load", "night"]).stdout),
        json!({"applied": true})
    );
    assert!(
        e.rig
            .hw
            .dim_shown
            .get()
            .is_some_and(|d| (d - 0.6).abs() < 1e-6)
    );
    assert_eq!(
        json_of(&done(&e.app, &["profile", "delete", "night"]).stdout),
        json!({"applied": true})
    );
    assert_eq!(
        json_of(&done(&e.app, &["profile", "list"]).stdout),
        json!({"profiles": []})
    );
    let missing = done(&e.app, &["profile", "load", "night"]);
    assert_eq!(missing.code, 1);
    assert!(
        missing.stderr.starts_with(
            "symcockpit: {\"message\":\"The file “profile-night.json” couldn’t be opened"
        ),
        "{}",
        missing.stderr
    );
    let bad = done(&e.app, &["profile", "load", "../x"]);
    assert_eq!(
        (bad.stderr.as_str(), bad.code),
        ("symcockpit: Invalid profile name: '../x'.\n", 2)
    );
}

#[test]
fn awake_holds_an_assertion_for_the_duration_and_releases_it() {
    let e = env();
    let started = std::time::Instant::now();
    let o = done(&e.app, &["awake", "--seconds", "0.2", "--display"]);
    assert!(started.elapsed() >= std::time::Duration::from_millis(190));
    assert_eq!((o.stdout.as_str(), o.code), ("", 0));
    assert_eq!(
        o.stderr, "",
        "stderr is written live while blocking, not returned"
    );
    assert_eq!(e.rig.power.created.lock().unwrap().len(), 1);
    assert_eq!(e.rig.power.released.lock().unwrap().len(), 1);
    // --until HH:MM with a bad time never takes an assertion.
    done(&e.app, &["awake", "--until", "7"]);
    assert_eq!(e.rig.power.created.lock().unwrap().len(), 1);
}

#[test]
fn awake_zero_seconds_returns_at_once_and_a_failed_assertion_is_exit_1() {
    let e = env();
    assert_eq!(done(&e.app, &["awake", "-s", "0"]).code, 0);
    *e.rig.power.fail.lock().unwrap() = true;
    let o = done(&e.app, &["awake", "--for", "1s"]);
    assert_eq!(
        (o.stderr.as_str(), o.code),
        (
            "symcockpit: Failed to create power assertion (IOReturn -1).\n",
            1
        )
    );
}

#[test]
fn awake_off_prints_the_inactive_session() {
    let e = env();
    let o = done(&e.app, &["awake", "off"]);
    let v = json_of(&o.stdout);
    assert_eq!(
        (
            v["active"].clone(),
            v["reason"].clone(),
            v["prevent_display_sleep"].clone()
        ),
        (json!(false), json!(""), json!(false))
    );
}

// ------------------------------------------------------------------- status

#[test]
fn status_reports_the_overrides_this_process_holds() {
    let e = env();
    let ports = LiveOverrides(FakeSmc::closed());
    assert_eq!(ports.active_overrides(), json!({}));
    done(&e.app, &["brightness", "set", "0.8"]);
    done(&e.app, &["warmth", "set", "0.3"]);
    let o = ports.active_overrides();
    assert!(o["brightness"].is_f64() && o["warmth"].is_f64());
    assert!(!ports.keep_awake_active());
}

// ---------------------------------------------------------------------- MCP

#[test]
fn mcp_write_tools_answer_like_v012_and_run_directly() {
    let e = env();
    for (tool, arguments) in [
        ("set_brightness", json!({"value": 0.5})),
        ("set_extended_brightness", json!({"value": 1.4})),
        ("set_dim", json!({"value": "0.3"})),
        ("reset_dim", json!({})),
        ("set_warmth", json!({"value": 1})),
        ("reset_warmth", json!({})),
        ("delete_profile", json!({"name": "none"})),
    ] {
        assert_eq!(
            text(&mcp(&e, tool, arguments.clone())),
            r#"{"applied":true}"#,
            "{tool}"
        );
    }
    assert_eq!(
        text(&mcp(&e, "save_profile", json!({"name": "mcp"}))),
        r#"{"saved":"mcp"}"#
    );
    assert_eq!(
        text(&mcp(&e, "load_profile", json!({"name": "mcp"}))),
        r#"{"applied":true}"#
    );
    assert!(
        e.app.legacy.is_none(),
        "nothing went through the Swift core"
    );
    assert!(e.rig.hw.calls().contains(&"brightness 1 0.5".to_owned()));
}

#[test]
fn mcp_errors_are_internal_errors_with_the_swift_message() {
    let e = env();
    e.rig.hw.fail_brightness_set.set(true);
    let r = mcp(&e, "set_brightness", json!({"value": 0.5}));
    assert_eq!(
        (r["error"]["code"].clone(), r["error"]["message"].clone()),
        (json!(-32603), json!("brightness refused"))
    );
    let r = mcp(&e, "load_profile", json!({"name": "a/b"}));
    assert_eq!(r["error"]["message"], "Invalid profile name: 'a/b'.");
}

#[test]
fn mcp_keep_awake_sessions_live_in_the_server_process() {
    let e = env();
    let stopped = json_of(text(&mcp(&e, "keep_awake", json!({"enabled": false}))));
    assert_eq!(stopped["active"], false);
    let started = json_of(text(&mcp(
        &e,
        "keep_awake",
        json!({"enabled": true, "prevent_display_sleep": true, "duration_seconds": 60}),
    )));
    assert_eq!(
        (
            started["active"].clone(),
            started["prevent_display_sleep"].clone(),
            started["reason"].clone()
        ),
        (json!(true), json!(true), json!("symcockpit MCP keep_awake"))
    );
    assert!(started["expires_at"].is_f64());
    let status = json_of(text(&mcp(&e, "keep_awake_status", json!({}))));
    assert_eq!(status, started, "status reads the same session");
    // A second start returns the running session unchanged.
    let again = json_of(text(&mcp(&e, "keep_awake", json!({"enabled": true}))));
    assert_eq!(again, started);
    assert_eq!(e.rig.power.created.lock().unwrap().len(), 1);
    let ended = json_of(text(&mcp(&e, "keep_awake", json!({"enabled": false}))));
    assert_eq!(ended["active"], false);
    assert_eq!(e.rig.power.released.lock().unwrap().len(), 1);
    assert_eq!(
        json_of(text(&mcp(&e, "keep_awake_status", json!({}))))["active"],
        false
    );
    let _ = &e.tmp;
}

#[test]
fn shutdown_is_the_restore_on_exit() {
    let e = env();
    done(&e.app, &["dim", "set", "0.5"]);
    mcp(&e, "keep_awake", json!({"enabled": true}));
    symcockpit::writes::shutdown();
    assert_eq!(e.rig.hw.dim_shown.get(), None);
    assert_eq!(e.rig.power.released.lock().unwrap().len(), 1);
    symcockpit::writes::shutdown();
}
