//! A fake Mac for `doctor` and `permissions`: every fact is a plain field.

use symcockpit_core::sensors::{AdapterPowerSource, PowerReport, SystemPowerSource};
use symcockpit_core::system::{HardwareFacts, HostInfo, PrivilegedExecutable};

#[derive(Clone, Debug)]
pub struct FakeHardware {
    pub battery: bool,
    pub edr: bool,
    pub smc_sensors: bool,
    pub smc_connected: bool,
    pub root: bool,
    pub charge_key: bool,
    pub privileged: PrivilegedExecutable,
    pub power: Option<PowerReport>,
}

impl Default for FakeHardware {
    /// A laptop with everything present, not running as root.
    fn default() -> Self {
        Self {
            battery: true,
            edr: true,
            smc_sensors: true,
            smc_connected: true,
            root: false,
            charge_key: true,
            privileged: PrivilegedExecutable {
                usable: true,
                state: "matching".into(),
                detail: "root-owned copy matches".into(),
            },
            power: Some(PowerReport {
                system_source: Some(SystemPowerSource::SmcPstr),
                watts: Some(10.0),
                adapter_source: Some(AdapterPowerSource::SmcPdtr),
                ..Default::default()
            }),
        }
    }
}

impl HardwareFacts for FakeHardware {
    fn battery_present(&self) -> bool {
        self.battery
    }
    fn edr_capable(&self) -> bool {
        self.edr
    }
    fn smc_sensors_available(&self) -> bool {
        self.smc_sensors
    }
    fn smc_connected(&self) -> bool {
        self.smc_connected
    }
    fn running_as_root(&self) -> bool {
        self.root
    }
    fn charge_limit_key_present(&self) -> bool {
        self.charge_key
    }
    fn privileged_executable(&self) -> PrivilegedExecutable {
        self.privileged.clone()
    }
    fn power_draw(&self) -> Option<PowerReport> {
        self.power.clone()
    }
    fn host(&self) -> HostInfo {
        HostInfo {
            macos_version: "Version 0.0 (Build FAKE)".into(),
            architecture: "arm64".into(),
        }
    }
}
