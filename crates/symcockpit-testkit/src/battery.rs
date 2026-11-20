//! Fakes for the battery ports and the oracle form tests of `battery` and
//! MCP `get_battery`.

use std::cell::Cell;

use symcockpit_core::battery::{
    AppleBatteryHealth, AppleHealthProvider, BatteryProperties, BatterySource, BatterySourceResult,
    ChargeLimitProbe,
};

/// Returns a fixed read result.
pub struct FakeBatterySource(pub BatterySourceResult);

impl BatterySource for FakeBatterySource {
    fn read_properties(&self) -> BatterySourceResult {
        self.0.clone()
    }
}

/// Fixed charge-limit answer; counts the probes.
pub struct FakeChargeLimitProbe {
    pub supported: bool,
    pub calls: Cell<u32>,
}

impl FakeChargeLimitProbe {
    pub fn new(supported: bool) -> Self {
        FakeChargeLimitProbe {
            supported,
            calls: Cell::new(0),
        }
    }
}

impl ChargeLimitProbe for FakeChargeLimitProbe {
    fn is_supported(&self) -> bool {
        self.calls.set(self.calls.get() + 1);
        self.supported
    }
}

/// Fixed Apple health figures, no subprocess.
pub struct FakeAppleHealth(pub AppleBatteryHealth);

impl AppleHealthProvider for FakeAppleHealth {
    fn read_apple_health(&self) -> AppleBatteryHealth {
        self.0.clone()
    }
}

/// A battery as the Apple Silicon registry reports it, with made-up numbers.
pub fn sample_battery() -> BatteryProperties {
    BatteryProperties {
        is_charging: Some(false),
        external_connected: Some(true),
        design_capacity: Some(6000),
        raw_max_capacity: Some(5400),
        raw_current_capacity: Some(5000),
        charge_percent: Some(100),
        cycle_count: Some(100),
        temperature_centidegrees: None,
        system_load_milliwatts: Some(12_000),
    }
}

/// Shape fixture of an oracle case (`oracle/v0.12/manifest.json`).
#[cfg(test)]
pub(crate) fn oracle_fixture(case_id: &str) -> serde_json::Value {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../oracle/v0.12");
    let read = |path: std::path::PathBuf| {
        serde_json::from_slice::<serde_json::Value>(&std::fs::read(&path).expect("oracle file"))
            .expect("oracle json")
    };
    let manifest = read(dir.join("manifest.json"));
    let case = manifest["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == case_id)
        .unwrap_or_else(|| panic!("no oracle case {case_id}"));
    read(dir.join(case["fixture"].as_str().unwrap()))
}

#[cfg(test)]
pub(crate) fn assert_shape(case_id: &str, actual: &serde_json::Value) {
    use symcockpit_oracle::shape::{compare, derive};
    let diff = compare(&oracle_fixture(case_id), &derive(actual).unwrap());
    assert!(diff.errors.is_empty(), "{case_id}: {:?}", diff.errors);
}

#[cfg(test)]
mod tests {
    use super::*;
    use symcockpit_core::battery::{BATTERY_HELP, battery_json};

    fn json(apple: bool) -> serde_json::Value {
        let source = FakeBatterySource(BatterySourceResult::Success(sample_battery()));
        let provider = FakeAppleHealth(AppleBatteryHealth {
            maximum_capacity_percent: Some(88),
            condition: Some("Normal".into()),
        });
        battery_json(
            &source,
            &FakeChargeLimitProbe::new(false),
            apple.then_some(&provider as &dyn AppleHealthProvider),
        )
        .unwrap()
    }

    #[test]
    fn battery_json_matches_the_oracle_shape() {
        assert_shape("battery-json", &json(true));
    }

    #[test]
    fn mcp_get_battery_matches_the_oracle_shape() {
        // The MCP tool prints the same value as compact JSON text.
        let text = serde_json::to_string(&json(true)).unwrap();
        assert_shape(
            "mcp-call-get_battery",
            &serde_json::from_str(&text).unwrap(),
        );
    }

    #[test]
    fn shape_check_rejects_a_missing_apple_figure() {
        use symcockpit_oracle::shape::{compare, derive};
        let diff = compare(
            &oracle_fixture("battery-json"),
            &derive(&json(false)).unwrap(),
        );
        assert_eq!(
            diff.errors,
            [
                "$: missing key 'apple_condition'",
                "$: missing key 'apple_maximum_capacity_percent'"
            ]
        );
    }

    #[test]
    fn battery_help_is_the_oracle_text() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../oracle/v0.12/cases");
        let expected = std::fs::read_to_string(dir.join("battery-help.stdout")).unwrap();
        assert_eq!(BATTERY_HELP, expected);
    }
}
