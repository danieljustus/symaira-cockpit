//! Fakes for the SMC/sensor ports (`symcockpit_core::sensors`) and the oracle
//! shape helper. No hardware, no private data: values are plausible numbers,
//! not captures.

use std::collections::BTreeMap;

use serde_json::Value;
use symcockpit_core::sensors::{
    ChipGeneration, FanSelection, FanSelectionSource, FourCc, GovernorProbe, RawKey, SensorHost,
    SmcPort,
};

/// In-memory SMC: a key table plus the enumeration the host would expose.
#[derive(Clone, Debug)]
pub struct FakeSmc {
    pub open: bool,
    pub keys: BTreeMap<String, RawKey>,
    /// `None`: the host does not allow index enumeration.
    pub enumerated: Option<Vec<String>>,
}

impl FakeSmc {
    pub fn new(open: bool) -> Self {
        Self {
            open,
            keys: BTreeMap::new(),
            enumerated: None,
        }
    }

    pub fn closed() -> Self {
        Self::new(false)
    }

    pub fn with_raw(mut self, key: &str, data_type: &FourCc, bytes: &[u8]) -> Self {
        self.keys.insert(
            key.into(),
            RawKey {
                data_type: *data_type,
                bytes: bytes.to_vec(),
            },
        );
        self
    }

    /// `flt ` is little-endian on the wire (issue #185).
    pub fn with_flt(self, key: &str, value: f32) -> Self {
        self.with_raw(key, b"flt ", &value.to_le_bytes())
    }

    pub fn with_ui8(self, key: &str, value: u8) -> Self {
        self.with_raw(key, b"ui8 ", &[value])
    }

    /// Unsigned fixed-point 14.2: the register holds the value times 4 (#193).
    pub fn with_fpe2(self, key: &str, raw: u16) -> Self {
        self.with_raw(key, b"fpe2", &raw.to_be_bytes())
    }

    pub fn with_enumeration(mut self, keys: &[&str]) -> Self {
        self.enumerated = Some(keys.iter().map(|k| (*k).to_string()).collect());
        self
    }

    /// Every key exposed, like a host that allows enumeration.
    pub fn enumerating_all_keys(mut self) -> Self {
        self.enumerated = Some(self.keys.keys().cloned().collect());
        self
    }

    /// A MacBook with an M4 Pro-like SMC: two fans, die hotspots plausible,
    /// several rows implausible (power-gated cores, the `Ta0P` placeholder), and
    /// a laptop's power rails. Numbers are typical, not measured.
    pub fn m4_pro_like() -> Self {
        let mut smc = Self::new(true)
            .with_raw("#KEY", b"ui32", &3374u32.to_be_bytes())
            .with_ui8("FNum", 2);
        for (key, celsius) in [
            ("TCMz", 62.4),
            ("TRDX", 55.1),
            ("TCMb", 61.0),
            ("TCHP", 38.5),
            ("Tp01", 2.25), // implemented but not the named sensor: reads 0-8 °C
            ("Tp02", 2.5),
            ("Tp05", 3.0),
            ("Ta0P", 8.3), // placeholder value
            ("Te04", 48.2),
            ("Te05", 49.0),
            ("Te0R", 47.5),
        ] {
            smc = smc.with_flt(key, celsius);
        }
        for (fan, (rpm, min, max)) in [(2150.0, 1200.0, 7800.0), (2210.0, 1200.0, 8200.0)]
            .into_iter()
            .enumerate()
        {
            smc = smc
                .with_flt(&format!("F{fan}Ac"), rpm)
                .with_flt(&format!("F{fan}Mn"), min)
                .with_flt(&format!("F{fan}Mx"), max)
                .with_flt(&format!("F{fan}Tg"), rpm)
                .with_ui8(&format!("F{fan}Md"), 0);
        }
        for (key, value) in [("VD0R", 20.1), ("ID0R", 0.0), ("PDTR", 0.0), ("PSTR", 8.4)] {
            smc = smc.with_flt(key, value);
        }
        smc.enumerating_all_keys()
    }
}

impl SmcPort for FakeSmc {
    fn is_open(&self) -> bool {
        self.open
    }

    fn read_key_raw(&self, key: &str) -> Option<RawKey> {
        self.open.then(|| self.keys.get(key).cloned()).flatten()
    }

    fn enumerate_keys(&self) -> Option<Vec<String>> {
        self.open.then(|| self.enumerated.clone()).flatten()
    }
}

