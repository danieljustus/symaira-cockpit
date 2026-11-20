//! `doctor` / MCP `get_capabilities` and `permissions`
//! (`TuneController.capabilities()` / `permissions()` in v0.12).
//!
//! Hardware facts come in through the [`HardwareFacts`] port; the areas that
//! own SMC, battery, display and power data implement it. Texts and ids are
//! the Swift strings byte for byte.

use serde_json::{Value, json};
use symcockpit_store::Config;

use crate::ai_usage;
use crate::sensors::{AdapterPowerSource, PowerReport, SystemPowerSource};

/// Why charge limiting cannot work on firmware without any charge-limit key
/// (#420). Shared with the write path, like in Swift.
pub const MISSING_CHARGE_LIMIT_KEY_DETAIL: &str = "this Mac's firmware has no charge-limit SMC key (CHTE, CH0B or CHLC), so `sudo` cannot help. Firmware shipped with macOS 27 removed these keys; use System Settings > Battery > Charge Limit instead.";

/// State of the root-owned `symcockpit` the GUI elevates (`PrivilegedExecutableStatus`).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PrivilegedExecutable {
    pub usable: bool,
    /// Raw state: `matching`, `stale`, `unchecked`, `unverifiable`, `untrusted`, `not_installed`.
    pub state: String,
    pub detail: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HostInfo {
    /// `ProcessInfo.operatingSystemVersionString`, e.g. `Version 27.2.1 (Build 26B131)`.
    pub macos_version: String,
    pub architecture: String,
}

/// Facts about this Mac that `doctor` and `permissions` report.
pub trait HardwareFacts {
    fn battery_present(&self) -> bool;
    fn edr_capable(&self) -> bool;
    /// Detailed sensors are readable (`sensors.smcAvailable`).
    fn smc_sensors_available(&self) -> bool;
    /// The AppleSMC connection is open (`smc.isAvailable`).
    fn smc_connected(&self) -> bool;
    fn running_as_root(&self) -> bool;
    /// A charge-limit key (CHTE, CH0B or CHLC) exists.
    fn charge_limit_key_present(&self) -> bool;
    fn privileged_executable(&self) -> PrivilegedExecutable;
    fn power_draw(&self) -> Option<PowerReport>;
    fn host(&self) -> HostInfo;
}

pub fn power_draw_detail(report: Option<&PowerReport>) -> String {
    let Some(report) = report else {
        return "No power readings exposed on this Mac — neither total system power (SMC PSTR / battery SystemLoad) nor adapter input (SMC VD0R/ID0R/PDTR/PD0R) is readable.".into();
    };
    let system = match report.system_source {
        Some(SystemPowerSource::SmcPstr) => "total system power (system_watts) via SMC PSTR",
        Some(SystemPowerSource::BatterySystemLoad) => {
            "total system power (system_watts) via battery PowerTelemetryData.SystemLoad"
        }
        None => "total system power (system_watts) unavailable",
    };
    let adapter_input = report.volts.is_some() || report.amps.is_some() || report.watts.is_some();
    let adapter = if adapter_input {
        let key = if report.adapter_source == Some(AdapterPowerSource::SmcPd0r) {
            "PD0R"
        } else {
            "PDTR"
        };
        format!(
            "adapter DC-in input only (volts/amps/watts, SMC VD0R/ID0R/{key}) — near 0 on battery, not the Mac's consumption"
        )
    } else {
        "adapter DC-in input (volts/amps/watts) unavailable".to_owned()
    };
    format!("Live power: {system}; {adapter}.")
}

fn capability(id: &str, available: bool, detail: &str) -> Value {
    json!({"id": id, "available": available, "tier": "core", "detail": detail})
}

/// `permissions` — the JSON object of `PermissionStatus`.
pub fn permissions_json(hw: &dyn HardwareFacts, config: &Config, history_writable: bool) -> Value {
    let smc_writable = hw.smc_connected() && hw.running_as_root();
    let first = if smc_writable {
        "SMC write access available."
    } else if hw.smc_connected() {
        "SMC connected but this process is not root, so writes are rejected. The CLI needs `sudo`; the cockpit app prompts for your administrator password on demand instead."
    } else {
        "SMC unreachable: the AppleSMC driver answered the open probe with no key found. This is not a privilege problem and `sudo` cannot fix it — it means a VM, or an SMC generation this build does not speak. Fan and charge-limit control are unavailable; thermal pressure still reports normally."
    };
    let mode = if config.is_mcp_read_only() {
        "MCP server mode is read-only (write tools hidden from tools/list)."
    } else {
        "MCP server mode is full (all write tools available)."
    };
    json!({
        "privileged_helper_installed": smc_writable,
        "history_writable": history_writable,
        "mcp_mode": config.mcp_mode,
        "notes": [first, mode],
    })
}

