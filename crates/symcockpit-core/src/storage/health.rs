//! NVMe SMART health (R30, R31): decoding, the versioned rule table, the
//! deterioration check and the `storage health` commands over ports.
//!
//! Rules are a worst-case reduction: the overall grade is the worst single
//! check. Every stored measurement carries [`RULES_VERSION`]; change a
//! threshold only together with a version bump (see `rules_fingerprint`).

use std::fmt::Write as _;

use serde_json::{Map, Value, json};
use symcockpit_contract::Error;

use crate::plan::Clock;

/// Version of the rule table below. Stored with every measurement.
pub const RULES_VERSION: u32 = 1;

/// Percentage used: warning from here, critical at 100 and above.
const USED_WARN: u8 = 80;
const USED_CRIT: u8 = 100;
/// Composite temperature in °C (kelvin minus 273).
const TEMP_WARN_C: i32 = 70;
const TEMP_CRIT_C: i32 = 85;
/// Critical Warning bits (NVMe base spec, SMART log byte 0): 0 spare below
/// threshold, 2 reliability degraded, 3 read-only, 4 volatile backup failed.
const CW_CRITICAL: u8 = 0b0001_1101;
/// Bit 1: temperature outside operating range.
const CW_WARNING: u8 = 0b0000_0010;
/// Bits 5 to 7 are not in the v1 table; set means "look at it".
const CW_UNLISTED: u8 = 0b1110_0000;
/// NVMe data unit: 1000 × 512 bytes.
const DATA_UNIT_BYTES: u128 = 512_000;

pub const DEFAULT_HISTORY_LIMIT: usize = 20;
pub const MAX_HISTORY_LIMIT: usize = 1000;

/// One line that pins every threshold of the current table. When this test
/// string must change, bump [`RULES_VERSION`] too.
pub fn rules_fingerprint() -> String {
    format!(
        "used:{USED_WARN},{USED_CRIT}|temp_c:{TEMP_WARN_C},{TEMP_CRIT_C}|cw:crit={CW_CRITICAL:#07b},warn={CW_WARNING:#04b},unlisted={CW_UNLISTED:#010b}|spare:lt=critical,eq=warning|media:>0=warning,rise=critical"
    )
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub enum Grade {
    Good,
    Warning,
    Critical,
}

impl Grade {
    pub fn as_str(self) -> &'static str {
        match self {
            Grade::Good => "good",
            Grade::Warning => "warning",
            Grade::Critical => "critical",
        }
    }

    pub fn parse(s: &str) -> Option<Grade> {
        [Grade::Good, Grade::Warning, Grade::Critical]
            .into_iter()
            .find(|g| g.as_str() == s)
    }
}

/// Decoded NVMe SMART / Health log page (512 bytes, little endian).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SmartSnapshot {
    pub critical_warning: u8,
    pub temperature_kelvin: u16,
    pub available_spare: u8,
    pub available_spare_threshold: u8,
    pub percentage_used: u8,
    pub data_units_read: u128,
    pub data_units_written: u128,
    pub host_read_commands: u128,
    pub host_write_commands: u128,
    pub controller_busy_minutes: u128,
    pub power_cycles: u128,
    pub power_on_hours: u128,
    pub unsafe_shutdowns: u128,
    pub media_errors: u128,
    pub error_log_entries: u128,
}

impl SmartSnapshot {
    pub fn from_log_page(page: &[u8; 512]) -> Self {
        // Counters are 128-bit little endian from byte 32 on, 16 bytes each.
        let counter = |i: usize| {
            let o = 32 + i * 16;
            u128::from_le_bytes(page[o..o + 16].try_into().expect("16 bytes"))
        };
        SmartSnapshot {
            critical_warning: page[0],
            temperature_kelvin: u16::from_le_bytes([page[1], page[2]]),
            available_spare: page[3],
            available_spare_threshold: page[4],
            percentage_used: page[5],
            data_units_read: counter(0),
            data_units_written: counter(1),
            host_read_commands: counter(2),
            host_write_commands: counter(3),
            controller_busy_minutes: counter(4),
            power_cycles: counter(5),
            power_on_hours: counter(6),
            unsafe_shutdowns: counter(7),
            media_errors: counter(8),
            error_log_entries: counter(9),
        }
    }

