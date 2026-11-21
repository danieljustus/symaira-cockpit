//! Fan control: the write policy, the profile curves and the service that
//! drives the SMC (ports of `SMCWritePolicy`, `FanProfile`/`FanCurve`,
//! `FanCoolTarget` and `FanControlService`). arm64 only (D16).
//!
//! Safety rules carried over unchanged (tuning/AGENTS.md):
//! - every fraction is clamped and floored (`FAN_SPEED_FLOOR`), every target
//!   RPM is floored at the firmware minimum;
//! - the thermal gate refuses only writes that would *slow* the fans on a hot
//!   Mac; it never refuses to speed them up;
//! - the governed profiles follow temperature, they never pin a constant speed;
//! - nothing here can switch off the firmware's own thermal protection.

use symcockpit_contract::Error;
use symcockpit_store::Config;

use crate::clock::Monotonic;
use crate::sensors::{
    FanProfile, FanSelection, SensorHost, SensorReport, SmcPort, average_cluster_temperature,
    read_fan_max_rpm, read_fan_min_rpm, read_fan_mode, read_fan_target_rpm, read_key_uint,
    read_sensors,
};
use crate::smc_write::{SmcWriter, write_value};

/// Soft floor for manual fan requests: even a request for 0.0 is floored here.
pub const FAN_SPEED_FLOOR: f64 = 0.15;
/// At or above this die temperature a write that would slow the fans is refused.
pub const THERMAL_OVERRIDE_CELSIUS: f64 = 90.0;
/// `F{n}Md` for firmware control on Apple Silicon (read back at rest on an
/// M4 Pro): 0 is the firmware's, 1 is forced.
pub const APPLE_SILICON_AUTO_MODE: u8 = 0;
/// How far a read-back target may sit from the written one and still count as
/// held: wider than the `flt ` rounding, far narrower than any audible change.
pub const APPLIED_TARGET_TOLERANCE_RPM: f64 = 50.0;

/// Everything the fan code touches.
#[derive(Clone, Copy)]
pub struct FanEnv<'a> {
    pub smc: &'a dyn SmcPort,
    pub writer: &'a dyn SmcWriter,
    pub host: &'a dyn SensorHost,
    pub config: &'a Config,
    pub clock: &'a dyn Monotonic,
}

/// `FanControlError` plus the validation errors, with the texts and exit codes
/// of `TuneControllerErrorMapping.swift` (see [`FanError::into_error`]).
#[derive(Clone, Debug, PartialEq)]
pub enum FanError {
    /// `FanControlService.applyFan` found no SMC.
    NotAvailable,
    Usage(String),
    NoFans,
    ModeRejected(usize),
    TargetWriteFailed(usize),
    RestoreWriteFailed(String),
    ThermalEmergency(f64),
    MaxRpmUnavailable(usize),
    /// The governor gave up on its own (no temperatures, SMC not holding the state).
    Failed(String),
}

impl FanError {
    pub fn into_error(self, is_root: bool) -> Error {
        match self {
            Self::NotAvailable => {
                Error::Permission("SMC not available — fan control requires a real Mac".into())
            }
            Self::Usage(m) => Error::Usage(m),
            Self::NoFans => {
                Error::Unsupported("SMC reports no fans; fan control is unavailable".into())
            }
            Self::ModeRejected(i) => Error::Permission(format!(
                "SMC rejected manual mode for fan {i}; run with sudo"
            )),
            Self::TargetWriteFailed(i) => {
                Error::Permission(format!("SMC rejected target RPM for fan {i}"))
            }
            Self::RestoreWriteFailed(key) if is_root => Error::Failed(format!(
                "SMC rejected {key} while returning the fans to firmware control; they may still be forced"
            )),
            Self::RestoreWriteFailed(key) => Error::Permission(format!(
                "returning the fans to firmware control needs root (SMC rejected {key}); run with sudo"
            )),
            Self::ThermalEmergency(c) => Error::Permission(format!(
                "thermal emergency at {}°C; refusing write",
                swift_double(c)
            )),
            Self::MaxRpmUnavailable(i) => {
                Error::Unsupported(format!("SMC did not report maximum RPM for fan {i}"))
            }
            Self::Failed(m) => Error::Failed(m),
        }
    }
}

/// Swift's `"\(Double)"`: a whole number keeps its `.0`.
pub fn swift_double(value: f64) -> String {
    if value.is_finite() && value.fract() == 0.0 && value.abs() < 1e15 {
        format!("{value:.1}")
    } else {
        value.to_string()
    }
}

// ---------------------------------------------------------------------------
// Curves
// ---------------------------------------------------------------------------

/// A temperature→fraction curve, interpolated linearly between its points.
#[derive(Clone, Debug, PartialEq)]
pub struct FanCurve(pub Vec<(f64, f64)>);

