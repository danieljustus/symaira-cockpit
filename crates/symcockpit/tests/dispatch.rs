//! The command line against fake services: what is answered natively, what is
//! forwarded, and the exact usage errors of v0.12.

mod common;

use common::{Overrides, app, args, done, forwarded};
use serde_json::json;
use symcockpit::app::{AREA_COMMANDS, Output, Params, ProcessSort, Request};
use symcockpit::cli::{Action, plan};
use symcockpit::help;
use symcockpit_testkit::hardware::FakeHardware;

fn home() -> tempfile::TempDir {
    tempfile::tempdir().unwrap()
}

#[test]
fn root_commands_match_the_v012_dispatcher() {
    let tmp = home();
    let a = app(tmp.path());
    for flag in ["help", "--help", "-h", "help", "--help --data-dir"] {
        let o = done(&a, &flag.split(' ').collect::<Vec<_>>());
        assert_eq!((o.stdout.as_str(), o.code), (help::ROOT_USAGE, 0), "{flag}");
    }
    let none = done(&a, &[]);
    assert_eq!(
        (none.stdout.as_str(), none.stderr.as_str(), none.code),
        ("", help::ROOT_USAGE, 2)
    );
    let unknown = done(&a, &["nope"]);
    assert_eq!(
        unknown.stderr,
        format!("symcockpit: unknown family 'nope'\n\n{}", help::ROOT_USAGE)
    );
    assert_eq!(unknown.code, 2);
    let tune = done(&a, &["tune", "sensors", "--json"]);
    assert_eq!(
        tune.stderr,
        "symcockpit: the 'tune' prefix was removed; run 'symcockpit sensors --json' instead.\n"
    );
    assert_eq!(
        done(&a, &["tune"]).stderr,
        "symcockpit: the 'tune' prefix was removed; run 'symcockpit <command>' instead.\n"
    );
    for family in ["operate", "scope"] {
        let o = done(&a, &[family]);
        assert_eq!(o.code, 4);
        assert_eq!(
            o.stderr,
            format!(
                "\nsymcockpit: '{family}' moved to Symaira Brain as an optional module.\nInstall it from a Brain checkout:\n  symbrain setup --from-source <brain-checkout> --modules {family}\n\nsymcockpit now ships hardware and system tuning only (thermals, power,\ndisplay, brightness). See docs/product-boundaries.md (PB-2026-09-09).\n"
            )
        );
    }
    // The version report still goes through the update-check logic.
    assert!(forwarded(&a, &["version"]) && forwarded(&a, &["-V"]) && forwarded(&a, &["--version"]));
}

#[test]
fn area_commands_are_forwarded_until_a_handler_is_registered() {
    let tmp = home();
    let mut a = app(tmp.path());
    let lines: [&[&str]; 9] = [
        &["sensors"],
        &["fan", "status"],
        &["battery"],
        &["awake", "status"],
        &["displays"],
        &["brightness", "get"],
        &["metrics"],
        &["processes"],
        &["top"],
    ];
    for l in lines {
        assert!(forwarded(&a, l), "{l:?}");
    }
    for name in AREA_COMMANDS {
        a.handlers.register(name, move |_, req| {
            assert_eq!(req.command, name);
            Ok(Output::Json(
                json!({"command": name, "ratio": 2.0, "path": "/x"}),
            ))
        });
    }
    for (l, name) in lines.iter().zip(AREA_COMMANDS) {
        let o = done(&a, l);
        assert_eq!(o.code, 0, "{l:?}");
        assert_eq!(
            o.stdout,
            format!("{{\n  \"command\" : \"{name}\",\n  \"path\" : \"/x\",\n  \"ratio\" : 2\n}}\n"),
            "{l:?}"
        );
    }
    // `brightness` alone is `brightness get`; `awake status` ignores what follows.
    assert_eq!(done(&a, &["brightness"]).code, 0);
    assert_eq!(done(&a, &["awake", "status", "--whatever"]).code, 0);
}