#[derive(Clone, Copy, Debug)]
pub struct FakeHost {
    pub thermal: &'static str,
    pub generation: ChipGeneration,
}

impl Default for FakeHost {
    fn default() -> Self {
        Self {
            thermal: "nominal",
            generation: ChipGeneration::M4,
        }
    }
}

impl SensorHost for FakeHost {
    fn thermal_pressure(&self) -> &'static str {
        self.thermal
    }

    fn chip_generation(&self) -> ChipGeneration {
        self.generation
    }
}

pub struct FakeFanSelection(pub FanSelection);

impl FanSelectionSource for FakeFanSelection {
    fn selection(&self) -> FanSelection {
        self.0
    }
}

pub struct FakeGovernor(pub bool);

impl GovernorProbe for FakeGovernor {
    fn is_running(&self) -> bool {
        self.0
    }
}

/// Compare the shape of `actual` with a frozen v0.12 fixture
/// (`oracle/v0.12/cases/<name>`) using the oracle harness's own comparison.
/// Returns the tolerated hints; panics listing every error otherwise.
pub fn assert_matches_oracle_shape(fixture: &str, actual: &Value) -> Vec<String> {
    let path = format!(
        "{}/../../oracle/v0.12/cases/{fixture}",
        env!("CARGO_MANIFEST_DIR")
    );
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"));
    let expected: Value = serde_json::from_str(&text).expect("fixture is JSON");
    let shape = symcockpit_oracle::shape::derive(actual).expect("actual has a shape");
    let diff = symcockpit_oracle::shape::compare(&expected, &shape);
    assert!(diff.errors.is_empty(), "{fixture}: {:#?}", diff.errors);
    diff.hints
}

#[cfg(test)]
mod tests {
    use serde_json::json;
    use symcockpit_contract::Error;
    use symcockpit_core::sensors::*;

    use super::*;

    // ---- form tests against the frozen oracle ------------------------------

    #[test]
    fn sensors_json_matches_the_oracle_shape() {
        // oracle case `sensors-json` (argv: sensors --json)
        let value = sensors_json(&FakeSmc::m4_pro_like(), &FakeHost::default()).unwrap();
        assert_matches_oracle_shape("sensors-json.shape.json", &value);
    }

    // The shape gate is not vacuous: a dropped, an extra and a retyped key all fail it.
    fn mutated_sensors(mutate: impl FnOnce(&mut Value)) {
        let mut value = sensors_json(&FakeSmc::m4_pro_like(), &FakeHost::default()).unwrap();
        mutate(&mut value);
        assert_matches_oracle_shape("sensors-json.shape.json", &value);
    }

    #[test]
    #[should_panic(expected = "missing key 'fans'")]
    fn shape_gate_rejects_a_missing_key() {
        mutated_sensors(|v| {
            v.as_object_mut().unwrap().remove("fans");
        });
    }

    #[test]
    #[should_panic(expected = "unexpected key 'extra'")]
    fn shape_gate_rejects_an_extra_key() {
        mutated_sensors(|v| v["temperatures"][0]["extra"] = json!(1));
    }

    #[test]
    #[should_panic(expected = "expected type string, got number")]
    fn shape_gate_rejects_a_retyped_value() {
        mutated_sensors(|v| v["thermal_pressure"] = json!(5));
    }

    #[test]
    fn get_sensors_tool_is_the_same_document_as_the_cli() {
        // oracle case `mcp-call-get_sensors`: the tool encodes the same `SensorReport`
        // (TuneTools.swift SensorsTool -> controller.sensorsReport()).
        let value = sensors_json(&FakeSmc::m4_pro_like(), &FakeHost::default()).unwrap();
        assert_matches_oracle_shape("mcp-call-get_sensors.shape.json", &value);
    }

    #[test]
    fn sensors_json_has_exactly_the_swift_keys() {
        let value = sensors_json(&FakeSmc::m4_pro_like(), &FakeHost::default()).unwrap();
        let keys = |v: &Value| {
            let mut k: Vec<_> = v.as_object().unwrap().keys().cloned().collect();
            k.sort();
            k
        };
        assert_eq!(
            keys(&value),
            [
                "fans",
                "notes",
                "smc_supported",
                "temperatures",
                "thermal_pressure"
            ]
        );
        assert_eq!(
            keys(&value["fans"][0]),
            ["index", "label", "max_rpm", "min_rpm", "rpm"]
        );
        assert_eq!(keys(&value["temperatures"][0]), ["celsius", "key", "label"]);
        // Nil optionals are omitted, not null (synthesised Codable).
        let report = FanReading {
            index: 0,
            label: "Main Fan".into(),
            rpm: 1,
            min_rpm: None,
            max_rpm: None,
        };
        assert_eq!(
            serde_json::to_value(report).unwrap(),
            json!({"index":0,"label":"Main Fan","rpm":1})
        );
    }

