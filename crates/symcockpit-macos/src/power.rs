//! Live thermal state and keep-awake status. Read-only: no power assertion is
//! created or released here.

use std::time::SystemTime;

use objc2_foundation::{NSProcessInfo, NSProcessInfoThermalState};
use symcockpit_core::power::{KeepAwakeSession, KeepAwakeStatus, ThermalSource, ThermalState};

/// `ProcessInfo.thermalState`.
pub struct LiveThermal;

impl ThermalSource for LiveThermal {
    fn thermal_state(&self) -> ThermalState {
        match NSProcessInfo::processInfo().thermalState() {
            NSProcessInfoThermalState::Nominal => ThermalState::Nominal,
            NSProcessInfoThermalState::Fair => ThermalState::Fair,
            NSProcessInfoThermalState::Serious => ThermalState::Serious,
            NSProcessInfoThermalState::Critical => ThermalState::Critical,
            _ => ThermalState::Unknown,
        }
    }
}

/// The keep-awake session of this process. v0.12 keeps it in the process's own
/// coordinator, and a read-only status command never starts one, so it is
/// always the inactive session (no state file, no system-assertion probe).
pub struct LiveKeepAwakeStatus;

impl KeepAwakeStatus for LiveKeepAwakeStatus {
    fn status(&self) -> KeepAwakeSession {
        KeepAwakeSession::inactive(SystemTime::now())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_is_inactive_without_a_session() {
        let s = LiveKeepAwakeStatus.status();
        assert!(
            !s.active && !s.prevent_display_sleep && s.expires_at.is_none() && s.reason.is_empty()
        );
    }

    #[test]
    #[ignore = "reads the real thermal state"]
    fn live_thermal_state() {
        eprintln!("thermal_pressure: {}", LiveThermal.thermal_state().label());
    }
}
