//! The release build has no way around the parent check: the debug-only test
//! switch of `symcockpit agent` is compiled out. Meaningful only in a release
//! profile build, so run it with
//!
//!     cargo test --release --locked -p symcockpit --test agent_release
//!
//! (`make rust-test-agent-release`). In a debug build the file compiles to
//! nothing, and `agent_stdio.rs` covers the debug binary instead.

#![cfg(not(debug_assertions))]

use std::process::{Command, Stdio};

const BIN: &str = env!("CARGO_BIN_EXE_symcockpit");
const SWITCH: &str = "SYMCOCKPIT_AGENT_SKIP_PARENT_CHECK";

#[test]
fn the_release_binary_ignores_the_test_switch() {
    let out = Command::new(BIN)
        .args(["agent", "--stdio"])
        .env_clear()
        .env(SWITCH, "1")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert_eq!(
        out.status.code(),
        Some(3),
        "the switch must not skip the check"
    );
    assert!(out.stdout.is_empty());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("symcockpit: agent:"), "{stderr}");
    assert!(!stderr.contains("skipped"), "{stderr}");
}

#[test]
fn the_release_binary_does_not_contain_the_switch_at_all() {
    let bytes = std::fs::read(BIN).unwrap();
    assert!(
        !bytes.windows(SWITCH.len()).any(|w| w == SWITCH.as_bytes()),
        "the switch name is in the release binary"
    );
}
