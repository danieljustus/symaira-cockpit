//! Live CoreMIDI adapter (read-only) for the core's `MidiHal` port.
//!
//! The `coremidi` crate supplies the client and its notifications; it has no
//! device or entity traversal, so those walk `coremidi-sys` directly.

use std::mem::MaybeUninit;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use ::coremidi::{Client, Notification};
use core_foundation_sys::string::CFStringRef;
use coremidi_sys as sys;
use objc2::rc::Retained;
use objc2_foundation::NSString;
use symcockpit_core::audio::{HalError, HalErrorKind};
use symcockpit_core::midi::{MidiDevice, MidiEndpoint, MidiEntity, MidiHal, MidiSnapshot};

pub struct RealMidiHal {
    epoch: Arc<AtomicU64>,
    /// Keeps the notification registration alive. Notifications are delivered on
    /// the run loop of the thread that created the client.
    _client: Option<Client>,
}

fn string_property(object: sys::MIDIObjectRef, key: CFStringRef) -> Option<String> {
    let mut out = MaybeUninit::<CFStringRef>::uninit();
    // SAFETY: `out` is a valid out-pointer; `key` is a CoreMIDI constant.
    let status = unsafe { sys::MIDIObjectGetStringProperty(object, key, out.as_mut_ptr()) };
    if status != 0 {
        return None;
    }
    // SAFETY: on success CoreMIDI returns a +1 CFString (toll-free bridged to NSString).
    let s = unsafe { Retained::from_raw(out.assume_init().cast::<NSString>().cast_mut()) }?;
    Some(s.to_string())
}

fn int_property(object: sys::MIDIObjectRef, key: CFStringRef) -> Option<i32> {
    let mut v = 0i32;
    // SAFETY: `v` is a valid out-pointer.
    (unsafe { sys::MIDIObjectGetIntegerProperty(object, key, &mut v) } == 0).then_some(v)
}

fn endpoint(e: sys::MIDIEndpointRef) -> MidiEndpoint {
    // SAFETY: reading CoreMIDI's constant property keys.
    let (name, id, offline) = unsafe {
        (
            sys::kMIDIPropertyName,
            sys::kMIDIPropertyUniqueID,
            sys::kMIDIPropertyOffline,
        )
    };
    MidiEndpoint {
        unique_id: int_property(e, id).unwrap_or(0),
        name: string_property(e, name).unwrap_or_default(),
        offline: int_property(e, offline).is_some_and(|v| v != 0),
    }
}

fn entity(e: sys::MIDIEntityRef) -> MidiEntity {
    // SAFETY: the counts and getters take the entity ref and an in-range index.
    let (sources, destinations) = unsafe {
        (
            (0..sys::MIDIEntityGetNumberOfSources(e))
                .map(|i| endpoint(sys::MIDIEntityGetSource(e, i)))
                .collect(),
            (0..sys::MIDIEntityGetNumberOfDestinations(e))
                .map(|i| endpoint(sys::MIDIEntityGetDestination(e, i)))
                .collect(),
        )
    };
    // SAFETY: constant keys.
    let (name, id) = unsafe { (sys::kMIDIPropertyName, sys::kMIDIPropertyUniqueID) };
    MidiEntity {
        unique_id: int_property(e, id).unwrap_or(0),
        name: string_property(e, name).unwrap_or_default(),
        sources,
        destinations,
    }
}

fn device(d: sys::MIDIDeviceRef) -> MidiDevice {
    // SAFETY: constant keys; entity indices are in range by the count.
    let (keys, entities) = unsafe {
        (
            (
                sys::kMIDIPropertyName,
                sys::kMIDIPropertyUniqueID,
                sys::kMIDIPropertyManufacturer,
                sys::kMIDIPropertyModel,
                sys::kMIDIPropertyOffline,
            ),
            (0..sys::MIDIDeviceGetNumberOfEntities(d))
                .map(|i| entity(sys::MIDIDeviceGetEntity(d, i)))
                .collect(),
        )
    };
    MidiDevice {
        unique_id: int_property(d, keys.1).unwrap_or(0),
        name: string_property(d, keys.0).unwrap_or_default(),
        manufacturer: string_property(d, keys.2).filter(|s| !s.is_empty()),
        model: string_property(d, keys.3).filter(|s| !s.is_empty()),
        offline: int_property(d, keys.4).is_some_and(|v| v != 0),
        entities,
    }
}

