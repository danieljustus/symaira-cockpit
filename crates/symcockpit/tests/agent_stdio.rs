//! `symcockpit agent --stdio` as a process, driven over pipes: handshake,
//! `call` through the MCP dispatch path, plan and confirm, subscriptions,
//! the exit on EOF and SIGTERM, and the parent check.
//!
//! These run the debug binary with the debug-only test switch. The Swift core
//! is a fake script and every data directory is a temporary one; the only real
//! read is `metrics` (CPU, memory, network counters), nothing is written to
//! hardware.

#![cfg(debug_assertions)]

use std::io::{BufRead, BufReader, Read, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::Duration;

use serde_json::{Value, json};
use symcockpit_testkit::legacy::FakeLegacy;

const BIN: &str = env!("CARGO_BIN_EXE_symcockpit");
const SWITCH: &str = "SYMCOCKPIT_AGENT_SKIP_PARENT_CHECK";
const WAIT: Duration = Duration::from_secs(20);

fn command(home: &Path, args: &[&str]) -> Command {
    let mut cmd = Command::new(BIN);
    cmd.args(args)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", home)
        .env("XDG_CONFIG_HOME", home.join("c"))
        .env("XDG_DATA_HOME", home.join("d"))
        .env("XDG_CACHE_HOME", home.join("ca"))
        .env("SYMCOCKPIT_CHECK_UPDATES", "0")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    cmd
}

struct Agent {
    child: Child,
    stdin: Option<ChildStdin>,
    lines: Receiver<String>,
    next_id: u64,
}

impl Agent {
    fn start(home: &Path, legacy: Option<&Path>) -> Self {
        let data = home.join("data");
        let mut cmd = command(
            home,
            &["agent", "--stdio", "--data-dir", data.to_str().unwrap()],
        );
        cmd.env(SWITCH, "1");
        if let Some(legacy) = legacy {
            cmd.env("SYMCOCKPIT_LEGACY_BIN", legacy);
        }
        let mut child = cmd.spawn().unwrap();
        let stdin = child.stdin.take();
        let stdout = child.stdout.take().unwrap();
        let (tx, lines) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                if tx.send(line.unwrap()).is_err() {
                    return;
                }
            }
        });
        Self {
            child,
            stdin,
            lines,
            next_id: 1,
        }
    }

    fn send(&mut self, method: &str, params: Value) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        let frame = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        let stdin = self.stdin.as_mut().unwrap();
        writeln!(stdin, "{frame}").unwrap();
        stdin.flush().unwrap();
        id
    }

    /// The next frame; every stdout line must be a JSON-RPC 2.0 frame.
    fn frame(&self, timeout: Duration) -> Option<Value> {
        let line = self.lines.recv_timeout(timeout).ok()?;
        let v: Value = serde_json::from_str(&line)
            .unwrap_or_else(|e| panic!("stdout line is not JSON ({e}): {line}"));
        assert_eq!(v["jsonrpc"], "2.0", "{line}");
        Some(v)
    }

    /// Sends a request and returns its response plus the events that came
    /// before it.
    fn request(&mut self, method: &str, params: Value) -> (Value, Vec<Value>) {
        let id = self.send(method, params);
        let mut events = Vec::new();
        loop {
            let frame = self.frame(WAIT).expect("no response in time");
            if frame["id"] == json!(id) {
                return (frame, events);
            }
            assert_eq!(frame["method"], "event", "{frame}");
            events.push(frame);
        }
    }

    fn hello(&mut self) -> Value {
        self.request("hello", json!({"protocol_version": 1, "client": "test"}))
            .0
    }

    fn close_stdin(&mut self) {
        self.stdin = None;
    }

    /// Exit code and stderr; fails the test if the agent does not exit.
    fn finish(mut self, within: Duration) -> (Option<i32>, String) {
        let deadline = std::time::Instant::now() + within;
        let status = loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                break status;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "the agent did not exit within {within:?}"
            );
            std::thread::sleep(Duration::from_millis(10));
        };
        let mut stderr = String::new();
        self.child
            .stderr
            .take()
            .unwrap()
            .read_to_string(&mut stderr)
            .unwrap();
        (status.code(), stderr)
    }
}