    #[test]
    fn fan_status_json_matches_the_oracle_shape() {
        // oracle case `fan-status` (argv: fan status): no target stored -> explicit null.
        let value = fan_status_json(
            &FakeFanSelection(FanSelection::SYSTEM),
            &FakeGovernor(false),
            &FakeSmc::m4_pro_like(),
            &FakeHost::default(),
        )
        .unwrap();
        assert_matches_oracle_shape("fan-status.shape.json", &value);
        assert_eq!(value["cool_target_celsius"], Value::Null);
        assert_eq!(value["profile"], "system");
        assert_eq!(value["governor_running"], false);
    }

    #[test]
    fn fan_status_with_a_target_only_drifts_in_a_tolerated_hint() {
        let value = fan_status_json(
            &FakeFanSelection(FanSelection::new(FanProfile::Comfort, Some(70.0))),
            &FakeGovernor(true),
            &FakeSmc::m4_pro_like(),
            &FakeHost::default(),
        )
        .unwrap();
        let hints = assert_matches_oracle_shape("fan-status.shape.json", &value);
        assert_eq!(hints.len(), 1, "{hints:?}"); // null on one side (expected null, got number)
        assert_eq!(value["cool_target_celsius"], 70.0);
        assert_eq!(value["governor_running"], true);
    }

    #[test]
    fn fan_status_nulls_the_average_without_sensors_and_rounds_to_a_tenth() {
        let status = |smc: &FakeSmc| {
            fan_status_json(
                &FakeFanSelection(FanSelection::SYSTEM),
                &FakeGovernor(false),
                smc,
                &FakeHost::default(),
            )
            .unwrap()
        };
        assert_eq!(
            status(&FakeSmc::closed())["average_cluster_celsius"],
            Value::Null
        );
        // Te04 48.2, Te05 49.0, Te0R 47.5 (Tp rows implausible) + TRDX 55.1:
        // (48.2+49.0+47.5+55.1)/4 = 49.95 -> 50.0 (flt values carry f32 noise).
        let avg = status(&FakeSmc::m4_pro_like())["average_cluster_celsius"]
            .as_f64()
            .unwrap();
        assert!(
            (avg - 50.0).abs() < 1e-9 || (avg - 49.9).abs() < 1e-9,
            "{avg}"
        );
        assert_eq!(avg, (avg * 10.0).round() / 10.0);
    }

    // ---- temperatures and fans: SMCServiceTests.swift ----------------------

    const M4: ChipGeneration = ChipGeneration::M4;

    #[test]
    fn unavailable_connection_returns_empty() {
        // testUnavailableConnectionReturnsEmptyTemperatures
        let smc = FakeSmc::closed().with_fpe2("Tp01", 0xC8);
        assert!(!smc.is_open());
        assert_eq!(read_temperatures(&smc, M4), []);
        assert_eq!(read_fans(&smc), []);
    }

    #[test]
    fn missing_temperature_keys_return_empty() {
        assert_eq!(read_temperatures(&FakeSmc::new(true), M4), []);
    }

    #[test]
    fn temperature_reading() {
        // testTemperatureReadings: 0x00C8 / 4 = 50.0 (fpe2, #193)
        let readings = read_temperatures(&FakeSmc::new(true).with_fpe2("Tp01", 0x00C8), M4);
        assert_eq!(
            readings,
            [SensorReading {
                key: "Tp01".into(),
                label: "CPU Core 1".into(),
                celsius: 50.0
            }]
        );
    }

    #[test]
    fn fan_count_zero_returns_empty() {
        // testFanCountZeroReturnsEmpty
        assert_eq!(read_fans(&FakeSmc::new(true).with_ui8("FNum", 0)), []);
        assert_eq!(read_fans(&FakeSmc::new(true)), []);
    }