/// An endpoint with no entity belongs to no device (a virtual port of another app).
fn is_standalone(e: sys::MIDIEndpointRef) -> bool {
    let mut owner: sys::MIDIEntityRef = 0;
    // SAFETY: `owner` is a valid out-pointer.
    let status = unsafe { sys::MIDIEndpointGetEntity(e, &mut owner) };
    status != 0 || owner == 0
}

impl RealMidiHal {
    /// With notifications: `change_epoch` moves when CoreMIDI reports a setup
    /// change, so the owner of a run loop can re-read.
    pub fn new() -> Result<Self, HalError> {
        let epoch = Arc::new(AtomicU64::new(0));
        let counter = epoch.clone();
        let client = Client::new_with_notifications("Symaira Cockpit", move |n: &Notification| {
            if matches!(
                n,
                Notification::SetupChanged
                    | Notification::ObjectAdded(_)
                    | Notification::ObjectRemoved(_)
            ) {
                counter.fetch_add(1, Ordering::SeqCst);
            }
        })
        .map_err(|status| HalError {
            kind: HalErrorKind::Other,
            op: "MIDIClientCreate".into(),
            status: Some(status),
            message: "cannot create a CoreMIDI client".into(),
        })?;
        Ok(RealMidiHal {
            epoch,
            _client: Some(client),
        })
    }
}

impl MidiHal for RealMidiHal {
    fn snapshot(&self) -> Result<MidiSnapshot, HalError> {
        // SAFETY: counts and indexed getters of the CoreMIDI setup; a device that
        // disappears meanwhile yields a ref whose properties fail to read (empty values).
        let devices = unsafe {
            let internal =
                (0..sys::MIDIGetNumberOfDevices()).map(|i| device(sys::MIDIGetDevice(i)));
            let external = (0..sys::MIDIGetNumberOfExternalDevices())
                .map(|i| device(sys::MIDIGetExternalDevice(i)));
            internal.chain(external).collect()
        };
        // SAFETY: as above.
        let (sources, destinations) = unsafe {
            (
                (0..sys::MIDIGetNumberOfSources())
                    .map(|i| sys::MIDIGetSource(i))
                    .filter(|e| is_standalone(*e))
                    .map(endpoint)
                    .collect(),
                (0..sys::MIDIGetNumberOfDestinations())
                    .map(|i| sys::MIDIGetDestination(i))
                    .filter(|e| is_standalone(*e))
                    .map(endpoint)
                    .collect(),
            )
        };
        Ok(MidiSnapshot {
            devices,
            standalone_sources: sources,
            standalone_destinations: destinations,
        })
    }

    fn change_epoch(&self) -> u64 {
        self.epoch.load(Ordering::SeqCst)
    }
}

#[cfg(test)]
mod live {
    use std::sync::Arc;

    use symcockpit_core::midi::MidiService;

    use super::*;

    /// Lists the real MIDI setup; prints counts only.
    #[test]
    #[ignore = "reads the real MIDI setup of this Mac"]
    fn read_only_midi_listing() {
        let svc = MidiService::new(Arc::new(RealMidiHal::new().expect("client")));
        let v = svc.devices_json().expect("snapshot");
        let devices = v["devices"].as_array().unwrap();
        let endpoints: usize = devices
            .iter()
            .flat_map(|d| d["entities"].as_array().unwrap())
            .map(|e| {
                e["sources"].as_array().unwrap().len() + e["destinations"].as_array().unwrap().len()
            })
            .sum();
        eprintln!(
            "midi devices: {}, device endpoints: {endpoints}",
            devices.len()
        );
        assert!(v["generation"].as_u64().unwrap() >= 1);
    }
}
