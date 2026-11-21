//! `human_only` commands (clipboard history, Finder actions) are unreachable for agents:
//! no tool in `tools/list`, no way to call one, and `serve` never touches the clipboard
//! store (D10, D13, architecture 5.3). The process runs with an isolated HOME and a planted
//! clipboard directory; nothing real is read.

use std::{
    fs,
    io::Write,
    path::Path,
    process::{Command, Output, Stdio},
    time::SystemTime,
};

use serde_json::{Value, json};
use symcockpit_contract::{Risk, areas, commands};

fn serve(home: &Path, input: &str) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_symcockpit"))
        .arg("serve")
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
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

fn rpc(id: u32, method: &str, params: Value) -> String {
    format!(
        "{}\n",
        json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params})
    )
}

const INIT: &str = r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}
"#;

fn responses(out: &Output) -> Vec<Value> {
    String::from_utf8(out.stdout.clone())
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

#[test]
fn tools_list_has_no_human_only_command() {
    let tmp = tempfile::tempdir().unwrap();
    let out = serve(
        tmp.path(),
        &format!("{INIT}{}", rpc(2, "tools/list", json!({}))),
    );
    let tools = responses(&out)[1]["result"]["tools"]
        .as_array()
        .unwrap()
        .clone();
    assert!(!tools.is_empty());
    let all: Vec<_> = commands()
        .iter()
        .cloned()
        .chain(areas::clipboard::specs())
        .chain(areas::input::specs())
        .collect();
    for tool in &tools {
        let name = tool["name"].as_str().unwrap();
        for word in ["clip", "paste", "finder", "haptic"] {
            assert!(!name.contains(word), "tool {name} looks human_only");
        }
        let spec = all.iter().find(|s| s.mcp_name == Some(name));
        assert!(
            spec.is_some_and(|s| s.risk != Risk::HumanOnly),
            "tool {name} is human_only or unknown"
        );
    }
    for spec in all.iter().filter(|s| s.risk == Risk::HumanOnly) {
        assert!(spec.mcp_name.is_none(), "{} has an MCP name", spec.name);
    }
}

#[test]
fn clipboard_tools_cannot_be_called_by_name() {
    let tmp = tempfile::tempdir().unwrap();
    let mut input = INIT.to_owned();
    for (i, name) in [
        "clipboard_status",
        "get_clipboard",
        "list_clipboard",
        "clipboard_clear",
        "finder_action",
        "clipboard.status",
    ]
    .iter()
    .enumerate()
    {
        input += &rpc(
            10 + i as u32,
            "tools/call",
            json!({"name": name, "arguments": {}}),
        );
    }
    let out = serve(tmp.path(), &input);
    let rs = responses(&out);
    assert_eq!(rs.len(), 7);
    for r in &rs[1..] {
        assert!(
            r.get("error").is_some(),
            "unknown tool must be an error: {r}"
        );
        assert!(r["result"].is_null());
    }
}

/// Names, sizes, modification times and bytes of everything below `dir`.
fn snapshot(dir: &Path) -> Vec<(String, u64, SystemTime, Vec<u8>)> {
    let mut v: Vec<_> = fs::read_dir(dir)
        .unwrap()
        .map(|e| {
            let e = e.unwrap();
            let m = e.metadata().unwrap();
            (
                e.file_name().to_string_lossy().into_owned(),
                m.len(),
                m.modified().unwrap(),
                fs::read(e.path()).unwrap_or_default(),
            )
        })
        .collect();
    v.sort();
    v
}

/// What a store open would leave behind (an `attachments/` directory, WAL files, a migrated
/// database, a rewritten settings file) must be absent. A pure read cannot be observed from
/// outside on this filesystem (atime does not move), so reads are guarded structurally by
/// `the_mcp_server_source_does_not_know_the_clipboard_or_finder_areas` below.
#[test]
fn serve_leaves_the_clipboard_directory_untouched() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("d/symtune/clipboard");
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("clipboard.sqlite"),
        b"SQLite format 3\0 planted, not a real database",
    )
    .unwrap();
    fs::write(dir.join("settings.json"), br#"{"enabled":true}"#).unwrap();
    let before = snapshot(&dir);
    let dir_mtime = fs::metadata(&dir).unwrap().modified().unwrap();

    let mut input = INIT.to_owned();
    input += &rpc(2, "tools/list", json!({}));
    for (i, tool) in [
        "get_status",
        "get_history",
        "list_profiles",
        "get_capabilities",
        "clipboard_status",
    ]
    .iter()
    .enumerate()
    {
        input += &rpc(
            3 + i as u32,
            "tools/call",
            json!({"name": tool, "arguments": {}}),
        );
    }
    let out = serve(tmp.path(), &input);
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(responses(&out).len(), 7);

    assert_eq!(snapshot(&dir), before);
    assert_eq!(fs::metadata(&dir).unwrap().modified().unwrap(), dir_mtime);
}

#[test]
fn the_mcp_server_source_does_not_know_the_clipboard_or_finder_areas() {
    let mcp = include_str!("../src/mcp.rs").to_lowercase();
    for word in [
        "clipboard",
        "symcockpit_db::clipboard",
        "finder::",
        "core::finder",
    ] {
        assert!(!mcp.contains(word), "src/mcp.rs mentions {word}");
    }
}