#[test]
fn hello_call_plan_and_confirm_run_through_the_mcp_dispatch_path() {
    let tmp = tempfile::tempdir().unwrap();
    let fake = FakeLegacy::new(tmp.path(), "{\"applied\":true}", "", 0);
    let mut agent = Agent::start(tmp.path(), Some(&fake.path));

    // Before hello nothing but ping works.
    let (r, _) = agent.request("call", json!({"command": "profile.list"}));
    assert_eq!(r["error"]["code"], -32002);
    // A wrong version is refused with the versions this agent speaks.
    let (r, _) = agent.request("hello", json!({"protocol_version": 2}));
    assert_eq!(r["error"]["code"], -32010);
    assert_eq!(r["error"]["data"]["supported"], json!([1]));

    let hello = agent.hello();
    let result = &hello["result"];
    assert_eq!(result["protocol_version"], 1);
    assert_eq!(result["server_version"], symcockpit::VERSION);
    let commands = result["commands"].as_array().unwrap();
    let risk = |name: &str| {
        commands
            .iter()
            .find(|c| c["name"] == name)
            .unwrap_or_else(|| panic!("{name} missing"))["risk"]
            .clone()
    };
    assert_eq!(risk("metrics"), "read");
    assert_eq!(risk("dim.set"), "reversible");
    assert_eq!(risk("fan.set"), "risky");

    // read: native handler, same JSON the CLI prints.
    let (r, _) = agent.request("call", json!({"command": "profile.list"}));
    assert_eq!(r["result"]["status"], "ok");
    assert_eq!(r["result"]["output"], json!({"profiles": []}));
    assert!(
        fake.calls().is_empty(),
        "a native read does not spawn Swift"
    );

    // reversible: direct, via the Swift core exactly as `tools/call` does.
    let (r, _) = agent.request(
        "call",
        json!({"command": "dim.set", "params": {"value": 0.5}}),
    );
    assert_eq!(r["result"]["output"], json!({"applied": true}));
    assert_eq!(fake.calls().len(), 1);
    assert_eq!(fake.calls()[0][..3], ["dim", "set", "0.5"]);

    // risky: a plan first, nothing executed.
    let (r, _) = agent.request(
        "call",
        json!({"command": "fan.set", "params": {"fraction": 0.7}}),
    );
    assert_eq!(r["result"]["status"], "confirmation_required");
    assert_eq!(fake.calls().len(), 1, "planning does not run the command");
    let id = r["result"]["plan"]["id"].as_str().unwrap().to_owned();
    let (r, _) = agent.request("confirm", json!({"plan_id": id}));
    assert_eq!(r["result"]["status"], "confirmed");
    assert_eq!(r["result"]["output"], json!({"applied": true}));
    assert_eq!(fake.calls().len(), 2);
    assert_eq!(fake.calls()[1][..3], ["fan", "set", "0.7"]);
    let (r, _) = agent.request("confirm", json!({"plan_id": id}));
    assert_eq!(r["error"]["code"], -32000, "a plan is confirmed once");
    assert_eq!(fake.calls().len(), 2);

    // A command failure keeps its CLI exit class.
    let (r, _) = agent.request("call", json!({"command": "no.such.command"}));
    assert_eq!(r["error"]["code"], -32602);

    agent.close_stdin();
    let (code, stderr) = agent.finish(Duration::from_secs(5));
    assert_eq!(code, Some(0), "{stderr}");
}