#[test]
fn bare_fan_profile_and_target_read_and_write_family_help_is_native() {
    let tmp = home();
    let mut a = app(tmp.path());
    a.handlers.register("fan.status", |_, _| {
        Ok(Output::Json(json!({"profile": "system"})))
    });
    for l in [&["fan", "profile"], &["fan", "target"], &["fan", "status"]] {
        assert_eq!(
            done(&a, l).stdout,
            "{\n  \"profile\" : \"system\"\n}\n",
            "{l:?}"
        );
    }
    for command in ["dim", "warmth", "fan", "battery-limit"] {
        let out = done(&a, &[command, "--help"]);
        assert_eq!(out.code, 0);
        assert!(
            out.stdout
                .starts_with(&format!("Usage: symcockpit {command} "))
        );
        assert_eq!(done(&a, &[command, "set", "-h"]).stdout, out.stdout);
    }
}

#[test]
fn fan_charge_and_the_endless_loops_are_always_forwarded() {
    let tmp = home();
    let mut a = app(tmp.path());
    a.handlers
        .register("sensors", |_, _| Ok(Output::Json(json!({}))));
    for l in [
        &["fan", "set", "0.5"][..],
        &["fan", "auto"],
        &["fan", "profile", "comfort"],
        &["fan", "target", "70"],
        &["fan", "governor"],
        &["battery-limit", "set", "80"],
        &["battery-limit", "clear"],
        &["ai-usage", "serve"],
        &["status", "--watch"],
        &["status", "--watch", "--interval", "2s"],
    ] {
        assert!(forwarded(&a, l), "{l:?}");
    }
}

#[test]
fn usage_errors_have_the_swift_messages_and_exit_2() {
    let tmp = home();
    let a = app(tmp.path());
    for (l, message) in [
        (
            &["sensors", "--bogus"][..],
            "sensors: unexpected argument '--bogus'",
        ),
        (
            &["doctor", "--bogus"],
            "doctor: unexpected argument '--bogus'",
        ),
        (
            &["battery", "x", "--json"],
            "battery: unexpected argument 'x'",
        ),
        (
            &["metrics", "--bogus"],
            "metrics: unexpected argument '--bogus'",
        ),
        (&["status", "--bogus"], "status: unknown option '--bogus'"),
        (&["status", "--help"], "status: unknown option '--help'"),
        (
            &["status", "--interval"],
            "status: --interval requires a value.",
        ),
        (&["history", "--bogus"], "history: unknown option '--bogus'"),
        (
            &["history", "--limit", "x"],
            "history: --limit requires an integer value",
        ),
        (
            &["processes", "--sort"],
            "processes: --sort expects 'cpu', 'memory', or 'gpu'",
        ),
        (
            &["processes", "--sort", "disk"],
            "processes: --sort expects 'cpu', 'memory', or 'gpu'",
        ),
        (
            &["top", "--limit", "0"],
            "processes: --limit expects a positive integer",
        ),
        (
            &["processes", "--interval", "0"],
            "processes: --interval expects a positive number of seconds",
        ),
        (
            &["processes", "--bogus"],
            "processes: unexpected argument '--bogus'",
        ),
        (
            &["brightness", "get", "extra"],
            "brightness get: unexpected argument 'extra'",
        ),
        (
            &["fan", "status", "extra"],
            "fan status: unexpected argument 'extra'",
        ),
        (
            &["profile"],
            "profile: expected subcommand (save, load, list, delete).",
        ),
        (
            &["profile", "list", "extra"],
            "profile list: unexpected argument 'extra'",
        ),
        (
            &["profile", "save", "a", "b"],
            "profile save: unexpected argument 'b'",
        ),
        (
            &["profile", "bogus", "a", "b"],
            "profile bogus: unexpected argument 'b'",
        ),
        (&["sensors", "--data-dir"], "--data-dir: expected a path"),
        (
            &["ai-usage", "a", "b"],
            "ai-usage: expected one provider and optional --json/--force",
        ),
        (
            &["ai-usage", "--bogus"],
            "ai-usage: expected one provider and optional --json/--force",
        ),
        (&["ai-usage", "nope"], "ai-usage: unknown provider 'nope'"),
    ] {
        let o = done(&a, l);
        assert_eq!(
            (o.stderr.as_str(), o.code, o.stdout.as_str()),
            (format!("symcockpit: {message}\n").as_str(), 2, ""),
            "{l:?}"
        );
    }
}