    #[test]
    fn fan_reading() {
        // testFanReadings: 0x0014 / 4 = 5.0
        let smc = FakeSmc::new(true)
            .with_ui8("FNum", 1)
            .with_fpe2("F0Ac", 0x0014);
        let fans = read_fans(&smc);
        assert_eq!(
            fans,
            [FanReading {
                index: 0,
                label: "Main Fan".into(),
                rpm: 5,
                min_rpm: None,
                max_rpm: None
            }]
        );
    }

    #[test]
    fn fans_are_capped_at_four_and_a_fan_without_rpm_is_skipped() {
        let mut smc = FakeSmc::new(true).with_ui8("FNum", 6);
        for i in [0, 1, 3] {
            smc = smc
                .with_flt(&format!("F{i}Ac"), 1000.0 + i as f32)
                .with_flt(&format!("F{i}Mx"), 5000.9);
        }
        let fans = read_fans(&smc);
        assert_eq!(fans.iter().map(|f| f.index).collect::<Vec<_>>(), [0, 1, 3]);
        assert_eq!(fans[1].label, "Fan 2");
        assert_eq!(fans[2].label, "Fan 4");
        assert_eq!((fans[0].min_rpm, fans[0].max_rpm), (None, Some(5000))); // truncated, not rounded
    }

    #[test]
    fn implausible_temperatures_are_not_reported() {
        // testImplausibleTemperaturesAreNotReported (#185): 2.25 °C dropped, 85 °C kept
        let smc = FakeSmc::new(true)
            .with_fpe2("TCMz", 0x0009)
            .with_fpe2("TRDX", 0x0154)
            .with_enumeration(&["TCMz", "TRDX"]);
        let keys: Vec<_> = read_temperatures(&smc, M4)
            .into_iter()
            .map(|r| r.key)
            .collect();
        assert_eq!(keys, ["TRDX"]);
    }

    #[test]
    fn enumeration_filters_to_the_intersection() {
        // testEnumerationFiltersTemperatureKeysToIntersection
        let table = temperature_keys(M4);
        let mut smc = FakeSmc::new(true).with_fpe2("ZZZZ", 0x00C8);
        for (key, _) in &table {
            smc = smc.with_fpe2(key, 0x00C8);
        }
        smc = smc.with_enumeration(&[table[0].0, "ZZZZ"]);
        let readings = read_temperatures(&smc, M4);
        assert_eq!(
            readings.iter().map(|r| r.key.as_str()).collect::<Vec<_>>(),
            [table[0].0]
        );
        assert!(readings.iter().all(|r| r.celsius > 0.0));
    }

    #[test]
    fn unavailable_enumeration_falls_back_to_the_candidate_table() {
        // testEnumerationUnavailableFallsBackToCandidateTable
        let mut smc = FakeSmc::new(true);
        for (key, _) in temperature_keys(M4) {
            smc = smc.with_fpe2(key, 0x00C8);
        }
        assert_eq!(smc.enumerate_keys(), None);
        assert_eq!(
            read_temperatures(&smc, M4).len(),
            temperature_keys(M4).len()
        );
    }

    #[test]
    fn enumerated_keys_outside_the_table_are_not_reported() {
        // testEnumeratedKeysOutsideTableAreNotReported
        let smc = FakeSmc::new(true)
            .with_fpe2("Te0Q", 0x3200)
            .with_enumeration(&["Te0Q"]);
        assert_eq!(read_temperatures(&smc, ChipGeneration::Unknown), []);
    }

    #[test]
    fn closed_connection_has_no_enumeration() {
        // testEnumerationUnavailableWhenConnectionClosed
        let smc = FakeSmc::closed().with_enumeration(&["TCMz"]);
        assert_eq!(smc.enumerate_keys(), None);
        assert_eq!(read_temperatures(&smc, ChipGeneration::Unknown), []);
    }

    #[test]
    fn m4_skips_a_deliberately_absent_key() {
        // testM4GenerationSkipsDeliberatelyAbsentKey: bytes are 16/32/48/64 °C at raw = value * 4
        let smc = FakeSmc::new(true)
            .with_fpe2("TCMz", 0x0040)
            .with_fpe2("Te05", 0x0080)
            .with_fpe2("Te0S", 0x00C0)
            .with_fpe2("Te09", 0x0100)
            .with_enumeration(&["TCMz", "Te05", "Te0S", "Te09"]);
        let keys: Vec<_> = read_temperatures(&smc, M4)
            .into_iter()
            .map(|r| r.key)
            .collect();
        assert_eq!(keys, ["TCMz", "Te05", "Te0S"]); // Te09 is not in the M4 row; Te0H/Te0L absent
    }

