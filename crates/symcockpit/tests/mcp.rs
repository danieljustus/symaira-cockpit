//! The MCP server in-process: wire behaviour of v0.12 (observed on the Swift
//! binary), tool visibility, native read tools, and the Swift-core subprocess
//! path for write tools — only ever against a fake legacy script.

mod common;

use std::path::Path;

use common::app;
use serde_json::{Value, json};
use symcockpit::app::{App, Context, Output};
use symcockpit::mcp::{Server, tools, tools_list};
use symcockpit_store::Config;
use symcockpit_testkit::legacy::FakeLegacy;

struct Fixture {
    tmp: tempfile::TempDir,
    app: App,
}

fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let app = app(tmp.path());
    // The display, keep-awake and profile writes run in-process: fakes only.
    symcockpit::writes::install(
        symcockpit_testkit::tune_write::rig(&app.paths.data_dir)
            .split()
            .0,
    );
    Fixture { tmp, app }
}

impl Fixture {
    fn with_legacy(&mut self, stdout: &str, stderr: &str, exit: i32) -> FakeLegacy {
        let dir = self.tmp.path().join("bin");
        std::fs::create_dir_all(&dir).unwrap();
        let fake = FakeLegacy::new(&dir, stdout, stderr, exit);
        self.app.legacy = Some(fake.path.clone());
        fake
    }

    /// Sends one request line with the given config mode and data dir override.
    fn ask_with(&self, mode: &str, data_dir: Option<&Path>, line: &str) -> Option<Value> {
        let config = Config {
            mcp_mode: mode.into(),
            ..Config::default()
        };
        let data = data_dir.map_or_else(|| self.app.paths.data_dir.clone(), Path::to_path_buf);
        let ctx = Context {
            config: &config,
            paths: &self.app.paths,
            data_dir: &data,
            data_dir_override: data_dir,
            env: &self.app.env,
            services: &self.app.services,
        };
        Server::new(&self.app, &ctx).handle_line(line)
    }

    fn ask(&self, line: &str) -> Value {
        self.ask_with("full", None, line).expect("a response")
    }

