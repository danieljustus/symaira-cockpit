//! Battery report (`battery`, MCP `get_battery`).
//!
//! Port of `BatteryService`, `BatterySource` and `BatteryHealthParser` from
//! `tuning/Sources/SymCockpitCore`. The platform reads sit behind ports; the
//! JSON matches Swift v0.12 key for key (snake_case, nil optionals omitted).
//!
//! Not ported: the `IOPowerSources` fallback of `HardwareBatterySource`. Its
//! symbols are not exported on macOS 27 (see `HardwareBatterySourceTests`), so
//! it only ever produced `Unavailable` there. A Mac without the registry node
//! reports "no battery" the same way.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::Value;
use symcockpit_contract::Error;

/// Raw properties of the `AppleSmartBattery` node. Every key can be absent.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BatteryProperties {
    pub is_charging: Option<bool>,
    pub external_connected: Option<bool>,
    /// Design capacity in mAh.
    pub design_capacity: Option<i64>,
    /// Full-charge capacity in mAh.
    pub raw_max_capacity: Option<i64>,
    /// Present charge in mAh.
    pub raw_current_capacity: Option<i64>,
    /// State of charge where the hardware reports a percentage directly.
    pub charge_percent: Option<i64>,
    pub cycle_count: Option<i64>,
    /// Temperature in centidegrees Celsius.
    pub temperature_centidegrees: Option<i64>,
    /// `PowerTelemetryData.SystemLoad` in milliwatts; also valid on battery.
    pub system_load_milliwatts: Option<i64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BatterySourceResult {
    /// No `AppleSmartBattery` node (a desktop Mac).
    Unavailable,
    /// The node exists but its properties could not be read.
    ReadFailed,
    Success(BatteryProperties),
}

/// Port: reads the `AppleSmartBattery` registry node.
pub trait BatterySource {
    fn read_properties(&self) -> BatterySourceResult;
}

/// Port: whether the SMC exposes a charge-limit key (CHTE/CH0B/CHLC). The
/// probe belongs to the SMC area; the coordinator wires it live.
pub trait ChargeLimitProbe {
    fn is_supported(&self) -> bool;
}

/// Apple's own figures from `system_profiler SPPowerDataType`.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct AppleBatteryHealth {
    pub maximum_capacity_percent: Option<i64>,
    pub condition: Option<String>,
}

/// Port: supplies [`AppleBatteryHealth`]; the live provider caches (see
/// [`CachedAppleHealth`]) because `system_profiler` takes seconds.
pub trait AppleHealthProvider {
    fn read_apple_health(&self) -> AppleBatteryHealth;
}

/// The battery report, serialised exactly like Swift's `BatteryReport`.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct BatteryReport {
    pub present: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub charging: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub external_connected: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub current_capacity_percent: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cycle_count: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub design_capacity_mah: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_capacity_mah: Option<i64>,
    /// `max / design` in percent.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub health_percent: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temperature_celsius: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub apple_maximum_capacity_percent: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub apple_condition: Option<String>,
    pub charge_limit_supported: bool,
    pub notes: Vec<String>,
}

impl BatteryReport {
    fn empty(present: bool, note: &str) -> Self {
        BatteryReport {
            present,
            charging: None,
            external_connected: None,
            current_capacity_percent: None,
            cycle_count: None,
            design_capacity_mah: None,
            max_capacity_mah: None,
            health_percent: None,
            temperature_celsius: None,
            apple_maximum_capacity_percent: None,
            apple_condition: None,
            charge_limit_supported: false,
            notes: vec![note.to_string()],
        }
    }
}

