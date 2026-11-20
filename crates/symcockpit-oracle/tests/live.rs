//! Live oracle run against a real binary; explicit opt-in:
//! `SYMCOCKPIT_ORACLE_BIN=<binary> cargo test -p symcockpit-oracle -- --ignored`
//! (or `make oracle BIN=<binary>`). Fails loudly when the variable is unset.

use std::path::Path;
use std::time::Duration;

#[test]
#[ignore = "needs SYMCOCKPIT_ORACLE_BIN and the frozen fixtures in oracle/v0.12"]
fn candidate_matches_v012_oracle() {
    let bin = std::env::var_os("SYMCOCKPIT_ORACLE_BIN")
        .expect("SYMCOCKPIT_ORACLE_BIN is not set: point it at the symcockpit binary to check (make oracle BIN=...)");
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../oracle/v0.12/manifest.json");
    assert!(
        manifest.is_file(),
        "missing {}: capture the fixtures first (scripts/oracle-capture.sh)",
        manifest.display()
    );

    let results =
        symcockpit_oracle::run_manifest(&manifest, Path::new(&bin), Duration::from_secs(30))
            .unwrap();
    assert!(!results.is_empty(), "manifest has no cases");
    let mut failed = 0;
    for case in &results {
        for hint in &case.hints {
            eprintln!("hint  {}: {hint}", case.id);
        }
        if case.errors.is_empty() {
            eprintln!("ok    {}", case.id);
        } else {
            failed += 1;
            for error in &case.errors {
                eprintln!("FAIL  {}: {error}", case.id);
            }
        }
    }
    assert_eq!(
        failed,
        0,
        "{failed} of {} oracle cases failed",
        results.len()
    );
}