    #[test]
    fn m4_pro_like_fake_drops_the_implausible_rows() {
        let keys: Vec<_> = read_temperatures(&FakeSmc::m4_pro_like(), M4)
            .into_iter()
            .map(|r| r.key)
            .collect();
        assert_eq!(
            keys,
            ["TCMz", "TRDX", "TCMb", "TCHP", "Te04", "Te05", "Te0R"]
        );
    }

    // ---- sensor report notes (SensorService.swift) --------------------------

    #[test]
    fn closed_smc_report_says_so_and_stays_honest() {
        let report = read_sensors(&FakeSmc::closed(), &FakeHost::default());
        assert!(!report.smc_supported);
        assert_eq!(report.notes.len(), 1);
        assert!(report.notes[0].starts_with("SMC unavailable — detailed die temperatures"));
        assert_eq!((report.temperatures.len(), report.fans.len()), (0, 0));
    }

    #[test]
    fn open_smc_without_data_explains_each_gap() {
        let host = FakeHost {
            generation: ChipGeneration::Unknown,
            ..FakeHost::default()
        };
        let report = read_sensors(&FakeSmc::new(true), &host);
        assert!(report.smc_supported);
        assert_eq!(
            report.notes,
            [
                "SMC connected but index-based key enumeration is unavailable — temperatures come from \
                 the built-in unknown-generation candidate table without host key verification.",
                "SMC connected but no temperature sensors returned data. Your Mac may use keys not yet in the probe list.",
                "No fans detected (fanless Mac or SMC returned fan count 0).",
            ]
        );
    }

    #[test]
    fn full_report_has_no_notes_and_carries_the_thermal_label() {
        let host = FakeHost {
            thermal: "fair",
            ..FakeHost::default()
        };
        let report = read_sensors(&FakeSmc::m4_pro_like(), &host);
        assert!(report.notes.is_empty());
        assert_eq!(report.thermal_pressure, "fair");
        assert_eq!(report.fans.len(), 2);
        assert_eq!(
            report.fans[0],
            FanReading {
                index: 0,
                label: "Main Fan".into(),
                rpm: 2150,
                min_rpm: Some(1200),
                max_rpm: Some(7800),
            }
        );
    }

    // ---- fan mode ------------------------------------------------------------

    #[test]
    fn fan_mode_prefers_upper_md_and_falls_back_to_lower() {
        let smc = FakeSmc::new(true).with_ui8("F0Md", 1).with_ui8("F0md", 3);
        assert_eq!(read_fan_mode(&smc, 0), Some(1));
        let smc = FakeSmc::new(true).with_ui8("F0Md", 0).with_ui8("F0md", 3);
        assert_eq!(read_fan_mode(&smc, 0), Some(3));
        // S5, M4 Pro: F0Md reads 0, F0md is absent -> a read, `Some(0)` is not >0 -> lower key -> None.
        assert_eq!(
            read_fan_mode(&FakeSmc::new(true).with_ui8("F0Md", 0), 0),
            None
        );
        assert_eq!(read_fan_mode(&FakeSmc::new(true), 1), None);
        assert_eq!(
            read_fan_mode(&FakeSmc::closed().with_ui8("F0Md", 1), 0),
            None
        );
    }

    #[test]
    fn fan_rpm_helpers_read_the_named_keys() {
        let smc = FakeSmc::new(true)
            .with_flt("F1Mn", 1200.0)
            .with_flt("F1Mx", 8200.0)
            .with_flt("F1Tg", 3000.0);
        assert_eq!(read_fan_min_rpm(&smc, 1), Some(1200.0));
        assert_eq!(read_fan_max_rpm(&smc, 1), Some(8200.0));
        assert_eq!(read_fan_target_rpm(&smc, 1), Some(3000.0));
        assert_eq!(read_fan_min_rpm(&smc, 0), None);
    }

    // ---- system power: SystemPowerTests.swift --------------------------------

    fn flt_smc(keys: &[(&str, f32)]) -> FakeSmc {
        keys.iter()
            .fold(FakeSmc::new(true), |s, (k, v)| s.with_flt(k, *v))
    }

    fn power(keys: &[(&str, f32)]) -> Option<PowerReport> {
        read_system_power(&flt_smc(keys), || None)
    }

