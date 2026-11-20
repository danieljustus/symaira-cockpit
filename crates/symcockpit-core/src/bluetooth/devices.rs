//! Paired devices and their battery levels (R50).

use serde::Serialize;
use serde_json::Value;
use symcockpit_contract::Error;

/// A battery reading. A missing value is `Unknown`, never 0 % (R50).
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(into = "LevelJson")]
pub enum Level {
    Known(u8),
    Unknown,
}

#[derive(Serialize)]
struct LevelJson {
    state: &'static str,
    percent: Option<u8>,
}

impl From<Level> for LevelJson {
    fn from(level: Level) -> Self {
        match level {
            Level::Known(p) => LevelJson {
                state: "known",
                percent: Some(p),
            },
            Level::Unknown => LevelJson {
                state: "unknown",
                percent: None,
            },
        }
    }
}

impl Level {
    /// Parses text such as `56 %` (the source uses a no-break space).
    /// Anything that is not a number in 0..=100 is `Unknown`.
    pub fn parse(text: &str) -> Level {
        let number = text.trim().trim_end_matches('%').trim();
        match number.parse::<u8>() {
            Ok(p) if p <= 100 => Level::Known(p),
            _ => Level::Unknown,
        }
    }
}

/// Battery of a device. `left`, `right` and `case` exist only for devices
/// that report them (AirPods and similar).
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub struct Battery {
    pub main: Level,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub left: Option<Level>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub right: Option<Level>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub case: Option<Level>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct PairedDevice {
    pub name: String,
    /// Lower-case device class (`headphones`, `keyboard`, ...), `unknown` if not reported.
    pub kind: String,
    pub connected: bool,
    pub battery: Battery,
}

/// Port: where the list of paired devices comes from.
pub trait PairedDevices {
    fn paired(&self) -> Result<Vec<PairedDevice>, Error>;
}

/// Parses `system_profiler SPBluetoothDataType -json`.
///
/// Entries that carry no identity beyond address and RSSI are nearby
/// advertisers, not paired devices, and are skipped (assumption checked on one
/// Mac: paired entries always had vendor and product ids).
pub fn parse_system_profiler(root: &Value) -> Result<Vec<PairedDevice>, Error> {
    let section = root
        .get("SPBluetoothDataType")
        .and_then(|v| v.get(0))
        .and_then(Value::as_object)
        .ok_or_else(|| Error::Failed("unexpected system_profiler Bluetooth output".into()))?;
    let mut devices = Vec::new();
    for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
        for entry in section
            .get(key)
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            for (name, props) in entry.as_object().into_iter().flatten() {
                if let Some(device) = parse_device(name, props, connected) {
                    devices.push(device);
                }
            }
        }
    }
    Ok(devices)
}

fn parse_device(name: &str, props: &Value, connected: bool) -> Option<PairedDevice> {
    let text = |k: &str| props.get(k).and_then(Value::as_str);
    if text("device_vendorID").is_none() && text("device_productID").is_none() {
        return None;
    }
    let level = |k: &str| text(k).map(Level::parse);
    Some(PairedDevice {
        name: name.to_owned(),
        kind: text("device_minorType").map_or_else(|| "unknown".into(), str::to_lowercase),
        connected,
        battery: Battery {
            main: level("device_batteryLevelMain").unwrap_or(Level::Unknown),
            left: level("device_batteryLevelLeft"),
            right: level("device_batteryLevelRight"),
            case: level("device_batteryLevelCase"),
        },
    })
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn level_parses_text_and_never_invents_zero() {
        assert_eq!(Level::parse("56\u{a0}%"), Level::Known(56));
        assert_eq!(Level::parse("0 %"), Level::Known(0));
        assert_eq!(Level::parse("100%"), Level::Known(100));
        for bad in ["", "n/a", "101 %", "-5", "999999999999"] {
            assert_eq!(Level::parse(bad), Level::Unknown, "{bad:?}");
        }
    }

    #[test]
    fn unknown_serializes_without_a_percent() {
        let v = serde_json::to_value(Level::Unknown).unwrap();
        assert_eq!(v, json!({"state": "unknown", "percent": null}));
    }

    #[test]
    fn profiler_output_maps_to_devices() {
        let root = json!({"SPBluetoothDataType": [{
            "device_connected": [{"Pods": {
                "device_vendorID": "0x004C", "device_minorType": "Headphones",
                "device_batteryLevelLeft": "98\u{a0}%", "device_batteryLevelRight": "97\u{a0}%",
                "device_batteryLevelCase": "56\u{a0}%"}}],
            "device_not_connected": [
                {"Board": {"device_productID": "0x1", "device_minorType": "Keyboard"}},
                {"seen": {"device_address": "AA", "device_rssi": "-70"}}]}]});
        let devices = parse_system_profiler(&root).unwrap();
        assert_eq!(devices.len(), 2, "advertiser-only entry is skipped");
        assert_eq!(devices[0].kind, "headphones");
        assert!(devices[0].connected);
        assert_eq!(devices[0].battery.left, Some(Level::Known(98)));
        assert_eq!(devices[0].battery.case, Some(Level::Known(56)));
        assert_eq!(devices[0].battery.main, Level::Unknown);
        assert_eq!(devices[1].battery.main, Level::Unknown);
        assert_eq!(devices[1].battery.left, None);
    }

    #[test]
    fn unexpected_shape_is_an_error() {
        assert!(parse_system_profiler(&json!({})).is_err());
    }
}
