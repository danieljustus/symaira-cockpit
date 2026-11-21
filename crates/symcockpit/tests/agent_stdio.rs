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
        .env("SYMCOCKPIT_TEST_NO_HARDWARE", "1")
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
        Self::start_with(home, legacy, &[])
    }

    fn start_with(home: &Path, legacy: Option<&Path>, extra: &[&str]) -> Self {
        let data = home.join("data");
        let mut args = vec!["agent", "--stdio", "--data-dir", data.to_str().unwrap()];
        args.extend_from_slice(extra);
        let mut cmd = command(home, &args);
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

    // reversible: direct, no plan. The test process forbids hardware writes
    // (SYMCOCKPIT_TEST_NO_HARDWARE), so the native dim write is refused as
    // unsupported instead of dimming the real display.
    let (r, _) = agent.request(
        "call",
        json!({"command": "dim.set", "params": {"value": 0.5}}),
    );
    assert!(
        r["error"]["message"]
            .as_str()
            .unwrap()
            .contains("hardware writes are disabled"),
        "{r}"
    );
    assert!(fake.calls().is_empty());

    // risky: a plan first, nothing executed.
    // (`fan.target` only writes the user's file and is still the Swift
    // core's, here the fake.)
    let (r, _) = agent.request("call", json!({"command": "fan.target"}));
    assert_eq!(r["result"]["status"], "confirmation_required");
    assert!(fake.calls().is_empty(), "planning does not run the command");
    let id = r["result"]["plan"]["id"].as_str().unwrap().to_owned();
    let (r, _) = agent.request("confirm", json!({"plan_id": id}));
    assert_eq!(r["result"]["status"], "confirmed");
    assert_eq!(r["result"]["output"], json!({"applied": true}));
    assert_eq!(fake.calls().len(), 1);
    assert_eq!(fake.calls()[0][..2], ["fan", "target"]);
    let (r, _) = agent.request("confirm", json!({"plan_id": id}));
    assert_eq!(r["error"]["code"], -32000, "a plan is confirmed once");
    assert_eq!(fake.calls().len(), 1);

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
        &["agent", "--stdio", "--finder-jobs-dir"],
    ] {
        let out = command(tmp.path(), args).output().unwrap();
        assert_eq!(out.status.code(), Some(2), "{args:?}");
        assert!(out.stdout.is_empty());
    }
}

// ------------------------------------------ the long-lived services (wave 2D-S), as a process

const OFF_BY: &str = "SYMCOCKPIT_TEST_NO_HARDWARE";

