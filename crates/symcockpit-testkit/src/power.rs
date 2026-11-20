//! Fakes for the power, thermal and keep-awake ports and the oracle form tests
//! of `awake status` and MCP `keep_awake_status`.

use symcockpit_core::power::{KeepAwakeSession, KeepAwakeStatus, ThermalSource, ThermalState};

pub struct FakeThermal(pub ThermalState);

impl ThermalSource for FakeThermal {
    fn thermal_state(&self) -> ThermalState {
        self.0
    }
}

pub struct FakeKeepAwake(pub KeepAwakeSession);

impl KeepAwakeStatus for FakeKeepAwake {
    fn status(&self) -> KeepAwakeSession {
        self.0.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::battery::assert_shape;
    use crate::smc::FakeSmc;
    use std::time::SystemTime;
    use symcockpit_core::power::awake_status_json;
    use symcockpit_core::sensors::read_system_power;

    fn status() -> serde_json::Value {
        awake_status_json(&FakeKeepAwake(
            KeepAwakeSession::inactive(SystemTime::now()),
        ))
        .unwrap()
    }

    #[test]
    fn awake_status_matches_the_oracle_shape() {
        assert_shape("awake-status", &status());
    }

    #[test]
    fn mcp_keep_awake_status_matches_the_oracle_shape() {
        let text = serde_json::to_string(&status()).unwrap();
        assert_shape(
            "mcp-call-keep_awake_status",
            &serde_json::from_str(&text).unwrap(),
        );
    }

    #[test]
    fn fake_keys_drive_the_system_power_function() {
        let smc = FakeSmc::new(true).with_flt("PDTR", 0.0);
        let report = read_system_power(&smc, || Some(8_000)).unwrap();
        assert_eq!(report.system_watts, Some(8.0));
        assert_eq!(
            FakeThermal(ThermalState::Fair).thermal_state().label(),
            "fair"
        );
    }
}