    fn call(&self, tool: &str, arguments: Value) -> Value {
        self.ask(&json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": arguments}}).to_string())
    }
}

fn error_of(response: &Value) -> (i64, &str) {
    (
        response["error"]["code"].as_i64().unwrap(),
        response["error"]["message"].as_str().unwrap(),
    )
}

fn text_of(response: &Value) -> &str {
    assert_eq!(response["result"]["isError"], false, "{response}");
    assert_eq!(response["result"]["content"][0]["type"], "text");
    response["result"]["content"][0]["text"].as_str().unwrap()
}

#[test]
fn handshake_and_protocol_errors_match_the_swift_server() {
    let f = fixture();
    // Transcript recorded from the v0.12 binary (`symcockpit serve`).
    let init = f.ask(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"x","version":"1"}}}"#);
    assert_eq!(
        init,
        json!({"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"symcockpit","version":symcockpit::VERSION},"capabilities":{"tools":{"listChanged":false}}}})
    );
    assert_eq!(
        f.ask(r#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#),
        json!({"jsonrpc":"2.0","id":2,"result":{}})
    );
    assert_eq!(
        f.ask(r#"{"id":12,"method":"ping"}"#)["id"],
        12,
        "jsonrpc is optional"
    );
    assert_eq!(
        f.ask(r#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#)["id"],
        "abc"
    );
    for (line, id, code, message) in [
        ("not json", Value::Null, -32700, "Parse error"),
        ("[1]", Value::Null, -32600, "Invalid Request"),
        ("5", Value::Null, -32600, "Invalid Request"),
        (
            r#"{"jsonrpc":"2.0","id":1.5,"method":"ping"}"#,
            Value::Null,
            -32600,
            "Invalid Request",
        ),
        (
            r#"{"jsonrpc":"2.0","id":13,"method":5}"#,
            Value::Null,
            -32600,
            "Invalid Request",
        ),
        (
            r#"{"jsonrpc":2,"id":13,"method":"ping"}"#,
            Value::Null,
            -32600,
            "Invalid Request",
        ),
        (
            r#"{"jsonrpc":"1.0","id":4,"method":"ping"}"#,
            json!(4),
            -32600,
            "Invalid Request: jsonrpc must be \"2.0\"",
        ),
        (
            r#"{"jsonrpc":"2.0","id":3,"method":"nope"}"#,
            json!(3),
            -32601,
            "Method not found: nope",
        ),
        (
            r#"{"jsonrpc":"2.0","id":14,"method":"initialize","params":5}"#,
            json!(14),
            -32602,
            "Invalid params: Type mismatch: expected Dictionary<String, Any>",
        ),
        (
            r#"{"jsonrpc":"2.0","id":14,"method":"initialize","params":{"protocolVersion":1}}"#,
            json!(14),
            -32602,
            "Invalid params: Type mismatch: expected String",
        ),
        (
            r#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{}}"#,
            json!(6),
            -32602,
            "Invalid params: Missing key: name",
        ),
        (
            r#"{"jsonrpc":"2.0","id":8,"method":"tools/call"}"#,
            json!(8),
            -32602,
            "Invalid params: Missing key: name",
        ),
        (
            r#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":5}}"#,
            json!(7),
            -32602,
            "Invalid params: Type mismatch: expected String",
        ),
        (
            r#"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"get_history","arguments":5}}"#,
            json!(11),
            -32602,
            "Invalid params: Type mismatch: expected Dictionary<String, Any>",
        ),
        (
            r#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nonesuch"}}"#,
            json!(5),
            -32603,
            "Unknown tool 'nonesuch'.",
        ),
    ] {
        let response = f.ask(line);
        assert_eq!(response["id"], id, "{line}");
        assert_eq!(error_of(&response), (code, message), "{line}");
        assert_eq!(response["jsonrpc"], "2.0");
    }
    // `tools/list` takes any params; notifications are never answered, not even with an error.
    assert!(
        f.ask(r#"{"jsonrpc":"2.0","id":15,"method":"tools/list","params":5}"#)["result"]["tools"]
            .is_array()
    );
    for line in [
        r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        r#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#,
        r#"{"jsonrpc":"2.0","method":"nope"}"#,
    ] {
        assert!(f.ask_with("full", None, line).is_none(), "{line}");
    }
}

#[test]
fn tools_list_equals_the_recorded_v012_result() {
    let f = fixture();
    let fixture_text = std::fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../oracle/v0.12/cases/mcp-tools-list.json"),
    )
    .unwrap();
    let expected: Value = serde_json::from_str(&fixture_text).unwrap();
    let listed = f.ask(r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)["result"].clone();
    assert_eq!(listed, expected);
    assert_eq!(tools_list(&tools(false)), expected);
    assert_eq!(listed["tools"].as_array().unwrap().len(), 26);
}

#[test]
fn read_only_mode_lists_exactly_the_twelve_read_tools_and_hides_the_rest() {
    let f = fixture();
    let list = f
        .ask_with(
            "read-only",
            None,
            r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        )
        .unwrap();
    let names: Vec<&str> = list["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    assert_eq!(
        names,
        [
            "get_capabilities",
            "get_sensors",
            "get_battery",
            "list_displays",
            "get_system_metrics",
            "get_top_processes",
            "get_ai_usage",
            "keep_awake_status",
            "get_brightness",
            "list_profiles",
            "get_status",
            "get_history"
        ]
    );
    for mode in ["read_only", "READONLY"] {
        let l = f
            .ask_with(
                mode,
                None,
                r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            )
            .unwrap();
        assert_eq!(l["result"]["tools"].as_array().unwrap().len(), 12, "{mode}");
    }
    // A hidden write tool is as unknown as a typo, and never reaches the Swift core.
    let mut f = fixture();
    let fake = f.with_legacy("{}", "", 0);
    let hidden = f.ask_with("read-only", None, r#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"set_fan","arguments":{"fraction":1}}}"#).unwrap();
    assert_eq!(error_of(&hidden), (-32603, "Unknown tool 'set_fan'."));
    assert!(fake.calls().is_empty());
}

#[test]
fn native_read_tools_return_compact_sorted_json_text() {
    let mut f = fixture();
    f.app.handlers.register("sensors", |_, _| {
        Ok(Output::Json(
            json!({"z": 2.0, "a": "/x", "thermal_pressure": "nominal"}),
        ))
    });
    let response = f.call("get_sensors", json!({}));
    assert_eq!(
        text_of(&response),
        r#"{"a":"\/x","thermal_pressure":"nominal","z":2}"#
    );
    // Extra arguments are ignored, like Swift's argument-less tools.
    assert_eq!(
        text_of(&f.call("get_sensors", json!({"whatever": true}))),
        text_of(&response)
    );
    f.app.handlers.register("awake.status", |_, _| {
        Ok(Output::Json(json!({"active": false})))
    });
    assert_eq!(
        text_of(&f.call("keep_awake_status", json!({}))),
        r#"{"active":false}"#
    );
}

#[test]
fn top_processes_validates_and_passes_arguments_to_the_handler() {
    let mut f = fixture();
    f.app.handlers.register("processes", |_, req| {
        let symcockpit::app::Params::Processes(p) = &req.params else { panic!() };
        Ok(Output::Json(json!({"sort": p.sort.as_str(), "limit": p.limit, "interval": p.interval, "json": req.json})))
    });
    assert_eq!(
        text_of(&f.call("get_top_processes", json!({}))),
        r#"{"interval":1,"json":true,"limit":6,"sort":"cpu"}"#
    );
    assert_eq!(
        text_of(&f.call(
            "get_top_processes",
            json!({"sort_by": "Memory", "limit": 20})
        )),
        r#"{"interval":1,"json":true,"limit":20,"sort":"memory"}"#
    );
    // A non-integral or non-numeric limit falls back to the default, like `intValue`.
    assert!(text_of(&f.call("get_top_processes", json!({"limit": 2.5}))).contains("\"limit\":6"));
    assert!(text_of(&f.call("get_top_processes", json!({"limit": "9"}))).contains("\"limit\":6"));
    assert_eq!(
        error_of(&f.call("get_top_processes", json!({"sort_by": "bogus"}))),
        (-32603, "sort_by must be 'cpu', 'memory' or 'gpu'.")
    );
}

#[test]
fn history_and_profiles_are_native_and_honour_the_data_dir() {
    let f = fixture();
    assert_eq!(text_of(&f.call("get_history", json!({}))), "[]");
    assert_eq!(
        text_of(&f.call("list_profiles", json!({}))),
        r#"{"profiles":[]}"#
    );
    let data = f.tmp.path().join("d");
    std::fs::create_dir_all(&data).unwrap();
    std::fs::write(data.join("history.ndjson"), "{\"action\":\"a\",\"timestamp\":\"2026-11-19T08:30:00Z\",\"result\":\"success\",\"requested_value\":0.123456}\n{\"action\":\"b\",\"timestamp\":\"2026-11-19T08:30:00Z\",\"result\":\"success\"}\n").unwrap();
    std::fs::write(
        data.join("profile-p.json"),
        "{\"name\":\"p\",\"createdAt\":1,\"updatedAt\":2}",
    )
    .unwrap();
    let call = |tool: &str, args: Value| {
        f.ask_with("full", Some(&data), &json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":tool,"arguments":args}}).to_string()).unwrap()
    };
    assert_eq!(
        text_of(&call("get_history", json!({"limit": 1}))),
        r#"[{"action":"b","result":"success","timestamp":816769800}]"#
    );
    assert!(
        text_of(&call("get_history", json!({"limit": "x"})))
            .contains("\"requested_value\":0.123456"),
        "a bad limit means the default of 100"
    );
    assert_eq!(
        text_of(&call("list_profiles", json!({}))),
        r#"{"profiles":[{"created_at":1,"name":"p","updated_at":2}]}"#
    );
}

#[test]
fn ai_usage_tool_uses_only_the_runner_port() {
    let mut f = fixture();
    let runner = symcockpit_testkit::symbrain::FakeSymbrain::replying(
        r#"{"schema_version":1,"providers":[]}"#,
    );
    f.app.services.usage_runner = Box::new(runner);
    let text = text_of(&f.call("get_ai_usage", json!({}))).to_owned();
    let results: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(results.as_array().unwrap().len(), 14);
    assert!(
        results[0]["error"]
            .as_str()
            .unwrap()
            .starts_with("AI usage unavailable. symbrain did not report")
    );
}

#[test]
fn doctor_and_status_tools_follow_the_ports() {
    let mut f = fixture();
    // Without ports and without a Swift core the tools cannot run at all.
    let missing = f.call("get_capabilities", json!({}));
    assert_eq!(error_of(&missing).0, -32603);
    assert!(
        error_of(&missing)
            .1
            .starts_with("unsupported: the Swift core was not found; set SYMCOCKPIT_LEGACY_BIN")
    );
    // Without a native implementation the Swift CLI answers and is re-encoded compactly.
    let fake = f.with_legacy("{\n  \"tool\" : \"symcockpit\",\n  \"n\" : 2\n}\n", "", 0);
    assert_eq!(
        text_of(&f.call("get_capabilities", json!({}))),
        r#"{"n":2,"tool":"symcockpit"}"#
    );
    assert_eq!(
        text_of(&f.call("get_status", json!({}))),
        r#"{"n":2,"tool":"symcockpit"}"#
    );
    assert_eq!(
        text_of(&f.call("get_top_processes", json!({"sort_by": "gpu", "limit": 3}))),
        r#"{"n":2,"tool":"symcockpit"}"#
    );
    assert_eq!(
        fake.calls(),
        [
            vec!["doctor"],
            vec!["status", "--json"],
            vec!["processes", "--json", "--sort", "gpu", "--limit", "3"]
        ]
    );
    // With the hardware port the native doctor answers and the Swift core is not asked again.
    f.app.services.hardware = Some(Box::new(
        symcockpit_testkit::hardware::FakeHardware::default(),
    ));
    let doctor: Value =
        serde_json::from_str(text_of(&f.call("get_capabilities", json!({})))).unwrap();
    assert_eq!(doctor["tool"], "symcockpit");
    assert_eq!(doctor["capabilities"].as_array().unwrap().len(), 14);
    assert_eq!(fake.calls().len(), 3);
}

#[test]
fn read_tools_without_handler_run_the_matching_cli_command() {
    let mut f = fixture();
    let fake = f.with_legacy("{\"ok\":true}", "", 0);
    for tool in [
        "get_sensors",
        "get_battery",
        "list_displays",
        "get_system_metrics",
        "keep_awake_status",
        "get_brightness",
    ] {
        assert_eq!(
            text_of(&f.call(tool, json!({}))),
            r#"{"ok":true}"#,
            "{tool}"
        );
    }
    assert_eq!(
        fake.calls(),
        [
            vec!["sensors"],
            vec!["battery"],
            vec!["displays"],
            vec!["metrics"],
            vec!["awake", "status"],
            vec!["brightness", "get"]
        ]
    );
}

#[test]
fn fan_and_charge_tools_run_the_cli_prefix_with_the_validated_value() {
    let mut f = fixture();
    let fake = f.with_legacy("{\n  \"applied\" : true\n}\n", "", 0);
    for (tool, arguments) in [
        ("restore", json!({})),
        ("set_fan", json!({"fraction": 0.25})),
        ("set_charge_limit", json!({"percent": 80})),
        ("set_charge_limit", json!({"percent": "75"})),
        ("clear_charge_limit", json!({})),
    ] {
        assert_eq!(
            text_of(&f.call(tool, arguments.clone())),
            r#"{"applied":true}"#,
            "{tool} {arguments}"
        );
    }
    // `restore` restores the displays here and leaves the SMC half to Swift.
    assert_eq!(
        fake.calls(),
        [
            vec!["restore"],
            vec!["fan", "set", "0.25"],
            vec!["battery-limit", "set", "80"],
            vec!["battery-limit", "set", "75"],
            vec!["battery-limit", "clear"],
        ]
    );
}

#[test]
fn write_tool_argument_errors_never_reach_the_swift_core() {
    let mut f = fixture();
    let fake = f.with_legacy("{}", "", 0);
    for (tool, arguments, message) in [
        (
            "set_brightness",
            json!({}),
            "Missing required numeric argument 'value'.",
        ),
        (
            "set_fan",
            json!({"fraction": "abc"}),
            "Missing required numeric argument 'fraction'.",
        ),
        (
            "set_fan",
            json!({"fraction": null}),
            "Missing required numeric argument 'fraction'.",
        ),
        (
            "set_charge_limit",
            json!({"percent": 80.5}),
            "Missing required integer argument 'percent'.",
        ),
        (
            "set_charge_limit",
            json!({}),
            "Missing required integer argument 'percent'.",
        ),
        ("save_profile", json!({}), "save_profile requires a name."),
        (
            "load_profile",
            json!({"name": 5}),
            "load_profile requires a name.",
        ),
        (
            "delete_profile",
            json!({}),
            "delete_profile requires a name.",
        ),
        (
            "keep_awake",
            json!({"enabled": true, "duration_seconds": -1}),
            "keep_awake duration_seconds must be non-negative.",
        ),
        (
            "keep_awake",
            json!({"enabled": true, "duration_seconds": 86401}),
            "keep_awake duration_seconds must not exceed 86400 seconds (24 hours).",
        ),
        (
            "keep_awake",
            json!({"enabled": true, "duration_seconds": "x"}),
            "keep_awake duration_seconds must be a number.",
        ),
    ] {
        assert_eq!(
            error_of(&f.call(tool, arguments.clone())),
            (-32603, message),
            "{tool} {arguments}"
        );
    }
    assert!(fake.calls().is_empty());
}

#[test]
fn swift_core_failures_become_internal_errors_with_the_cli_message() {
    let mut f = fixture();
    f.with_legacy(
        "",
        "note: something\nsymcockpit: permission error: SMC writes need root\n",
        3,
    );
    assert_eq!(
        error_of(&f.call("set_fan", json!({"fraction": 1}))),
        (-32603, "permission error: SMC writes need root")
    );
    f.with_legacy("", "", 7);
    assert_eq!(
        error_of(&f.call("restore", json!({}))),
        (-32603, "symcockpit exited with status 7")
    );
    f.with_legacy("not json", "", 0);
    assert_eq!(
        error_of(&f.call("restore", json!({}))),
        (-32603, "symcockpit restore printed no JSON")
    );
    f.app.legacy = Some(f.tmp.path().join("gone"));
    assert!(
        error_of(&f.call("restore", json!({})))
            .1
            .starts_with("cannot start ")
    );
}

#[test]
fn the_data_dir_override_is_handed_to_the_swift_core() {
    let mut f = fixture();
    let fake = f.with_legacy("{\"applied\":true}", "", 0);
    let data = f.tmp.path().join("state");
    let response = f
        .ask_with("full", Some(&data), r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"restore","arguments":{}}}"#)
        .unwrap();
    assert_eq!(text_of(&response), r#"{"applied":true}"#);
    assert_eq!(
        fake.calls(),
        [vec![
            "restore".to_owned(),
            "--data-dir".to_owned(),
            data.to_string_lossy().into_owned()
        ]]
    );
}
