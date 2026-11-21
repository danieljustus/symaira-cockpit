//! Sensors: the SMC read path (ports plus pure functions).
//!
//! Port of `SMCService.swift` (read side), `SensorService.swift`, the sensor and
//! power models of `Models.swift`, the read-only parts of `FanControlService` /
//! `SMCWritePolicy` (`readFanMode`, `fan status`) and `ChargeLimitService.detectKeyFamily`.
//!
//! Strictly read-only: [`SmcPort`] has no write method. Intel (`FS!`, `TC*C`,
//! `CHLC`) is dropped (D16): arm64 only. Report types serialize exactly like
//! Swift v0.12 (snake_case, nil optionals omitted unless noted).
//!
//! Known edge: Swift's `JSONEncoder` throws on NaN/inf; serde_json writes `null`.
//! Only a malfunctioning SMC can produce one.

use std::collections::HashSet;

use serde::Serialize;
use serde_json::Value;
use symcockpit_contract::Error;

/// A four-character SMC type code in readable order, e.g. `*b"ui8 "`.
pub type FourCc = [u8; 4];

/// Type and payload of one SMC key, as `readKeyRaw` returns them.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RawKey {
    pub data_type: FourCc,
    pub bytes: Vec<u8>,
}

/// Read-only view of the AppleSMC connection. Implemented by
/// `symcockpit-macos` (live) and `symcockpit-testkit` (fake).
pub trait SmcPort {
    /// True when the SMC actually answers (not just the transport).
    fn is_open(&self) -> bool;
    /// Type and raw bytes, or `None` when the key does not exist or cannot be read.
    fn read_key_raw(&self, key: &str) -> Option<RawKey>;
    /// Keys this host exposes via the index selector; `None` when unavailable.
    /// Callers must treat `None` honestly, never as "no keys".
    fn enumerate_keys(&self) -> Option<Vec<String>>;
}

/// Host facts that are not SMC keys.
pub trait SensorHost {
    /// `nominal` | `fair` | `serious` | `critical` | `unknown` (`ProcessInfo.thermalState`).
    fn thermal_pressure(&self) -> &'static str;
    /// Apple Silicon generation from `machdep.cpu.brand_string`.
    fn chip_generation(&self) -> ChipGeneration;
}

// ---------------------------------------------------------------------------
// Value conversion
// ---------------------------------------------------------------------------

/// Convert raw SMC bytes by data type (`smcConvertValue`). The payload has a
/// per-type byte order: `flt ` is little-endian, the integer and fixed-point
/// types are big-endian, unknown types read as a big-endian unsigned integer.
/// (The param *block* is native-endian; that lives in the macOS adapter.)
pub fn convert_value(data_type: &FourCc, bytes: &[u8]) -> f64 {
    let b = bytes;
    match data_type {
        // Unsigned fixed-point 14.2 (issue #193).
        b"fpe2" if b.len() >= 2 => f64::from(u16::from_be_bytes([b[0], b[1]])) / 4.0,
        // IEEE 754, little-endian (issue #185).
        b"flt " if b.len() >= 4 => f64::from(f32::from_le_bytes([b[0], b[1], b[2], b[3]])),
        b"sp78" if b.len() >= 2 => f64::from(i16::from_be_bytes([b[0], b[1]])) / 256.0,
        b"ui8 " if !b.is_empty() => f64::from(b[0]),
        b"ui16" if b.len() >= 2 => f64::from(u16::from_be_bytes([b[0], b[1]])),
        b"ui32" if b.len() >= 4 => f64::from(u32::from_be_bytes([b[0], b[1], b[2], b[3]])),
        b"fpe2" | b"flt " | b"sp78" | b"ui8 " | b"ui16" | b"ui32" => 0.0,
        _ => big_endian_uint(b) as f64,
    }
}

fn big_endian_uint(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0, |acc, &b| (acc << 8) | u64::from(b))
}

pub fn read_key_value(smc: &dyn SmcPort, key: &str) -> Option<f64> {
    let raw = smc.read_key_raw(key)?;
    Some(convert_value(&raw.data_type, &raw.bytes))
}

/// All payload bytes as a big-endian unsigned integer (`readKeyUInt`).
pub fn read_key_uint(smc: &dyn SmcPort, key: &str) -> Option<u64> {
    let raw = smc.read_key_raw(key)?;
    (!raw.bytes.is_empty()).then(|| big_endian_uint(&raw.bytes))
}