#[test]
fn help_of_read_commands_is_native_and_restore_is_forwarded() {
    let tmp = home();
    let a = app(tmp.path());
    for c in ["sensors", "battery", "displays", "permissions", "doctor"] {
        assert_eq!(
            done(&a, &[c, "--help"]).stdout,
            help::always_json(c).unwrap(),
            "{c}"
        );
        assert_eq!(
            done(&a, &[c, "--json", "-h"]).stdout,
            help::always_json(c).unwrap(),
            "{c}"
        );
    }
    assert_eq!(done(&a, &["metrics", "--help"]).stdout, help::METRICS);
    assert_eq!(done(&a, &["processes", "-h"]).stdout, help::PROCESSES);
    assert_eq!(done(&a, &["top", "--help"]).stdout, help::PROCESSES);
    assert!(
        done(&a, &["history", "--help"])
            .stdout
            .starts_with("Usage: symcockpit history")
    );
    assert!(
        done(&a, &["ai-usage", "--help"])
            .stdout
            .starts_with("Usage: symcockpit ai-usage")
    );
    assert!(
        done(&a, &["profile", "--help"])
            .stdout
            .starts_with("Usage: symcockpit profile save")
    );
    assert!(
        done(&a, &["profile", "save", "-h"])
            .stdout
            .starts_with("Usage: symcockpit profile save")
    );
    // The write families' usage text is native too (see the next test); `restore`
    // has none: Swift treats `--help` as an unexpected argument (exit 2).
    let restore = done(&a, &["restore", "--help"]);
    assert_eq!(
        (restore.stderr.as_str(), restore.code),
        ("symcockpit: restore: unexpected argument '--help'\n", 2)
    );
}

#[test]
fn process_options_reach_the_handler_parsed() {
    let tmp = home();
    let mut a = app(tmp.path());
    a.handlers.register("processes", |_, req: &Request| {
        let Params::Processes(p) = &req.params else { panic!("no params") };
        Ok(Output::Json(json!({"sort": p.sort.as_str(), "limit": p.limit, "interval": p.interval, "json": req.json})))
    });
    let o = done(
        &a,
        &[
            "processes",
            "--sort",
            "MEMORY",
            "--limit",
            "12",
            "--interval",
            "0.5",
            "--json",
        ],
    );
    assert!(
        o.stdout.contains("\"sort\" : \"memory\"")
            && o.stdout.contains("\"limit\" : 12")
            && o.stdout.contains("\"interval\" : 0.5"),
        "{}",
        o.stdout
    );
    assert_eq!(ProcessSort::parse("Gpu"), Some(ProcessSort::Gpu));
    let defaults = done(&a, &["processes"]);
    assert!(
        defaults.stdout.contains("\"limit\" : 6") && defaults.stdout.contains("\"json\" : false")
    );
}

