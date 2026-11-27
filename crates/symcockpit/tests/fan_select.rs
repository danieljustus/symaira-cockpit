//! `fan profile <name>` and `fan target <°C>|off` against a temporary HOME: the
//! file bytes, the history line, the texts and exit codes of the v0.12 binary
//! (observed once on `symcockpit` 0.12.2; the fan status document is a fake).

mod common;

use common::{FakeFanControl, FanControlCounter, app, done, unavailable};
use serde_json::{Value, json};
use symcockpit::app::{App, Context, Output};
use symcockpit::mcp::Server;
use symcockpit_store::{Config, read_history_records};

fn fan_app(home: &std::path::Path) -> App {
    let mut a = app(home);
    // What `fan status` reads from the file, like the real handler does.
    let file = a.paths.fan_profile_file();
    a.handlers.register("fan.status", move |_, _| {
        let bytes = std::fs::read(&file).unwrap_or_default();
        let selection = symcockpit_core::sensors::FanSelection::from_json(&bytes);
        Ok(Output::Json(json!({
            "profile": selection.profile.as_str(),
            "governor_running": false,
            "cool_target_celsius": selection.cool_target_celsius,
            "average_cluster_celsius": 84.5,
            "software_override": false,
            "fans": [],
        })))
    });
    a
}

fn file(a: &App) -> String {
    std::fs::read_to_string(a.paths.fan_profile_file()).unwrap_or_default()
}

fn pretty(profile: &str, target: &str) -> String {
    format!(
        concat!(
            "{{\n",
            "  \"average_cluster_celsius\" : 84.5,\n",
            "  \"cool_target_celsius\" : {target},\n",
            "  \"fans\" : [\n\n  ],\n",
            "  \"governor_running\" : false,\n",
            "  \"profile\" : \"{profile}\",\n",
            "  \"software_override\" : false\n",
            "}}\n"
        ),
        target = target,
        profile = profile
    )
}

const STORED: &str = "Stored. The target applies while the fan control is on Cool (`symcockpit fan profile comfort`).\n";