/// A `ui32` key only (`readKeyUInt32`).
pub fn read_key_uint32(smc: &dyn SmcPort, key: &str) -> Option<u32> {
    let raw = smc.read_key_raw(key)?;
    match (&raw.data_type, raw.bytes.as_slice()) {
        (b"ui32", [a, b, c, d, ..]) => Some(u32::from_be_bytes([*a, *b, *c, *d])),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct SensorReading {
    pub key: String,
    pub label: String,
    pub celsius: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct FanReading {
    pub index: i64,
    pub label: String,
    pub rpm: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub min_rpm: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_rpm: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct SensorReport {
    pub thermal_pressure: String,
    pub smc_supported: bool,
    pub temperatures: Vec<SensorReading>,
    pub fans: Vec<FanReading>,
    pub notes: Vec<String>,
}

/// Which SMC key supplied the adapter (DC-in) wattage.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AdapterPowerSource {
    SmcPdtr,
    SmcPd0r,
}

/// Where the total system power came from.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SystemPowerSource {
    SmcPstr,
    BatterySystemLoad,
}

/// Live power readings. Every field is optional and omitted when absent; the
/// block itself is omitted when nothing is readable (no zeros, no guesses).
/// `adapter_watts` always repeats `watts`, as in Swift.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct PowerReport {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub volts: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub amps: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub watts: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub adapter_watts: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub adapter_source: Option<AdapterPowerSource>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub system_watts: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub system_source: Option<SystemPowerSource>,
}

impl PowerReport {
    pub fn new(
        volts: Option<f64>,
        amps: Option<f64>,
        watts: Option<f64>,
        adapter_source: Option<AdapterPowerSource>,
        system_watts: Option<f64>,
        system_source: Option<SystemPowerSource>,
    ) -> Self {
        Self {
            volts,
            amps,
            watts,
            adapter_watts: watts,
            adapter_source,
            system_watts,
            system_source,
        }
    }
}

// ---------------------------------------------------------------------------
// Chip generation and key tables
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ChipGeneration {
    M1,
    M2,
    M3,
    M4,
    /// Not detected, or an unrecognised/future chip (e.g. M5).
    Unknown,
}

impl ChipGeneration {
    /// Label used in report notes.
    pub fn display_name(self) -> &'static str {
        match self {
            Self::M1 => "M1",
            Self::M2 => "M2",
            Self::M3 => "M3",
            Self::M4 => "M4",
            Self::Unknown => "unknown-generation",
        }
    }

    /// Parse `machdep.cpu.brand_string` (`"Apple M4 Pro"` -> `M4`).
    pub fn from_brand_string(brand: &str) -> Option<Self> {
        let upper = brand.to_uppercase();
        [Self::M1, Self::M2, Self::M3, Self::M4]
            .into_iter()
            .find(|g| upper.contains(g.display_name()))
    }
}

/// Candidate rows shared by every generation (verified against live hardware;
/// presence in the key table does not prove a row means what it names, see
/// [`is_plausible_temperature`]).
const COMMON_TEMPERATURE_KEYS: &[(&str, &str)] = &[
    ("TCMz", "CPU Die Hotspot"),
    ("TRDX", "GPU Die Hotspot"),
    ("Tp01", "CPU Core 1"),
    ("Tp02", "CPU Core 2"),
    ("Tp03", "CPU Core 3"),
    ("Tp04", "CPU Core 4"),
    ("Tp05", "CPU Core 5"),
    ("Tp06", "CPU Core 6"),
    ("Tp07", "CPU Core 7"),
    ("Tp08", "CPU Core 8"),
    ("Tp09", "CPU Core 9"),
    ("Tp10", "CPU Core 10"),
    ("Tp11", "CPU Core 11"),
    ("Tp12", "CPU Core 12"),
    ("TG0P", "GPU Die"),
    ("TM0P", "Memory Proximity"),
    ("Ts0S", "SoC Die"),
    ("Ta0P", "Ambient"),
];

/// Verified on M2 and later.
const M2_PLUS_CPU_KEYS: &[(&str, &str)] = &[
    ("TCMb", "CPU Die (Core Max)"),
    ("TCHP", "CPU/Charger Proximity"),
];

/// E-core cluster keys per generation. The `Unknown` row is the union.
fn e_core_keys(generation: ChipGeneration) -> &'static [&'static str] {
    match generation {
        ChipGeneration::M1 => &[],
        ChipGeneration::M2 => &["Te04", "Te05", "Te06"],
        ChipGeneration::M3 => &["Te05", "Te0L", "Te0P", "Te0S"],
        // Verified on an M4 Pro (Mac16,8); `Te09`/`Te0H` do not exist there (#185).
        ChipGeneration::M4 => &["Te04", "Te05", "Te06", "Te0R", "Te0S", "Te0T"],
        ChipGeneration::Unknown => &[
            "Te04", "Te05", "Te06", "Te09", "Te0H", "Te0L", "Te0P", "Te0R", "Te0S", "Te0T",
        ],
    }
}