/// `BatteryService.read()`. `apple` is `None` for injected fakes, as in Swift
/// (`appleHealthProvider: batterySource == nil ? shared : nil`).
pub fn read_battery(
    source: &dyn BatterySource,
    charge_limit: &dyn ChargeLimitProbe,
    apple: Option<&dyn AppleHealthProvider>,
) -> BatteryReport {
    let props = match source.read_properties() {
        BatterySourceResult::Unavailable => {
            return BatteryReport::empty(
                false,
                "No AppleSmartBattery node — likely a desktop Mac.",
            );
        }
        BatterySourceResult::ReadFailed => {
            return BatteryReport::empty(true, "Failed to read AppleSmartBattery properties.");
        }
        BatterySourceResult::Success(props) => props,
    };

    let health = match (props.design_capacity, props.raw_max_capacity) {
        (Some(design), Some(max)) if design > 0 => Some(rounded_percent(max, design)),
        _ => None,
    };

    let percent = charge_percent(&props);

    let apple_health = apple.map(|provider| provider.read_apple_health());
    let charge_limit_supported = charge_limit.is_supported();
    let mut notes = vec![
        "Read from raw AppleSmartBattery keys; interpretation can vary by Mac model.".to_string(),
    ];
    if !charge_limit_supported {
        notes.push("Charge-limit SMC key not detected on this Mac.".to_string());
    }

    BatteryReport {
        present: true,
        charging: props.is_charging,
        external_connected: props.external_connected,
        current_capacity_percent: percent,
        cycle_count: props.cycle_count,
        design_capacity_mah: props.design_capacity,
        max_capacity_mah: props.raw_max_capacity,
        health_percent: health,
        temperature_celsius: props.temperature_centidegrees.map(|raw| raw as f64 / 100.0),
        apple_maximum_capacity_percent: apple_health
            .as_ref()
            .and_then(|h| h.maximum_capacity_percent),
        apple_condition: apple_health.and_then(|h| h.condition),
        charge_limit_supported,
        notes,
    }
}

/// The state of charge. A percentage straight from the hardware wins over the mAh pair: on
/// Apple Silicon 5466/5701 ≈ 96 % for a battery macOS calls 100 % charged.
pub fn charge_percent(props: &BatteryProperties) -> Option<i64> {
    props.charge_percent.map(|p| p.clamp(0, 100)).or_else(|| {
        match (props.raw_max_capacity, props.raw_current_capacity) {
            (Some(max), Some(current)) if max > 0 => {
                Some(rounded_percent(current, max).clamp(0, 100))
            }
            _ => None,
        }
    })
}

/// `Int((Double(a) / Double(b) * 100).rounded())`; `f64::round` rounds half
/// away from zero like Swift's `.rounded()`.
fn rounded_percent(a: i64, b: i64) -> i64 {
    (a as f64 / b as f64 * 100.0).round() as i64
}

/// CLI `battery --json` and MCP `get_battery`: both print this value.
pub fn battery_json(
    source: &dyn BatterySource,
    charge_limit: &dyn ChargeLimitProbe,
    apple: Option<&dyn AppleHealthProvider>,
) -> Result<Value, Error> {
    serde_json::to_value(read_battery(source, charge_limit, apple))
        .map_err(|e| Error::Failed(format!("Failed to encode battery report: {e}")))
}

/// Output of `battery --help` / `-h` (frozen by oracle case `battery-help`).
pub const BATTERY_HELP: &str = "Usage: symcockpit battery [--json]\n\nBattery health: charge %, cycles, capacity, condition (JSON).\n--json is accepted for consistency with other read commands; it is a no-op here.\n";

/// `HardwareBatterySource.properties(fromRegistry:)`: maps one
/// `AppleSmartBattery` property dictionary (as JSON) onto [`BatteryProperties`].
///
/// Intel reports `MaxCapacity`/`CurrentCapacity` in mAh and also `AppleRaw*`.
/// Apple Silicon reports those two as percentages and keeps the mAh figures in
/// `BatteryData` (#232).
pub fn properties_from_registry(props: &Value) -> BatteryProperties {
    let int = |v: Option<&Value>| v.and_then(Value::as_i64);
    let flag = |v: Option<&Value>| v.and_then(Value::as_bool);
    let battery_data = props.get("BatteryData");
    let in_data = |key: &str| int(battery_data.and_then(|d| d.get(key)));

    let design_capacity = int(props.get("DesignCapacity")).or_else(|| in_data("DesignCapacity"));
    let top_max = int(props.get("MaxCapacity"));
    // A full-charge capacity of at most 100 next to a design capacity in the
    // thousands is a percentage, not a milliamp-hour reading.
    let top_is_percentage = top_max.is_some_and(|m| m <= 100 && design_capacity.unwrap_or(0) > 100);
    let top_current = int(props.get("CurrentCapacity"));

    BatteryProperties {
        is_charging: flag(props.get("IsCharging")),
        external_connected: flag(props.get("ExternalConnected")),
        design_capacity,
        raw_max_capacity: int(props.get("AppleRawMaxCapacity"))
            .or_else(|| in_data("NominalChargeCapacity"))
            .or(if top_is_percentage { None } else { top_max }),
        raw_current_capacity: int(props.get("AppleRawCurrentCapacity"))
            .or_else(|| in_data("RemainingCapacity"))
            .or(if top_is_percentage { None } else { top_current }),
        charge_percent: if top_is_percentage { top_current } else { None },
        cycle_count: int(props.get("CycleCount")),
        temperature_centidegrees: int(props.get("Temperature")),
        system_load_milliwatts: int(props
            .get("PowerTelemetryData")
            .and_then(|t| t.get("SystemLoad"))),
    }
}

