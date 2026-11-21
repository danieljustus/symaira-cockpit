//! Battery charge limit (port of `ChargeLimitService`, `ChargeLimitState` and
//! the charge parts of `TuneController`), with the mechanism chosen by what
//! the Mac *has*, not by its macOS version (K11, spike S8):
//!
//! 1. an SMC charge-limit key is present (`CHTE`, else `CH0B`): the SMC path
//!    of v0.12 (root, inhibit while at or above the target);
//! 2. otherwise `PowerUISmartChargeClient` reports the macOS charge limit as
//!    supported: that (80..=100 %, no root expected);
//! 3. otherwise `unsupported`.
//!
//! Every set reads back (Q01): a write that returned but left another state
//! is `unconfirmed`, never reported as applied.
//!
//! **Not proven on hardware:** whether the PowerUI *setters* work without root
//! (S8's write test is still pending). That path is implemented against the
//! [`MacChargeLimit`] port and tested with fakes only.

use symcockpit_contract::{Error, Outcome};
use symcockpit_store::Config;

use crate::battery::{BatterySource, BatterySourceResult};
use crate::fan::FanEnv;
use crate::restore::RestoreTracker;
use crate::sensors::{
    ChargeLimitKeyFamily, MISSING_CHARGE_LIMIT_KEY_DETAIL, detect_charge_limit_key_family,
    read_charge_inhibit_state,
};
use crate::smc_write::write_value;

/// The macOS charge limit offers 80..=100 %; below 80 needs an unsupported
/// intervention in `PowerUIAgent`'s private settings, so it is not offered.
pub const MACOS_LIMIT_MIN: i64 = 80;

/// `PowerUISmartChargeClient` (private API), as a port. Implemented by
/// `symcockpit-macos` over the Objective-C runtime, by a fake in the testkit.
pub trait MacChargeLimit {
    /// `isMCLSupported`; also `false` when the framework, the class or an
    /// expected selector encoding is missing (fail closed).
    fn is_supported(&self) -> bool;
    /// `isMCLCurrentlyEnabled:` (an NSUInteger, not a BOOL).
    fn is_enabled(&self) -> Option<bool>;
    /// `getMCLLimitWithError:` (a uint8).
    fn limit(&self) -> Option<u8>;
    fn enable(&self) -> Result<(), String>;
    fn disable(&self) -> Result<(), String>;
    fn set_limit(&self, percent: u8) -> Result<(), String>;
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Mechanism {
    Smc(ChargeLimitKeyFamily),
    MacOs,
    Unsupported(String),
}

impl Mechanism {
    pub fn name(&self) -> &'static str {
        match self {
            Self::Smc(_) => "smc",
            Self::MacOs => "macos",
            Self::Unsupported(_) => "unsupported",
        }
    }
}

/// Choose by presence: SMC key, else the macOS limit, else unsupported.
pub fn select(env: &FanEnv, mac: Option<&dyn MacChargeLimit>) -> Mechanism {
    if env.smc.is_open()
        && let Some(family) = detect_charge_limit_key_family(env.smc)
    {
        return Mechanism::Smc(family);
    }
    if mac.is_some_and(|m| m.is_supported()) {
        return Mechanism::MacOs;
    }
    if env.smc.is_open() {
        Mechanism::Unsupported(MISSING_CHARGE_LIMIT_KEY_DETAIL.into())
    } else {
        Mechanism::Unsupported(
            "the SMC is not reachable and the macOS charge limit is not available".into(),
        )
    }
}

/// What a set or clear ended in. `Confirmed` only after a matching read-back.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ChargeResult {
    pub outcome: Outcome,
    pub detail: Option<String>,
}

impl ChargeResult {
    fn confirmed() -> Self {
        Self {
            outcome: Outcome::Confirmed,
            detail: None,
        }
    }

    fn unconfirmed(detail: impl Into<String>) -> Self {
        Self {
            outcome: Outcome::Unconfirmed,
            detail: Some(detail.into()),
        }
    }