/// The Apple Silicon candidate table for one generation, in report order.
pub fn temperature_keys(generation: ChipGeneration) -> Vec<(&'static str, &'static str)> {
    let mut keys = COMMON_TEMPERATURE_KEYS.to_vec();
    if generation != ChipGeneration::M1 {
        keys.extend_from_slice(M2_PLUS_CPU_KEYS);
    }
    keys.extend(
        e_core_keys(generation)
            .iter()
            .map(|k| (*k, "CPU E-Core Cluster")),
    );
    keys
}

/// Physically plausible band for a die/proximity sensor on a running Mac. An
/// M4 Pro implements `Tp01`-`Tp09` and reads them back at 0-8 °C while the die
/// is at 85 °C, so `> 0` is not a gate.
pub const PLAUSIBLE_TEMPERATURE_RANGE: std::ops::RangeInclusive<f64> = 10.0..=125.0;

pub fn is_plausible_temperature(celsius: f64) -> bool {
    PLAUSIBLE_TEMPERATURE_RANGE.contains(&celsius)
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

/// Candidate table intersected with the keys the host exposes; implausible
/// readings are dropped. Without enumeration the table is used as-is.
pub fn read_temperatures(smc: &dyn SmcPort, generation: ChipGeneration) -> Vec<SensorReading> {
    if !smc.is_open() {
        return Vec::new();
    }
    let known: Option<HashSet<String>> = smc.enumerate_keys().map(|k| k.into_iter().collect());
    temperature_keys(generation)
        .into_iter()
        .filter(|(key, _)| known.as_ref().is_none_or(|k| k.contains(*key)))
        .filter_map(|(key, label)| {
            let celsius = read_key_value(smc, key)?;
            is_plausible_temperature(celsius).then(|| SensorReading {
                key: key.into(),
                label: label.into(),
                celsius,
            })
        })
        .collect()
}

/// Fans from `FNum` (at most 4). Fanless Macs report `FNum` 0: empty list.
pub fn read_fans(smc: &dyn SmcPort) -> Vec<FanReading> {
    if !smc.is_open() {
        return Vec::new();
    }
    let count = match read_key_uint(smc, "FNum") {
        Some(n) if n > 0 => n.min(4),
        _ => return Vec::new(),
    };
    (0..count as i64)
        .filter_map(|i| {
            let rpm = read_key_value(smc, &format!("F{i}Ac"))?;
            Some(FanReading {
                index: i,
                label: if i == 0 {
                    "Main Fan".into()
                } else {
                    format!("Fan {}", i + 1)
                },
                rpm: rpm as i64,
                min_rpm: read_key_value(smc, &format!("F{i}Mn")).map(|v| v as i64),
                max_rpm: read_key_value(smc, &format!("F{i}Mx")).map(|v| v as i64),
            })
        })
        .collect()
}

pub fn read_fan_min_rpm(smc: &dyn SmcPort, fan: u8) -> Option<f64> {
    read_key_value(smc, &format!("F{fan}Mn"))
}

pub fn read_fan_max_rpm(smc: &dyn SmcPort, fan: u8) -> Option<f64> {
    read_key_value(smc, &format!("F{fan}Mx"))
}

pub fn read_fan_target_rpm(smc: &dyn SmcPort, fan: u8) -> Option<f64> {
    read_key_value(smc, &format!("F{fan}Tg"))
}

/// Fan mode: `1` manual, `3` system/auto, `None` when unavailable. `F{n}Md`
/// wins when above 0, otherwise `F{n}md` (a value above 255 is not a mode: `None`).
pub fn read_fan_mode(smc: &dyn SmcPort, fan: u8) -> Option<u8> {
    let upper = read_key_uint(smc, &format!("F{fan}Md")).and_then(|v| u8::try_from(v).ok());
    match upper {
        Some(m) if m > 0 => Some(m),
        _ => read_key_uint(smc, &format!("F{fan}md")).and_then(|v| u8::try_from(v).ok()),
    }
}

/// Adapter (DC-in) rail and total system power (`readSystemPower`).
///
/// `VD0R` volts, `ID0R` amps, `PDTR` watts (falling back to `PD0R` when `PDTR`
/// is 0 or absent), total from `PSTR`; when `PSTR` is absent or not positive,
/// `system_load_milliwatts` (battery `PowerTelemetryData.SystemLoad`) supplies
/// it, and is only called then. `None` when nothing is readable.
pub fn read_system_power(
    smc: &dyn SmcPort,
    system_load_milliwatts: impl FnOnce() -> Option<i64>,
) -> Option<PowerReport> {
    let (mut volts, mut amps, mut watts, mut adapter_source) = (None, None, None, None);
    let (mut system_watts, mut system_source) = (None, None);
    if smc.is_open() {
        volts = read_key_value(smc, "VD0R");
        amps = read_key_value(smc, "ID0R");
        let pdtr = read_key_value(smc, "PDTR");
        let pd0r = || read_key_value(smc, "PD0R").filter(|p| p.is_finite() && *p > 0.0);
        match pdtr {
            Some(p) if p != 0.0 => {
                (watts, adapter_source) = (Some(p), Some(AdapterPowerSource::SmcPdtr))
            }
            _ => {
                if let Some(p) = pd0r() {
                    (watts, adapter_source) = (Some(p), Some(AdapterPowerSource::SmcPd0r));
                } else if let Some(p) = pdtr {
                    // PDTR is readable and genuinely 0 (e.g. on battery).
                    (watts, adapter_source) = (Some(p), Some(AdapterPowerSource::SmcPdtr));
                }
            }
        }
        if let Some(p) = read_key_value(smc, "PSTR").filter(|p| p.is_finite() && *p > 0.0) {
            (system_watts, system_source) = (Some(p), Some(SystemPowerSource::SmcPstr));
        }
    }
    if system_watts.is_none()
        && let Some(mw) = system_load_milliwatts().filter(|mw| *mw > 0)
    {
        system_watts = Some(mw as f64 / 1000.0);
        system_source = Some(SystemPowerSource::BatterySystemLoad);
    }
    if volts.is_none() && amps.is_none() && watts.is_none() && system_watts.is_none() {
        return None;
    }
    Some(PowerReport {
        volts,
        amps,
        watts,
        adapter_watts: watts,
        adapter_source,
        system_watts,
        system_source,
    })
}

/// `SensorService.read`: thermal pressure, temperatures, fans and honest notes.
pub fn read_sensors(smc: &dyn SmcPort, host: &dyn SensorHost) -> SensorReport {
    let generation = host.chip_generation();
    let temperatures = read_temperatures(smc, generation);
    let fans = read_fans(smc);
    let mut notes = Vec::new();
    if !smc.is_open() {
        notes.push(
            "SMC unavailable — detailed die temperatures and fan RPM cannot be read. \
             This happens on a VM, and on macOS builds that no longer let unprivileged \
             processes talk to the AppleSMC driver."
                .to_string(),
        );
    } else {
        if smc.enumerate_keys().is_none() {
            notes.push(format!(
                "SMC connected but index-based key enumeration is unavailable — \
                 temperatures come from the built-in {} candidate table without host key verification.",
                generation.display_name()
            ));
        }
        if temperatures.is_empty() {
            notes.push(
                "SMC connected but no temperature sensors returned data. \
                 Your Mac may use keys not yet in the probe list."
                    .to_string(),
            );
        }
        if fans.is_empty() {
            notes.push("No fans detected (fanless Mac or SMC returned fan count 0).".to_string());
        }
    }
    SensorReport {
        thermal_pressure: host.thermal_pressure().to_string(),
        smc_supported: smc.is_open(),
        temperatures,
        fans,
        notes,
    }
}

fn to_json<T: Serialize>(value: &T) -> Result<Value, Error> {
    serde_json::to_value(value).map_err(|e| Error::Failed(format!("encoding failed: {e}")))
}

// ---------------------------------------------------------------------------
// `sensors` (CLI `sensors [--json]`, MCP `get_sensors`: same JSON)
// ---------------------------------------------------------------------------

/// `symcockpit sensors --help` (exact Swift text, without trailing newline).
pub const SENSORS_HELP: &str = "Usage: symcockpit sensors [--json]\n\n\
Thermal pressure + (when available) temps/fan RPM (JSON).\n\
--json is accepted for consistency with other read commands; it is a no-op here.";

/// Arguments after `sensors`: `Ok(true)` asks for help, `--json` is a no-op,
/// anything else is a usage error (exit 2).
pub fn parse_sensors_args(rest: &[String]) -> Result<bool, Error> {
    if rest.iter().any(|a| a == "--help" || a == "-h") {
        return Ok(true);
    }
    match rest.iter().find(|a| *a != "--json") {
        Some(arg) => Err(Error::Usage(format!(
            "sensors: unexpected argument '{arg}'"
        ))),
        None => Ok(false),
    }
}

/// The `sensors --json` / `get_sensors` document.
pub fn sensors_json(smc: &dyn SmcPort, host: &dyn SensorHost) -> Result<Value, Error> {
    to_json(&read_sensors(smc, host))
}

// ---------------------------------------------------------------------------
// `fan status` (read side of the fan profile)
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FanProfile {
    System,
    Comfort,
    Performance,
}

impl FanProfile {
    /// `FanProfile(rawValue: name.lowercased())`.
    pub fn parse(raw: &str) -> Option<Self> {
        match raw.to_lowercase().as_str() {
            "system" => Some(Self::System),
            "comfort" => Some(Self::Comfort),
            "performance" => Some(Self::Performance),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::Comfort => "comfort",
            Self::Performance => "performance",
        }
    }
}

/// Allowed Cool target bounds in °C, enforced on write and on read.
pub const COOL_TARGET_RANGE: std::ops::RangeInclusive<f64> = 50.0..=85.0;

/// A finite value clamped into [`COOL_TARGET_RANGE`]; `None` for `None`/NaN/inf.
pub fn sanitize_cool_target(celsius: Option<f64>) -> Option<f64> {
    celsius
        .filter(|c| c.is_finite())
        .map(|c| c.clamp(*COOL_TARGET_RANGE.start(), *COOL_TARGET_RANGE.end()))
}

/// The persisted fan selection: a position plus the optional Cool target.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FanSelection {
    pub profile: FanProfile,
    pub cool_target_celsius: Option<f64>,
}

