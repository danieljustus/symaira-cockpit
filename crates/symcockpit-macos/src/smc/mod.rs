//! AppleSMC access. `iokit` is the only module with raw FFI; everything else
//! is safe code.
//!
//! The read path (`iokit::Command`) has no write variant: the type system keeps
//! the readers read-only. The one write command (`6`, `kSMCWriteKey`) exists
//! only in `write`, behind the key allowlist of
//! `symcockpit_core::smc_write::is_allowed`, and is only ever reached by the
//! privileged paths (the helper, and the CLI as root).

mod host;
mod iokit;
mod live;
mod probe;
mod write;

pub use host::LiveHost;
pub use live::LiveSmc;
pub use probe::{FileFanSelection, PgrepGovernorProbe};

/// Live, read-only checks against this Mac's real SMC. Run explicitly:
/// `cargo test -p symcockpit-macos -- --ignored --nocapture live_`
#[cfg(test)]
mod live_tests {
    use symcockpit_core::sensors::*;
    use symcockpit_testkit::smc::assert_matches_oracle_shape;

    use super::*;

    #[test]
    #[ignore = "reads the real AppleSMC (read-only)"]
    fn live_documents_match_the_oracle_shapes() {
        let (smc, host) = (LiveSmc::open(), LiveHost);
        assert!(smc.is_open(), "SMC not reachable on this Mac");

        let sensors = sensors_json(&smc, &host).unwrap();
        assert_matches_oracle_shape("sensors-json.shape.json", &sensors);
        assert_matches_oracle_shape("mcp-call-get_sensors.shape.json", &sensors);

        // An absent file is the isolated-HOME state the oracle was recorded in.
        let nowhere = FileFanSelection::at("/nonexistent/symcockpit-live-test/fan-profile.json");
        let fan_status = fan_status_json(&nowhere, &PgrepGovernorProbe, &smc, &host).unwrap();
        assert_matches_oracle_shape("fan-status.shape.json", &fan_status);

        let power = read_system_power(&smc, || None);
        let charge = detect_charge_limit_key_family(&smc);
        let enumeration = smc.enumerate_keys().map(|k| k.len());
        println!("LIVE sensors {sensors}");
        println!("LIVE fan_status {fan_status}");
        println!("LIVE power {}", serde_json::to_string(&power).unwrap());
        println!(
            "LIVE charge_limit_family {charge:?} require={:?}",
            require_charge_limit_key(&smc)
        );
        println!(
            "LIVE chip {:?} enumerated_keys {enumeration:?}",
            host.chip_generation()
        );
        println!(
            "LIVE fan_mode0 {:?} fan_mode1 {:?}",
            read_fan_mode(&smc, 0),
            read_fan_mode(&smc, 1)
        );
    }
}