    /// The CLI/MCP error for anything but `Confirmed`.
    pub fn into_result(self) -> Result<(), Error> {
        match self.outcome {
            Outcome::Confirmed => Ok(()),
            Outcome::Unsupported => Err(Error::Unsupported(self.detail.unwrap_or_default())),
            _ => Err(Error::Failed(
                self.detail
                    .unwrap_or_else(|| "charge limit not applied".into()),
            )),
        }
    }
}

/// Swift's `localizedDescription` of a payload-less enum case that is not a
/// `LocalizedError`, as `symcockpit` prints it (`handleNonTuneError`).
fn swift_error_line(type_name: &str, code: u32) -> Error {
    let text =
        format!("The operation couldn’t be completed. (SymCockpitCore.{type_name} error {code}.)");
    Error::Failed(
        serde_json::json!({"error": type_name, "localized": text, "message": text}).to_string(),
    )
}

/// `ChargeLimitError.inhibitWriteFailed` / `.allowWriteFailed`, as printed.
fn inhibit_write_failed() -> Error {
    swift_error_line("ChargeLimitError", 2)
}

fn allow_write_failed() -> Error {
    swift_error_line("ChargeLimitError", 3)
}

/// Refuse to inhibit charging unless the Mac is on AC power (battery-powered
/// inhibiting can cause an unexpected shutdown). Without a battery, or when
/// the state is unknown, it passes.
pub fn require_ac_power(battery: &dyn BatterySource) -> Result<(), Error> {
    if let BatterySourceResult::Success(p) = battery.read_properties()
        && p.external_connected == Some(false)
    {
        return Err(Error::Permission(
            "charge limit requires AC power and SMC write access".into(),
        ));
    }
    Ok(())
}

pub struct ChargeEnv<'a> {
    pub fan: &'a FanEnv<'a>,
    pub mac: Option<&'a dyn MacChargeLimit>,
    pub battery: &'a dyn BatterySource,
    pub config: &'a Config,
}

/// Inhibit charging so the battery stays at or below `percent` (clamped to the
/// configured range). The SMC path needs AC power, saves the restore record
/// before its first write and reads the inhibit state back.
pub fn set(
    env: &ChargeEnv,
    tracker: &mut RestoreTracker,
    percent: i64,
) -> Result<ChargeResult, Error> {
    let clamped = percent
        .max(env.config.charge_limit_min)
        .min(env.config.charge_limit_max);
    match select(env.fan, env.mac) {
        Mechanism::Unsupported(detail) => Err(Error::Unsupported(detail)),
        Mechanism::Smc(family) => {
            require_ac_power(env.battery)?;
            tracker.save_charge_original(env.fan);
            let w = |key: &str, value: f64, t: &[u8; 4]| write_value(env.fan.writer, key, value, t);
            match family {
                ChargeLimitKeyFamily::Chte => {
                    if !w("CHTE", 1.0, b"ui32") {
                        return Err(inhibit_write_failed());
                    }
                }
                ChargeLimitKeyFamily::Ch0b => {
                    if !w("CH0B", 2.0, b"ui8 ") {
                        return Err(inhibit_write_failed());
                    }
                    // Some firmwares need CH0C as a redundant pair.
                    w("CH0C", 2.0, b"ui8 ");
                }
            }
            Ok(match read_charge_inhibit_state(env.fan.smc) {
                Some(true) => ChargeResult::confirmed(),
                other => ChargeResult::unconfirmed(format!(
                    "charging was asked to stop at {clamped}%, but the SMC reads back inhibit = {other:?}"
                )),
            })
        }
        Mechanism::MacOs => {
            if clamped < MACOS_LIMIT_MIN {
                return Ok(ChargeResult {
                    outcome: Outcome::Unsupported,
                    detail: Some(format!(
                        "the macOS charge limit offers {MACOS_LIMIT_MIN}-100%; {clamped}% is below that"
                    )),
                });
            }
            let mac = env
                .mac
                .ok_or_else(|| Error::Unsupported("no macOS charge limit".into()))?;
            mac.enable().map_err(Error::Failed)?;
            mac.set_limit(clamped as u8).map_err(Error::Failed)?;
            Ok(match (mac.is_enabled(), mac.limit()) {
                (Some(true), Some(l)) if i64::from(l) == clamped => ChargeResult::confirmed(),
                (enabled, limit) => ChargeResult::unconfirmed(format!(
                    "the macOS charge limit was set to {clamped}%, but reads back enabled = {enabled:?}, limit = {limit:?}"
                )),
            })
        }
    }
}