#[test]
fn nothing_is_measured_without_a_subscriber_and_samples_stop_on_unsubscribe() {
    let tmp = tempfile::tempdir().unwrap();
    let mut agent = Agent::start(tmp.path(), None);
    agent.hello();
    assert!(
        agent.frame(Duration::from_millis(500)).is_none(),
        "no subscriber, no frames"
    );

    let (r, events) = agent.request(
        "subscribe",
        json!({"command": "metrics", "interval_visible_ms": 100, "interval_hidden_ms": 100}),
    );
    assert!(events.is_empty());
    let sub = r["result"]["subscription_id"].as_u64().unwrap();
    let mut seqs = Vec::new();
    while seqs.len() < 3 {
        let e = agent.frame(WAIT).expect("event");
        assert_eq!(e["method"], "event");
        assert!(e.get("id").is_none());
        assert_eq!(e["params"]["subscription_id"], sub);
        assert_eq!(e["params"]["command"], "metrics");
        // A sample is a result or an error event, never a made-up value.
        assert!(e["params"].get("result").is_some() ^ e["params"].get("error").is_some());
        seqs.push(e["params"]["seq"].as_u64().unwrap());
    }
    assert_eq!(seqs, [1, 2, 3]);

    let (r, _) = agent.request("unsubscribe", json!({"subscription_id": sub}));
    assert_eq!(r["result"]["active"], 0);
    assert!(
        agent.frame(Duration::from_millis(500)).is_none(),
        "no event after the unsubscribe response"
    );
    agent.close_stdin();
    assert_eq!(agent.finish(Duration::from_secs(5)).0, Some(0));
}

#[test]
fn end_of_input_stops_the_samplers_and_ends_the_agent() {
    let tmp = tempfile::tempdir().unwrap();
    let mut agent = Agent::start(tmp.path(), None);
    agent.hello();
    agent.request(
        "subscribe",
        json!({"command": "metrics", "interval_visible_ms": 100, "interval_hidden_ms": 100}),
    );
    agent.close_stdin();
    let (code, stderr) = agent.finish(Duration::from_secs(5));
    assert_eq!(code, Some(0), "{stderr}");
}

#[test]
fn sigterm_ends_the_agent_cleanly_even_while_subscribed() {
    let tmp = tempfile::tempdir().unwrap();
    let mut agent = Agent::start(tmp.path(), None);
    agent.hello();
    agent.request(
        "subscribe",
        json!({"command": "metrics", "interval_visible_ms": 100, "interval_hidden_ms": 100}),
    );
    // stdin stays open: only the signal can end it.
    let status = Command::new("/bin/kill")
        .args(["-TERM", &agent.child.id().to_string()])
        .status()
        .unwrap();
    assert!(status.success());
    let (code, stderr) = agent.finish(Duration::from_secs(5));
    assert_eq!(code, Some(0), "{stderr}");
}

#[test]
fn without_the_test_switch_the_parent_check_refuses_with_exit_3() {
    let tmp = tempfile::tempdir().unwrap();
    // The parent is this test binary: not the signed app.
    let out = command(tmp.path(), &["agent", "--stdio"]).output().unwrap();
    assert_eq!(out.status.code(), Some(3));
    assert!(out.stdout.is_empty(), "stdout stays protocol-only");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("symcockpit: agent:"), "{stderr}");
    assert!(stderr.contains("Symaira Cockpit.app"), "{stderr}");
    // Only the value 1 is the switch.
    let out = command(tmp.path(), &["agent", "--stdio"])
        .env(SWITCH, "0")
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(3));
}

#[test]
fn usage_errors_come_before_the_parent_check() {
    let tmp = tempfile::tempdir().unwrap();
    for args in [
        &["agent"][..],
        &["agent", "--stdio", "--bogus"],
        &["agent", "--data-dir"],
    ] {
        let out = command(tmp.path(), args).output().unwrap();
        assert_eq!(out.status.code(), Some(2), "{args:?}");
        assert!(out.stdout.is_empty());
    }
}