    #[test]
    fn nothing_readable_yields_none_not_zeros() {
        assert_eq!(read_system_power(&FakeSmc::closed(), || None), None); // ReadSystemPowerNilWhenConnectionClosed
        assert_eq!(power(&[]), None);
        assert_eq!(read_system_power(&FakeSmc::new(true), || Some(0)), None);
        assert_eq!(read_system_power(&FakeSmc::new(true), || None), None);
    }

    #[test]
    fn pstr_is_the_system_total_beside_the_adapter_rail() {
        let p = power(&[
            ("VD0R", 20.0),
            ("ID0R", 0.5),
            ("PDTR", 10.0),
            ("PSTR", 23.5),
        ])
        .unwrap();
        assert_eq!(
            (p.volts, p.amps, p.watts, p.adapter_watts, p.adapter_source),
            (
                Some(20.0),
                Some(0.5),
                Some(10.0),
                Some(10.0),
                Some(AdapterPowerSource::SmcPdtr)
            )
        );
        assert_eq!(
            (p.system_watts, p.system_source),
            (Some(23.5), Some(SystemPowerSource::SmcPstr))
        );
    }

    #[test]
    fn pstr_wins_over_battery_and_the_fallback_is_not_consulted() {
        let mut consulted = false;
        let p = read_system_power(&flt_smc(&[("PSTR", 12.0)]), || {
            consulted = true;
            Some(99_000)
        })
        .unwrap();
        assert_eq!(p.system_watts, Some(12.0));
        assert!(
            !consulted,
            "the battery must not be read when the SMC already has a total"
        );
    }

    #[test]
    fn system_watts_without_any_adapter_key() {
        let p = power(&[("PSTR", 8.0)]).unwrap();
        assert_eq!(
            (p.watts, p.adapter_watts, p.adapter_source),
            (None, None, None)
        );
    }

    #[test]
    fn battery_system_load_fills_a_missing_or_non_positive_pstr() {
        let p = read_system_power(
            &flt_smc(&[("VD0R", 20.0), ("ID0R", 0.0), ("PDTR", 0.0)]),
            || Some(19_233),
        )
        .unwrap();
        assert_eq!(
            (p.system_watts, p.system_source),
            (Some(19.233), Some(SystemPowerSource::BatterySystemLoad))
        );
        let p = read_system_power(&flt_smc(&[("PSTR", 0.0)]), || Some(5_500)).unwrap();
        assert_eq!(
            (p.system_watts, p.system_source),
            (Some(5.5), Some(SystemPowerSource::BatterySystemLoad))
        );
    }

    #[test]
    fn battery_system_load_works_with_a_closed_smc() {
        let p = read_system_power(&FakeSmc::closed(), || Some(7_000)).unwrap();
        assert_eq!(
            (p.system_watts, p.system_source, p.watts),
            (Some(7.0), Some(SystemPowerSource::BatterySystemLoad), None)
        );
    }

    #[test]
    fn pd0r_is_the_adapter_fallback() {
        let p = power(&[("PDTR", 0.0), ("PD0R", 41.5)]).unwrap();
        assert_eq!(
            (p.watts, p.adapter_source),
            (Some(41.5), Some(AdapterPowerSource::SmcPd0r))
        );
        let p = power(&[("PD0R", 17.0)]).unwrap();
        assert_eq!(
            (p.watts, p.adapter_source),
            (Some(17.0), Some(AdapterPowerSource::SmcPd0r))
        );
        let p = power(&[("PDTR", 9.0), ("PD0R", 41.5)]).unwrap();
        assert_eq!(
            (p.watts, p.adapter_source),
            (Some(9.0), Some(AdapterPowerSource::SmcPdtr))
        );
    }

    #[test]
    fn a_genuine_zero_pdtr_is_kept_when_pd0r_is_absent() {
        // On battery the adapter draws nothing; that is a real reading.
        let p = power(&[("PDTR", 0.0), ("PSTR", 6.0)]).unwrap();
        assert_eq!(
            (p.watts, p.adapter_source),
            (Some(0.0), Some(AdapterPowerSource::SmcPdtr))
        );
    }

