//! Native mode of the harness against a fake candidate: a read command that
//! forwards to the legacy binary must show up as skipped, never as passed,
//! and write commands must not be run at all. Synthetic data only.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use symcockpit_oracle::{CaseResult, run_manifest, run_manifest_native};

/// `help` and `doctor` are answered here; `sensors` forwards; `fan set` would
/// write (and must never be invoked by native mode).
const FAKE: &str = r#"#!/bin/sh
case "$1" in
  help) echo 'fake help' ;;
  doctor) echo '{"tool":"fake"}' ;;
  sensors) exec "$SYMCOCKPIT_LEGACY_BIN" "$@" ;;
  fan) [ "$2" = set ] && echo "WRITE REACHED" >> "$FAKE_WRITE_LOG"; echo '{"applied":true}' ;;
  *) echo "unknown" >&2; exit 2 ;;
esac
"#;

const MANIFEST: &str = r#"{"schema":1,"env":{"isolate_xdg":true,"set":{}},"cases":[
 {"id":"help","argv":["help"],"kind":"exact","expect_exit":0,"fixture":"cases/help.stdout","normalize":[]},
 {"id":"doctor","argv":["doctor"],"kind":"json_shape","expect_exit":0,"fixture":"cases/doctor.shape.json"},
 {"id":"sensors","argv":["sensors"],"kind":"json_shape","expect_exit":0,"fixture":"cases/sensors.shape.json"},
 {"id":"fan-set","argv":["fan","set","0.5"],"kind":"exit_code","expect_exit":0},
 {"id":"fan-help","argv":["fan","--help"],"kind":"exit_code","expect_exit":2},
 {"id":"fan-status","argv":["fan","status"],"kind":"exit_code","expect_exit":2},
 {"id":"unknown","argv":["nope"],"kind":"exit_code","expect_exit":2},
 {"id":"wrong-help","argv":["help"],"kind":"exact","expect_exit":0,"fixture":"cases/wrong.stdout","normalize":[]}
]}"#;

fn setup(dir: &Path) -> (PathBuf, PathBuf) {
    let cases = dir.join("oracle/cases");
    std::fs::create_dir_all(&cases).unwrap();
    std::fs::write(dir.join("oracle/manifest.json"), MANIFEST).unwrap();
    std::fs::write(cases.join("help.stdout"), "fake help\n").unwrap();
    std::fs::write(cases.join("wrong.stdout"), "different\n").unwrap();
    std::fs::write(
        cases.join("doctor.shape.json"),
        r#"{"type":"object","properties":{"tool":{"type":"string"}}}"#,
    )
    .unwrap();
    std::fs::write(
        cases.join("sensors.shape.json"),
        r#"{"type":"object","properties":{}}"#,
    )
    .unwrap();
    let bin = dir.join("fake-symcockpit");
    std::fs::write(&bin, FAKE).unwrap();
    std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
    (dir.join("oracle/manifest.json"), bin)
}

fn verdict(results: &[CaseResult], id: &str) -> String {
    let r = results.iter().find(|r| r.id == id).unwrap();
    match (&r.skipped, r.errors.is_empty()) {
        (Some(reason), _) => format!("skipped: {reason}"),
        (None, true) => "passed".into(),
        (None, false) => format!("failed: {}", r.errors.join("; ")),
    }
}

#[test]
fn native_mode_separates_passed_forwarded_skipped_and_failed() {
    let tmp = tempfile::tempdir().unwrap();
    let (manifest, bin) = setup(tmp.path());
    let results = run_manifest_native(&manifest, &bin, Duration::from_secs(20)).unwrap();
    assert_eq!(verdict(&results, "help"), "passed");
    assert_eq!(verdict(&results, "doctor"), "passed");
    assert_eq!(
        verdict(&results, "sensors"),
        "skipped: forwarded to the Swift core (no native implementation yet)"
    );
    assert_eq!(verdict(&results, "fan-set"), "skipped: not a read command");
    assert_eq!(
        verdict(&results, "fan-help"),
        "failed: exit code: expected 2, got Some(0)",
        "usage text may run; this fake answers it wrongly"
    );
    assert_eq!(
        verdict(&results, "fan-status"),
        "failed: exit code: expected 2, got Some(0)"
    );
    assert_eq!(verdict(&results, "unknown"), "passed");
    assert!(
        verdict(&results, "wrong-help").starts_with("failed: stdout differs"),
        "native mode still reports real mismatches"
    );
}

#[test]
fn native_mode_ignores_the_callers_legacy_binary_and_runs_no_write() {
    let tmp = tempfile::tempdir().unwrap();
    let (manifest, bin) = setup(tmp.path());
    // A write that reached the fake would append here. The caller's legacy
    // variable pointing at a "working" binary must not leak into native mode.
    let log = tmp.path().join("write.log");
    let working = tmp.path().join("working-legacy");
    std::fs::write(&working, "#!/bin/sh\necho '{}'\n").unwrap();
    std::fs::set_permissions(&working, std::fs::Permissions::from_mode(0o755)).unwrap();
    let wrapper = tmp.path().join("wrapper");
    std::fs::write(
        &wrapper,
        format!(
            "#!/bin/sh\nFAKE_WRITE_LOG='{}' exec '{}' \"$@\"\n",
            log.display(),
            bin.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o755)).unwrap();
    let results = run_manifest_native(&manifest, &wrapper, Duration::from_secs(20)).unwrap();
    assert!(!log.exists(), "native mode ran a write command");
    assert!(
        results
            .iter()
            .any(|r| r.skipped.as_deref() == Some("not a read command"))
    );
    // Normal mode keeps its behaviour: nothing is skipped.
    let full = run_manifest(&manifest, &bin, Duration::from_secs(20)).unwrap();
    assert!(full.iter().all(|r| r.skipped.is_none()));
}
