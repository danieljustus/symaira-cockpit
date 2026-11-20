//! Fake CoreMIDI: devices come and go, the change epoch moves.

use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

use symcockpit_core::audio::HalError;
use symcockpit_core::midi::{MidiDevice, MidiEndpoint, MidiEntity, MidiHal, MidiSnapshot};

#[derive(Default)]
pub struct FakeMidiHal {
    snapshot: Mutex<MidiSnapshot>,
    epoch: AtomicU64,
}

impl FakeMidiHal {
    pub fn set(&self, snapshot: MidiSnapshot) {
        *self.snapshot.lock().unwrap() = snapshot;
        self.epoch.fetch_add(1, Ordering::SeqCst);
    }
}

impl MidiHal for FakeMidiHal {
    fn snapshot(&self) -> Result<MidiSnapshot, HalError> {
        Ok(self.snapshot.lock().unwrap().clone())
    }

    fn change_epoch(&self) -> u64 {
        self.epoch.load(Ordering::SeqCst)
    }
}

pub fn endpoint(id: i32, name: &str) -> MidiEndpoint {
    MidiEndpoint {
        unique_id: id,
        name: name.to_owned(),
        offline: false,
    }
}

/// One keyboard with a source and a destination.
pub fn keyboard(id: i32) -> MidiDevice {
    MidiDevice {
        unique_id: id,
        name: format!("Fake Keys {id}"),
        manufacturer: Some("Fake MIDI Co".into()),
        model: Some("K1".into()),
        offline: false,
        entities: vec![MidiEntity {
            unique_id: id + 1,
            name: "Port 1".into(),
            sources: vec![endpoint(id + 2, "Out")],
            destinations: vec![endpoint(id + 3, "In")],
        }],
    }
}

/// A snapshot with one device and one virtual port of another app.
pub fn sample_hal() -> FakeMidiHal {
    let hal = FakeMidiHal::default();
    hal.set(MidiSnapshot {
        devices: vec![keyboard(100)],
        standalone_sources: vec![endpoint(900, "Virtual Out")],
        standalone_destinations: vec![endpoint(901, "Virtual In")],
    });
    hal
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use symcockpit_core::midi::MidiService;

    use super::*;

    #[test]
    fn list_updates_without_restart_when_a_device_or_endpoint_is_removed() {
        let hal = Arc::new(sample_hal());
        let svc = MidiService::new(hal.clone());
        let v = svc.devices_json().unwrap();
        assert_eq!(v["devices"][0]["present"], true);
        assert_eq!(
            v["devices"][0]["entities"][0]["sources"][0]["unique_id"],
            102
        );
        let epoch = svc.change_epoch();

        // an endpoint of a present device is removed: the next read shows it gone
        let mut dev = keyboard(100);
        dev.entities[0].destinations.clear();
        hal.set(MidiSnapshot {
            devices: vec![dev],
            ..Default::default()
        });
        assert_ne!(svc.change_epoch(), epoch);
        let v = svc.devices_json().unwrap();
        assert_eq!(
            v["devices"][0]["entities"][0]["destinations"],
            serde_json::json!([])
        );
        assert_eq!(
            v["standalone_sources"][0]["present"], false,
            "virtual port went away"
        );

        // the device is unplugged: it stays listed as not present
        hal.set(MidiSnapshot::default());
        let v = svc.devices_json().unwrap();
        assert_eq!(v["devices"][0]["present"], false);
        assert_eq!(v["generation"], 3);

        // and comes back
        hal.set(MidiSnapshot {
            devices: vec![keyboard(100)],
            ..Default::default()
        });
        assert_eq!(svc.devices_json().unwrap()["devices"][0]["present"], true);
    }

    #[test]
    fn an_empty_system_is_an_empty_list() {
        let svc = MidiService::new(Arc::new(FakeMidiHal::default()));
        let v = svc.devices_json().unwrap();
        assert_eq!(v["devices"], serde_json::json!([]));
    }
}
