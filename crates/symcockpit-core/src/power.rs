//! Power readings, thermal pressure and keep-awake status (`awake status`,
//! MCP `keep_awake_status`, plus inputs for `status` and `doctor`).
//!
//! Read-only: nothing here creates or releases a power assertion. Port of
//! `SensorService.thermalPressureLabel` and the status half of
//! `KeepAwakeCoordinator`; the system-power reading itself is `sensors::read_system_power`.

use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;
use serde_json::Value;
use symcockpit_contract::Error;

use crate::battery::{BatterySource, BatterySourceResult};

// ------------------------------------------------- system power fallback
// The logic and the `PowerReport` wire type live in `sensors` (one implementation).

/// The battery side of the system-power fallback: `SystemLoad` in milliwatts,
/// only when the registry read succeeded.
pub fn battery_system_load_milliwatts(source: &dyn BatterySource) -> Option<i64> {
    match source.read_properties() {
        BatterySourceResult::Success(props) => props.system_load_milliwatts,
        _ => None,
    }
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
    use std::time::Duration;

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