#[test]
fn a_sequence_writes_the_swift_file_and_history_and_prints_the_swift_texts() {
    let tmp = tempfile::tempdir().unwrap();
    let a = fan_app(tmp.path());

    let o = done(&a, &["fan", "target", "72.5"]);
    assert_eq!(
        (o.stdout, o.stderr, o.code),
        (pretty("system", "72.5"), STORED.to_owned(), 0)
    );
    assert_eq!(
        file(&a),
        r#"{"profile":"system","cool_target_celsius":72.5}"#
    );

    let o = done(&a, &["fan", "profile", "comfort"]);
    assert_eq!(
        o.stdout,
        format!(
            "Selected comfort. No fan governor is running \u{2014} start one with `sudo symcockpit fan governor`.\n{}",
            pretty("comfort", "72.5")
        )
    );
    assert_eq!(
        file(&a),
        r#"{"profile":"comfort","cool_target_celsius":72.5}"#
    );

    // On Cool the target needs no hint.
    let o = done(&a, &["fan", "target", "70"]);
    assert_eq!(
        (o.stdout, o.stderr),
        (pretty("comfort", "70"), String::new())
    );

    let o = done(&a, &["fan", "target", "OFF"]);
    assert_eq!(o.stdout, pretty("comfort", "null"));
    assert_eq!(file(&a), r#"{"profile":"comfort"}"#);

    // `system` prints no governor hint and keeps the stored target out of it.
    let o = done(&a, &["fan", "profile", "SYSTEM"]);
    assert_eq!(o.stdout, pretty("system", "null"));

    let history = read_history_records(&a.paths.data_dir.join("history.ndjson"), None);
    let lines: Vec<(&str, Value, Value)> = history
        .iter()
        .map(|r| {
            (
                r.action.as_str(),
                r.payload
                    .get("requested_value")
                    .cloned()
                    .unwrap_or(Value::Null),
                r.payload
                    .get("clamped_value")
                    .cloned()
                    .unwrap_or(Value::Null),
            )
        })
        .collect();
    assert_eq!(
        lines,
        [
            ("fan.cooltarget", json!(72.5), json!(72.5)),
            ("fan.profile.comfort", Value::Null, Value::Null),
            ("fan.cooltarget", json!(70), json!(70)),
            ("fan.cooltarget", Value::Null, Value::Null),
            ("fan.profile.system", Value::Null, Value::Null),
        ]
    );
    assert!(history.iter().all(|r| r.payload["result"] == "success"));
}

#[test]
fn selecting_system_with_a_stale_override_hands_the_fans_back() {
    let tmp = tempfile::tempdir().unwrap();
    let mut a = fan_app(tmp.path());
    let counter = FanControlCounter::default();
    a.services.fan_control = Some(Box::new(FakeFanControl {
        software_override: true,
        counter: counter.clone(),
        ..FakeFanControl::default()
    }));
    // Store a non-system selection first, so the switch is a real change.
    done(&a, &["fan", "profile", "comfort"]);
    let o = done(&a, &["fan", "profile", "system"]);
    assert_eq!(o.code, 0);
    assert_eq!(counter.count(), 1, "the SMC is handed back once");
    assert!(
        read_history_records(&a.paths.data_dir.join("history.ndjson"), None)
            .iter()
            .all(|r| r.payload["result"] == "success")
    );
}

#[test]
fn profile_and_target_changes_route_the_helper_governor() {
    // The agent/CLI starts or retargets the governor for a non-System
    // selection and stops it for System; the fake port records the calls so
    // no XPC or SMC is touched. The action mapping itself is unit-tested in
    // symcockpit-core.
    let tmp = tempfile::tempdir().unwrap();
    let mut a = fan_app(tmp.path());
    let fake = FakeFanControl::default();
    let routed = fake.routed.clone();
    a.services.fan_control = Some(Box::new(fake));

    for argv in [
        &["fan", "profile", "comfort"][..],
        &["fan", "target", "72.5"],
        &["fan", "profile", "performance"],
        &["fan", "profile", "system"],
    ] {
        assert_eq!(done(&a, argv).code, 0);
    }

    use symcockpit_core::sensors::FanProfile;
    let calls = routed.borrow();
    assert_eq!(calls.len(), 4, "every selection is routed");
    assert_eq!(calls[0].profile, FanProfile::Comfort);
    assert_eq!(calls[1].profile, FanProfile::Comfort);
    assert_eq!(calls[1].cool_target_celsius, Some(72.5), "target retargets");
    assert_eq!(calls[2].profile, FanProfile::Performance);
    assert_eq!(calls[3].profile, FanProfile::System, "System stops it");
}

#[test]
fn a_failed_handback_is_a_failed_profile_switch() {
    let tmp = tempfile::tempdir().unwrap();
    let mut a = fan_app(tmp.path());
    let counter = FanControlCounter::default();
    a.services.fan_control = Some(Box::new(FakeFanControl {
        software_override: true,
        restore_error: Some("SMC rejected F0Md".into()),
        counter: counter.clone(),
        ..FakeFanControl::default()
    }));
    let o = done(&a, &["fan", "profile", "system"]);
    assert_eq!(o.code, 1);
    assert!(o.stderr.contains("SMC rejected F0Md"));
    assert_eq!(counter.count(), 1);
    let history = read_history_records(&a.paths.data_dir.join("history.ndjson"), None);
    assert_eq!(history.len(), 1);
    assert_eq!(history[0].action, "fan.profile.system");
    assert_eq!(history[0].payload["result"], "failed");
    assert!(
        history[0].payload["error_reason"]
            .as_str()
            .unwrap()
            .contains("SMC rejected F0Md")
    );
}

#[test]
fn a_switch_without_elevation_is_failed_in_history_with_the_reason() {
    let tmp = tempfile::tempdir().unwrap();
    let mut a = fan_app(tmp.path());
    a.services.fan_control = Some(Box::new(FakeFanControl {
        elevation_error: Some("stale /usr/local/bin/symcockpit 0.11.0; no helper".into()),
        ..FakeFanControl::default()
    }));
    let o = done(&a, &["fan", "profile", "comfort"]);
    assert_eq!(o.code, 3);
    assert!(o.stderr.contains("stale /usr/local/bin/symcockpit"));
    assert_eq!(file(&a), "", "nothing was selected");
    let history = read_history_records(&a.paths.data_dir.join("history.ndjson"), None);
    assert_eq!(history.len(), 1);
    assert_eq!(history[0].action, "fan.profile.comfort");
    assert_eq!(history[0].payload["result"], "failed");
    assert!(
        history[0].payload["error_reason"]
            .as_str()
            .unwrap()
            .contains("stale /usr/local/bin/symcockpit")
    );
}

#[test]
fn bad_arguments_exit_2_with_the_swift_messages_and_change_nothing() {
    let tmp = tempfile::tempdir().unwrap();
    let a = fan_app(tmp.path());
    for (line, message) in [
        (
            &["fan", "profile", "bogus"][..],
            "fan profile: expected one of system, comfort, performance.",
        ),
        (
            &["fan", "target", "90"],
            "fan target: expected a number from 50 to 85 (\u{b0}C), or 'off'.",
        ),
        (
            &["fan", "target", "abc"],
            "fan target: expected a number from 50 to 85 (\u{b0}C), or 'off'.",
        ),
        (
            &["fan", "target", "60", "x"],
            "fan target: unexpected argument 'x'",
        ),
    ] {
        let o = done(&a, line);
        assert_eq!(
            (o.stderr.as_str(), o.code),
            (&*format!("symcockpit: {message}\n"), 2),
            "{line:?}"
        );
        assert!(o.stdout.is_empty());
    }
    assert_eq!(file(&a), "");
    assert!(!a.paths.data_dir.join("history.ndjson").exists());
}

#[test]
fn a_corrupt_file_counts_as_system_and_is_replaced() {
    let tmp = tempfile::tempdir().unwrap();
    let a = fan_app(tmp.path());
    std::fs::create_dir_all(a.paths.fan_profile_file().parent().unwrap()).unwrap();
    std::fs::write(a.paths.fan_profile_file(), "{nope").unwrap();
    done(&a, &["fan", "profile", "performance"]);
    assert_eq!(file(&a), r#"{"profile":"performance"}"#);
    use std::os::unix::fs::PermissionsExt;
    let mode = |p: &std::path::Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(&a.paths.fan_profile_file()), 0o600);
    assert_eq!(mode(a.paths.fan_profile_file().parent().unwrap()), 0o700);
}

#[test]
fn without_a_status_handler_it_is_unsupported_and_writes_nothing() {
    let tmp = tempfile::tempdir().unwrap();
    let a = app(tmp.path());
    assert!(unavailable(&a, &["fan", "profile", "comfort"]));
    assert_eq!(file(&a), "", "nothing was written");
}

#[test]
fn the_app_agent_commands_run_natively_too() {
    let tmp = tempfile::tempdir().unwrap();
    let a = fan_app(tmp.path());
    let config = Config::default();
    let ctx = Context {
        config: &config,
        paths: &a.paths,
        data_dir: &a.paths.data_dir,
        data_dir_override: None,
        env: &a.env,
        services: &a.services,
    };
    let server = Server::new(&a, &ctx);
    let run = |name: &str, params: Value| {
        let spec = symcockpit_contract::commands()
            .iter()
            .find(|c| c.name == name)
            .unwrap();
        server.run_spec(spec, params.as_object().unwrap())
    };
    assert_eq!(
        run("fan.target", json!({"celsius": 70})).unwrap()["cool_target_celsius"],
        70.0
    );
    assert_eq!(
        run("fan.profile", json!({"profile": "comfort"})).unwrap()["profile"],
        "comfort"
    );
    assert_eq!(
        file(&a),
        r#"{"profile":"comfort","cool_target_celsius":70}"#
    );
    assert_eq!(
        run("fan.target", json!({"celsius": "off"})).unwrap()["cool_target_celsius"],
        Value::Null
    );
    // The app clears with null.
    assert_eq!(
        run("fan.target", json!({"celsius": null})).unwrap()["cool_target_celsius"],
        Value::Null
    );
    assert!(run_err(&server, "fan.profile", json!({})).contains("requires 'profile'"));
    assert!(
        run_err(&server, "fan.profile", json!({"profile": null})).contains("requires 'profile'")
    );
    assert!(run_err(&server, "fan.target", json!({"celsius": 99})).contains("expected a number"));
}

fn run_err(server: &Server, name: &str, params: Value) -> String {
    let spec = symcockpit_contract::commands()
        .iter()
        .find(|c| c.name == name)
        .unwrap();
    server
        .run_spec(spec, params.as_object().unwrap())
        .unwrap_err()
        .to_string()
}