impl FanCurve {
    pub fn fraction(&self, celsius: f64) -> f64 {
        let points = &self.0;
        let (Some(first), Some(last)) = (points.first(), points.last()) else {
            return 0.0;
        };
        if celsius <= first.0 {
            return first.1;
        }
        if celsius >= last.0 {
            return last.1;
        }
        for pair in points.windows(2) {
            let (a, b) = (pair[0], pair[1]);
            if celsius >= a.0 && celsius <= b.0 {
                let range = b.0 - a.0;
                if range <= 0.0 {
                    return a.1;
                }
                return a.1 + (celsius - a.0) / range * (b.1 - a.1);
            }
        }
        last.1
    }
}

/// The curve a governed profile follows; `None` for `System`, which writes nothing.
pub fn profile_curve(profile: FanProfile) -> Option<FanCurve> {
    match profile {
        FanProfile::System => None,
        FanProfile::Comfort => Some(FanCurve(vec![
            (45.0, 0.30),
            (55.0, 0.45),
            (65.0, 0.60),
            (75.0, 0.78),
            (85.0, 1.00),
        ])),
        FanProfile::Performance => Some(FanCurve(vec![
            (40.0, 0.35),
            (50.0, 0.55),
            (60.0, 0.72),
            (70.0, 0.88),
            (80.0, 1.00),
        ])),
    }
}

/// SMC keys that report a CPU or GPU *die* temperature, the sensors the curve
/// is driven from (proximity, ambient and battery sensors lag the die).
pub const DIE_TEMPERATURE_KEYS: [&str; 17] = [
    "TCMz", "TCMb", "TRDX", "TG0P", "Ts0S", "TC0C", "TC1C", "TC2C", "TC3C", "TC4C", "TC5C", "TC6C",
    "TC7C", "TC8C", "TC9C", "TCXC", "TC0P",
];

/// The hottest die sensor; with readings but no known die sensor the hottest
/// reading (an unfamiliar Mac is still governed, from a coarser sensor);
/// `None` without any temperature, so callers hold rather than read "cold".
pub fn governing_temperature(report: &SensorReport) -> Option<f64> {
    let max = |it: &mut dyn Iterator<Item = f64>| {
        it.fold(None, |m: Option<f64>, c| Some(m.map_or(c, |m| m.max(c))))
    };
    let die = max(&mut report
        .temperatures
        .iter()
        .filter(|r| DIE_TEMPERATURE_KEYS.contains(&r.key.as_str()))
        .map(|r| r.celsius));
    die.or_else(|| max(&mut report.temperatures.iter().map(|r| r.celsius)))
}

/// The Cool curve shifted so it reaches full speed at `target`.
pub fn cool_target_curve(target: f64) -> FanCurve {
    let t = crate::sensors::sanitize_cool_target(Some(target)).unwrap_or(85.0);
    FanCurve(vec![
        (t - 40.0, 0.30),
        (t - 30.0, 0.45),
        (t - 20.0, 0.60),
        (t - 10.0, 0.78),
        (t, 1.00),
    ])
}

/// `max(default curve at the hottest die, target curve at the average)`: the
/// target can raise the answer, never lower it. `None` for `System` or
/// without a temperature.
pub fn target_fraction(
    profile: FanProfile,
    temperature: Option<f64>,
    cool_target: Option<f64>,
    average: Option<f64>,
) -> Option<f64> {
    let curve = profile_curve(profile)?;
    let mut fraction = curve.fraction(temperature?);
    if profile == FanProfile::Comfort
        && let (Some(target), Some(average)) = (
            crate::sensors::sanitize_cool_target(cool_target),
            average.filter(|a| a.is_finite()),
        )
    {
        fraction = fraction.max(cool_target_curve(target).fraction(average));
    }
    Some(fraction)
}

/// The Cool target only counts on the Cool position.
pub fn effective_cool_target(selection: &FanSelection) -> Option<f64> {
    (selection.profile == FanProfile::Comfort)
        .then_some(selection.cool_target_celsius)
        .flatten()
}

pub fn average_for(selection: &FanSelection, report: &SensorReport) -> Option<f64> {
    effective_cool_target(selection).and_then(|_| average_cluster_temperature(report))
}

// ---------------------------------------------------------------------------
// Write policy
// ---------------------------------------------------------------------------

/// Clamp into the configured range, then floor at [`FAN_SPEED_FLOOR`].
pub fn clamp_fan_fraction(fraction: f64, min: f64, max: f64) -> f64 {
    fraction.max(min).min(max).max(FAN_SPEED_FLOOR)
}