#[test]
fn handler_errors_become_stderr_lines_with_the_error_exit_code() {
    let tmp = home();
    let mut a = app(tmp.path());
    a.handlers.register("sensors", |_, _| {
        Err(symcockpit_contract::Error::Permission("no access".into()))
    });
    a.handlers.register("battery", |_, _| {
        Err(symcockpit_contract::Error::Unsupported("no battery".into()))
    });
    a.handlers.register("displays", |_, _| {
        Err(symcockpit_contract::Error::Failed("boom".into()))
    });
    for (c, line, code) in [
        ("sensors", "permission error: no access", 3),
        ("battery", "unsupported: no battery", 4),
        ("displays", "boom", 1),
    ] {
        let o = done(&a, &[c]);
        assert_eq!(
            (o.stderr, o.code, o.stdout),
            (format!("symcockpit: {line}\n"), code, String::new())
        );
    }
}

#[test]
#[should_panic(expected = "no handler slot")]
fn registering_a_name_outside_the_register_is_a_programming_error() {
    let tmp = home();
    app(tmp.path())
        .handlers
        .register("fan.setz", |_, _| Ok(Output::text("")));
}

#[test]
fn any_command_of_the_register_can_get_a_handler() {
    let tmp = home();
    let mut a = app(tmp.path());
    for spec in symcockpit_contract::commands() {
        a.handlers.register(spec.name, |_, _| Ok(Output::text("")));
    }
}

#[test]
fn history_and_profile_list_read_the_data_directory() {
    let tmp = home();
    let a = app(tmp.path());
    // No data directory at all: empty results, and nothing is created.
    assert_eq!(
        done(&a, &["history"]).stdout,
        "No history events recorded.\n"
    );
    assert_eq!(done(&a, &["history", "--json"]).stdout, "[\n\n]\n");
    assert_eq!(
        done(&a, &["profile", "list"]).stdout,
        "{\n  \"profiles\" : [\n\n  ]\n}\n"
    );
    assert!(!a.paths.data_dir.exists());

    let data = tmp.path().join("custom");
    std::fs::create_dir_all(&data).unwrap();
    std::fs::write(
        data.join("history.ndjson"),
        "{\"action\":\"fan.set\",\"payload\":{\"action\":\"fan.set\",\"requested_value\":2,\"clamped_value\":1,\"result\":\"failed\",\"error_reason\":\"permission error: x\",\"timestamp\":\"2026-11-19T09:00:00Z\"},\"schema_version\":1,\"source\":\"tune\",\"timestamp\":\"2026-11-19T09:00:00Z\"}\n",
    )
    .unwrap();
    std::fs::write(
        data.join("profile-work.json"),
        "{\"name\":\"work\",\"createdAt\":1,\"updatedAt\":2,\"dim\":0.5}",
    )
    .unwrap();
    let dir = data.to_str().unwrap();
    let text = done(&a, &["history", "--data-dir", dir]);
    assert_eq!(
        text.stdout.lines().nth(2),
        Some("T1795078800 fan.set 2.00 1.00 n/a failed permission error: x")
    );
    let json = done(&a, &["--data-dir", dir, "history", "--json"]);
    assert_eq!(
        json.code, 2,
        "the command must come first, like at the root of v0.12"
    );
    let json = done(&a, &["history", "--json", "-n", "1", "--data-dir", dir]);
    assert!(
        json.stdout.contains("\"timestamp\" : 816771600")
            && json.stdout.contains("\"clamped_value\" : 1,"),
        "{}",
        json.stdout
    );
    let profiles = done(&a, &["profile", "list", "--data-dir", dir]);
    assert!(
        profiles.stdout.contains("\"name\" : \"work\"")
            && profiles.stdout.contains("\"dim\" : 0.5"),
        "{}",
        profiles.stdout
    );
}