/// `doctor` / `get_capabilities` — the JSON object of `CapabilityReport`.
pub fn capabilities_json(
    hw: &dyn HardwareFacts,
    config: &Config,
    history_writable: bool,
    version: &str,
) -> Value {
    let battery_present = hw.battery_present();
    let edr = hw.edr_capable();
    let smc_available = hw.smc_sensors_available();
    let smc_writable = hw.smc_connected() && hw.running_as_root();
    let charge_limit_key_missing = smc_available && !hw.charge_limit_key_present();
    let privileged = hw.privileged_executable();
    let power = hw.power_draw();

    let smc_detail = if smc_available {
        "Detailed die temps & fan RPM via AppleSMC IOKit (unprivileged)."
    } else {
        "SMC unreachable — detailed sensors not accessible. Reads are unprivileged, so this is a platform gap (VM, or an unsupported SMC generation), not something running as root would change."
    };
    let fan_detail = if smc_writable {
        "Fan speed control via SMC."
    } else if smc_available {
        "Fan speed control via SMC. Requires root — the CLI needs `sudo`; the cockpit app prompts for your administrator password on demand."
    } else {
        "SMC unreachable — not a privilege problem, and `sudo` will not help. Either this is a VM, or the host's SMC generation is not supported by this build."
    };
    // Firmware without a charge-limit key is a hardware limit, not a missing
    // privilege (#420): that check comes first.
    let charge_detail = if charge_limit_key_missing {
        format!("Battery charge limiting unsupported: {MISSING_CHARGE_LIMIT_KEY_DETAIL}")
    } else if smc_writable {
        "Battery charge limiting via SMC.".into()
    } else if smc_available {
        "Battery charge limiting via SMC. Requires root (run the CLI with `sudo`).".into()
    } else {
        "SMC unavailable — charge limiting not possible.".into()
    };
    let ok = |b: bool, yes: &str, no: &str| if b { yes.to_owned() } else { no.to_owned() };

    let capabilities = vec![
        capability(
            "sensors.thermalPressure",
            true,
            "Coarse thermal pressure from ProcessInfo (nominal…critical).",
        ),
        capability("sensors.smc", smc_available, smc_detail),
        capability(
            "battery.read",
            battery_present,
            &ok(
                battery_present,
                "AppleSmartBattery health readout.",
                "No battery present.",
            ),
        ),
        capability(
            "display.edr.read",
            edr,
            &ok(
                edr,
                "At least one display reports EDR headroom.",
                "No EDR-capable display detected.",
            ),
        ),
        capability(
            "display.brightness.extended.set",
            edr,
            &ok(
                edr,
                "Extended brightness via a 1×1 EDR trigger layer plus a gamma boost, clamped to 1.0–1.6 and to the headroom the display grants.",
                "No EDR-capable display detected — extended brightness unavailable.",
            ),
        ),
        capability(
            "display.dim.set",
            true,
            "Sub-minimum software dim overlay via transparent NSWindow.",
        ),
        capability(
            "display.brightness.set",
            true,
            "Built-in display brightness get/set via DisplayServices/IOKit.",
        ),
        capability(
            "display.warmth.set",
            true,
            "Color temperature warmth as a gamma-LUT shift on the display's own calibration curve, composed with any brightness boost.",
        ),
        capability(
            "processes.read",
            true,
            "Per-process CPU and memory usage via libproc. Processes owned by other users (root) are not readable without elevation.",
        ),
        capability(
            "power.keepAwake",
            true,
            "Prevent idle sleep via IOKit power assertion.",
        ),
        capability("fan.control", smc_writable, fan_detail),
        capability(
            "battery.chargeLimit",
            smc_writable && !charge_limit_key_missing,
            &charge_detail,
        ),
        capability(
            "fan.privilegedExecutable",
            privileged.usable,
            &format!("[{}] {}", privileged.state, privileged.detail),
        ),
        capability(
            "power.draw.read",
            power.is_some(),
            &power_draw_detail(power.as_ref()),
        ),
    ];

    let mut recommendations: Vec<String> = Vec::new();
    if matches!(privileged.state.as_str(), "stale" | "unverifiable") {
        recommendations.push(privileged.detail.clone());
    }
    if !edr {
        recommendations.push(
            "No EDR-capable display detected; extended brightness will be unavailable here.".into(),
        );
    }
    if !battery_present {
        recommendations
            .push("No battery detected; battery features are not applicable on this Mac.".into());
    }
    if recommendations.is_empty() {
        recommendations.push(
            "Core features are ready. Run `symcockpit serve` to expose them over MCP.".into(),
        );
    }

    let host = hw.host();
    json!({
        "tool": "symcockpit",
        "version": version,
        "macos_version": host.macos_version,
        "architecture": host.architecture,
        "capabilities": capabilities,
        "permissions": permissions_json(hw, config, history_writable),
        "recommendations": recommendations,
        "credential_sources": ai_usage::credential_sources(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fake {
        battery: bool,
        edr: bool,
        smc_sensors: bool,
        smc_connected: bool,
        root: bool,
        charge_key: bool,
        privileged: PrivilegedExecutable,
        power: Option<PowerReport>,
    }

    impl Default for Fake {
        fn default() -> Self {
            Fake {
                battery: true,
                edr: true,
                smc_sensors: true,
                smc_connected: true,
                root: false,
                charge_key: true,
                privileged: PrivilegedExecutable {
                    usable: true,
                    state: "matching".into(),
                    detail: "ok".into(),
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

    impl HardwareFacts for Fake {
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
                macos_version: "Version 27.0 (Build X)".into(),
                architecture: "arm64".into(),
            }
        }
    }

    fn cap<'a>(report: &'a Value, id: &str) -> &'a Value {
        report["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["id"] == id)
            .unwrap()
    }

    fn report(f: &Fake) -> Value {
        capabilities_json(f, &Config::default(), true, "0.12.2")
    }

    #[test]
    fn capability_ids_and_order_match_v012() {
        let r = report(&Fake::default());
        let ids: Vec<_> = r["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["id"].as_str().unwrap())
            .collect();
        assert_eq!(
            ids,
            [
                "sensors.thermalPressure",
                "sensors.smc",
                "battery.read",
                "display.edr.read",
                "display.brightness.extended.set",
                "display.dim.set",
                "display.brightness.set",
                "display.warmth.set",
                "processes.read",
                "power.keepAwake",
                "fan.control",
                "battery.chargeLimit",
                "fan.privilegedExecutable",
                "power.draw.read"
            ]
        );
        assert!(
            r["capabilities"]
                .as_array()
                .unwrap()
                .iter()
                .all(|c| c["tier"] == "core")
        );
        assert_eq!(
            (r["tool"].as_str(), r["version"].as_str()),
            (Some("symcockpit"), Some("0.12.2"))
        );
        assert_eq!(
            r["recommendations"],
            json!(["Core features are ready. Run `symcockpit serve` to expose them over MCP."])
        );
    }

    #[test]
    fn charge_limit_follows_issue_420_logic() {
        // Key missing on firmware with a reachable SMC: hardware limit, root cannot help.
        let missing = report(&Fake {
            charge_key: false,
            root: true,
            ..Fake::default()
        });
        let c = cap(&missing, "battery.chargeLimit");
        assert_eq!(c["available"], false);
        assert!(c["detail"].as_str().unwrap().starts_with(
            "Battery charge limiting unsupported: this Mac's firmware has no charge-limit SMC key"
        ));
        // Key present, not root: needs sudo.
        let not_root = report(&Fake::default());
        assert_eq!(cap(&not_root, "battery.chargeLimit")["available"], false);
        assert_eq!(
            cap(&not_root, "battery.chargeLimit")["detail"],
            "Battery charge limiting via SMC. Requires root (run the CLI with `sudo`)."
        );
        // Key present and root: available.
        let root = report(&Fake {
            root: true,
            ..Fake::default()
        });
        assert_eq!(cap(&root, "battery.chargeLimit")["available"], true);
        assert_eq!(
            cap(&root, "battery.chargeLimit")["detail"],
            "Battery charge limiting via SMC."
        );
        // No SMC at all: the key probe is moot.
        let no_smc = report(&Fake {
            smc_sensors: false,
            smc_connected: false,
            charge_key: false,
            ..Fake::default()
        });
        assert_eq!(
            cap(&no_smc, "battery.chargeLimit")["detail"],
            "SMC unavailable — charge limiting not possible."
        );
        assert_eq!(cap(&no_smc, "fan.control")["available"], false);
        assert_eq!(cap(&no_smc, "sensors.smc")["available"], false);
    }

    #[test]
    fn recommendations_follow_the_swift_order() {
        let r = report(&Fake {
            battery: false,
            edr: false,
            privileged: PrivilegedExecutable {
                usable: false,
                state: "stale".into(),
                detail: "old copy".into(),
            },
            ..Fake::default()
        });
        assert_eq!(
            r["recommendations"],
            json!([
                "old copy",
                "No EDR-capable display detected; extended brightness will be unavailable here.",
                "No battery detected; battery features are not applicable on this Mac."
            ])
        );
        assert_eq!(
            cap(&r, "fan.privilegedExecutable")["detail"],
            "[stale] old copy"
        );
        assert_eq!(cap(&r, "battery.read")["detail"], "No battery present.");
        // Only stale and unverifiable are recommendations.
        let untrusted = report(&Fake {
            privileged: PrivilegedExecutable {
                usable: false,
                state: "untrusted".into(),
                detail: "x".into(),
            },
            ..Fake::default()
        });
        assert_eq!(untrusted["recommendations"].as_array().unwrap().len(), 1);
        assert!(
            untrusted["recommendations"][0]
                .as_str()
                .unwrap()
                .starts_with("Core features")
        );
    }

    #[test]
    fn power_draw_text_covers_sources_and_absence() {
        let both = PowerReport {
            system_source: Some(SystemPowerSource::SmcPstr),
            watts: Some(10.0),
            adapter_source: Some(AdapterPowerSource::SmcPdtr),
            ..Default::default()
        };
        assert_eq!(
            power_draw_detail(Some(&both)),
            "Live power: total system power (system_watts) via SMC PSTR; adapter DC-in input only (volts/amps/watts, SMC VD0R/ID0R/PDTR) — near 0 on battery, not the Mac's consumption."
        );
        let load = PowerReport {
            system_source: Some(SystemPowerSource::BatterySystemLoad),
            ..Default::default()
        };
        assert_eq!(
            power_draw_detail(Some(&load)),
            "Live power: total system power (system_watts) via battery PowerTelemetryData.SystemLoad; adapter DC-in input (volts/amps/watts) unavailable."
        );
        let pd0r = PowerReport {
            system_source: None,
            watts: Some(10.0),
            adapter_source: Some(AdapterPowerSource::SmcPd0r),
            ..Default::default()
        };
        assert!(power_draw_detail(Some(&pd0r)).contains("system_watts) unavailable; adapter DC-in input only (volts/amps/watts, SMC VD0R/ID0R/PD0R)"));
        assert!(power_draw_detail(None).starts_with("No power readings exposed on this Mac"));
        let none = report(&Fake {
            power: None,
            ..Fake::default()
        });
        assert_eq!(cap(&none, "power.draw.read")["available"], false);
    }

    #[test]
    fn permissions_notes_cover_the_three_smc_states_and_both_mcp_modes() {
        let json_of = |f: &Fake, mode: &str| {
            permissions_json(
                f,
                &Config {
                    mcp_mode: mode.into(),
                    ..Config::default()
                },
                false,
            )
        };
        let root = json_of(
            &Fake {
                root: true,
                ..Fake::default()
            },
            "full",
        );
        assert_eq!(root["privileged_helper_installed"], true);
        assert_eq!(root["notes"][0], "SMC write access available.");
        assert_eq!(
            root["notes"][1],
            "MCP server mode is full (all write tools available)."
        );
        assert_eq!(
            (
                root["history_writable"].as_bool(),
                root["mcp_mode"].as_str()
            ),
            (Some(false), Some("full"))
        );
        let user = json_of(&Fake::default(), "read-only");
        assert_eq!(user["privileged_helper_installed"], false);
        assert!(
            user["notes"][0]
                .as_str()
                .unwrap()
                .starts_with("SMC connected but this process is not root")
        );
        assert_eq!(
            user["notes"][1],
            "MCP server mode is read-only (write tools hidden from tools/list)."
        );
        let none = json_of(
            &Fake {
                smc_connected: false,
                ..Fake::default()
            },
            "full",
        );
        assert!(
            none["notes"][0]
                .as_str()
                .unwrap()
                .starts_with("SMC unreachable: the AppleSMC driver")
        );
        // The report embeds the same permissions object.
        assert_eq!(report(&Fake::default())["permissions"]["mcp_mode"], "full");
    }

    #[test]
    fn credential_sources_list_every_catalog_provider_as_none() {
        let r = report(&Fake::default());
        let sources = r["credential_sources"].as_array().unwrap();
        assert_eq!(sources.len(), 14);
        assert_eq!(sources[0], json!({"provider": "claude", "source": "none"}));
        assert!(sources.iter().all(|s| s["source"] == "none"));
    }
}
