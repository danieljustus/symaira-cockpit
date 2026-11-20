//! MIDI devices, entities and endpoints (R43), read-only.
//!
//! The platform adapter yields a [`MidiSnapshot`]; [`MidiService`] folds each
//! snapshot into a registry so a removed device or endpoint shows up as
//! `present: false` instead of silently vanishing, and an updated list needs no
//! restart: the adapter bumps [`MidiHal::change_epoch`] on every CoreMIDI
//! notification and the consumer re-reads.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};
use symcockpit_contract::Error;

use crate::audio::HalError;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MidiEndpoint {
    /// CoreMIDI unique id; stable across plug cycles for a given endpoint.
    pub unique_id: i32,
    pub name: String,
    /// The driver reports the endpoint as not currently connected.
    pub offline: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MidiEntity {
    pub unique_id: i32,
    pub name: String,
    pub sources: Vec<MidiEndpoint>,
    pub destinations: Vec<MidiEndpoint>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MidiDevice {
    pub unique_id: i32,
    pub name: String,
    pub manufacturer: Option<String>,
    pub model: Option<String>,
    pub offline: bool,
    pub entities: Vec<MidiEntity>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct MidiSnapshot {
    pub devices: Vec<MidiDevice>,
    /// Endpoints that belong to no device, e.g. virtual ports of other apps.
    pub standalone_sources: Vec<MidiEndpoint>,
    pub standalone_destinations: Vec<MidiEndpoint>,
}

pub trait MidiHal: Send + Sync {
    fn snapshot(&self) -> Result<MidiSnapshot, HalError>;
    /// Bumped by CoreMIDI setup-change, object-added and object-removed
    /// notifications. They are delivered on the run loop of the thread that
    /// created the client, so a consumer that wants live updates must run one.
    fn change_epoch(&self) -> u64;
}

#[derive(Default)]
struct Registry {
    generation: u64,
    devices: BTreeMap<i32, (MidiDevice, bool)>,
    sources: BTreeMap<i32, (MidiEndpoint, bool)>,
    destinations: BTreeMap<i32, (MidiEndpoint, bool)>,
}

fn merge<T: Clone>(known: &mut BTreeMap<i32, (T, bool)>, now: impl Iterator<Item = (i32, T)>) {
    for (_, present) in known.values_mut() {
        *present = false;
    }
    for (id, item) in now {
        known.insert(id, (item, true));
    }
}

pub struct MidiService {
    hal: Arc<dyn MidiHal>,
    registry: Mutex<Registry>,
}

impl MidiService {
    pub fn new(hal: Arc<dyn MidiHal>) -> Self {
        MidiService {
            hal,
            registry: Mutex::new(Registry::default()),
        }
    }

    pub fn change_epoch(&self) -> u64 {
        self.hal.change_epoch()
    }

    /// Re-read the system state and return the full list, including what
    /// vanished since the first read (`present: false`).
    pub fn devices_json(&self) -> Result<Value, Error> {
        let snap = self.hal.snapshot()?;
        let mut reg = self.registry.lock().unwrap_or_else(|e| e.into_inner());
        reg.generation += 1;
        merge(
            &mut reg.devices,
            snap.devices.into_iter().map(|d| (d.unique_id, d)),
        );
        merge(
            &mut reg.sources,
            snap.standalone_sources
                .into_iter()
                .map(|e| (e.unique_id, e)),
        );
        merge(
            &mut reg.destinations,
            snap.standalone_destinations
                .into_iter()
                .map(|e| (e.unique_id, e)),
        );
        let endpoint = |e: &MidiEndpoint, present: bool| json!({"unique_id": e.unique_id, "name": e.name, "offline": e.offline, "present": present});
        let devices: Vec<Value> = reg
            .devices
            .values()
            .map(|(d, present)| {
                let entities: Vec<Value> = d
                    .entities
                    .iter()
                    .map(|en| {
                        json!({
                            "unique_id": en.unique_id,
                            "name": en.name,
                            "sources": en.sources.iter().map(|e| endpoint(e, *present)).collect::<Vec<_>>(),
                            "destinations": en.destinations.iter().map(|e| endpoint(e, *present)).collect::<Vec<_>>(),
                        })
                    })
                    .collect();
                json!({
                    "unique_id": d.unique_id,
                    "name": d.name,
                    "manufacturer": d.manufacturer,
                    "model": d.model,
                    "offline": d.offline,
                    "present": present,
                    "entities": entities,
                })
            })
            .collect();
        let list = |m: &BTreeMap<i32, (MidiEndpoint, bool)>| -> Vec<Value> {
            m.values().map(|(e, p)| endpoint(e, *p)).collect()
        };
        Ok(json!({
            "generation": reg.generation,
            "devices": devices,
            "standalone_sources": list(&reg.sources),
            "standalone_destinations": list(&reg.destinations),
        }))
    }
}
