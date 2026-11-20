//! `symcockpit serve` as a process: framing, stdout purity and the exit code.
//! The Swift core is replaced by a fake script; no real hardware, credential
//! or configuration is touched (isolated HOME, cleared environment).

use std::io::Write;
use std::path::Path;
use std::process::{Command, Output, Stdio};

use serde_json::{Value, json};
use symcockpit_testkit::legacy::FakeLegacy;

fn serve(home: &Path, legacy: Option<&Path>, extra_env: &[(&str, &str)], input: &str) -> Output {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_symcockpit"));
    cmd.arg("serve")
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", home)
        .env("XDG_CONFIG_HOME", home.join("c"))
        .env("XDG_DATA_HOME", home.join("d"))
        .env("XDG_CACHE_HOME", home.join("ca"))
        .env("SYMTUNE_CHECK_UPDATES", "0")
        .env("SYMCOCKPIT_CHECK_UPDATES", "0")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(legacy) = legacy {
        cmd.env("SYMCOCKPIT_LEGACY_BIN", legacy);
    }
    for (k, v) in extra_env {
        cmd.env(k, v);
    }
    let mut child = cmd.spawn().unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

fn frames(out: &Output) -> Vec<Value> {
    String::from_utf8(out.stdout.clone())
        .unwrap()
        .lines()
        .map(|line| {
            let v: Value = serde_json::from_str(line)
                .unwrap_or_else(|e| panic!("stdout line is not JSON ({e}): {line}"));
            assert_eq!(
                v["jsonrpc"], "2.0",
                "every stdout line is a JSON-RPC frame: {line}"
            );
            v
        })
        .collect()
}

const SESSION: &str = concat!(
    r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
    "\n",
    r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
    "\n",
    "\n",
    r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
    "\n",
    r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_history","arguments":{}}}"#,
    "\n",
    r#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"set_dim","arguments":{"value":0.5}}}"#,
    "\n",
    "garbage\n",
    r#"{"jsonrpc":"2.0","id":5,"method":"ping"}"#,
);

#[test]
fn a_full_session_answers_in_order_and_keeps_stdout_clean() {
    let tmp = tempfile::tempdir().unwrap();
    let fake = FakeLegacy::new(tmp.path(), "{\"applied\":true}", "", 0);
    // The last request has no trailing newline: end of input flushes it.
    let out = serve(tmp.path(), Some(&fake.path), &[], SESSION);
    assert_eq!(out.status.code(), Some(0));
    assert!(
        out.stderr.is_empty(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let frames = frames(&out);
    let ids: Vec<Value> = frames.iter().map(|f| f["id"].clone()).collect();
    assert_eq!(
        ids,
        [
            json!(1),
            json!(2),
            json!(3),
            json!(4),
            Value::Null,
            json!(5)
        ]
    );
    assert_eq!(
        frames[0]["result"]["serverInfo"],
        json!({"name": "symcockpit", "version": symcockpit::VERSION})
    );
    let expected: Value = serde_json::from_str(
        &std::fs::read_to_string(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../oracle/v0.12/cases/mcp-tools-list.json"),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(
        frames[1]["result"], expected,
        "tools/list must equal the recorded v0.12 result"
    );
    assert_eq!(frames[2]["result"]["content"][0]["text"], "[]");
    assert_eq!(
        frames[3]["result"]["content"][0]["text"],
        "{\"applied\":true}"
    );
    assert_eq!(frames[4]["error"]["code"], -32700);
    assert_eq!(frames[5]["result"], json!({}));
    assert_eq!(fake.calls(), [["dim", "set", "0.5"]]);
    // Nothing was created in the (isolated) data or config directories.
    assert!(!tmp.path().join("d").exists() && !tmp.path().join("c").exists());
}

#[test]
fn config_read_only_mode_and_the_environment_override_both_apply() {
    let tmp = tempfile::tempdir().unwrap();
    let fake = FakeLegacy::new(tmp.path(), "{}", "", 0);
    let list = r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#;
    let count = |out: &Output| frames(out)[0]["result"]["tools"].as_array().unwrap().len();
    // Environment: SYMTUNE_MCP_MODE.
    assert_eq!(
        count(&serve(
            tmp.path(),
            Some(&fake.path),
            &[("SYMTUNE_MCP_MODE", "read-only")],
            list
        )),
        12
    );
    // Configuration file: [mcp] mode.
    let config = tmp.path().join("c/symtune");
    std::fs::create_dir_all(&config).unwrap();
    std::fs::write(config.join("config.toml"), "[mcp]\nmode = \"read-only\"\n").unwrap();
    assert_eq!(count(&serve(tmp.path(), Some(&fake.path), &[], list)), 12);
    // The environment wins over the file.
    assert_eq!(
        count(&serve(
            tmp.path(),
            Some(&fake.path),
            &[("SYMTUNE_MCP_MODE", "full")],
            list
        )),
        26
    );
    let call = r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"restore"}}"#;
    let hidden = serve(tmp.path(), Some(&fake.path), &[], call);
    assert_eq!(
        frames(&hidden)[0]["error"]["message"],
        "Unknown tool 'restore'."
    );
    assert!(fake.calls().is_empty());
}

#[test]
fn config_warnings_stay_on_stderr() {
    let tmp = tempfile::tempdir().unwrap();
    let out = serve(
        tmp.path(),
        None,
        &[("SYMTUNE_DIM_MIN", "0.9"), ("SYMTUNE_DIM_MAX", "0.5")],
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n",
    );
    assert_eq!(
        String::from_utf8_lossy(&out.stderr),
        "symcockpit: config error: inverted min/max range detected, falling back to defaults\n"
    );
    assert_eq!(frames(&out).len(), 1);
}

#[test]
fn empty_input_ends_cleanly_and_an_oversized_line_ends_the_session() {
    let tmp = tempfile::tempdir().unwrap();
    let out = serve(tmp.path(), None, &[], "");
    assert_eq!(
        (out.status.code(), out.stdout.len(), out.stderr.len()),
        (Some(0), 0, 0)
    );
    // Blank and whitespace-only lines are skipped, CRLF is tolerated.
    let out = serve(
        tmp.path(),
        None,
        &[],
        "  \n\r\n{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\r\n",
    );
    assert_eq!(frames(&out).len(), 1);
}

#[test]
fn non_utf8_arguments_are_forwarded_to_swift() {
    use std::os::unix::ffi::OsStrExt;
    let tmp = tempfile::tempdir().unwrap();
    let fake = FakeLegacy::new(tmp.path(), "forwarded", "", 0);
    let out = Command::new(env!("CARGO_BIN_EXE_symcockpit"))
        .arg(std::ffi::OsStr::from_bytes(b"\xff\xfe"))
        .env("SYMCOCKPIT_LEGACY_BIN", &fake.path)
        .output()
        .unwrap();
    assert_eq!(out.stdout, b"forwarded");
    assert_eq!(fake.calls().len(), 1);
}

#[test]
fn native_commands_run_as_a_process_with_exact_exit_codes() {
    let tmp = tempfile::tempdir().unwrap();
    let run = |args: &[&str]| {
        Command::new(env!("CARGO_BIN_EXE_symcockpit"))
            .args(args)
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("HOME", tmp.path())
            .env("XDG_DATA_HOME", tmp.path().join("d"))
            .output()
            .unwrap()
    };
    let help = run(&["help"]);
    assert_eq!(help.status.code(), Some(0));
    assert_eq!(
        String::from_utf8(help.stdout).unwrap(),
        symcockpit::help::ROOT_USAGE
    );
    let bad = run(&["history", "--bogus"]);
    assert_eq!(bad.status.code(), Some(2));
    assert_eq!(
        String::from_utf8(bad.stderr).unwrap(),
        "symcockpit: history: unknown option '--bogus'\n"
    );
    let history = run(&["history"]);
    assert_eq!(
        String::from_utf8(history.stdout).unwrap(),
        "No history events recorded.\n"
    );
    assert_eq!(run(&["operate"]).status.code(), Some(4));
}
