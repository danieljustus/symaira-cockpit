//! Power readings, thermal pressure and keep-awake status (`awake status`,
//! MCP `keep_awake_status`, plus inputs for `status` and `doctor`).
//!
//! Read-only: nothing here creates or releases a power assertion. Port of
//! `PowerReport`/`readSystemPower` (#403), `SensorService.thermalPressureLabel`
//! and the status half of `KeepAwakeCoordinator`.

use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;
use serde_json::Value;
use symcockpit_contract::Error;

use crate::battery::{BatterySource, BatterySourceResult};

// ---------------------------------------------------------------- power draw

/// Which SMC key supplied the adapter (DC-in) wattage.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AdapterPowerSource {
    /// `PDTR`, the DC-in total power key.
    SmcPdtr,
    /// `PD0R`, the DC-in key desktops expose when `PDTR` reads 0.
    SmcPd0r,
}

/// Where the total system power came from.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SystemPowerSource {
    /// SMC `PSTR`, total system power.
    SmcPstr,
    /// `AppleSmartBattery` `PowerTelemetryData.SystemLoad` (laptops).
    BatterySystemLoad,
}

/// Live power readings. Adapter input (DC-in rail, ~0 on battery) and total
/// system power are different quantities and never conflated (#403). Every
/// field is optional; nothing readable means no report at all.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PowerReport {
    pub volts: Option<f64>,
    pub amps: Option<f64>,
    /// Adapter input in watts; serialised twice (`watts`, `adapter_watts`).
    pub watts: Option<f64>,
    pub adapter_source: Option<AdapterPowerSource>,
    pub system_watts: Option<f64>,
    pub system_source: Option<SystemPowerSource>,
}

impl Serialize for PowerReport {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        #[derive(Serialize)]
        struct Wire<'a> {
            #[serde(skip_serializing_if = "Option::is_none")]
            volts: &'a Option<f64>,
            #[serde(skip_serializing_if = "Option::is_none")]
            amps: &'a Option<f64>,
            #[serde(skip_serializing_if = "Option::is_none")]
            watts: &'a Option<f64>,
            #[serde(skip_serializing_if = "Option::is_none")]
            adapter_watts: &'a Option<f64>,
            #[serde(skip_serializing_if = "Option::is_none")]
            adapter_source: &'a Option<AdapterPowerSource>,
            #[serde(skip_serializing_if = "Option::is_none")]
            system_watts: &'a Option<f64>,
            #[serde(skip_serializing_if = "Option::is_none")]
            system_source: &'a Option<SystemPowerSource>,
        }
        Wire {
            volts: &self.volts,
            amps: &self.amps,
            watts: &self.watts,
            adapter_watts: &self.watts,
            adapter_source: &self.adapter_source,
            system_watts: &self.system_watts,
            system_source: &self.system_source,
        }
        .serialize(serializer)
    }
}

/// Port: the SMC power keys (`VD0R`, `ID0R`, `PDTR`, `PD0R`, `PSTR`). The SMC
/// reader belongs to the sensors area; the coordinator implements this on it.
pub trait PowerKeyReader {
    /// Whether the SMC connection is open.
    fn is_open(&self) -> bool;
    /// Decoded value of one key; `None` when absent or unreadable.
    fn read_key(&self, key: &str) -> Option<f64>;
}

/// `SMCService.readSystemPower`: adapter input from the SMC (direct key reads,
/// not V×A), total system power from `PSTR`, else the battery's `SystemLoad`
/// (milliwatts, from `system_load_fallback`, consulted only when `PSTR` gave
/// nothing). `None` when nothing is readable: absent, not zero.
pub fn read_system_power(
    smc: &dyn PowerKeyReader,
    system_load_fallback: impl FnOnce() -> Option<i64>,
) -> Option<PowerReport> {
    let mut report = PowerReport::default();
    if smc.is_open() {
        report.volts = smc.read_key("VD0R");
        report.amps = smc.read_key("ID0R");
        let pdtr = smc.read_key("PDTR");
        match pdtr {
            Some(w) if w != 0.0 => {
                report.watts = Some(w);
                report.adapter_source = Some(AdapterPowerSource::SmcPdtr);
            }
            _ => {
                if let Some(w) = smc.read_key("PD0R").filter(|w| w.is_finite() && *w > 0.0) {
                    report.watts = Some(w);
                    report.adapter_source = Some(AdapterPowerSource::SmcPd0r);
                } else if let Some(w) = pdtr {
                    // PDTR is readable and genuinely 0 (e.g. on battery).
                    report.watts = Some(w);
                    report.adapter_source = Some(AdapterPowerSource::SmcPdtr);
                }
            }
        }
        if let Some(w) = smc.read_key("PSTR").filter(|w| w.is_finite() && *w > 0.0) {
            report.system_watts = Some(w);
            report.system_source = Some(SystemPowerSource::SmcPstr);
        }
    }
    if report.system_watts.is_none()
        && let Some(mw) = system_load_fallback().filter(|mw| *mw > 0)
    {
        report.system_watts = Some(mw as f64 / 1000.0);
        report.system_source = Some(SystemPowerSource::BatterySystemLoad);
    }
    let any = report.volts.is_some()
        || report.amps.is_some()
        || report.watts.is_some()
        || report.system_watts.is_some();
    any.then_some(report)
}

