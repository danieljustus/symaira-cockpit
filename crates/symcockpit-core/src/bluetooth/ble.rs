//! BLE ports and value types (R51). Blocking, no async runtime (architecture §10).
//!
//! A live adapter owns the platform event loop; callers only see these traits.
//! Callbacks must never run on the caller's thread, so a long-lived process
//! (the app agent) creates one `BleCentral` and shares it behind a channel.

use std::time::Duration;

use serde::Serialize;
use symcockpit_contract::Error;

/// One advertising device seen during a scan. `id` is the platform peripheral
/// identifier (CoreBluetooth hides the MAC address).
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct Advertisement {
    pub id: String,
    pub name: Option<String>,
    pub rssi: Option<i16>,
    pub service_uuids: Vec<String>,
    pub connectable: Option<bool>,
}

/// Display filter for scan results (R51). It only selects what is shown;
/// it never touches a connection.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ScanFilter {
    needle: Option<String>,
}

impl ScanFilter {
    /// Case-insensitive substring over name, id and service UUIDs; empty text matches all.
    pub fn new(text: &str) -> ScanFilter {
        let text = text.trim().to_lowercase();
        ScanFilter {
            needle: (!text.is_empty()).then_some(text),
        }
    }

    pub fn matches(&self, ad: &Advertisement) -> bool {
        let Some(needle) = &self.needle else {
            return true;
        };
        let has = |s: &str| s.to_lowercase().contains(needle);
        ad.name.as_deref().is_some_and(has)
            || has(&ad.id)
            || ad.service_uuids.iter().any(|u| has(u))
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct Characteristic {
    pub uuid: String,
    /// Property names such as `read`, `write`, `write_without_response`, `notify`.
    pub properties: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct Service {
    pub uuid: String,
    pub characteristics: Vec<Characteristic>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Notification {
    /// Milliseconds since the subscription started.
    pub elapsed_ms: u64,
    pub value: Vec<u8>,
}

/// What the transport reported for a write.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WriteAck {
    /// Write with response: the peripheral confirmed it at the ATT layer.
    Acknowledged,
    /// Write without response: the transport accepted it; nothing was confirmed.
    NotRequested,
}

/// An open connection to one peripheral.
pub trait BleLink {
    /// Discovers services and characteristics.
    fn services(&self) -> Result<Vec<Service>, Error>;
    fn read(&self, service: &str, characteristic: &str) -> Result<Vec<u8>, Error>;
    fn write(
        &self,
        service: &str,
        characteristic: &str,
        value: &[u8],
        with_response: bool,
    ) -> Result<WriteAck, Error>;
    /// Subscribes and calls `on_value` for each notification until `window` has passed.
    fn subscribe(
        &self,
        service: &str,
        characteristic: &str,
        window: Duration,
        on_value: &mut dyn FnMut(Notification),
    ) -> Result<(), Error>;
    fn disconnect(&self);
}

/// The local Bluetooth radio acting as BLE central.
pub trait BleCentral {
    /// Scans for `timeout` and returns each device once (latest advertisement).
    /// `Error::Permission` if Bluetooth access is denied, `Error::Unsupported`
    /// if the radio is off or missing.
    fn scan(&self, timeout: Duration) -> Result<Vec<Advertisement>, Error>;
    fn connect(&self, id: &str, timeout: Duration) -> Result<Box<dyn BleLink>, Error>;
}

/// Normalizes a Bluetooth UUID: 4 or 8 hex digits or the 36-character form,
/// returned upper-case. Anything else is a usage error.
pub fn normalize_uuid(text: &str) -> Result<String, Error> {
    let t = text.trim();
    let hex = |s: &str| s.chars().all(|c| c.is_ascii_hexdigit());
    let valid = match t.len() {
        4 | 8 => hex(t),
        36 => t.char_indices().all(|(i, c)| match i {
            8 | 13 | 18 | 23 => c == '-',
            _ => c.is_ascii_hexdigit(),
        }),
        _ => false,
    };
    if valid {
        Ok(t.to_ascii_uppercase())
    } else {
        Err(Error::Usage(format!("not a Bluetooth UUID: {text:?}")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ad(id: &str, name: Option<&str>, uuids: &[&str]) -> Advertisement {
        Advertisement {
            id: id.into(),
            name: name.map(Into::into),
            rssi: Some(-60),
            service_uuids: uuids.iter().map(|s| (*s).into()).collect(),
            connectable: Some(true),
        }
    }

    #[test]
    fn filter_matches_name_id_and_service_case_insensitively() {
        let a = ad("ID-1", Some("Heart Strap"), &["180D"]);
        assert!(ScanFilter::new("").matches(&a));
        assert!(ScanFilter::new("  strap ").matches(&a));
        assert!(ScanFilter::new("id-1").matches(&a));
        assert!(ScanFilter::new("180d").matches(&a));
        assert!(!ScanFilter::new("lamp").matches(&a));
        assert!(!ScanFilter::new("lamp").matches(&ad("x", None, &[])));
    }

    #[test]
    fn uuids_are_validated_and_upper_cased() {
        assert_eq!(normalize_uuid("180f").unwrap(), "180F");
        assert_eq!(normalize_uuid("0000180f").unwrap(), "0000180F");
        let full = "0000180f-0000-1000-8000-00805f9b34fb";
        assert_eq!(normalize_uuid(full).unwrap(), full.to_ascii_uppercase());
        for bad in ["", "18", "zzzz", "0000180f_0000-1000-8000-00805f9b34fb"] {
            assert!(normalize_uuid(bad).is_err(), "{bad:?}");
        }
    }
}