    /// Composite temperature in °C, `None` when the device reports none (0 K).
    pub fn temperature_celsius(&self) -> Option<i32> {
        (self.temperature_kelvin != 0).then(|| i32::from(self.temperature_kelvin) - 273)
    }
}

/// One evaluated rule with the reason in words.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Check {
    pub rule: &'static str,
    pub grade: Grade,
    pub message: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Assessment {
    /// The worst grade of all checks.
    pub grade: Grade,
    pub checks: Vec<Check>,
}

/// Rule table v1. `previous` is the earlier measurement of the same device;
/// only the media-error rule needs it.
pub fn assess(current: &SmartSnapshot, previous: Option<&SmartSnapshot>) -> Assessment {
    let mut checks = Vec::new();
    let mut add = |rule, grade, message: String| {
        checks.push(Check {
            rule,
            grade,
            message,
        })
    };

    let cw = current.critical_warning;
    let (grade, message) = if cw & CW_CRITICAL != 0 {
        (
            Grade::Critical,
            format!(
                "critical warning bits {cw:#07b} include a critical bit (spare, reliability, read-only or volatile backup)"
            ),
        )
    } else if cw & (CW_WARNING | CW_UNLISTED) != 0 {
        (
            Grade::Warning,
            format!("critical warning bits {cw:#07b}: temperature or an unlisted bit"),
        )
    } else {
        (Grade::Good, "no critical warning bit set".to_owned())
    };
    add("critical_warning", grade, message);

    let (spare, threshold) = (current.available_spare, current.available_spare_threshold);
    let grade = match spare.cmp(&threshold) {
        std::cmp::Ordering::Less => Grade::Critical,
        std::cmp::Ordering::Equal => Grade::Warning,
        std::cmp::Ordering::Greater => Grade::Good,
    };
    add(
        "available_spare",
        grade,
        format!("available spare {spare} % against threshold {threshold} %"),
    );

    let used = current.percentage_used;
    let grade = if used >= USED_CRIT {
        Grade::Critical
    } else if used >= USED_WARN {
        Grade::Warning
    } else {
        Grade::Good
    };
    add(
        "percentage_used",
        grade,
        format!("{used} % of the rated endurance used"),
    );

    let errors = current.media_errors;
    let (grade, message) = match previous {
        Some(p) if errors > p.media_errors => (
            Grade::Critical,
            format!("media errors rose from {} to {errors}", p.media_errors),
        ),
        _ if errors > 0 => (
            Grade::Warning,
            format!("{errors} media errors, none new since the last measurement"),
        ),
        _ => (Grade::Good, "no media errors".to_owned()),
    };
    add("media_errors", grade, message);

    let (grade, message) = match current.temperature_celsius() {
        None => (Grade::Good, "temperature not reported".to_owned()),
        Some(c) if c >= TEMP_CRIT_C => (Grade::Critical, format!("{c} °C")),
        Some(c) if c >= TEMP_WARN_C => (Grade::Warning, format!("{c} °C")),
        Some(c) => (Grade::Good, format!("{c} °C")),
    };
    add("temperature", grade, message);

    let grade = checks.iter().map(|c| c.grade).max().unwrap_or(Grade::Good);
    Assessment { grade, checks }
}

/// One way in which a device got worse between two measurements (R31).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Degradation {
    pub kind: &'static str,
    pub message: String,
}

/// What got worse from `previous` to `current`; empty when nothing did. Both
/// are judged by the current rule table, so a rules change alone never
/// raises a notification. Plain growth of `percentage_used`, power-on hours
/// and unsafe shutdowns is not a deterioration by itself; a grade change is.
pub fn degradations(previous: &SmartSnapshot, current: &SmartSnapshot) -> Vec<Degradation> {
    let mut out = Vec::new();
    let (before, after) = (
        assess(previous, None).grade,
        assess(current, Some(previous)).grade,
    );
    if after > before {
        out.push(Degradation {
            kind: "grade",
            message: format!(
                "overall grade went from {} to {}",
                before.as_str(),
                after.as_str()
            ),
        });
    }
    let new_bits = current.critical_warning & !previous.critical_warning;
    if new_bits != 0 {
        out.push(Degradation {
            kind: "critical_warning",
            message: format!("new critical warning bits {new_bits:#07b}"),
        });
    }
    if current.available_spare < previous.available_spare {
        out.push(Degradation {
            kind: "available_spare",
            message: format!(
                "available spare fell from {} % to {} %",
                previous.available_spare, current.available_spare
            ),
        });
    }
    if current.media_errors > previous.media_errors {
        out.push(Degradation {
            kind: "media_errors",
            message: format!(
                "media errors rose from {} to {}",
                previous.media_errors, current.media_errors
            ),
        });
    }
    out
}