    #[test]
    fn power_json_matches_the_swift_snapshot() {
        // testPowerJSONShapeSnapshot / testMissingKeysLeaveFieldsAbsentInJSON / testBatterySystemLoadSourceSerializesAsLabel
        let p = power(&[
            ("VD0R", 20.0),
            ("ID0R", 0.5),
            ("PDTR", 10.0),
            ("PSTR", 23.5),
        ])
        .unwrap();
        assert_eq!(
            serde_json::to_value(&p).unwrap(),
            json!({"volts":20.0,"amps":0.5,"watts":10.0,"adapter_watts":10.0,
                   "adapter_source":"smc_pdtr","system_watts":23.5,"system_source":"smc_pstr"})
        );
        let only_pd0r = serde_json::to_value(power(&[("PD0R", 17.0)]).unwrap()).unwrap();
        assert_eq!(
            only_pd0r,
            json!({"watts":17.0,"adapter_watts":17.0,"adapter_source":"smc_pd0r"})
        );
        let load = PowerReport {
            volts: None,
            amps: None,
            watts: None,
            adapter_watts: None,
            adapter_source: None,
            system_watts: Some(19.233),
            system_source: Some(SystemPowerSource::BatterySystemLoad),
        };
        assert_eq!(
            serde_json::to_value(load).unwrap(),
            json!({"system_watts":19.233,"system_source":"battery_system_load"})
        );
    }

    #[test]
    fn m4_pro_like_power_reads_the_laptop_rails() {
        let p = read_system_power(&FakeSmc::m4_pro_like(), || None).unwrap();
        // On battery: genuine zero adapter power, PSTR is the total.
        assert_eq!(
            (p.watts, p.adapter_source),
            (Some(0.0), Some(AdapterPowerSource::SmcPdtr))
        );
        assert_eq!(p.system_source, Some(SystemPowerSource::SmcPstr));
    }

    // ---- charge-limit key probe: ChargeLimitServiceTests.swift ---------------

    #[test]
    fn detects_chte_then_ch0b_then_nothing() {
        let chte = FakeSmc::new(true).with_raw("CHTE", b"ui32", &[0, 0, 0, 0]);
        assert_eq!(
            detect_charge_limit_key_family(&chte),
            Some(ChargeLimitKeyFamily::Chte)
        );
        let ch0b = FakeSmc::new(true).with_ui8("CH0B", 0);
        assert_eq!(
            detect_charge_limit_key_family(&ch0b),
            Some(ChargeLimitKeyFamily::Ch0b)
        );
        // CHTE that is not a ui32 does not count (readKeyUInt32); CH0B then decides.
        let wrong_type = FakeSmc::new(true).with_ui8("CHTE", 1).with_ui8("CH0B", 0);
        assert_eq!(
            detect_charge_limit_key_family(&wrong_type),
            Some(ChargeLimitKeyFamily::Ch0b)
        );
        // S5 on an M4 Pro under macOS 27.2: neither exists (CHIE is unknown to Cockpit).
        let none = FakeSmc::new(true).with_raw("CHIE", b"hex_", &[1]);
        assert_eq!(detect_charge_limit_key_family(&none), None);
        assert_eq!(detect_charge_limit_key_family(&FakeSmc::closed()), None);
    }

    #[test]
    fn inhibit_state_per_family() {
        // testReadInhibitStateCH0B (2 = inhibited) and CHTE (1 = inhibited)
        let ch0b = |v| FakeSmc::new(true).with_ui8("CH0B", v);
        assert_eq!(read_charge_inhibit_state(&ch0b(2)), Some(true));
        assert_eq!(read_charge_inhibit_state(&ch0b(0)), Some(false));
        let chte = |v: u32| FakeSmc::new(true).with_raw("CHTE", b"ui32", &v.to_be_bytes());
        assert_eq!(read_charge_inhibit_state(&chte(1)), Some(true));
        assert_eq!(read_charge_inhibit_state(&chte(0)), Some(false));
        assert_eq!(read_charge_inhibit_state(&FakeSmc::new(true)), None);
    }

    #[test]
    fn missing_charge_limit_key_is_honestly_unsupported() {
        // #420: a hardware limit (exit 4), not a missing privilege.
        let err = require_charge_limit_key(&FakeSmc::new(true)).unwrap_err();
        assert_eq!(
            err,
            Error::Unsupported(MISSING_CHARGE_LIMIT_KEY_DETAIL.into())
        );
        assert_eq!(err.exit_code(), 4);
        assert!(require_charge_limit_key(&FakeSmc::new(true).with_ui8("CH0B", 0)).is_ok());
        // An unreachable SMC keeps its own error.
        assert!(require_charge_limit_key(&FakeSmc::closed()).is_ok());
    }
}