impl FanSelection {
    pub const SYSTEM: Self = Self {
        profile: FanProfile::System,
        cool_target_celsius: None,
    };

    pub fn new(profile: FanProfile, cool_target_celsius: Option<f64>) -> Self {
        Self {
            profile,
            cool_target_celsius: sanitize_cool_target(cool_target_celsius),
        }
    }

    /// Decode `~/.symtune/fan-profile.json`; corrupt or unreadable content is
    /// `system` ("don't override"), exactly like `FanProfileStore.readSelection`.
    /// A file without `cool_target_celsius` means "no target".
    pub fn from_json(bytes: &[u8]) -> Self {
        let parse = || -> Option<Self> {
            let v: Value = serde_json::from_slice(bytes).ok()?;
            let profile = match v.get("profile")?.as_str()? {
                "system" => FanProfile::System,
                "comfort" => FanProfile::Comfort,
                "performance" => FanProfile::Performance,
                _ => return None,
            };
            let target = match v.get("cool_target_celsius") {
                None | Some(Value::Null) => None,
                Some(t) => Some(t.as_f64()?),
            };
            Some(Self::new(profile, target))
        };
        parse().unwrap_or(Self::SYSTEM)
    }
}

/// Where the selected fan profile is stored.
pub trait FanSelectionSource {
    fn selection(&self) -> FanSelection;
}