#[test]
fn doctor_permissions_and_status_wait_for_their_ports() {
    let tmp = home();
    let mut a = app(tmp.path());
    for c in ["doctor", "permissions", "status"] {
        assert!(forwarded(&a, &[c]), "{c} before wiring");
    }
    a.services.hardware = Some(Box::new(FakeHardware::default()));
    let doctor = done(&a, &["doctor", "--json"]);
    assert!(
        doctor.stdout.contains("\"tool\" : \"symcockpit\"")
            && doctor.stdout.contains("\"id\" : \"battery.chargeLimit\"")
    );
    assert!(
        doctor
            .stdout
            .contains(&format!("\"version\" : \"{}\"", symcockpit::VERSION))
    );
    let permissions = done(&a, &["permissions"]);
    assert!(
        permissions.stdout.contains("\"history_writable\" : true")
            && permissions.stdout.contains("\"mcp_mode\" : \"full\"")
    );
    // Status needs the three reports and the live overrides.
    assert!(forwarded(&a, &["status"]));
    a.handlers.register("sensors", |_, _| {
        Ok(Output::Json(
            json!({"thermal_pressure": "nominal", "smc_supported": true}),
        ))
    });
    a.handlers.register("battery", |_, _| {
        Ok(Output::Json(json!({"present": true, "health_percent": 86})))
    });
    a.handlers.register("displays", |_, _| {
        Ok(Output::Json(json!({"displays": [], "notes": []})))
    });
    assert!(forwarded(&a, &["status"]), "overrides port still missing");
    a.services.overrides = Some(Box::new(Overrides(json!({"fan_fraction": 0.5}), true)));
    let json = done(&a, &["status", "--json"]);
    assert!(
        json.stdout.contains("\"health_score\" : 100")
            && json.stdout.contains("\"fan_fraction\" : 0.5"),
        "{}",
        json.stdout
    );
    assert!(json.stdout.contains("Keep-awake assertion is active"));
    let text = done(&a, &["status"]);
    assert!(
        text.stdout
            .starts_with("symcockpit health: System health is optimal. (Score: 100/100)\n"),
        "{}",
        text.stdout
    );
    assert!(text.stdout.contains("- Fan: 50%"));
    assert!(forwarded(&a, &["status", "--watch"]));
}

#[test]
fn config_warnings_go_to_stderr_before_the_result() {
    let tmp = home();
    let mut a = app(tmp.path());
    a.env.insert("SYMTUNE_DIM_MIN".into(), "0.9".into());
    a.env.insert("SYMTUNE_DIM_MAX".into(), "0.5".into());
    let o = done(&a, &["profile", "list"]);
    assert_eq!(o.code, 0);
    assert_eq!(
        o.stderr,
        "symcockpit: config error: inverted min/max range detected, falling back to defaults\n"
    );
    assert!(
        done(&a, &["history", "--bogus"])
            .stderr
            .starts_with("symcockpit: config error: inverted")
    );
}

#[test]
fn ai_usage_runs_symbrain_through_the_port_only() {
    let tmp = home();
    let mut a = app(tmp.path());
    a.services.usage_runner = Box::new(symcockpit_testkit::symbrain::FakeSymbrain::replying(
        r#"{"schema_version":1,"providers":[{"id":"claude","display_name":"Claude","configured":false,"auth_status":{"status":"missing","detail":"x"}}]}"#,
    ));
    let json = done(&a, &["ai-usage", "claude", "--json", "--force"]);
    assert_eq!(
        json.stdout,
        "[\n  {\n    \"error\" : \"not configured\",\n    \"provider_id\" : \"claude\"\n  }\n]\n"
    );
    assert_eq!(
        done(&a, &["ai-usage", "claude"]).stdout,
        "claude: not set up (not configured)\n"
    );
    let all = done(&a, &["ai-usage", "--json"]);
    assert_eq!(all.stdout.matches("\"provider_id\"").count(), 14);
    // A runner failure is reported per provider and exits 0, like v0.12.
    a.services.usage_runner = Box::new(symcockpit_testkit::symbrain::FakeSymbrain::unavailable());
    let none = done(&a, &["ai-usage", "codex", "--json"]);
    assert_eq!(
        (none.code, none.stdout.contains("symbrain is not installed")),
        (0, true)
    );
}

