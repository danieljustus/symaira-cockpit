//! End-to-end checks of the harness against a fake binary and a small
//! synthetic manifest (tests/fixtures/synthetic). Synthetic data only: the
//! real v0.12 fixtures live in `oracle/v0.12` and are exercised by `live.rs`.

use std::collections::BTreeMap;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use symcockpit_oracle::run_manifest;

const FAKE_BIN: &str = r#"#!/bin/sh
if [ "$1" = serve ]; then
  while IFS= read -r line; do
    case "$line" in
      *'"method":"initialize"'*) echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}' ;;
      *'"method":"tools/list"'*) echo '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"get_sensors","inputSchema":{"type":"object","properties":{"limit":{"type":"integer","maximum":50.0}},"required":[]}}]}}' ;;
      *'"method":"tools/call"'*) echo '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"{\"thermal\":\"nominal\",\"fans\":[{\"rpm\":1200}],\"temp\":null}"}],"isError":false}}' ;;
    esac
  done
  exit 0
fi
case "$1" in
  sensors) echo '{"thermal":"nominal","fans":[{"rpm":1200.5}],"temp":null}' ;;
  help) echo 'fake v7 help' ;;
  *) echo "unknown" >&2; exit 2 ;;
esac
"#;

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/synthetic")
}

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_dir(&entry.path(), &target);
        } else {
            std::fs::copy(entry.path(), target).unwrap();
        }
    }
}

fn fake_bin(dir: &Path) -> PathBuf {
    let path = dir.join("fake-symcockpit");
    std::fs::write(&path, FAKE_BIN).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

/// Run a (possibly mutated) copy of the synthetic fixtures; returns id -> errors.
fn verdicts(mutate: impl FnOnce(&Path)) -> BTreeMap<String, Vec<String>> {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("oracle");
    copy_dir(&fixtures(), &dir);
    mutate(&dir);
    let bin = fake_bin(tmp.path());
    run_manifest(&dir.join("manifest.json"), &bin, Duration::from_secs(20))
        .unwrap()
        .into_iter()
        .map(|r| (r.id, r.errors))
        .collect()
}

fn failing(v: &BTreeMap<String, Vec<String>>) -> Vec<&str> {
    v.iter()
        .filter(|(_, e)| !e.is_empty())
        .map(|(id, _)| id.as_str())
        .collect()
}

#[test]
fn matching_binary_passes_every_case() {
    let v = verdicts(|_| {});
    assert_eq!(v.len(), 5);
    assert!(failing(&v).is_empty(), "{v:?}");
}

#[test]
fn each_kind_of_drift_fails_only_its_own_case() {
    let v = verdicts(|dir| {
        let write = |p: &str, s: &str| std::fs::write(dir.join(p), s).unwrap();
        // json_shape: fixture demands a key the binary does not emit.
        write(
            "cases/sensors-json.shape.json",
            r#"{"type":"object","properties":{"thermal":{"type":"string"},"gone":{"type":"string"}}}"#,
        );
        // exact: different text.
        write("cases/help.stdout", "fake v1 other\n");
        // mcp_tools_list: fixture lists one more tool.
        write(
            "cases/mcp-tools-list.json",
            r#"{"tools":[{"name":"get_sensors","inputSchema":{}},{"name":"extra","inputSchema":{}}]}"#,
        );
        // mcp_call_shape: wrong type for rpm.
        write(
            "cases/mcp-call-get_sensors.shape.json",
            r#"{"type":"object","properties":{"thermal":{"type":"number"},"fans":{"type":"array","items":null},"temp":{"type":"null"}}}"#,
        );
    });
    assert_eq!(
        failing(&v),
        [
            "help",
            "mcp-call-get_sensors",
            "mcp-tools-list",
            "sensors-json"
        ]
    );
    assert!(
        v["mcp-tools-list"]
            .iter()
            .any(|e| e == "missing tool 'extra'")
    );
    assert!(
        v["sensors-json"]
            .iter()
            .any(|e| e.contains("missing key 'gone'"))
    );
    assert!(
        v["sensors-json"]
            .iter()
            .any(|e| e.contains("unexpected key 'fans'"))
    );
}

#[test]
fn wrong_exit_code_fails() {
    let v = verdicts(|dir| {
        let path = dir.join("manifest.json");
        let mut manifest: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        manifest["cases"][0]["expect_exit"] = 1.into();
        manifest["cases"][2]["expect_exit"] = 0.into();
        std::fs::write(path, manifest.to_string()).unwrap();
    });
    assert_eq!(failing(&v), ["sensors-json", "unknown-command"]);
    assert!(v["unknown-command"][0].contains("expected 0, got Some(2)"));
}

#[test]
fn unreadable_manifest_and_missing_binary_are_reported_not_skipped() {
    let tmp = tempfile::tempdir().unwrap();
    assert!(
        run_manifest(
            &tmp.path().join("nope.json"),
            Path::new("/bin/true"),
            Duration::from_secs(5)
        )
        .is_err()
    );
    let results = run_manifest(
        &fixtures().join("manifest.json"),
        &tmp.path().join("no-such-binary"),
        Duration::from_secs(5),
    )
    .unwrap();
    assert!(results.iter().all(|r| !r.errors.is_empty()));
}
