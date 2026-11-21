//! Fakes for the Bluetooth ports. No radio is touched; tests script what the
//! "device" does and read the counters afterwards.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;
use std::time::Duration;

use symcockpit_contract::Error;
use symcockpit_core::bluetooth::{
    Advertisement, BleCentral, BleLink, Notification, PairedDevice, PairedDevices, Service,
    WriteAck,
};

/// Paired devices from a fixed list.
pub struct FakePaired(pub Vec<PairedDevice>);

impl PairedDevices for FakePaired {
    fn paired(&self) -> Result<Vec<PairedDevice>, Error> {
        Ok(self.0.clone())
    }
}

/// What the fake peripheral does with a write.
#[derive(Clone, Debug)]
pub enum WriteBehavior {
    /// Stores the value and acknowledges.
    Accept,
    /// Acknowledges but keeps the old value (readback will differ).
    AcceptButKeepOld,
    /// Fails the write at the ATT layer.
    Reject(String),
}

pub struct FakeDevice {
    pub services: Vec<Service>,
    /// Readable values by (service, characteristic); a missing key is not readable.
    pub values: BTreeMap<(String, String), Vec<u8>>,
    pub write: WriteBehavior,
    pub notifications: Vec<Notification>,
}

#[derive(Default, Debug, PartialEq, Eq)]
pub struct Counters {
    pub scans: u32,
    pub connects: u32,
    pub disconnects: u32,
}

pub struct FakeCentral {
    pub ads: Vec<Advertisement>,
    pub scan_error: Option<Error>,
    pub connect_error: Option<Error>,
    pub device: Rc<RefCell<FakeDevice>>,
    pub counters: Rc<RefCell<Counters>>,
}

impl FakeCentral {
    pub fn new(ads: Vec<Advertisement>, device: FakeDevice) -> FakeCentral {
        FakeCentral {
            ads,
            scan_error: None,
            connect_error: None,
            device: Rc::new(RefCell::new(device)),
            counters: Rc::default(),
        }
    }
}

impl BleCentral for FakeCentral {
    fn scan(&self, _timeout: Duration) -> Result<Vec<Advertisement>, Error> {
        self.counters.borrow_mut().scans += 1;
        match &self.scan_error {
            Some(e) => Err(e.clone()),
            None => Ok(self.ads.clone()),
        }
    }

    fn connect(&self, _id: &str, _timeout: Duration) -> Result<Box<dyn BleLink>, Error> {
        if let Some(e) = &self.connect_error {
            return Err(e.clone());
        }
        self.counters.borrow_mut().connects += 1;
        Ok(Box::new(FakeLink {
            device: self.device.clone(),
            counters: self.counters.clone(),
        }))
    }
}

pub struct FakeLink {
    device: Rc<RefCell<FakeDevice>>,
    counters: Rc<RefCell<Counters>>,
}

fn key(service: &str, characteristic: &str) -> (String, String) {
    (service.to_owned(), characteristic.to_owned())
}

impl BleLink for FakeLink {
    fn services(&self) -> Result<Vec<Service>, Error> {
        Ok(self.device.borrow().services.clone())
    }

    fn read(&self, service: &str, characteristic: &str) -> Result<Vec<u8>, Error> {
        self.device
            .borrow()
            .values
            .get(&key(service, characteristic))
            .cloned()
            .ok_or_else(|| Error::Unsupported("characteristic is not readable".into()))
    }

    fn write(
        &self,
        service: &str,
        characteristic: &str,
        value: &[u8],
        with_response: bool,
    ) -> Result<WriteAck, Error> {
        let mut dev = self.device.borrow_mut();
        match dev.write.clone() {
            WriteBehavior::Reject(m) => return Err(Error::Failed(m)),
            WriteBehavior::Accept => {
                dev.values
                    .insert(key(service, characteristic), value.to_vec());
            }
            WriteBehavior::AcceptButKeepOld => {}
        }
        Ok(if with_response {
            WriteAck::Acknowledged
        } else {
            WriteAck::NotRequested
        })
    }

    fn subscribe(
        &self,
        _service: &str,
        _characteristic: &str,
        _window: Duration,
        on_value: &mut dyn FnMut(Notification),
    ) -> Result<(), Error> {
        for n in self.device.borrow().notifications.clone() {
            on_value(n);
        }
        Ok(())
    }