/// The battery side of the system-power fallback: `SystemLoad` in milliwatts,
/// only when the registry read succeeded.
pub fn battery_system_load_milliwatts(source: &dyn BatterySource) -> Option<i64> {
    match source.read_properties() {
        BatterySourceResult::Success(props) => props.system_load_milliwatts,
        _ => None,
    }
}

/// `TuneController.powerDrawDetail`: the `doctor` text for `power.draw.read`
/// (available when `report` is `Some`).
pub fn power_draw_detail(report: Option<&PowerReport>) -> String {
    let Some(report) = report else {
        return "No power readings exposed on this Mac — neither total system power (SMC PSTR / \
                battery SystemLoad) nor adapter input (SMC VD0R/ID0R/PDTR/PD0R) is readable."
            .to_string();
    };
    let mut parts = Vec::new();
    parts.push(match report.system_source {
        Some(SystemPowerSource::SmcPstr) => {
            "total system power (system_watts) via SMC PSTR".to_string()
        }
        Some(SystemPowerSource::BatterySystemLoad) => {
            "total system power (system_watts) via battery PowerTelemetryData.SystemLoad"
                .to_string()
        }
        None => "total system power (system_watts) unavailable".to_string(),
    });
    if report.volts.is_some() || report.amps.is_some() || report.watts.is_some() {
        let key = if report.adapter_source == Some(AdapterPowerSource::SmcPd0r) {
            "PD0R"
        } else {
            "PDTR"
        };
        parts.push(format!(
            "adapter DC-in input only (volts/amps/watts, SMC VD0R/ID0R/{key}) — near 0 on battery, \
             not the Mac's consumption"
        ));
    } else {
        parts.push("adapter DC-in input (volts/amps/watts) unavailable".to_string());
    }
    format!("Live power: {}.", parts.join("; "))
}

// ----------------------------------------------------------- thermal pressure

/// `ProcessInfo.thermalState`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ThermalState {
    Nominal,
    Fair,
    Serious,
    Critical,
    Unknown,
}

impl ThermalState {
    /// The `thermal_pressure` string of the sensors report.
    pub fn label(self) -> &'static str {
        match self {
            ThermalState::Nominal => "nominal",
            ThermalState::Fair => "fair",
            ThermalState::Serious => "serious",
            ThermalState::Critical => "critical",
            ThermalState::Unknown => "unknown",
        }
    }
}

/// Port: the OS thermal state.
pub trait ThermalSource {
    fn thermal_state(&self) -> ThermalState;
}

// ----------------------------------------------------------------- keep-awake

/// Seconds between the Unix epoch and Foundation's reference date (2001-01-01).
const REFERENCE_DATE_UNIX_SECONDS: f64 = 978_307_200.0;

/// Seconds since the Foundation reference date, the number Swift's default
/// `Date` encoding writes (`started_at`).
pub fn reference_date_seconds(at: SystemTime) -> f64 {
    let unix = match at.duration_since(UNIX_EPOCH) {
        Ok(d) => d.as_secs_f64(),
        Err(e) => -e.duration().as_secs_f64(),
    };
    unix - REFERENCE_DATE_UNIX_SECONDS
}

/// `KeepAwakeSession`; dates are reference-date seconds, as in Swift's JSON.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct KeepAwakeSession {
    pub active: bool,
    pub prevent_display_sleep: bool,
    pub started_at: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<f64>,
    pub reason: String,
}

impl KeepAwakeSession {
    /// `KeepAwakeSession.inactive`; Swift stamps it with `Date()`.
    pub fn inactive(now: SystemTime) -> Self {
        KeepAwakeSession {
            active: false,
            prevent_display_sleep: false,
            started_at: reference_date_seconds(now),
            expires_at: None,
            reason: String::new(),
        }
    }
}

/// Port: the current keep-awake session. In v0.12 this is the coordinator of
/// the running process, so a fresh `symcockpit awake status` always reports
/// the inactive session (there is no state file and no system-assertion probe).
pub trait KeepAwakeStatus {
    fn status(&self) -> KeepAwakeSession;
}

/// `awake status` takes effect when `status` is the first argument; further
/// arguments are ignored (`AwakeOptions.parseOptions`).
pub fn is_awake_status_request(args: &[String]) -> bool {
    args.first().is_some_and(|a| a == "status")
}