/// Re-enable charging by clearing the inhibit (or switching the macOS limit
/// off), reading the state back.
pub fn clear(env: &ChargeEnv) -> Result<ChargeResult, Error> {
    match select(env.fan, env.mac) {
        Mechanism::Unsupported(detail) => Err(Error::Unsupported(detail)),
        Mechanism::Smc(family) => {
            let w = |key: &str, value: f64, t: &[u8; 4]| write_value(env.fan.writer, key, value, t);
            // v0.12 wrote `CHTE` first and failed when that was rejected, which
            // is wrong on a `CH0B` Mac: write the keys of the detected family.
            let accepted = match family {
                ChargeLimitKeyFamily::Chte => w("CHTE", 0.0, b"ui32"),
                ChargeLimitKeyFamily::Ch0b => {
                    let ok = w("CH0B", 0.0, b"ui8 ");
                    w("CH0C", 0.0, b"ui8 ");
                    ok
                }
            };
            if !accepted {
                return Err(allow_write_failed());
            }
            Ok(match read_charge_inhibit_state(env.fan.smc) {
                Some(false) => ChargeResult::confirmed(),
                other => ChargeResult::unconfirmed(format!(
                    "charging was asked to resume, but the SMC reads back inhibit = {other:?}"
                )),
            })
        }
        Mechanism::MacOs => {
            let mac = env
                .mac
                .ok_or_else(|| Error::Unsupported("no macOS charge limit".into()))?;
            mac.disable().map_err(Error::Failed)?;
            Ok(match mac.is_enabled() {
                Some(false) => ChargeResult::confirmed(),
                other => ChargeResult::unconfirmed(format!(
                    "the macOS charge limit was switched off, but reads back enabled = {other:?}"
                )),
            })
        }
    }
}

/// What the band asks for at a given charge: inhibit at or above the target, release only
/// once the battery is `hysteresis` percent below it while inhibited, otherwise keep the state.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BandStep {
    Inhibit,
    Release,
    Keep,
}

pub fn band_step(inhibited: bool, percent: i64, target: i64, hysteresis: i64) -> BandStep {
    if percent >= target {
        // Lapsed on wake (or never re-applied): re-assert.
        if inhibited {
            BandStep::Keep
        } else {
            BandStep::Inhibit
        }
    } else if percent <= target - hysteresis && inhibited {
        BandStep::Release
    } else {
        BandStep::Keep
    }
}

/// Hysteresis control for a long-lived process (SMC path): inhibit at or above
/// the target, re-allow only once the battery has dropped `hysteresis` percent
/// below it, keep the current state inside the band (`reconcileChargeLimit`).
/// Returns whether it wrote.
pub fn reconcile(env: &ChargeEnv, target: i64, current_percent: Option<i64>) -> bool {
    let Mechanism::Smc(family) = select(env.fan, env.mac) else {
        return false;
    };
    let (Some(percent), true) = (current_percent, env.fan.smc.is_open()) else {
        return false;
    };
    let inhibited = read_charge_inhibit_state(env.fan.smc).unwrap_or(false);
    let w = |key: &str, value: f64, t: &[u8; 4]| write_value(env.fan.writer, key, value, t);
    let (on, off): (f64, f64) = match family {
        ChargeLimitKeyFamily::Chte => (1.0, 0.0),
        ChargeLimitKeyFamily::Ch0b => (2.0, 0.0),
    };
    let write_state = |value: f64| match family {
        ChargeLimitKeyFamily::Chte => w("CHTE", value, b"ui32"),
        ChargeLimitKeyFamily::Ch0b => {
            let ok = w("CH0B", value, b"ui8 ");
            w("CH0C", value, b"ui8 ");
            ok
        }
    };
    match band_step(
        inhibited,
        percent,
        target,
        env.config.charge_limit_hysteresis_percent,
    ) {
        BandStep::Inhibit => write_state(on),
        BandStep::Release => write_state(off),
        BandStep::Keep => false,
    }
}