    fn disconnect(&self) {
        self.counters.borrow_mut().disconnects += 1;
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use serde_json::{Value, json};
    use symcockpit_contract::Outcome;
    use symcockpit_core::bluetooth::*;
    use symcockpit_core::plan::Engine;

    use super::*;
    use crate::storage_clean::{FixedClock, MemoryStore};

    const SVC: &str = "180F";
    const CHR: &str = "2A19";

    fn ad(id: &str, name: Option<&str>) -> Advertisement {
        Advertisement {
            id: id.into(),
            name: name.map(Into::into),
            rssi: Some(-58),
            service_uuids: vec![SVC.into()],
            connectable: Some(true),
        }
    }

    fn central() -> FakeCentral {
        let device = FakeDevice {
            services: vec![Service {
                uuid: SVC.into(),
                characteristics: vec![Characteristic {
                    uuid: CHR.into(),
                    properties: vec!["read".into(), "write".into(), "notify".into()],
                }],
            }],
            values: BTreeMap::from([(key(SVC, CHR), vec![0x01, 0x02])]),
            write: WriteBehavior::Accept,
            notifications: vec![
                Notification {
                    elapsed_ms: 10,
                    value: vec![1],
                },
                Notification {
                    elapsed_ms: 20,
                    value: vec![2, 3],
                },
            ],
        };
        FakeCentral::new(vec![ad("id-a", Some("Alpha")), ad("id-b", None)], device)
    }

    fn log() -> BleLog {
        let t = std::cell::Cell::new(1_000u64);
        BleLog::with_clock(100, move || {
            t.set(t.get() + 1);
            t.get()
        })
    }

    fn request(with_response: bool) -> WriteRequest {
        WriteRequest::new("id-a", SVC, CHR, "0a0b", with_response).unwrap()
    }

    fn action(c: &FakeCentral) -> LinkWriteAction<'_> {
        LinkWriteAction {
            central: c,
            connect_timeout: Duration::from_secs(1),
        }
    }

    #[test]
    fn filter_changes_the_display_only_and_keeps_connections() {
        let c = central();
        let link = c.connect("id-a", Duration::from_secs(1)).unwrap();
        let v = ble_scan_json(
            &c,
            &mut log(),
            Duration::from_secs(2),
            &ScanFilter::new("alpha"),
        )
        .unwrap();
        assert_eq!(
            (v["total_seen"].as_u64(), v["shown"].as_u64()),
            (Some(2), Some(1))
        );
        assert_eq!(
            c.counters.borrow().disconnects,
            0,
            "a filter never disconnects"
        );
        assert_eq!(
            link.read(SVC, CHR).unwrap(),
            [1, 2],
            "the open link still works"
        );
    }

    #[test]
    fn scan_errors_keep_their_exit_code_class() {
        let mut c = central();
        c.scan_error = Some(Error::Permission("Bluetooth access denied".into()));
        let err = ble_scan_json(
            &c,
            &mut log(),
            Duration::from_secs(1),
            &ScanFilter::default(),
        )
        .unwrap_err();
        assert_eq!(err.exit_code(), 3);
    }

    #[test]
    fn write_is_confirmed_only_after_ack_and_matching_readback() {
        let c = central();
        let report = action(&c).execute(&request(true)).unwrap();
        assert_eq!(report.outcome, Outcome::Confirmed);
        assert_eq!(report.ack, AckState::Acknowledged);
        assert_eq!(report.readback.as_deref(), Some(&[0x0a, 0x0b][..]));
        let stages: Vec<_> = report.stages.iter().map(|s| (s.stage, s.status)).collect();
        assert_eq!(
            stages,
            [
                (WriteStage::Requested, "ok"),
                (WriteStage::Sent, "ok"),
                (WriteStage::Acknowledged, "ok"),
                (WriteStage::Readback, "ok"),
            ]
        );
        assert_eq!(c.counters.borrow().disconnects, 1);
    }

    #[test]
    fn acknowledged_write_with_differing_readback_is_unconfirmed() {
        let c = central();
        c.device.borrow_mut().write = WriteBehavior::AcceptButKeepOld;
        let report = action(&c).execute(&request(true)).unwrap();
        assert_eq!(report.ack, AckState::Acknowledged);
        assert_eq!(report.outcome, Outcome::Unconfirmed);
        assert_eq!(report.readback.as_deref(), Some(&[1, 2][..]));
        assert_eq!(report.stages[3].status, "failed");
    }

    #[test]
    fn rejected_write_is_failed_and_skips_the_readback() {
        let c = central();
        c.device.borrow_mut().write = WriteBehavior::Reject("ATT error 3".into());
        let report = action(&c).execute(&request(true)).unwrap();
        assert_eq!(report.outcome, Outcome::Failed);
        assert_eq!(report.ack, AckState::Failed);
        assert_eq!(report.readback, None);
        let status: Vec<_> = report.stages.iter().map(|s| s.status).collect();
        assert_eq!(status, ["ok", "failed", "failed", "unavailable"]);
    }

    #[test]
    fn write_without_response_has_no_ack_and_unreadable_value_stays_unconfirmed() {
        let c = central();
        let report = action(&c).execute(&request(false)).unwrap();
        assert_eq!(report.ack, AckState::NotApplicable);
        assert_eq!(report.outcome, Outcome::Confirmed, "readback matched");
        c.device.borrow_mut().values.clear();
        c.device.borrow_mut().write = WriteBehavior::AcceptButKeepOld;
        let report = action(&c).execute(&request(false)).unwrap();
        assert_eq!(
            report.outcome,
            Outcome::Unconfirmed,
            "no readback, no confirmation"
        );
        assert_eq!(report.stages.last().unwrap().status, "unavailable");
    }

