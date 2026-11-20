//! Device identity (R40): the UID recognises a device across plug cycles, the
//! object id addresses it for one appearance, the epoch tells appearances apart.
//!
//! A device that disappears stays in the registry as offline (`object: None`).
//! When it returns it gets a new epoch, so a [`DeviceHandle`] taken before the
//! disappearance can never address the new appearance, even if the HAL hands
//! out the same object id again.

use std::collections::BTreeMap;

use symcockpit_contract::Error;

use super::hal::{HalSnapshot, ObjectId, RawDevice, Scope};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeviceHandle {
    pub uid: String,
    pub object: ObjectId,
    pub epoch: u64,
}

#[derive(Clone, Debug)]
pub struct DeviceRecord {
    pub uid: String,
    /// Appearance counter: 1 on first sight, +1 each time the device comes back.
    pub epoch: u64,
    /// `None` while the device is offline.
    pub object: Option<ObjectId>,
    /// State at the last sighting (stale while offline).
    pub last: RawDevice,
}

impl DeviceRecord {
    pub fn online(&self) -> bool {
        self.object.is_some()
    }
}

#[derive(Debug, Default)]
pub struct DeviceRegistry {
    generation: u64,
    records: BTreeMap<String, DeviceRecord>,
    default_input: Option<String>,
    default_output: Option<String>,
}

/// What a refresh changed, by UID.
#[derive(Debug, Default, Eq, PartialEq)]
pub struct Changes {
    pub appeared: Vec<String>,
    pub vanished: Vec<String>,
}

impl DeviceRegistry {
    /// Number of refreshes so far; stamps answers so late ones can be dropped.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn refresh(&mut self, snapshot: HalSnapshot) -> Changes {
        self.generation += 1;
        let mut changes = Changes::default();
        let mut seen = Vec::new();
        // Defaults are recomputed each time, so one that points at a vanished
        // device is simply absent.
        self.default_input = None;
        self.default_output = None;
        for raw in &snapshot.devices {
            seen.push(raw.uid.clone());
            let default_for = |obj: Option<ObjectId>| obj == Some(raw.object);
            if default_for(snapshot.default_input) {
                self.default_input = Some(raw.uid.clone());
            }
            if default_for(snapshot.default_output) {
                self.default_output = Some(raw.uid.clone());
            }
            match self.records.get_mut(&raw.uid) {
                Some(rec) if rec.object == Some(raw.object) => rec.last = raw.clone(),
                Some(rec) => {
                    // Back after being offline, or re-created under a new object id.
                    rec.epoch += 1;
                    rec.object = Some(raw.object);
                    rec.last = raw.clone();
                    changes.appeared.push(raw.uid.clone());
                }
                None => {
                    self.records.insert(
                        raw.uid.clone(),
                        DeviceRecord {
                            uid: raw.uid.clone(),
                            epoch: 1,
                            object: Some(raw.object),
                            last: raw.clone(),
                        },
                    );
                    changes.appeared.push(raw.uid.clone());
                }
            }
        }
        for rec in self.records.values_mut() {
            if rec.object.is_some() && !seen.contains(&rec.uid) {
                rec.object = None;
                changes.vanished.push(rec.uid.clone());
            }
        }
        changes
    }

    pub fn records(&self) -> impl Iterator<Item = &DeviceRecord> {
        self.records.values()
    }

    pub fn record(&self, uid: &str) -> Option<&DeviceRecord> {
        self.records.get(uid)
    }

    pub fn default_uid(&self, scope: Scope) -> Option<&str> {
        match scope {
            Scope::Input => self.default_input.as_deref(),
            Scope::Output => self.default_output.as_deref(),
        }
    }

    /// A handle to the current appearance of an online device.
    pub fn handle(&self, uid: &str) -> Result<DeviceHandle, Error> {
        let rec = self
            .records
            .get(uid)
            .ok_or_else(|| Error::Usage(format!("no audio device with uid '{uid}'")))?;
        match rec.object {
            Some(object) => Ok(DeviceHandle {
                uid: rec.uid.clone(),
                object,
                epoch: rec.epoch,
            }),
            None => Err(Error::Failed(format!("audio device '{uid}' is offline"))),
        }
    }

    /// Check that a handle still addresses the current appearance.
    pub fn validate(&self, handle: &DeviceHandle) -> Result<&RawDevice, Error> {
        match self.records.get(&handle.uid) {
            Some(rec) if rec.object == Some(handle.object) && rec.epoch == handle.epoch => {
                Ok(&rec.last)
            }
            _ => Err(Error::Failed(format!(
                "audio device '{}' changed or disappeared; handle is stale",
                handle.uid
            ))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::hal::{DeviceKind, ScopeState};

    fn raw(uid: &str, object: u32) -> RawDevice {
        RawDevice {
            object: ObjectId(object),
            uid: uid.into(),
            name: uid.into(),
            manufacturer: None,
            transport: "usb".into(),
            kind: DeviceKind::Physical,
            input: ScopeState::default(),
            output: ScopeState::default(),
            sample_rate: None,
            sample_rates: vec![],
            members: vec![],
        }
    }

    fn snap(devices: Vec<RawDevice>) -> HalSnapshot {
        HalSnapshot {
            devices,
            ..Default::default()
        }
    }

    #[test]
    fn vanished_device_goes_offline_and_old_handle_is_stale_after_return() {
        let mut reg = DeviceRegistry::default();
        reg.refresh(snap(vec![raw("a", 10)]));
        let old = reg.handle("a").unwrap();
        assert!(reg.validate(&old).is_ok());

        let changes = reg.refresh(snap(vec![]));
        assert_eq!(changes.vanished, ["a"]);
        assert!(!reg.record("a").unwrap().online());
        assert!(reg.validate(&old).is_err());
        assert!(reg.handle("a").is_err());

        // Same object id handed out again: still a new appearance.
        reg.refresh(snap(vec![raw("a", 10)]));
        let new = reg.handle("a").unwrap();
        assert_eq!(new.object, old.object);
        assert_ne!(new.epoch, old.epoch);
        assert!(reg.validate(&old).is_err());
        assert!(reg.validate(&new).is_ok());
    }

    #[test]
    fn object_id_change_without_vanishing_also_starts_a_new_epoch() {
        let mut reg = DeviceRegistry::default();
        reg.refresh(snap(vec![raw("a", 10)]));
        let old = reg.handle("a").unwrap();
        reg.refresh(snap(vec![raw("a", 11)]));
        assert!(reg.validate(&old).is_err());
    }

    #[test]
    fn default_pointing_at_an_offline_device_is_cleared() {
        let mut reg = DeviceRegistry::default();
        reg.refresh(HalSnapshot {
            devices: vec![raw("a", 10)],
            default_output: Some(ObjectId(10)),
            ..Default::default()
        });
        assert_eq!(reg.default_uid(Scope::Output), Some("a"));
        reg.refresh(snap(vec![]));
        assert_eq!(reg.default_uid(Scope::Output), None);
    }
}