// ---- ports ----------------------------------------------------------------

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Location {
    Internal,
    External,
    Unknown,
}

impl Location {
    pub fn as_str(self) -> &'static str {
        match self {
            Location::Internal => "internal",
            Location::External => "external",
            Location::Unknown => "unknown",
        }
    }
}

/// Why the log page could not be read: failing stage and OS status code.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SmartReadError {
    pub stage: &'static str,
    pub code: i32,
}

/// What a platform adapter reports for one NVMe device. Never carries a serial number.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NvmeDevice {
    pub location: Location,
    pub model: Option<String>,
    pub firmware: Option<String>,
    pub smart: Result<[u8; 512], SmartReadError>,
}

pub trait NvmeSource {
    /// All SMART-capable NVMe devices, read-only. `Err` when the enumeration itself fails.
    fn devices(&self) -> Result<Vec<NvmeDevice>, Error>;
}

/// A stored measurement: the raw log page plus what was concluded from it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SmartSample {
    pub measured_at: i64,
    pub device_key: String,
    pub model: String,
    pub firmware: String,
    pub location: Location,
    pub rules_version: u32,
    pub grade: Grade,
    pub page: [u8; 512],
}

pub trait HistoryStore {
    fn latest(&self, device_key: &str) -> Result<Option<SmartSample>, Error>;
    fn record(&self, sample: &SmartSample) -> Result<(), Error>;
    /// Newest first; `device_key` `None` means every device.
    fn list(&self, device_key: Option<&str>, limit: usize) -> Result<Vec<SmartSample>, Error>;
}

/// Devices are told apart by `location:model`; two identical drives share a
/// key because the serial number is deliberately never read.
pub fn device_key(location: Location, model: Option<&str>) -> String {
    format!("{}:{}", location.as_str(), model.unwrap_or("unknown"))
}

// ---- time and measurement helpers shared by the storage commands ----------

