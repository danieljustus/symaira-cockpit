//! Fakes for the display ports, plus the oracle shape tests for the four
//! read cases (`displays-json`, `brightness-get`, `mcp-call-list_displays`,
//! `mcp-call-get_brightness`).

use symcockpit_contract::Error;
use symcockpit_core::display::{BrightnessSource, DisplayEnumerator, ScreenSnapshot};

/// Fixed list of screens.
pub struct FakeDisplays(pub Vec<ScreenSnapshot>);

impl DisplayEnumerator for FakeDisplays {
    fn enumerate_screens(&self) -> Vec<ScreenSnapshot> {
        self.0.clone()
    }
}

/// Fixed brightness reading (or error) for any display id.
pub struct FakeBrightness(pub Result<f64, Error>);

impl BrightnessSource for FakeBrightness {
    fn brightness(&self, _display_id: u32) -> Result<f64, Error> {
        self.0.clone()
    }
}

/// One generic built-in panel with EDR headroom: invented numbers, no device data.
pub fn sample_builtin() -> ScreenSnapshot {
    ScreenSnapshot {
        name: "Built-in Display".into(),
        display_id: 1,
        is_builtin: true,
        max_edr_headroom: 1.0,
        potential_edr_headroom: 2.0,
        backing_scale_factor: 2.0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use std::path::Path;
    use symcockpit_core::display::{brightness_get_json, displays_json};
    use symcockpit_oracle::shape;

    fn fixture(case: &str) -> Value {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../oracle/v0.12/cases")
            .join(format!("{case}.shape.json"));
        serde_json::from_str(&std::fs::read_to_string(&path).expect("fixture missing")).unwrap()
    }

    fn assert_shape(case: &str, actual: &Value) {
        let diff = shape::compare(&fixture(case), &shape::derive(actual).unwrap());
        assert!(diff.errors.is_empty(), "{case}: {:?}", diff.errors);
    }

    #[test]
    fn displays_cases_match_oracle_shape() {
        let v = displays_json(&FakeDisplays(vec![sample_builtin()])).unwrap();
        assert_shape("displays-json", &v);
        assert_shape("mcp-call-list_displays", &v);
    }

    #[test]
    fn brightness_cases_match_oracle_shape() {
        let v = brightness_get_json(
            &FakeDisplays(vec![sample_builtin()]),
            &FakeBrightness(Ok(0.5)),
        )
        .unwrap();
        assert_shape("brightness-get", &v);
        assert_shape("mcp-call-get_brightness", &v);
    }

    #[test]
    fn oracle_shape_check_rejects_a_drifted_report() {
        let mut v = displays_json(&FakeDisplays(vec![sample_builtin()])).unwrap();
        v["displays"][0]["extra"] = Value::Bool(true);
        let diff = shape::compare(&fixture("displays-json"), &shape::derive(&v).unwrap());
        assert!(!diff.errors.is_empty());
    }

    #[test]
    fn help_text_matches_fixture_bytes() {
        let expected = std::fs::read_to_string(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../oracle/v0.12/cases/displays-help.stdout"),
        )
        .unwrap();
        assert_eq!(symcockpit_core::display::DISPLAYS_HELP, expected);
    }
}