/// Swift's `CharacterSet.whitespaces`: tab and the Unicode `Zs` category. It
/// matters: `system_profiler` prints `88\u{a0}%` (no-break space) on macOS 27.
fn is_swift_whitespace(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200a}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
    )
}

/// `BatteryHealthParser.parse`: the first `Condition:` and `Maximum Capacity:`
/// lines of `system_profiler SPPowerDataType` (run with an English locale).
/// Unparseable input yields `None` fields, never guesses.
pub fn parse_apple_health(output: &str) -> AppleBatteryHealth {
    let mut health = AppleBatteryHealth::default();
    for raw in output.split('\n') {
        let line = raw.trim_matches(is_swift_whitespace);
        if let Some(rest) = line.strip_prefix("Condition:") {
            let value = rest.trim_matches(is_swift_whitespace);
            if health.condition.is_none() && !value.is_empty() {
                health.condition = Some(value.to_string());
            }
        } else if let Some(rest) = line.strip_prefix("Maximum Capacity:")
            && health.maximum_capacity_percent.is_none()
        {
            // Some localizations emit "97 %" with a space before the sign.
            let cleaned = rest.trim_matches(is_swift_whitespace).replace('%', "");
            health.maximum_capacity_percent = cleaned
                .trim_matches(is_swift_whitespace)
                .parse::<i64>()
                .ok();
        }
    }
    health
}

/// TTL cache around a (slow) health reader, mirroring
/// `SystemProfilerBatteryHealthProvider`: one run per `ttl`, process-wide when
/// the adapter keeps a single instance.
pub struct CachedAppleHealth<F: Fn() -> AppleBatteryHealth> {
    ttl: Duration,
    runner: F,
    cached: Mutex<Option<(Instant, AppleBatteryHealth)>>,
}

impl<F: Fn() -> AppleBatteryHealth> CachedAppleHealth<F> {
    pub fn new(ttl: Duration, runner: F) -> Self {
        CachedAppleHealth {
            ttl,
            runner,
            cached: Mutex::new(None),
        }
    }
}