/// Target RPM of fan `index`: `fraction * F{n}Mx`, floored at `F{n}Mn`.
pub fn target_rpm(env: &FanEnv, fraction: f64, index: usize) -> Result<f64, FanError> {
    if !env.smc.is_open() {
        return Err(FanError::NotAvailable);
    }
    let max = read_fan_max_rpm(env.smc, index as u8)
        .filter(|m| *m > 0.0)
        .ok_or(FanError::MaxRpmUnavailable(index))?;
    let min = read_fan_min_rpm(env.smc, index as u8).unwrap_or(0.0);
    Ok((fraction * max).max(min))
}

/// Refuse a write that would slow the fans on a Mac at or above
/// [`THERMAL_OVERRIDE_CELSIUS`]. `cooling_increase` (the target is at or
/// above what the fans are already asked for) passes: refusing to speed them
/// up is the hazard, not the safeguard.
pub fn require_thermal_headroom(env: &FanEnv, cooling_increase: bool) -> Result<(), FanError> {
    if cooling_increase {
        return Ok(());
    }
    let report = read_sensors(env.smc, env.host);
    let hottest = report
        .temperatures
        .iter()
        .map(|r| r.celsius)
        .fold(None, |m: Option<f64>, c| Some(m.map_or(c, |m| m.max(c))))
        .unwrap_or(0.0);
    if hottest < THERMAL_OVERRIDE_CELSIUS {
        Ok(())
    } else {
        Err(FanError::ThermalEmergency(hottest))
    }
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

fn fan_count(smc: &dyn SmcPort) -> usize {
    read_key_uint(smc, "FNum").unwrap_or(0) as usize
}

/// What `captureOriginalStates` found on one fan.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FanOriginalState {
    pub mode: Option<u8>,
    pub target_rpm: Option<f64>,
}

/// One fan's state before the first override (`originalState(fanIndex:)`).
///
/// `read_fan_mode` answers `None` for a fan at mode 0 whose lowercase `F{n}md`
/// twin is absent (it only returns an `F{n}Md` above 0). A fan that rests in
/// firmware mode must still be captured, or the way out would leave it
/// forced, so the plain `F{n}Md` is the fallback (a deviation from v0.12 that
/// only ever restores more).
pub fn original_state(env: &FanEnv, index: usize) -> Option<FanOriginalState> {
    env.smc.is_open().then(|| FanOriginalState {
        mode: read_fan_mode(env.smc, index as u8).or_else(|| {
            read_key_uint(env.smc, &format!("F{index}Md")).and_then(|m| u8::try_from(m).ok())
        }),
        target_rpm: read_fan_target_rpm(env.smc, index as u8),
    })
}

pub fn capture_original_states(env: &FanEnv) -> Vec<(usize, FanOriginalState)> {
    (0..fan_count(env.smc))
        .filter_map(|i| original_state(env, i).map(|s| (i, s)))
        .collect()
}

fn write(env: &FanEnv, key: &str, value: f64, data_type: &[u8; 4]) -> bool {
    write_value(env.writer, key, value, data_type)
}

/// Every check of [`apply_fan`] that happens before the first write: finite
/// value, reachable SMC, clamp and floor, at least one fan, thermal gate.
/// Returns the clamped fraction and the fan count.
pub fn preflight_apply(env: &FanEnv, fraction: f64) -> Result<(f64, usize), FanError> {
    if !fraction.is_finite() {
        return Err(FanError::Usage("Value must be finite.".into()));
    }
    if !env.smc.is_open() {
        return Err(FanError::NotAvailable);
    }
    let clamped = clamp_fan_fraction(
        fraction,
        env.config.fan_fraction_min,
        env.config.fan_fraction_max,
    );
    let count = fan_count(env.smc);
    if count == 0 {
        return Err(FanError::NoFans);
    }
    require_thermal_headroom(env, increases_cooling(env, clamped, count))?;
    Ok((clamped, count))
}

/// The writes of [`apply_fan`]: unlock, manual mode, target RPM per fan.
pub fn write_apply(env: &FanEnv, clamped: f64, count: usize) -> Result<(), FanError> {
    // Unlock the diagnostic register so the SMC accepts manual mode writes.
    write(env, "Ftst", 1.0, b"ui8 ");
    for i in 0..count {
        switch_fan_to_manual(env, i)?;
        let target = target_rpm(env, clamped, i)?;
        if !write(env, &format!("F{i}Tg"), target, b"flt ") {
            return Err(FanError::TargetWriteFailed(i));
        }
    }
    Ok(())
}

/// Apply a uniform fraction to all fans: clamp, floor, per-fan firmware
/// minimum, thermal gate, then manual mode and target RPM.
pub fn apply_fan(env: &FanEnv, fraction: f64) -> Result<(), FanError> {
    let (clamped, count) = preflight_apply(env, fraction)?;
    write_apply(env, clamped, count)
}