#[test]
fn the_services_start_only_on_the_users_settings_and_never_reach_the_real_machine_in_a_test() {
    let tmp = tempfile::tempdir().unwrap();
    let jobs = tmp.path().join("jobs");
    let mut agent = Agent::start_with(
        tmp.path(),
        None,
        &["--finder-jobs-dir", jobs.to_str().unwrap()],
    );
    let hello = agent.hello();
    let methods = hello["result"]["capabilities"]["methods"]
        .as_array()
        .unwrap();
    for m in symcockpit_contract::agent_proto::HOST_METHODS {
        assert!(methods.iter().any(|x| x == m), "{m}");
    }

    // A fresh agent runs nothing: no capture, no tap, no mixer, no session, nothing created.
    let (r, _) = agent.request("services", json!({}));
    let s = &r["result"];
    assert_eq!(s["clipboard"]["state"], "off", "{s}");
    assert_eq!(s["input_tap"]["finder_cut"], "off");
    assert_eq!(s["mixer"]["running"], false);
    assert_eq!(s["ble"]["connections"], json!([]));
    assert_eq!(s["finder_jobs"]["succeeded"], 0);
    assert!(!tmp.path().join("data/clipboard").exists());

    // The opt-in: the service wants to start, and in a test binary it is blocked, which the
    // state says plainly instead of touching the user's pasteboard or Keychain.
    let (r, _) = agent.request("clipboard.configure", json!({"enabled": true}));
    assert_eq!(r["result"]["state"], "failed", "{r}");
    assert!(
        r["result"]["last_error"].as_str().unwrap().contains(OFF_BY),
        "{r}"
    );
    let (r, _) = agent.request("clipboard.settings", json!({}));
    assert_eq!(r["result"]["enabled"], true);
    let (r, _) = agent.request("clipboard.list", json!({}));
    assert_eq!(r["result"]["count"], 0);
    let (r, _) = agent.request("clipboard.read", json!({"id": "nope"}));
    assert_eq!(r["error"]["code"], -32000, "{r}");
    let (r, _) = agent.request("clipboard.read", json!({}));
    assert_eq!(r["error"]["data"]["class"], "usage");

    // The Finder tap: switched on by the CLI's own command, still never installed in a test.
    let (r, _) = agent.request(
        "call",
        json!({"command": "input.finder-cut", "params": {"state": "on"}}),
    );
    assert_eq!(r["result"]["status"], "ok", "{r}");
    let (r, _) = agent.request("services", json!({}));
    let state = r["result"]["input_tap"]["finder_cut"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(
        ["permission", "unsupported"].contains(&state.as_str()),
        "{r}"
    );

    // BLE: the session exists, the radio is never opened.
    let (r, _) = agent.request("call", json!({"command": "ble.session"}));
    assert_eq!(r["result"]["output"]["log_entries"], 0, "{r}");
    let (r, _) = agent.request(
        "call",
        json!({"command": "ble.connect", "params": {"device_id": "x"}}),
    );
    assert_eq!(r["error"]["data"]["class"], "unsupported", "{r}");
    assert!(
        r["error"]["message"].as_str().unwrap().contains(OFF_BY),
        "{r}"
    );

    // A Finder job: validated, run once, answered; the pasteboard effect is blocked.
    let inbox = symcockpit_core::finder::Inbox::new(&jobs);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    let job = symcockpit_core::finder::Job {
        id: symcockpit_core::finder::new_job_id(),
        action: symcockpit_core::finder::Action::CopyPath,
        paths: vec!["/tmp/x".into()],
        created_at: now,
        expires_at: now + 60,
    };
    inbox.submit(&job).unwrap();
    let deadline = std::time::Instant::now() + WAIT;
    let result = loop {
        if let Some(result) = inbox.result(&job.id) {
            break result;
        }
        assert!(std::time::Instant::now() < deadline, "no result file");
        std::thread::sleep(Duration::from_millis(20));
    };
    assert_eq!(result["state"], "failed", "{result}");
    assert!(
        result["detail"].as_str().unwrap().contains(OFF_BY),
        "{result}"
    );

    // Closing stdin ends everything, exit 0.
    agent.close_stdin();
    let (code, stderr) = agent.finish(Duration::from_secs(10));
    assert_eq!(code, Some(0), "{stderr}");
    assert!(!stderr.contains("panicked"), "{stderr}");
}

#[test]
fn sigterm_ends_an_agent_with_running_services_cleanly() {
    let tmp = tempfile::tempdir().unwrap();
    let jobs = tmp.path().join("jobs");
    let mut agent = Agent::start_with(
        tmp.path(),
        None,
        &["--finder-jobs-dir", jobs.to_str().unwrap()],
    );
    agent.hello();
    agent.request("clipboard.configure", json!({"enabled": true}));
    agent.request(
        "subscribe",
        json!({"command": "ble.session", "interval_visible_ms": 100, "interval_hidden_ms": 100}),
    );
    // stdin stays open: only the signal can end it.
    let status = Command::new("/bin/kill")
        .args(["-TERM", &agent.child.id().to_string()])
        .status()
        .unwrap();
    assert!(status.success());
    let (code, stderr) = agent.finish(Duration::from_secs(10));
    assert_eq!(code, Some(0), "{stderr}");
}