impl<F: Fn() -> AppleBatteryHealth> AppleHealthProvider for CachedAppleHealth<F> {
    fn read_apple_health(&self) -> AppleBatteryHealth {
        // Held across the runner on purpose: concurrent callers wait for the
        // one subprocess instead of starting more (Swift does the same).
        let mut guard = self.cached.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((at, health)) = guard.as_ref()
            && at.elapsed() < self.ttl
        {
            return health.clone();
        }
        let health = (self.runner)();
        *guard = Some((Instant::now(), health.clone()));
        health
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::cell::Cell;

    struct Fixed(BatterySourceResult);
    impl BatterySource for Fixed {
        fn read_properties(&self) -> BatterySourceResult {
            self.0.clone()
        }
    }
    struct Limit(bool);
    impl ChargeLimitProbe for Limit {
        fn is_supported(&self) -> bool {
            self.0
        }
    }
    struct Apple(AppleBatteryHealth);
    impl AppleHealthProvider for Apple {
        fn read_apple_health(&self) -> AppleBatteryHealth {
            self.0.clone()
        }
    }

    fn read(props: BatteryProperties) -> BatteryReport {
        read_battery(
            &Fixed(BatterySourceResult::Success(props)),
            &Limit(false),
            None,
        )
    }

    // Vectors: BatteryServiceTests.swift.
    #[test]
    fn unavailable_is_a_desktop_report() {
        let r = read_battery(&Fixed(BatterySourceResult::Unavailable), &Limit(true), None);
        assert!(!r.present);
        assert_eq!(
            r.notes,
            ["No AppleSmartBattery node — likely a desktop Mac."]
        );
        assert!(!r.charge_limit_supported);
        assert_eq!(
            battery_json(&Fixed(BatterySourceResult::Unavailable), &Limit(true), None).unwrap(),
            json!({"present": false, "charge_limit_supported": false,
                   "notes": ["No AppleSmartBattery node — likely a desktop Mac."]})
        );
    }

    #[test]
    fn read_failed_is_present_but_empty() {
        let r = read_battery(&Fixed(BatterySourceResult::ReadFailed), &Limit(true), None);
        assert!(r.present);
        assert_eq!(r.notes, ["Failed to read AppleSmartBattery properties."]);
        assert!(r.current_capacity_percent.is_none() && r.health_percent.is_none());
    }

    #[test]
    fn partial_data_omits_health() {
        let r = read(BatteryProperties {
            is_charging: Some(true),
            external_connected: Some(true),
            raw_max_capacity: Some(8000),
            raw_current_capacity: Some(4000),
            temperature_centidegrees: Some(2500),
            ..Default::default()
        });
        assert_eq!(r.current_capacity_percent, Some(50));
        assert_eq!(r.health_percent, None);
        assert_eq!(r.max_capacity_mah, Some(8000));
        assert_eq!(r.temperature_celsius, Some(25.0));
    }

    #[test]
    fn full_data_computes_health_and_percent() {
        let r = read(BatteryProperties {
            is_charging: Some(false),
            external_connected: Some(false),
            design_capacity: Some(10000),
            raw_max_capacity: Some(9000),
            raw_current_capacity: Some(4500),
            cycle_count: Some(42),
            temperature_centidegrees: Some(3000),
            ..Default::default()
        });
        assert_eq!(
            (
                r.current_capacity_percent,
                r.cycle_count,
                r.health_percent,
                r.temperature_celsius
            ),
            (Some(50), Some(42), Some(90), Some(30.0))
        );
    }

    #[test]
    fn capacity_percent_is_clamped_to_100() {
        let r = read(BatteryProperties {
            raw_max_capacity: Some(100),
            raw_current_capacity: Some(999),
            ..Default::default()
        });
        assert_eq!(r.current_capacity_percent, Some(100));
    }

    #[test]
    fn charge_limit_probe_drives_flag_and_note() {
        let props = BatteryProperties {
            is_charging: Some(true),
            external_connected: Some(true),
            ..Default::default()
        };
        let src = Fixed(BatterySourceResult::Success(props));
        let yes = read_battery(&src, &Limit(true), None);
        assert!(yes.charge_limit_supported);
        assert_eq!(yes.notes.len(), 1);
        let no = read_battery(&src, &Limit(false), None);
        assert!(!no.charge_limit_supported);
        assert!(
            no.notes
                .contains(&"Charge-limit SMC key not detected on this Mac.".to_string())
        );
    }

    #[test]
    fn hardware_percentage_wins_over_the_mah_pair() {
        // Registry vector: appleSiliconRegistry() in HardwareBatterySourceTests.swift.
        let props = properties_from_registry(&json!({
            "IsCharging": false, "ExternalConnected": true, "CurrentCapacity": 100,
            "MaxCapacity": 100, "CycleCount": 136,
            "BatteryData": {"DesignCapacity": 6249, "NominalChargeCapacity": 5701,
                "FullChargeCapacity": 5549, "RemainingCapacity": 5466,
                "MaxCapacity": 100, "CurrentCapacity": 100}
        }));
        assert_eq!(props.design_capacity, Some(6249));
        assert_eq!(props.raw_max_capacity, Some(5701));
        assert_eq!(props.raw_current_capacity, Some(5466));
        assert_eq!(props.charge_percent, Some(100));
        let r = read(props);
        assert_eq!(
            (
                r.max_capacity_mah,
                r.design_capacity_mah,
                r.health_percent,
                r.current_capacity_percent
            ),
            (Some(5701), Some(6249), Some(91), Some(100))
        );
    }

    #[test]
    fn intel_registry_keeps_top_level_mah_keys() {
        let props = properties_from_registry(&json!({
            "IsCharging": true, "ExternalConnected": true, "DesignCapacity": 8790,
            "MaxCapacity": 8100, "CurrentCapacity": 6400, "AppleRawMaxCapacity": 8060,
            "AppleRawCurrentCapacity": 6380, "CycleCount": 310, "Temperature": 3021
        }));
        assert_eq!(props.design_capacity, Some(8790));
        assert_eq!(props.raw_max_capacity, Some(8060));
        assert_eq!(props.raw_current_capacity, Some(6380));
        assert_eq!(props.temperature_centidegrees, Some(3021));
        assert_eq!(props.charge_percent, None);
    }

    // Vectors: SystemPowerTests.swift (registry mapping).
    #[test]
    fn registry_exposes_system_load_from_power_telemetry() {
        let p = properties_from_registry(&json!({
            "ExternalConnected": true,
            "PowerTelemetryData": {"SystemLoad": 19233, "SystemPowerIn": 36515}
        }));
        assert_eq!(p.system_load_milliwatts, Some(19233));
        assert_eq!(
            properties_from_registry(&json!({"ExternalConnected": true})).system_load_milliwatts,
            None
        );
        assert_eq!(
            properties_from_registry(&json!({"PowerTelemetryData": {"SystemPowerIn": 1}}))
                .system_load_milliwatts,
            None
        );
    }

    // Vectors: BatteryHealthParserTests.swift.
    #[test]
    fn parses_system_profiler_output() {
        let out = "Power:\n\n    Battery Information:\n\n      Health Information:\n          Cycle Count: 120\n          Condition: Normal\n          Maximum Capacity: 97 %\n\n    System Power Settings:\n";
        let h = parse_apple_health(out);
        assert_eq!(
            (h.maximum_capacity_percent, h.condition.as_deref()),
            (Some(97), Some("Normal"))
        );
        let h = parse_apple_health(
            "Health Information:\n    Cycle Count: 10\n    Condition: Normal\n    Maximum Capacity: 89%",
        );
        assert_eq!(
            (h.maximum_capacity_percent, h.condition.as_deref()),
            (Some(89), Some("Normal"))
        );
        let h = parse_apple_health("Health Information:\n    Condition: Service Battery\n");
        assert_eq!(
            (h.maximum_capacity_percent, h.condition.as_deref()),
            (None, Some("Service Battery"))
        );
    }

    #[test]
    fn no_break_space_before_the_percent_sign_is_whitespace() {
        // Seen live on macOS 27: "Maximum Capacity: 88<U+00A0>%".
        let h = parse_apple_health("  Condition: Normal\n  Maximum Capacity: 88\u{a0}%\n");
        assert_eq!(h.maximum_capacity_percent, Some(88));
    }

    #[test]
    fn malformed_and_empty_input_give_none() {
        let garbage = "random binary noise\nCondition:\nMaximum Capacity: not-a-number\nMaximum Capacity: %\nMaximum Capacity: 12x";
        assert_eq!(parse_apple_health(garbage), AppleBatteryHealth::default());
        assert_eq!(
            parse_apple_health("Power:\n    UPS Installed: No\n"),
            AppleBatteryHealth::default()
        );
        assert_eq!(parse_apple_health(""), AppleBatteryHealth::default());
    }

    #[test]
    fn apple_fields_follow_the_provider_and_are_omitted_without_one() {
        let props = BatteryProperties {
            design_capacity: Some(10000),
            raw_max_capacity: Some(9000),
            ..Default::default()
        };
        let src = Fixed(BatterySourceResult::Success(props));
        let apple = Apple(AppleBatteryHealth {
            maximum_capacity_percent: Some(97),
            condition: Some("Normal".into()),
        });
        let with = battery_json(&src, &Limit(false), Some(&apple)).unwrap();
        assert_eq!(with["apple_maximum_capacity_percent"], 97);
        assert_eq!(with["apple_condition"], "Normal");
        assert_eq!(with["health_percent"], 90);
        let without = battery_json(&src, &Limit(false), None).unwrap();
        assert!(without.get("apple_maximum_capacity_percent").is_none());
        assert!(without.get("apple_condition").is_none());
    }

    #[test]
    fn cache_runs_once_within_ttl_and_again_after() {
        let runs = Cell::new(0);
        let health = || {
            runs.set(runs.get() + 1);
            AppleBatteryHealth {
                maximum_capacity_percent: Some(97),
                condition: Some("Normal".into()),
            }
        };
        let cached = CachedAppleHealth::new(Duration::from_secs(300), health);
        cached.read_apple_health();
        cached.read_apple_health();
        assert_eq!(runs.get(), 1);

        let runs = Cell::new(0);
        let health = || {
            runs.set(runs.get() + 1);
            AppleBatteryHealth::default()
        };
        let cached = CachedAppleHealth::new(Duration::ZERO, health);
        cached.read_apple_health();
        cached.read_apple_health();
        assert_eq!(runs.get(), 2);
    }
}