/// `YYYY-MM-DDTHH:MM:SSZ` for a Unix time (proleptic Gregorian, UTC).
pub fn rfc3339(unix: i64) -> String {
    let (days, rem) = (unix.div_euclid(86_400), unix.rem_euclid(86_400));
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

/// A value with its unit, timestamp and quality (`measured` or `derived`).
pub fn measurement(value: impl Into<Value>, unit: &str, at: &str, quality: &str) -> Value {
    json!({"value": value.into(), "unit": unit, "at": at, "quality": quality})
}

/// u128 counters are saturated at `u64::MAX` for JSON.
fn sat(v: u128) -> u64 {
    u64::try_from(v).unwrap_or(u64::MAX)
}

fn metrics(s: &SmartSnapshot, at: &str) -> Value {
    let m = |v: u128, unit: &str| measurement(sat(v), unit, at, "measured");
    let bytes = |units: u128| {
        measurement(
            sat(units.saturating_mul(DATA_UNIT_BYTES)),
            "byte",
            at,
            "derived",
        )
    };
    json!({
        "critical_warning": measurement(s.critical_warning, "bitmask", at, "measured"),
        "temperature_kelvin": measurement(s.temperature_kelvin, "kelvin", at, "measured"),
        "temperature_celsius": s.temperature_celsius().map_or(Value::Null, |c| measurement(c, "celsius", at, "derived")),
        "available_spare": measurement(s.available_spare, "percent", at, "measured"),
        "available_spare_threshold": measurement(s.available_spare_threshold, "percent", at, "measured"),
        "percentage_used": measurement(s.percentage_used, "percent", at, "measured"),
        "data_read": bytes(s.data_units_read),
        "data_written": bytes(s.data_units_written),
        "host_read_commands": m(s.host_read_commands, "count"),
        "host_write_commands": m(s.host_write_commands, "count"),
        "controller_busy_time": m(s.controller_busy_minutes, "minute"),
        "power_cycles": m(s.power_cycles, "count"),
        "power_on_hours": m(s.power_on_hours, "hour"),
        "unsafe_shutdowns": m(s.unsafe_shutdowns, "count"),
        "media_errors": m(s.media_errors, "count"),
        "error_log_entries": m(s.error_log_entries, "count"),
    })
}

fn checks_json(a: &Assessment) -> Value {
    a.checks
        .iter()
        .map(|c| json!({"rule": c.rule, "grade": c.grade.as_str(), "message": c.message}))
        .collect()
}

// ---- commands ---------------------------------------------------------------

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HealthParams {
    /// Append the measurement to the history (CLI default; MCP passes `false`).
    pub record: bool,
}

impl Default for HealthParams {
    fn default() -> Self {
        HealthParams { record: true }
    }
}

impl HealthParams {
    /// Arguments after `storage health`: `[--no-record] [--json]`.
    pub fn parse_cli(args: &[String]) -> Result<Self, Error> {
        let mut p = HealthParams::default();
        for a in args {
            match a.as_str() {
                "--no-record" => p.record = false,
                "--json" => {}
                other => {
                    return Err(Error::Usage(format!(
                        "storage health: unknown argument '{other}'"
                    )));
                }
            }
        }
        Ok(p)
    }
}

/// `storage health`: read every NVMe device, grade it and (optionally) record it.
pub fn health_json(
    nvme: &dyn NvmeSource,
    clock: &dyn Clock,
    history: Option<&dyn HistoryStore>,
    params: &HealthParams,
) -> Result<Value, Error> {
    let mut devices = nvme.devices()?;
    if devices.is_empty() {
        return Err(Error::Unsupported(
            "no SMART-capable NVMe device found".into(),
        ));
    }
    devices.sort_by_key(|d| (d.location.as_str(), d.model.clone(), d.firmware.clone()));
    let now = clock.now();
    let at = rfc3339(now);
    let mut overall: Option<Grade> = None;
    let mut out = Vec::new();
    for d in &devices {
        let key = device_key(d.location, d.model.as_deref());
        let mut dev = Map::new();
        dev.insert("key".into(), key.clone().into());
        dev.insert("model".into(), d.model.clone().into());
        dev.insert("firmware".into(), d.firmware.clone().into());
        dev.insert("location".into(), d.location.as_str().into());
        dev.insert("protocol".into(), "nvme".into());
        match &d.smart {
            Err(e) => {
                dev.insert("access".into(), json!({"status": "error", "stage": e.stage, "code": format!("{:#010x}", e.code as u32)}));
                dev.insert("grade".into(), "unknown".into());
                dev.insert("checks".into(), json!([]));
                dev.insert("metrics".into(), Value::Null);
                dev.insert(
                    "history".into(),
                    json!({"status": "skipped", "detail": null}),
                );
            }
            Ok(page) => {
                let snap = SmartSnapshot::from_log_page(page);
                let (previous, mut hist) = match history {
                    None => (None, json!({"status": "skipped", "detail": null})),
                    Some(h) => match h.latest(&key) {
                        Ok(p) => (p, json!({"status": "skipped", "detail": null})),
                        Err(e) => (None, json!({"status": "error", "detail": e.to_string()})),
                    },
                };
                let previous_snap = previous
                    .as_ref()
                    .map(|s| SmartSnapshot::from_log_page(&s.page));
                let a = assess(&snap, previous_snap.as_ref());
                overall = overall.max(Some(a.grade));
                if let (true, Some(h)) = (params.record, history) {
                    let sample = SmartSample {
                        measured_at: now,
                        device_key: key.clone(),
                        model: d.model.clone().unwrap_or_default(),
                        firmware: d.firmware.clone().unwrap_or_default(),
                        location: d.location,
                        rules_version: RULES_VERSION,
                        grade: a.grade,
                        page: *page,
                    };
                    hist = match h.record(&sample) {
                        Ok(()) => json!({"status": "recorded", "detail": null}),
                        Err(e) => json!({"status": "error", "detail": e.to_string()}),
                    };
                }
                dev.insert(
                    "access".into(),
                    json!({"status": "ok", "stage": null, "code": null}),
                );
                dev.insert("grade".into(), a.grade.as_str().into());
                dev.insert("checks".into(), checks_json(&a));
                dev.insert("metrics".into(), metrics(&snap, &at));
                dev.insert("history".into(), hist);
            }
        }
        out.push(Value::Object(dev));
    }
    Ok(json!({
        "schema": 1,
        "rules_version": RULES_VERSION,
        "measured_at": at,
        "overall_grade": overall.map_or("unknown", Grade::as_str),
        "devices": out,
    }))
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HistoryParams {
    pub limit: usize,
    pub device: Option<String>,
}

impl Default for HistoryParams {
    fn default() -> Self {
        HistoryParams {
            limit: DEFAULT_HISTORY_LIMIT,
            device: None,
        }
    }
}

pub(crate) fn bounded(name: &str, v: u64, min: u64, max: u64) -> Result<usize, Error> {
    if (min..=max).contains(&v) {
        Ok(v as usize)
    } else {
        Err(Error::Usage(format!(
            "{name} must be between {min} and {max}"
        )))
    }
}

pub(crate) fn number(name: &str, text: &str) -> Result<u64, Error> {
    text.parse()
        .map_err(|_| Error::Usage(format!("{name} needs a whole number, got '{text}'")))
}

impl HistoryParams {
    /// Arguments after `storage health history`: `[--limit N] [--device KEY] [--json]`.
    pub fn parse_cli(args: &[String]) -> Result<Self, Error> {
        let mut p = HistoryParams::default();
        let mut it = args.iter();
        while let Some(a) = it.next() {
            let mut value = || {
                it.next()
                    .ok_or_else(|| Error::Usage(format!("{a} needs a value")))
            };
            match a.as_str() {
                "--limit" => {
                    p.limit = bounded(
                        "--limit",
                        number("--limit", value()?)?,
                        1,
                        MAX_HISTORY_LIMIT as u64,
                    )?
                }
                "--device" => p.device = Some(value()?.clone()),
                "--json" => {}
                other => {
                    return Err(Error::Usage(format!(
                        "storage health history: unknown argument '{other}'"
                    )));
                }
            }
        }
        Ok(p)
    }

    /// MCP arguments of `get_storage_health_history`.
    pub fn from_json(args: &Value) -> Result<Self, Error> {
        let mut p = HistoryParams::default();
        if let Some(v) = args.get("limit") {
            let n = v
                .as_u64()
                .ok_or_else(|| Error::Usage("limit must be a whole number".into()))?;
            p.limit = bounded("limit", n, 1, MAX_HISTORY_LIMIT as u64)?;
        }
        if let Some(v) = args.get("device") {
            p.device = Some(
                v.as_str()
                    .ok_or_else(|| Error::Usage("device must be a string".into()))?
                    .to_owned(),
            );
        }
        Ok(p)
    }
}

/// `storage health history`: stored measurements, newest first, with what got
/// worse since the next older measurement of the same device inside the window.
pub fn health_history_json(
    history: &dyn HistoryStore,
    params: &HistoryParams,
) -> Result<Value, Error> {
    let samples = history.list(params.device.as_deref(), params.limit)?;
    let rows: Vec<Value> = samples
        .iter()
        .enumerate()
        .map(|(i, s)| {
            let snap = SmartSnapshot::from_log_page(&s.page);
            let older = samples[i + 1..]
                .iter()
                .find(|o| o.device_key == s.device_key);
            let changes = older.map_or(Value::Null, |o| {
                degradations(&SmartSnapshot::from_log_page(&o.page), &snap)
                    .iter()
                    .map(|d| json!({"kind": d.kind, "message": d.message}))
                    .collect()
            });
            json!({
                "measured_at": rfc3339(s.measured_at),
                "device_key": s.device_key,
                "model": s.model,
                "firmware": s.firmware,
                "location": s.location.as_str(),
                "rules_version": s.rules_version,
                "grade": s.grade.as_str(),
                "temperature_celsius": snap.temperature_celsius(),
                "available_spare_percent": snap.available_spare,
                "percentage_used": snap.percentage_used,
                "media_errors": sat(snap.media_errors),
                "changes": changes,
            })
        })
        .collect();
    Ok(json!({"schema": 1, "rules_version": RULES_VERSION, "samples": rows}))
}

/// Human-readable form of [`health_json`].
pub fn render_health(v: &Value) -> String {
    let mut s = format!(
        "Storage health (rules v{}), overall {}\n",
        v["rules_version"],
        v["overall_grade"].as_str().unwrap_or("?")
    );
    for d in v["devices"].as_array().into_iter().flatten() {
        let _ = writeln!(
            s,
            "{} [{}] {}",
            d["key"].as_str().unwrap_or("?"),
            d["location"].as_str().unwrap_or("?"),
            d["grade"].as_str().unwrap_or("?")
        );
        match d["access"]["status"].as_str() {
            Some("ok") => {
                for c in d["checks"].as_array().into_iter().flatten() {
                    let _ = writeln!(
                        s,
                        "  {:<18} {:<8} {}",
                        c["rule"].as_str().unwrap_or("?"),
                        c["grade"].as_str().unwrap_or("?"),
                        c["message"].as_str().unwrap_or("")
                    );
                }
            }
            _ => {
                let _ = writeln!(
                    s,
                    "  not readable at {} (code {})",
                    d["access"]["stage"].as_str().unwrap_or("?"),
                    d["access"]["code"].as_str().unwrap_or("?")
                );
            }
        }
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    fn page(f: impl FnOnce(&mut [u8; 512])) -> [u8; 512] {
        let mut p = [0u8; 512];
        p[1..3].copy_from_slice(&310u16.to_le_bytes());
        p[3] = 100;
        p[4] = 10;
        f(&mut p);
        p
    }

    fn snap(f: impl FnOnce(&mut [u8; 512])) -> SmartSnapshot {
        SmartSnapshot::from_log_page(&page(f))
    }

    fn grade(s: &SmartSnapshot) -> Grade {
        assess(s, None).grade
    }

    #[test]
    fn decodes_offsets_and_128_bit_counters() {
        let s = snap(|p| {
            p[0] = 4;
            p[5] = 7;
            p[32..40].copy_from_slice(&5u64.to_le_bytes());
            p[40..48].copy_from_slice(&1u64.to_le_bytes());
            p[160..168].copy_from_slice(&9u64.to_le_bytes());
            p[176..184].copy_from_slice(&3u64.to_le_bytes());
        });
        assert_eq!(
            (
                s.critical_warning,
                s.temperature_kelvin,
                s.available_spare,
                s.available_spare_threshold,
                s.percentage_used
            ),
            (4, 310, 100, 10, 7)
        );
        assert_eq!(s.data_units_read, (1u128 << 64) | 5);
        assert_eq!((s.media_errors, s.error_log_entries), (9, 3));
        assert_eq!(s.temperature_celsius(), Some(37));
    }

    #[test]
    fn rules_version_and_thresholds_are_pinned() {
        // Changing any threshold changes this string: bump RULES_VERSION with it.
        assert_eq!(RULES_VERSION, 1);
        assert_eq!(
            rules_fingerprint(),
            "used:80,100|temp_c:70,85|cw:crit=0b11101,warn=0b10,unlisted=0b11100000|spare:lt=critical,eq=warning|media:>0=warning,rise=critical"
        );
    }

    #[test]
    fn healthy_device_is_good_with_five_checks() {
        let a = assess(&snap(|_| {}), None);
        assert_eq!(a.grade, Grade::Good);
        assert_eq!(a.checks.len(), 5);
    }

    #[test]
    fn critical_warning_bits() {
        for bit in [0, 2, 3, 4] {
            assert_eq!(
                grade(&snap(|p| p[0] = 1 << bit)),
                Grade::Critical,
                "bit {bit}"
            );
        }
        for bit in [1, 5, 6, 7] {
            assert_eq!(
                grade(&snap(|p| p[0] = 1 << bit)),
                Grade::Warning,
                "bit {bit}"
            );
        }
    }

    #[test]
    fn available_spare_against_threshold_including_apple_99() {
        // Apple reports threshold 99 at spare 100: good, not a permanent warning.
        let apple = |spare| {
            snap(|p| {
                p[3] = spare;
                p[4] = 99;
            })
        };
        assert_eq!(grade(&apple(100)), Grade::Good);
        assert_eq!(grade(&apple(99)), Grade::Warning);
        assert_eq!(grade(&apple(98)), Grade::Critical);
    }

    #[test]
    fn percentage_used_boundaries() {
        let used = |u| grade(&snap(|p| p[5] = u));
        assert_eq!(
            (used(79), used(80), used(99), used(100), used(255)),
            (
                Grade::Good,
                Grade::Warning,
                Grade::Warning,
                Grade::Critical,
                Grade::Critical
            )
        );
    }

    #[test]
    fn temperature_boundaries_in_celsius() {
        let t = |c: u16| grade(&snap(|p| p[1..3].copy_from_slice(&(c + 273).to_le_bytes())));
        assert_eq!(
            (t(69), t(70), t(84), t(85)),
            (Grade::Good, Grade::Warning, Grade::Warning, Grade::Critical)
        );
        assert_eq!(
            grade(&snap(|p| p[1..3].copy_from_slice(&0u16.to_le_bytes()))),
            Grade::Good
        );
    }

    #[test]
    fn media_errors_warn_alone_and_are_critical_when_rising() {
        let with = |n: u64| snap(|p| p[160..168].copy_from_slice(&n.to_le_bytes()));
        assert_eq!(grade(&with(0)), Grade::Good);
        assert_eq!(grade(&with(2)), Grade::Warning);
        assert_eq!(assess(&with(2), Some(&with(2))).grade, Grade::Warning);
        assert_eq!(assess(&with(3), Some(&with(2))).grade, Grade::Critical);
        // A counter that went down (replaced device) is not a rise.
        assert_eq!(assess(&with(1), Some(&with(2))).grade, Grade::Warning);
    }

    #[test]
    fn overall_is_the_worst_single_check() {
        let s = snap(|p| {
            p[5] = 85;
            p[0] = 1 << 3;
        });
        let a = assess(&s, None);
        assert_eq!(a.grade, Grade::Critical);
        assert!(a.checks.iter().any(|c| c.grade == Grade::Warning));
    }

    #[test]
    fn degradation_is_a_pure_comparison_of_two_measurements() {
        let base = snap(|_| {});
        assert!(degradations(&base, &base).is_empty());
        // Wear and uptime growing is not a deterioration.
        assert!(
            degradations(
                &base,
                &snap(|p| {
                    p[5] = 3;
                    p[128] = 9;
                    p[144] = 2;
                })
            )
            .is_empty()
        );
        let kinds = |a: &SmartSnapshot, b: &SmartSnapshot| {
            degradations(a, b)
                .iter()
                .map(|d| d.kind)
                .collect::<Vec<_>>()
        };
        assert_eq!(kinds(&base, &snap(|p| p[5] = 80)), ["grade"]);
        assert_eq!(kinds(&base, &snap(|p| p[3] = 90)), ["available_spare"]);
        assert_eq!(
            kinds(&base, &snap(|p| p[160] = 1)),
            ["grade", "media_errors"]
        );
        assert_eq!(
            kinds(&base, &snap(|p| p[0] = 1 << 1)),
            ["grade", "critical_warning"]
        );
        // An improvement reports nothing.
        assert!(degradations(&snap(|p| p[5] = 90), &base).is_empty());
    }

    #[test]
    fn rfc3339_known_instants() {
        assert_eq!(rfc3339(0), "1970-01-01T00:00:00Z");
        assert_eq!(rfc3339(1_700_000_000), "2023-11-14T22:13:20Z");
        assert_eq!(rfc3339(951_782_400), "2000-02-29T00:00:00Z");
        assert_eq!(rfc3339(-1), "1969-12-31T23:59:59Z");
    }

    #[test]
    fn cli_parsing() {
        let a = |v: &[&str]| v.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
        assert!(
            !HealthParams::parse_cli(&a(&["--no-record", "--json"]))
                .unwrap()
                .record
        );
        assert_eq!(
            HistoryParams::parse_cli(&a(&["--limit", "5", "--device", "internal:X"])).unwrap(),
            HistoryParams {
                limit: 5,
                device: Some("internal:X".into())
            }
        );
        for bad in [
            &["--limit", "0"][..],
            &["--limit", "x"],
            &["--limit"],
            &["--bogus"],
        ] {
            assert_eq!(
                HistoryParams::parse_cli(&a(bad)).unwrap_err().exit_code(),
                2
            );
        }
        assert_eq!(
            HistoryParams::from_json(&json!({"limit": 1001}))
                .unwrap_err()
                .exit_code(),
            2
        );
    }
}
