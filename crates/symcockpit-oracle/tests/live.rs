//! Live oracle run against a real binary; explicit opt-in:
//! `SYMCOCKPIT_ORACLE_BIN=<binary> cargo test -p symcockpit-oracle -- --ignored`
//! (or `make oracle BIN=<binary>`). Fails loudly when the variable is unset.
//!
//! With `SYMCOCKPIT_ORACLE_NATIVE=1` (or `make oracle-native BIN=<binary>`) the
//! candidate runs without any Swift binary: only read commands are checked,
//! and a case the candidate forwards counts as skipped, not as passed.

use std::path::Path;
use std::time::Duration;

#[test]
#[ignore = "needs SYMCOCKPIT_ORACLE_BIN and the frozen fixtures in oracle/v0.12"]
fn candidate_matches_v012_oracle() {
    let bin = std::env::var_os("SYMCOCKPIT_ORACLE_BIN")
        .expect("SYMCOCKPIT_ORACLE_BIN is not set: point it at the symcockpit binary to check (make oracle BIN=...)");
    let native = std::env::var("SYMCOCKPIT_ORACLE_NATIVE").is_ok_and(|v| v == "1");
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../oracle/v0.12/manifest.json");
    assert!(
        manifest.is_file(),
        "missing {}: capture the fixtures first (scripts/oracle-capture.sh)",
        manifest.display()
    );

    let run = if native {
        symcockpit_oracle::run_manifest_native
    } else {
        symcockpit_oracle::run_manifest
    };
    let results = run(&manifest, Path::new(&bin), Duration::from_secs(30)).unwrap();
    assert!(!results.is_empty(), "manifest has no cases");
    let (mut failed, mut skipped, mut passed) = (0, 0, 0);
    for case in &results {
        for hint in &case.hints {
            eprintln!("hint  {}: {hint}", case.id);
        }
        if let Some(reason) = &case.skipped {
            skipped += 1;
            eprintln!("skip  {}: {reason}", case.id);
        } else if case.errors.is_empty() {
            passed += 1;
            eprintln!("ok    {}", case.id);
        } else {
            failed += 1;
            for error in &case.errors {
                eprintln!("FAIL  {}: {error}", case.id);
            }
        }
    }
    eprintln!(
        "oracle {}: {passed} passed, {skipped} skipped, {failed} failed of {} cases",
        if native { "native" } else { "full" },
        results.len()
    );
    assert_eq!(
        failed,
        0,
        "{failed} of {} oracle cases failed",
        results.len()
    );
    if native {
        assert!(passed > 0, "native mode verified no case at all");
    } else {
        assert_eq!(skipped, 0, "full mode runs every case");
    }
}