/// Whether a fan governor is running.
pub trait GovernorProbe {
    fn is_running(&self) -> bool;
}

fn is_cluster_key(key: &str) -> bool {
    key.len() == 4 && (key.starts_with("Tp") || key.starts_with("Te"))
}

fn is_gpu_key(key: &str) -> bool {
    key == "TG0P" || key == "TRDX" || (key.len() == 4 && key.starts_with("Tg"))
}

/// Mean of every plausible CPU cluster (`Tp**`, `Te**`) and GPU (`Tg**`,
/// `TG0P`, `TRDX`) reading (`FanCoolTarget.averageClusterTemperature`). `TCMz`
/// (CPU hotspot) stands in only when no CPU cluster row exists; proximity,
/// ambient, SoC and `TCMb` never count. `None` without a qualifying reading.
pub fn average_cluster_temperature(report: &SensorReport) -> Option<f64> {
    let plausible: Vec<&SensorReading> = report
        .temperatures
        .iter()
        .filter(|r| r.celsius.is_finite() && is_plausible_temperature(r.celsius))
        .collect();
    let mut used: Vec<&SensorReading> = plausible
        .iter()
        .copied()
        .filter(|r| is_cluster_key(&r.key))
        .collect();
    if used.is_empty() {
        used = plausible
            .iter()
            .copied()
            .filter(|r| r.key == "TCMz")
            .collect();
    }
    used.extend(plausible.iter().filter(|r| is_gpu_key(&r.key)));
    (!used.is_empty()).then(|| used.iter().map(|r| r.celsius).sum::<f64>() / used.len() as f64)
}

/// Arguments of `fan status`; `rest` starts with `status`.
pub fn parse_fan_status_args(rest: &[String]) -> Result<(), Error> {
    match rest.get(1) {
        Some(arg) => Err(Error::Usage(format!(
            "fan status: unexpected argument '{arg}'"
        ))),
        None => Ok(()),
    }
}

