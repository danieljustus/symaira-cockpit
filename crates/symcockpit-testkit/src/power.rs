//! Fakes for the power, thermal and keep-awake ports and the oracle form tests
//! of `awake status` and MCP `keep_awake_status`.

use std::collections::HashMap;

use symcockpit_core::power::{
    KeepAwakeSession, KeepAwakeStatus, PowerKeyReader, ThermalSource, ThermalState,
};

/// SMC power keys from a map; `open` mimics the connection state.
pub struct FakePowerKeys {
    pub open: bool,
    pub keys: HashMap<String, f64>,
}

impl FakePowerKeys {
    pub fn new(keys: &[(&str, f64)]) -> Self {
        FakePowerKeys {
            open: true,
            keys: keys.iter().map(|(k, v)| (k.to_string(), *v)).collect(),
        }
    }
}

impl PowerKeyReader for FakePowerKeys {
    fn is_open(&self) -> bool {
        self.open
    }
    fn read_key(&self, key: &str) -> Option<f64> {
        self.keys.get(key).copied()
    }
}

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
    use std::time::SystemTime;
    use symcockpit_core::power::{awake_status_json, read_system_power};

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
        let report =
            read_system_power(&FakePowerKeys::new(&[("PDTR", 0.0)]), || Some(8_000)).unwrap();
        assert_eq!(report.system_watts, Some(8.0));
        assert_eq!(
            FakeThermal(ThermalState::Fair).thermal_state().label(),
            "fair"
        );
    }
}
