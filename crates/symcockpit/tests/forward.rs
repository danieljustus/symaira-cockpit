//! End-to-end checks of the built `symcockpit` binary against a fake legacy
//! script that mirrors its arguments, stdin and an exit code of our choosing.

use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

const FAKE_LEGACY: &str = r#"#!/bin/sh
printf 'argc=%s\n' "$#"
for a in "$@"; do printf '[%s]\n' "$a"; done
cat
echo "to-stderr" >&2
exit "${FAKE_EXIT:-0}"
"#;

fn fake_legacy(dir: &Path) -> PathBuf {
    let path = dir.join("fake-legacy");
    std::fs::write(&path, FAKE_LEGACY).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

fn run(legacy: Option<&Path>, args: &[&str], stdin: &str, exit: &str) -> Output {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_symcockpit"));
    cmd.args(args)
        .env_remove("SYMCOCKPIT_LEGACY_BIN")
        .env_remove("SYMCOCKPIT_CHECK_UPDATES")
        .env("FAKE_EXIT", exit)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(legacy) = legacy {
        cmd.env("SYMCOCKPIT_LEGACY_BIN", legacy);
    }
    let mut child = cmd.spawn().unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(stdin.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

#[test]
fn forwards_argv_stdio_and_exit_code_unchanged() {
    let tmp = tempfile::tempdir().unwrap();
    let legacy = fake_legacy(tmp.path());
    let out = run(
        Some(&legacy),
        &["fan", "--json", "", "a b", "--data-dir=x y", "é"],
        "in-bytes",
        "3",
    );
    assert_eq!(out.status.code(), Some(3));
    assert_eq!(
        String::from_utf8(out.stdout).unwrap(),
        "argc=6\n[fan]\n[--json]\n[]\n[a b]\n[--data-dir=x y]\n[é]\nin-bytes"
    );
    assert_eq!(String::from_utf8(out.stderr).unwrap(), "to-stderr\n");
}

#[test]
fn unknown_and_empty_invocations_are_answered_natively_with_exit_2() {
    let tmp = tempfile::tempdir().unwrap();
    let legacy = fake_legacy(tmp.path());
    for args in [&["nope"][..], &[]] {
        let out = run(Some(&legacy), args, "", "0");
        assert_eq!(out.status.code(), Some(2), "{args:?}");
        assert!(
            out.stdout.is_empty(),
            "usage goes to stderr, nothing reaches the legacy binary"
        );
        assert!(
            String::from_utf8(out.stderr)
                .unwrap()
                .contains("Usage:\n  symcockpit <command> [options]")
        );
    }
}

#[test]
fn version_is_answered_without_a_legacy_binary() {
    let out = run(None, &["version"], "", "0");
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(
        String::from_utf8(out.stdout).unwrap(),
        format!(
            "symcockpit {} — update check skipped\n",
            symcockpit::VERSION
        )
    );
}

#[test]
fn explicit_update_opt_in_is_forwarded() {
    let tmp = tempfile::tempdir().unwrap();
    let legacy = fake_legacy(tmp.path());
    let out = Command::new(env!("CARGO_BIN_EXE_symcockpit"))
        .arg("version")
        .env("SYMCOCKPIT_LEGACY_BIN", &legacy)
        .env("SYMCOCKPIT_CHECK_UPDATES", "1")
        .output()
        .unwrap();
    assert!(
        String::from_utf8(out.stdout)
            .unwrap()
            .starts_with("argc=1\n[version]")
    );
}

#[test]
fn missing_legacy_binary_exits_4_with_a_message() {
    // Run a copy so no `symcockpit-legacy` neighbour can exist.
    let tmp = tempfile::tempdir().unwrap();
    let exe = tmp.path().join("symcockpit");
    std::fs::copy(env!("CARGO_BIN_EXE_symcockpit"), &exe).unwrap();
    let out = Command::new(&exe)
        .arg("dim")
        .env_remove("SYMCOCKPIT_LEGACY_BIN")
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(4));
    assert!(out.stdout.is_empty());
    assert!(
        String::from_utf8(out.stderr)
            .unwrap()
            .contains("legacy binary not found")
    );
    // An override pointing nowhere fails the same way.
    let out = Command::new(&exe)
        .arg("dim")
        .env("SYMCOCKPIT_LEGACY_BIN", tmp.path().join("gone"))
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(4));
}

#[test]
fn sibling_legacy_binary_is_found_next_to_the_executable() {
    let tmp = tempfile::tempdir().unwrap();
    let exe = tmp.path().join("symcockpit");
    std::fs::copy(env!("CARGO_BIN_EXE_symcockpit"), &exe).unwrap();
    let sibling = fake_legacy(tmp.path());
    std::fs::rename(&sibling, tmp.path().join("symcockpit-legacy")).unwrap();
    let out = Command::new(&exe)
        .arg("dim")
        .env_remove("SYMCOCKPIT_LEGACY_BIN")
        .env("FAKE_EXIT", "0")
        .output()
        .unwrap();
    assert!(
        String::from_utf8(out.stdout)
            .unwrap()
            .starts_with("argc=1\n[dim]")
    );
}