/// The `fan status` document: `{profile, governor_running, cool_target_celsius,
/// average_cluster_celsius}`. The two optionals are explicit `null`s ("no
/// target" is an answer); the average is rounded to 0.1 °C.
pub fn fan_status_json(
    profiles: &dyn FanSelectionSource,
    governor: &dyn GovernorProbe,
    smc: &dyn SmcPort,
    host: &dyn SensorHost,
) -> Result<Value, Error> {
    #[derive(Serialize)]
    struct FanProfileResult {
        profile: &'static str,
        governor_running: bool,
        cool_target_celsius: Option<f64>,
        average_cluster_celsius: Option<f64>,
    }
    let selection = profiles.selection();
    let governor_running = governor.is_running();
    let average = average_cluster_temperature(&read_sensors(smc, host));
    to_json(&FanProfileResult {
        profile: selection.profile.as_str(),
        governor_running,
        cool_target_celsius: selection.cool_target_celsius,
        average_cluster_celsius: average.map(|a| (a * 10.0).round() / 10.0),
    })
}

// ---------------------------------------------------------------------------
// Charge-limit key probe (read only)
// ---------------------------------------------------------------------------

/// Which SMC charge-limit key family this Mac implements (arm64 only).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ChargeLimitKeyFamily {
    /// `CHTE`, a `ui32` (modern Apple Silicon).
    Chte,
    /// `CH0B`, any readable integer (older Apple Silicon).
    Ch0b,
}

/// Probe `CHTE`, then `CH0B`. `None` when neither exists. Swift memoises the
/// result; callers that poll should do the same.
pub fn detect_charge_limit_key_family(smc: &dyn SmcPort) -> Option<ChargeLimitKeyFamily> {
    if read_key_uint32(smc, "CHTE").is_some() {
        Some(ChargeLimitKeyFamily::Chte)
    } else if read_key_uint(smc, "CH0B").is_some() {
        Some(ChargeLimitKeyFamily::Ch0b)
    } else {
        None
    }
}

/// Whether charging is currently inhibited, for the detected family.
pub fn read_charge_inhibit_state(smc: &dyn SmcPort) -> Option<bool> {
    match detect_charge_limit_key_family(smc)? {
        ChargeLimitKeyFamily::Chte => read_key_uint32(smc, "CHTE").map(|v| v == 1),
        ChargeLimitKeyFamily::Ch0b => read_key_uint(smc, "CH0B").map(|v| v == 2),
    }
}

/// Why charge limiting cannot work on firmware without any charge-limit key
/// (text shared by the write paths and `doctor`; kept verbatim from Swift).
pub const MISSING_CHARGE_LIMIT_KEY_DETAIL: &str = "this Mac's firmware has no charge-limit SMC key \
(CHTE, CH0B or CHLC), so `sudo` cannot help. Firmware shipped with macOS 27 removed these keys; \
use System Settings > Battery > Charge Limit instead.";

