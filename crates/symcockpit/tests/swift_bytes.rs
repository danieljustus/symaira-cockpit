//! Byte-for-byte comparison of the Rust binary with output the Swift v0.12.2
//! binary printed for the same inputs (`tests/swift_fixtures/`, see its README).
//! Covers the CLI encoder (`prettyPrinted`, `sortedKeys`, no slash escaping),
//! the MCP encoder (compact, sorted keys, `\/`) and the root `version` report.

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use serde_json::Value;

fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/swift_fixtures")
}

fn expected(name: &str) -> Vec<u8> {
    std::fs::read(dir().join("expected").join(name)).unwrap()
}

fn command(home: &std::path::Path) -> Command {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_symcockpit"));
    cmd.env_clear()
        .env("SYMCOCKPIT_TEST_NO_HARDWARE", "1")
        .env("HOME", home)
        .env("PATH", "/usr/bin:/bin")
        .env("TZ", "UTC")
        .env("LC_ALL", "C")
        .env("SYMCOCKPIT_CHECK_UPDATES", "0");
    cmd
}

fn run(args: &[&str]) -> Vec<u8> {
    let home = tempfile::tempdir().unwrap();
    let data = dir().join("data");
    let out = command(home.path())
        .args(args)
        .arg("--data-dir")
        .arg(&data)
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(0), "{args:?}");
    assert!(out.stderr.is_empty(), "{args:?}");
    out.stdout
}

#[test]
fn cli_json_and_text_match_the_swift_bytes() {
    for (args, file) in [
        (&["history", "--json"][..], "history_--json.out"),
        (&["history"], "history.out"),
        (&["history", "--json", "-n", "2"], "history_--json_-n_2.out"),
        (&["history", "--limit", "1"], "history_--limit_1.out"),
        (&["profile", "list"], "profile_list.out"),
    ] {
        assert_eq!(
            String::from_utf8(run(args)).unwrap(),
            String::from_utf8(expected(file)).unwrap(),
            "{args:?}"
        );
    }
}

#[test]
fn version_report_matches_the_swift_bytes() {
    let home = tempfile::tempdir().unwrap();
    for (args, file) in [
        (&["version", "--json"][..], "version_--json.out"),
        (&["version"], "version.out"),
    ] {
        let out = command(home.path()).args(args).output().unwrap();
        assert_eq!(out.status.code(), Some(0));
        // The fixtures are the v0.12.2 bytes; the version in them follows this build, so
        // that bumping the release (scripts/set-version.sh) does not break the comparison.
        assert_eq!(
            String::from_utf8(out.stdout).unwrap(),
            String::from_utf8(expected(file))
                .unwrap()
                .replace("0.12.2", env!("CARGO_PKG_VERSION")),
            "{args:?}"
        );
    }
}

/// Swift emits the JSON-RPC envelope keys in random order, so only the tool
/// text (the encoder under test) is compared.
#[test]
fn mcp_tool_text_matches_the_swift_bytes() {
    let home = tempfile::tempdir().unwrap();
    let mut child = command(home.path())
        .arg("serve")
        .arg("--data-dir")
        .arg(dir().join("data"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(&std::fs::read(dir().join("mcp_in.jsonl")).unwrap())
        .unwrap();
    let out = child.wait_with_output().unwrap();
    let texts: Vec<(i64, String)> = String::from_utf8(out.stdout)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .filter_map(|v| {
            let text = v["result"]["content"][0]["text"].as_str()?.to_owned();
            Some((v["id"].as_i64()?, text))
        })
        .collect();
    let want = |file: &str| String::from_utf8(expected(file)).unwrap();
    assert_eq!(
        texts,
        [
            (2, want("mcp_get_history.json")),
            (3, want("mcp_list_profiles.json"))
        ]
    );
}