/// Manual-mode write with exponential backoff: the SMC may briefly reject
/// writes while `thermalmonitord` holds the fan controller.
fn switch_fan_to_manual(env: &FanEnv, index: usize) -> Result<(), FanError> {
    let mut delay_ms = 50u64;
    for attempt in 0..10 {
        write(env, &format!("F{index}Md"), 1.0, b"ui8 ");
        if read_fan_mode(env.smc, index as u8) == Some(1) {
            return Ok(());
        }
        if attempt < 9 {
            env.clock.sleep(std::time::Duration::from_millis(delay_ms));
            delay_ms = (delay_ms * 2).min(200);
        }
    }
    Err(FanError::ModeRejected(index))
}

/// Hand every fan back to the firmware and clear the unlock flag. Every
/// write is attempted even after one fails, so a partial failure still hands
/// back as many fans as possible; the first rejected key is then reported,
/// because a restore that did not happen must not be reported as applied.
pub fn restore_auto(env: &FanEnv) -> Result<(), FanError> {
    if !env.smc.is_open() {
        return Ok(());
    }
    let count = fan_count(env.smc);
    if count == 0 {
        return Err(FanError::NoFans);
    }
    let mut rejected = None;
    let mut put = |key: String, value: f64| {
        if !write(env, &key, value, b"ui8 ") && rejected.is_none() {
            rejected = Some(key);
        }
    };
    for i in 0..count {
        put(format!("F{i}Md"), f64::from(APPLE_SILICON_AUTO_MODE));
    }
    put("Ftst".into(), 0.0);
    rejected.map_or(Ok(()), |key| Err(FanError::RestoreWriteFailed(key)))
}

/// Whether a software override still holds the fans: the diagnostic unlock or
/// a fan in manual mode. Nothing readable answers `false`. A process that
/// governs nothing (a freshly started helper) can treat `true` as stale; a
/// false positive only costs a redundant hand-back.
pub fn has_software_override(env: &FanEnv) -> bool {
    if !env.smc.is_open() {
        return false;
    }
    let count = fan_count(env.smc);
    if count == 0 {
        return false;
    }
    read_key_uint(env.smc, "Ftst") == Some(1)
        || (0..count).any(|i| read_key_uint(env.smc, &format!("F{i}Md")) == Some(1))
}

/// Whether every fan still holds what [`apply_fan`] writes for `fraction`:
/// manual mode and a target within the tolerance. A fan that cannot be read
/// answers `false`: control that cannot be seen cannot be vouched for.
pub fn holds_applied_state(env: &FanEnv, fraction: f64) -> bool {
    if !env.smc.is_open() {
        return false;
    }
    let count = fan_count(env.smc);
    if count == 0 {
        return false;
    }
    let clamped = clamp_fan_fraction(
        fraction,
        env.config.fan_fraction_min,
        env.config.fan_fraction_max,
    );
    (0..count).all(|i| {
        read_fan_mode(env.smc, i as u8) == Some(1)
            && target_rpm(env, clamped, i).ok().is_some_and(|expected| {
                read_fan_target_rpm(env.smc, i as u8)
                    .is_some_and(|actual| (actual - expected).abs() <= APPLIED_TARGET_TOLERANCE_RPM)
            })
    })
}

/// Whether writing `fraction` asks the fans for at least as much air as they
/// are already asked for, per fan against the live target. Unknown state
/// answers `false`: without a reading to compare against, the write is
/// treated as the possibly-slowing one and stays gated.
fn increases_cooling(env: &FanEnv, fraction: f64, count: usize) -> bool {
    count > 0
        && (0..count).all(|i| {
            match (
                target_rpm(env, fraction, i).ok(),
                read_fan_target_rpm(env.smc, i as u8),
            ) {
                (Some(requested), Some(current)) => requested >= current,
                _ => false,
            }
        })
}

/// Restore captured per-fan state; best effort, because it runs on the way
/// out of the governor where failing would only lose the remaining fans.
/// Without a capture, fall back to [`restore_auto`]. Writes `Ftst` 0 last
/// (as `SMCRestoreTracker` does) so no diagnostic unlock outlives the run.
pub fn restore(env: &FanEnv, originals: &[(usize, FanOriginalState)]) {
    for (index, state) in originals {
        if let Some(target) = state.target_rpm {
            write(env, &format!("F{index}Tg"), target, b"flt ");
        }
        if let Some(mode) = state.mode {
            write(env, &format!("F{index}Md"), f64::from(mode), b"ui8 ");
        }
    }
    if originals.is_empty() {
        let _ = restore_auto(env);
    } else {
        write(env, "Ftst", 0.0, b"ui8 ");
    }
}