    #[test]
    fn unreachable_device_is_an_error_not_a_report() {
        let mut c = central();
        c.connect_error = Some(Error::Failed("connection timed out".into()));
        assert!(action(&c).execute(&request(true)).is_err());
    }

    #[test]
    fn plan_touches_no_device() {
        let c = central();
        let (store, clock) = (MemoryStore::default(), FixedClock::new(1_000));
        let plan = plan_ble_write_json(&Engine::new(&store, &clock), &request(true)).unwrap();
        assert_eq!(plan["items"][0]["value_hex"], "0a0b");
        assert_eq!(plan["kind"], "ble_write");
        assert_eq!(c.counters.borrow().connects, 0);
    }

    #[test]
    fn write_log_shows_request_ack_and_readback_separately() {
        let c = central();
        let mut l = log();
        ble_write_json(&action(&c), &mut l, &request(true)).unwrap();
        let kinds: Vec<_> = l.entries().map(|e| e.kind).collect();
        assert_eq!(
            kinds,
            [
                LogKind::WriteRequested,
                LogKind::WriteAcknowledged,
                LogKind::WriteReadback
            ]
        );
    }

    #[test]
    fn export_after_a_session_holds_raw_bytes() {
        let c = central();
        let mut l = log();
        ble_read_json(&c, &mut l, "id-a", "180f", "2a19", Duration::from_secs(1)).unwrap();
        ble_subscribe_json(&c, &mut l, "id-a", SVC, CHR, Duration::from_secs(1)).unwrap();
        let v = ble_export_json(&l, ExportFormat::Json).unwrap();
        let notify: Vec<&Value> = v["entries"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|e| e["kind"] == "notify")
            .collect();
        assert_eq!(notify.len(), 2);
        assert_eq!(notify[1]["bytes"], json!([2, 3]));
        let csv = ble_export_json(&l, ExportFormat::Csv).unwrap();
        assert!(csv["content"].as_str().unwrap().contains("notify"));
    }

    #[test]
    fn read_of_an_unreadable_characteristic_is_logged_and_fails() {
        let c = central();
        let mut l = log();
        let err =
            ble_read_json(&c, &mut l, "id-a", SVC, "2A00", Duration::from_secs(1)).unwrap_err();
        assert_eq!(err.exit_code(), 4);
        assert!(l.entries().any(|e| e.kind == LogKind::Error));
        assert_eq!(
            c.counters.borrow().disconnects,
            1,
            "disconnects even on error"
        );
    }

    #[test]
    fn bad_uuid_is_a_usage_error_before_any_connection() {
        let c = central();
        let err =
            ble_read_json(&c, &mut log(), "id-a", "xyz", CHR, Duration::from_secs(1)).unwrap_err();
        assert_eq!(err.exit_code(), 2);
        assert_eq!(c.counters.borrow().connects, 0);
    }

    #[test]
    fn json_shapes_match_the_snapshots() {
        let paired = FakePaired(vec![
            PairedDevice {
                name: "Pods".into(),
                kind: "headphones".into(),
                connected: true,
                battery: Battery {
                    main: Level::Unknown,
                    left: Some(Level::Known(90)),
                    right: Some(Level::Known(88)),
                    case: Some(Level::Unknown),
                },
            },
            PairedDevice {
                name: "Board".into(),
                kind: "keyboard".into(),
                connected: false,
                battery: Battery {
                    main: Level::Known(40),
                    left: None,
                    right: None,
                    case: None,
                },
            },
        ]);
        let c = central();
        let mut l = log();
        let t = Duration::from_secs(1);
        let write = action(&c);
        let (store, clock) = (MemoryStore::default(), FixedClock::new(1_000));
        let checks: Vec<(&str, Value)> = vec![
            ("bt.devices", bt_devices_json(&paired).unwrap()),
            (
                "ble.scan",
                ble_scan_json(&c, &mut l, t, &ScanFilter::default()).unwrap(),
            ),
            (
                "ble.read.services",
                ble_services_json(&c, &mut l, "id-a").unwrap(),
            ),
            (
                "ble.read",
                ble_read_json(&c, &mut l, "id-a", SVC, CHR, t).unwrap(),
            ),
            (
                "ble.subscribe",
                ble_subscribe_json(&c, &mut l, "id-a", SVC, CHR, t).unwrap(),
            ),
            (
                "ble.write.plan",
                plan_ble_write_json(&Engine::new(&store, &clock), &request(true)).unwrap(),
            ),
            (
                "ble.write",
                ble_write_json(&write, &mut l, &request(true)).unwrap(),
            ),
            (
                "ble.export",
                ble_export_json(&l, ExportFormat::Json).unwrap(),
            ),
            (
                "ble.export.csv",
                ble_export_json(&l, ExportFormat::Csv).unwrap(),
            ),
        ];
        for (id, value) in &checks {
            crate::snapshot::check("bluetooth", id, value);
        }
    }
}
