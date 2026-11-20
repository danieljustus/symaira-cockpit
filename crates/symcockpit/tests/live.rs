//! The built binary against this Mac, read-only: no Swift core is reachable
//! (`SYMCOCKPIT_LEGACY_BIN` points nowhere), so every command below must be
//! answered natively. Only shapes and exit codes are asserted; the values are
//! whatever the host reports (a CI VM has no battery or SMC and that is fine).

use std::io::Write;
use std::process::{Command, Stdio};

use serde_json::{Value, json};

fn command() -> Command {
    let home = std::env::var("HOME").unwrap_or_default();
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_symcockpit"));
    cmd.env_clear()
        .env("HOME", home)
        .env("PATH", "/usr/bin:/bin")
        .env("SYMCOCKPIT_CHECK_UPDATES", "0")
        .env("SYMCOCKPIT_LEGACY_BIN", "/nonexistent/no-swift-core");
    cmd
}

fn json_of(args: &[&str]) -> Value {
    let out = command().args(args).output().unwrap();
    assert_eq!(out.status.code(), Some(0), "{args:?}");
    serde_json::from_slice(&out.stdout).unwrap_or_else(|e| panic!("{args:?}: {e}"))
}

#[test]
fn read_commands_run_natively_without_the_swift_core() {
    for args in [
        &["sensors"][..],
        &["battery"],
        &["displays"],
        &["metrics"],
        &["awake", "status"],
        &["fan", "status"],
        &["fan", "profile"],
        &["fan", "target"],
        &["doctor"],
        &["permissions"],
        &["status", "--json"],
        &["processes", "--json", "--limit", "1", "--interval", "0.1"],
        &["top", "--json", "--limit", "1", "--interval", "0.1"],
    ] {
        json_of(args);
    }
    let doctor = json_of(&["doctor"]);
    assert_eq!(doctor["tool"], "symcockpit");
    assert!(doctor["capabilities"].as_array().unwrap().len() >= 14);
    let status = json_of(&["status", "--json"]);
    assert!(status["health_score"].is_number());
}

/// `displays` needs the main thread; both entry points keep it there.
#[test]
fn displays_work_from_the_cli_and_from_serve() {
    assert!(json_of(&["displays"])["displays"].is_array());
    let replies = serve(&[
        json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_displays","arguments":{}}}),
    ]);
    assert!(replies[0]["displays"].is_array(), "{replies:?}");
}

/// The metrics service lives as long as the process: the second call has the
/// previous reading to compute rates against.
#[test]
fn serve_keeps_the_metrics_service_across_calls() {
    let call = |id| json!({"jsonrpc":"2.0","id":id,"method":"tools/call","params":{"name":"get_system_metrics","arguments":{}}});
    let replies = serve(&[call(1), call(2)]);
    assert!(replies[0]["cpu"].get("total_utilization").is_none());
    assert!(replies[1]["cpu"]["total_utilization"].is_number());
}

/// One JSON-RPC session; the text of each tool result parsed as JSON.
fn serve(requests: &[Value]) -> Vec<Value> {
    let mut child = command()
        .arg("serve")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    for request in requests {
        writeln!(stdin, "{request}").unwrap();
    }
    drop(stdin);
    let out = child.wait_with_output().unwrap();
    String::from_utf8(out.stdout)
        .unwrap()
        .lines()
        .map(|line| {
            let reply: Value = serde_json::from_str(line).unwrap();
            let text = reply["result"]["content"][0]["text"]
                .as_str()
                .unwrap_or_else(|| panic!("{reply}"));
            serde_json::from_str(text).unwrap()
        })
        .collect()
}