/// CLI `awake status` and MCP `keep_awake_status`: both print this value.
pub fn awake_status_json(source: &dyn KeepAwakeStatus) -> Result<Value, Error> {
    serde_json::to_value(source.status())
        .map_err(|e| Error::Failed(format!("Failed to encode keep-awake status: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::collections::HashMap;
    use std::time::Duration;

    struct Smc {
        open: bool,
        keys: HashMap<&'static str, f64>,
    }
    impl PowerKeyReader for Smc {
        fn is_open(&self) -> bool {
            self.open
        }
        fn read_key(&self, key: &str) -> Option<f64> {
            self.keys.get(key).copied()
        }
    }
    fn smc(keys: &[(&'static str, f64)]) -> Smc {
        Smc {
            open: true,
            keys: keys.iter().copied().collect(),
        }
    }
    fn power(keys: &[(&'static str, f64)], fallback: Option<i64>) -> Option<PowerReport> {
        read_system_power(&smc(keys), || fallback)
    }

    // Vectors: SystemPowerTests.swift (#403).
    #[test]
    fn pstr_is_system_watts_separate_from_adapter() {
        let p = power(
            &[
                ("VD0R", 20.0),
                ("ID0R", 0.5),
                ("PDTR", 10.0),
                ("PSTR", 23.5),
            ],
            None,
        )
        .unwrap();
        assert_eq!(
            (p.system_watts, p.system_source),
            (Some(23.5), Some(SystemPowerSource::SmcPstr))
        );
        assert_eq!(
            (p.watts, p.adapter_source),
            (Some(10.0), Some(AdapterPowerSource::SmcPdtr))
        );
    }

    #[test]
    fn pstr_wins_and_the_battery_is_not_consulted() {
        let consulted = std::cell::Cell::new(false);
        let p = read_system_power(&smc(&[("PSTR", 3.0)]), || {
            consulted.set(true);
            Some(1)
        })
        .unwrap();
        assert_eq!(p.system_source, Some(SystemPowerSource::SmcPstr));
        assert!(!consulted.get());
        let p = power(&[("PSTR", 12.0)], Some(99_000)).unwrap();
        assert_eq!(p.system_watts, Some(12.0));
    }

    #[test]
    fn system_watts_without_adapter_keys() {
        let p = power(&[("PSTR", 8.0)], None).unwrap();
        assert_eq!((p.watts, p.adapter_source), (None, None));
    }

    #[test]
    fn missing_or_non_positive_pstr_falls_back_to_battery_system_load() {
        let p = power(
            &[("VD0R", 20.0), ("ID0R", 0.0), ("PDTR", 0.0)],
            Some(19_233),
        )
        .unwrap();
        assert_eq!(
            (p.system_watts, p.system_source),
            (Some(19.233), Some(SystemPowerSource::BatterySystemLoad))
        );
        let p = power(&[("PSTR", 0.0)], Some(5_500)).unwrap();
        assert_eq!(p.system_watts, Some(5.5));
        let closed = Smc {
            open: false,
            keys: HashMap::new(),
        };
        let p = read_system_power(&closed, || Some(7_000)).unwrap();
        assert_eq!((p.system_watts, p.watts), (Some(7.0), None));
    }

    #[test]
    fn pd0r_adapter_fallback() {
        let p = power(&[("PDTR", 0.0), ("PD0R", 41.5)], None).unwrap();
        assert_eq!(
            (p.watts, p.adapter_source),
            (Some(41.5), Some(AdapterPowerSource::SmcPd0r))
        );
        let p = power(&[("PD0R", 17.0)], None).unwrap();
        assert_eq!(p.adapter_source, Some(AdapterPowerSource::SmcPd0r));
        let p = power(&[("PDTR", 9.0), ("PD0R", 41.5)], None).unwrap();
        assert_eq!(
            (p.watts, p.adapter_source),
            (Some(9.0), Some(AdapterPowerSource::SmcPdtr))
        );
        // On battery the adapter draws nothing: a genuine zero is kept.
        let p = power(&[("PDTR", 0.0), ("PSTR", 6.0)], None).unwrap();
        assert_eq!(
            (p.watts, p.adapter_source),
            (Some(0.0), Some(AdapterPowerSource::SmcPdtr))
        );
    }

    #[test]
    fn nothing_readable_is_none_not_zeros() {
        assert!(power(&[], None).is_none());
        assert!(power(&[], Some(0)).is_none());
    }

    #[test]
    fn json_keys_match_swift() {
        let p = PowerReport {
            volts: Some(20.0),
            amps: Some(0.5),
            watts: Some(10.0),
            adapter_source: Some(AdapterPowerSource::SmcPdtr),
            system_watts: Some(23.5),
            system_source: Some(SystemPowerSource::SmcPstr),
        };
        assert_eq!(
            serde_json::to_value(&p).unwrap(),
            json!({"volts": 20.0, "amps": 0.5, "watts": 10.0, "adapter_watts": 10.0,
                   "adapter_source": "smc_pdtr", "system_watts": 23.5, "system_source": "smc_pstr"})
        );
        let only_system = PowerReport {
            system_watts: Some(19.233),
            system_source: Some(SystemPowerSource::BatterySystemLoad),
            ..Default::default()
        };
        assert_eq!(
            serde_json::to_value(&only_system).unwrap(),
            json!({"system_watts": 19.233, "system_source": "battery_system_load"})
        );
        let only_pd0r = power(&[("PD0R", 17.0)], None).unwrap();
        let v = serde_json::to_value(&only_pd0r).unwrap();
        assert_eq!(v["adapter_watts"], 17.0);
        assert!(v.get("system_watts").is_none() && v.get("volts").is_none());
    }

    #[test]
    fn capability_detail_text() {
        let full = PowerReport {
            volts: Some(20.0),
            amps: Some(0.5),
            watts: Some(10.0),
            adapter_source: Some(AdapterPowerSource::SmcPdtr),
            system_watts: Some(23.5),
            system_source: Some(SystemPowerSource::SmcPstr),
        };
        let d = power_draw_detail(Some(&full));
        for needle in [
            "total system power",
            "PSTR",
            "adapter DC-in input only",
            "not the Mac's consumption",
        ] {
            assert!(d.contains(needle), "{needle}: {d}");
        }
        let d = power_draw_detail(Some(&PowerReport {
            watts: Some(40.0),
            adapter_source: Some(AdapterPowerSource::SmcPd0r),
            system_watts: Some(19.2),
            system_source: Some(SystemPowerSource::BatterySystemLoad),
            ..Default::default()
        }));
        assert!(d.contains("PowerTelemetryData.SystemLoad") && d.contains("PD0R"));
        assert!(power_draw_detail(None).contains("No power readings"));
        let d = power_draw_detail(Some(&PowerReport {
            watts: Some(10.0),
            adapter_source: Some(AdapterPowerSource::SmcPdtr),
            ..Default::default()
        }));
        assert!(d.contains("total system power (system_watts) unavailable"));
    }

    #[test]
    fn battery_system_load_needs_a_successful_read() {
        use crate::battery::BatteryProperties;
        struct S(BatterySourceResult);
        impl BatterySource for S {
            fn read_properties(&self) -> BatterySourceResult {
                self.0.clone()
            }
        }
        let ok = S(BatterySourceResult::Success(BatteryProperties {
            system_load_milliwatts: Some(11_250),
            ..Default::default()
        }));
        assert_eq!(battery_system_load_milliwatts(&ok), Some(11_250));
        assert_eq!(
            battery_system_load_milliwatts(&S(BatterySourceResult::Unavailable)),
            None
        );
        assert_eq!(
            battery_system_load_milliwatts(&S(BatterySourceResult::ReadFailed)),
            None
        );
    }

    #[test]
    fn thermal_labels() {
        let labels: Vec<_> = [
            ThermalState::Nominal,
            ThermalState::Fair,
            ThermalState::Serious,
            ThermalState::Critical,
            ThermalState::Unknown,
        ]
        .map(ThermalState::label)
        .to_vec();
        assert_eq!(
            labels,
            ["nominal", "fair", "serious", "critical", "unknown"]
        );
    }

    #[test]
    fn inactive_session_json_has_the_four_swift_keys() {
        struct S;
        impl KeepAwakeStatus for S {
            fn status(&self) -> KeepAwakeSession {
                // 2026-11-20T00:00:00Z = 1_795_132_800 Unix = 816_825_600 since 2001.
                KeepAwakeSession::inactive(UNIX_EPOCH + Duration::from_secs(1_795_132_800))
            }
        }
        assert_eq!(
            awake_status_json(&S).unwrap(),
            json!({"active": false, "prevent_display_sleep": false, "reason": "", "started_at": 816_825_600.0})
        );
    }

    #[test]
    fn expiry_is_serialised_only_when_present() {
        let mut s = KeepAwakeSession::inactive(UNIX_EPOCH);
        assert_eq!(s.started_at, -978_307_200.0);
        assert!(
            serde_json::to_value(&s)
                .unwrap()
                .get("expires_at")
                .is_none()
        );
        s.expires_at = Some(60.0);
        assert_eq!(serde_json::to_value(&s).unwrap()["expires_at"], 60.0);
    }

    #[test]
    fn status_is_the_first_argument_only() {
        let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert!(is_awake_status_request(&args(&["status"])));
        assert!(is_awake_status_request(&args(&["status", "--display"])));
        assert!(!is_awake_status_request(&args(&["--display", "status"])));
        assert!(!is_awake_status_request(&args(&[])));
    }
}