#[test]
fn serve_is_a_separate_action_with_its_data_dir() {
    let tmp = home();
    let a = app(tmp.path());
    assert!(matches!(
        plan(&a, &args(&["serve"])),
        Action::Serve {
            data_dir_override: None
        }
    ));
    match plan(&a, &args(&["serve", "--data-dir", "/x", "extra"])) {
        Action::Serve { data_dir_override } => assert_eq!(
            data_dir_override.as_deref(),
            Some(std::path::Path::new("/x"))
        ),
        _ => panic!("not serving"),
    }
    assert_eq!(done(&a, &["serve", "--data-dir"]).code, 2);
}

#[test]
fn write_commands_parse_natively_and_run_through_their_wired_handler() {
    use symcockpit::app::WRITE_COMMANDS;
    use symcockpit_core::write_commands::Command;

    let tmp = home();
    let mut a = app(tmp.path());
    // Usage errors never reach a handler or the Swift core: v0.12's texts and exit 2.
    for (line, message) in [
        (
            &["fan", "set"][..],
            "fan set: expected a numeric value, e.g. `symcockpit fan set set 1.4`",
        ),
        (
            &["fan", "set", "fast"],
            "fan set: unexpected argument 'fast'",
        ),
        (&["fan", "auto", "x"], "fan auto: unexpected argument 'x'"),
        (&["fan", "nan"], "Value must be finite."),
        (
            &["fan", "governor", "--state"],
            "fan governor: --state requires a path.",
        ),
        (
            &["battery-limit"],
            "battery-limit set: expected an integer value, e.g. `symcockpit battery-limit set set 80`",
        ),
        (
            &["battery-limit", "clear", "x"],
            "battery-limit clear: unexpected argument 'x'",
        ),
        (&["restore", "now"], "restore: unexpected argument 'now'"),
    ] {
        let o = done(&a, line);
        assert_eq!(
            (o.stderr.as_str(), o.code),
            (&*format!("symcockpit: {message}\n"), 2),
            "{line:?}"
        );
    }

    // Without a wired handler (a test app, a build without the live ports) the Swift core decides.
    for line in [
        &["fan", "set", "0.5"][..],
        &["fan", "auto"],
        &["fan", "governor"],
        &["battery-limit", "set", "80"],
        &["battery-limit", "clear"],
        &["fan", "profile", "comfort"],
    ] {
        assert!(forwarded(&a, line), "{line:?}");
    }

    // Wired: the parsed command reaches the handler, `{"applied": true}` comes back, errors keep their exit codes.
    let seen = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    for name in WRITE_COMMANDS {
        let seen = seen.clone();
        a.handlers.register(name, move |_, req: &Request| {
            let Params::Write(command) = &req.params else {
                panic!("not a write request");
            };
            seen.borrow_mut().push((req.command, command.clone()));
            match command {
                Command::Restore => Err(symcockpit_contract::Error::Permission("no".into())),
                _ => Ok(Output::Json(json!({"applied": true}))),
            }
        });
    }
    let ok = done(&a, &["fan", "set", "0.5"]);
    assert_eq!(
        (ok.stdout.as_str(), ok.code),
        ("{\n  \"applied\" : true\n}\n", 0)
    );
    assert_eq!(done(&a, &["fan", "0.25"]).code, 0);
    assert_eq!(done(&a, &["fan", "auto"]).code, 0);
    assert_eq!(done(&a, &["battery-limit", "set", "80"]).code, 0);
    assert_eq!(done(&a, &["battery-limit", "clear"]).code, 0);
    // `restore` runs its display half first (tests/writes.rs), then this handler.
    assert_eq!(
        *seen.borrow(),
        vec![
            ("fan.set", Command::FanSet(0.5)),
            ("fan.set", Command::FanSet(0.25)),
            ("fan.auto", Command::FanAuto),
            ("battery-limit.set", Command::ChargeSet(80)),
            ("battery-limit.clear", Command::ChargeClear),
        ]
    );
}