/// A reachable SMC without a charge-limit key is a hardware limit, not a
/// missing privilege (#420): `Unsupported` (exit 4). An unreachable SMC passes
/// (it keeps its own error).
pub fn require_charge_limit_key(smc: &dyn SmcPort) -> Result<(), Error> {
    if smc.is_open() && detect_charge_limit_key_family(smc).is_none() {
        return Err(Error::Unsupported(MISSING_CHARGE_LIMIT_KEY_DETAIL.into()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // Vectors: tuning/Tests/SymCockpitCoreTests/SMCServiceTests.swift
    // (testChipGenerationDetectionFromBrandString, testPlausibleTemperatureRangeBounds,
    // testAppleSiliconTablesAreGenerationAware, testUnknownGenerationUsesUnionOfECoreRows),
    // SystemPowerTests/SMCTransport (value decoding), FanCoolTargetTests.

    #[test]
    fn decodes_each_type_with_its_own_byte_order() {
        // F0Ac `d1 9c a3 45` little-endian = 5235.6 (Swift comment, issue #185).
        assert_eq!(
            convert_value(b"flt ", &[0xd1, 0x9c, 0xa3, 0x45]),
            5_235.602_050_781_25
        );
        assert_eq!(convert_value(b"fpe2", &[0x5D, 0xC0]), 6000.0); // SMCServiceTests, #193
        assert_eq!(convert_value(b"fpe2", &[0x00, 0x14]), 5.0);
        assert_eq!(convert_value(b"sp78", &[0x1e, 0x80]), 30.5);
        assert_eq!(convert_value(b"sp78", &[0xff, 0x00]), -1.0);
        assert_eq!(convert_value(b"ui8 ", &[2]), 2.0);
        assert_eq!(convert_value(b"ui16", &[0x01, 0x02]), 258.0);
        assert_eq!(convert_value(b"ui32", &[0, 0, 0x0d, 0x2e]), 3374.0);
        assert_eq!(convert_value(b"hex_", &[0x01, 0x00]), 256.0); // unknown: big-endian
        assert_eq!(convert_value(b"ui16", &[1]), 0.0); // too short
        assert_eq!(convert_value(b"flt ", &[]), 0.0);
    }

    #[test]
    fn brand_string_detection() {
        use ChipGeneration::*;
        for (brand, want) in [
            ("Apple M1", Some(M1)),
            ("Apple M2 Pro", Some(M2)),
            ("Apple M3 Max", Some(M3)),
            ("Apple M4 Pro", Some(M4)),
            ("Intel Core i9-13900K", None),
            ("Apple M5", None),
        ] {
            assert_eq!(ChipGeneration::from_brand_string(brand), want, "{brand}");
        }
    }

    #[test]
    fn plausible_range_bounds() {
        for (c, ok) in [
            (2.2, false),
            (8.3, false),
            (10.0, true),
            (50.0, true),
            (96.2, true),
            (125.0, true),
            (125.1, false),
            (200.0, false),
            (f64::NAN, false),
        ] {
            assert_eq!(is_plausible_temperature(c), ok, "{c}");
        }
    }

    fn keys(g: ChipGeneration) -> Vec<&'static str> {
        temperature_keys(g).into_iter().map(|(k, _)| k).collect()
    }

    #[test]
    fn tables_are_generation_aware() {
        let (m1, m3, m4, unknown) = (
            keys(ChipGeneration::M1),
            keys(ChipGeneration::M3),
            keys(ChipGeneration::M4),
            keys(ChipGeneration::Unknown),
        );
        assert!(m3.contains(&"Te0L") && m3.contains(&"Te0P"));
        for k in ["Te04", "Te05", "Te06", "Te0R", "Te0S", "Te0T"] {
            assert!(m4.contains(&k), "M4 row must carry {k}");
        }
        for k in ["Te09", "Te0H", "Te0L"] {
            assert!(!m4.contains(&k), "M4 row must not carry {k}");
        }
        assert!(m3.contains(&"TCMz") && m4.contains(&"TRDX"));
        for k in [
            "Te04", "Te05", "Te06", "Te09", "Te0H", "Te0L", "Te0P", "Te0R", "Te0S", "Te0T",
        ] {
            assert!(unknown.contains(&k), "unknown row must carry {k}");
        }
        // M1 has neither the M2+ CPU rows nor E-core rows.
        assert!(!m1.contains(&"TCMb") && !m1.iter().any(|k| k.starts_with("Te")));
        assert_eq!(temperature_keys(ChipGeneration::M4).len(), 18 + 2 + 6);
    }

    #[test]
    fn labels_for_e_cores_and_first_rows() {
        let t = temperature_keys(ChipGeneration::M4);
        assert_eq!(t[0], ("TCMz", "CPU Die Hotspot"));
        assert_eq!(t[2], ("Tp01", "CPU Core 1"));
        assert_eq!(*t.last().unwrap(), ("Te0T", "CPU E-Core Cluster"));
    }

    fn report(rows: &[(&str, f64)]) -> SensorReport {
        SensorReport {
            thermal_pressure: "nominal".into(),
            smc_supported: true,
            temperatures: rows
                .iter()
                .map(|(k, c)| SensorReading {
                    key: (*k).into(),
                    label: (*k).into(),
                    celsius: *c,
                })
                .collect(),
            fans: vec![],
            notes: vec![],
        }
    }

    // Vectors: FanCoolTargetTests.swift (average cluster temperature section).
    #[test]
    fn average_cluster_vectors() {
        let avg = |rows: &[(&str, f64)]| average_cluster_temperature(&report(rows));
        let close = |a: Option<f64>, b: f64| (a.unwrap() - b).abs() < 1e-9;
        assert!(close(
            avg(&[
                ("Tp01", 60.0),
                ("Tp02", 70.0),
                ("Te04", 50.0),
                ("Tg0a", 80.0)
            ]),
            65.0
        ));
        let m4 = [
            ("TCMz", 80.0),
            ("TRDX", 70.0),
            ("TCMb", 79.0),
            ("Tp01", 60.0),
            ("Tp02", 62.0),
            ("Tp03", 64.0),
            ("TCHP", 45.0),
            ("Te04", 50.0),
            ("Te05", 52.0),
        ];
        assert!(close(avg(&m4), 358.0 / 6.0));
        let implausible = [
            ("Tp01", 3.0),
            ("Tp02", 8.0),
            ("Tp03", 70.0),
            ("Te04", 130.0),
            ("Te05", f64::NAN),
            ("Te06", 60.0),
        ];
        assert!(close(avg(&implausible), 65.0));
        // Intel rows are not clusters any more (D16): only GPU rows count.
        assert!(close(avg(&[("TC0C", 60.0), ("TG0P", 70.0)]), 70.0));
        assert!(close(
            avg(&[
                ("TCMz", 80.0),
                ("TRDX", 60.0),
                ("TCMb", 90.0),
                ("TCHP", 40.0)
            ]),
            70.0
        ));
        assert!(close(
            avg(&[("TCMz", 99.0), ("Tp01", 60.0), ("TRDX", 70.0)]),
            65.0
        ));
        assert!(close(avg(&[("TRDX", 61.0), ("TCHP", 40.0)]), 61.0));
        assert_eq!(avg(&[]), None);
        assert_eq!(
            avg(&[
                ("TCHP", 45.0),
                ("Ta0P", 25.0),
                ("TM0P", 40.0),
                ("Ts0S", 50.0),
                ("TCMb", 80.0)
            ]),
            None
        );
        assert_eq!(
            avg(&[("Tp01", 2.0), ("Tp02", 5.0), ("TCMz", 200.0), ("TRDX", 3.0)]),
            None
        );
    }

    #[test]
    fn cool_target_is_clamped_and_non_finite_dropped() {
        // FanCoolTargetTests.testSanitizedClampsAndDropsNonFiniteValues
        assert_eq!(sanitize_cool_target(Some(70.0)), Some(70.0));
        assert_eq!(sanitize_cool_target(Some(10.0)), Some(50.0));
        assert_eq!(sanitize_cool_target(Some(500.0)), Some(85.0));
        assert_eq!(sanitize_cool_target(Some(-3.0)), Some(50.0));
        assert_eq!(sanitize_cool_target(None), None);
        assert_eq!(sanitize_cool_target(Some(f64::NAN)), None);
        assert_eq!(sanitize_cool_target(Some(f64::NEG_INFINITY)), None);
    }

    #[test]
    fn selection_decoding_matches_the_store() {
        let sel = |s: &str| FanSelection::from_json(s.as_bytes());
        assert_eq!(
            sel(r#"{"profile":"comfort","cool_target_celsius":70}"#),
            FanSelection::new(FanProfile::Comfort, Some(70.0))
        );
        // A file written before the Cool target existed.
        assert_eq!(
            sel(r#"{"profile":"performance"}"#),
            FanSelection::new(FanProfile::Performance, None)
        );
        assert_eq!(
            sel(r#"{"profile":"comfort","cool_target_celsius":null}"#).cool_target_celsius,
            None
        );
        // Out-of-range targets are clamped on read.
        assert_eq!(
            sel(r#"{"profile":"comfort","cool_target_celsius":99}"#).cool_target_celsius,
            Some(85.0)
        );
        // Corrupt content is "don't override".
        for bad in [
            "",
            "nope",
            "{}",
            r#"{"profile":"turbo"}"#,
            r#"{"profile":"comfort","cool_target_celsius":"hot"}"#,
            r#"{"profile":1}"#,
        ] {
            assert_eq!(sel(bad), FanSelection::SYSTEM, "{bad:?}");
        }
    }

    #[test]
    fn argument_parsing() {
        let v = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(parse_sensors_args(&v(&[])), Ok(false));
        assert_eq!(parse_sensors_args(&v(&["--json"])), Ok(false));
        assert_eq!(parse_sensors_args(&v(&["--bogus", "--help"])), Ok(true));
        assert_eq!(parse_sensors_args(&v(&["-h"])), Ok(true));
        let err = parse_sensors_args(&v(&["--bogus"])).unwrap_err();
        assert_eq!(
            err,
            Error::Usage("sensors: unexpected argument '--bogus'".into())
        );
        assert_eq!(err.exit_code(), 2);
        assert_eq!(parse_fan_status_args(&v(&["status"])), Ok(()));
        assert_eq!(
            parse_fan_status_args(&v(&["status", "extra"])),
            Err(Error::Usage(
                "fan status: unexpected argument 'extra'".into()
            ))
        );
    }

    #[test]
    fn sensors_help_is_the_oracle_text() {
        let fixture = include_str!("../../../oracle/v0.12/cases/sensors-help.stdout");
        assert_eq!(format!("{SENSORS_HELP}\n"), fixture);
    }

    #[test]
    fn missing_charge_limit_key_text_is_the_swift_text() {
        let src = include_str!("../../../tuning/Sources/SymCockpitCore/TuneController.swift");
        // Swift joins three string literals; compare the text without quoting/continuations.
        let flat: String = MISSING_CHARGE_LIMIT_KEY_DETAIL
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        for part in [
            "this Mac's firmware has no charge-limit SMC key (CHTE, CH0B or CHLC), ",
            "so `sudo` cannot help. Firmware shipped with macOS 27 removed these keys; ",
            "use System Settings > Battery > Charge Limit instead.",
        ] {
            assert!(src.contains(part.trim_end()), "{part}");
            assert!(flat.contains(part.trim_end()), "{part}");
        }
    }
}
