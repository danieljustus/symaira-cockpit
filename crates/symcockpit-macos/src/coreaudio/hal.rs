//! Live CoreAudio adapter for the core's `AudioHal` port.
//!
//! Reads are always safe to run. Writes change the system: they are called only
//! by the core after its preconditions, and every one is followed by a readback
//! there, not here.

use std::ffi::c_void;
use std::ptr::NonNull;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2_core_audio::{
    AudioHardwareCreateAggregateDevice, AudioHardwareDestroyAggregateDevice,
    AudioObjectAddPropertyListener, AudioObjectID, AudioObjectPropertyAddress,
    AudioObjectRemovePropertyListener, AudioStreamRangedDescription, kAudioAggregateDeviceClassID,
    kAudioAggregateDeviceIsPrivateKey, kAudioAggregateDeviceIsStackedKey,
    kAudioAggregateDeviceMainSubDeviceKey, kAudioAggregateDeviceNameKey,
    kAudioAggregateDevicePropertyFullSubDeviceList, kAudioAggregateDeviceSubDeviceListKey,
    kAudioAggregateDeviceUIDKey, kAudioDevicePropertyAvailableNominalSampleRates,
    kAudioDevicePropertyDeviceUID, kAudioDevicePropertyMute, kAudioDevicePropertyNominalSampleRate,
    kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyStreams,
    kAudioDevicePropertyTransportType, kAudioDevicePropertyVolumeScalar,
    kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice,
    kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioHardwarePropertyDevices,
    kAudioHardwarePropertyRunLoop, kAudioObjectPropertyClass, kAudioObjectPropertyElementMain,
    kAudioObjectPropertyManufacturer, kAudioObjectPropertyName,
    kAudioStreamPropertyAvailablePhysicalFormats, kAudioStreamPropertyPhysicalFormat,
    kAudioSubDeviceDriftCompensationKey, kAudioSubDeviceUIDKey,
};
use objc2_core_audio_types::{AudioStreamBasicDescription, AudioValueRange};
use objc2_core_foundation::CFDictionary;
use objc2_foundation::{NSNumber, NSString};
use symcockpit_core::audio::{
    AggregateSpec, AudioHal, DeviceKind, HalError, HalErrorKind, HalSnapshot, ObjectId, RateRange,
    RawDevice, Scope, ScopeState, StreamFormat,
};

use super::objc::{array_of, dict_set, new_obj};
use super::props::{
    SYSTEM, channel_count, error, fourcc, get, get_string, get_strings, get_vec, global, has,
    scoped, set, settable,
};

const MAIN: u32 = kAudioObjectPropertyElementMain;

/// Selectors whose change means the device list or a default moved.
const WATCHED: [u32; 3] = [
    kAudioHardwarePropertyDevices,
    kAudioHardwarePropertyDefaultInputDevice,
    kAudioHardwarePropertyDefaultOutputDevice,
];

extern "C-unwind" fn on_change(
    _object: AudioObjectID,
    _n: u32,
    _a: NonNull<AudioObjectPropertyAddress>,
    client: *mut c_void,
) -> i32 {
    // SAFETY: `client` is the pointer from `Arc::into_raw` in `watch`, valid until
    // `Drop` removes the listener; we only borrow the counter.
    let epoch = unsafe { &*client.cast::<AtomicU64>() };
    epoch.fetch_add(1, Ordering::SeqCst);
    0
}

pub struct RealAudioHal {
    epoch: Arc<AtomicU64>,
    watching: bool,
}

impl Default for RealAudioHal {
    fn default() -> Self {
        Self::new()
    }
}

impl RealAudioHal {
    /// No listeners: `change_epoch` stays 0. Right for one-shot commands.
    pub fn new() -> Self {
        RealAudioHal {
            epoch: Arc::new(AtomicU64::new(0)),
            watching: false,
        }
    }

    /// Register listeners for the device list and the default devices; the
    /// epoch then moves on every change. Also detaches the HAL from the main
    /// run loop so notifications arrive without one (documented CoreAudio
    /// requirement for command line tools).
    pub fn watch() -> Result<Self, HalError> {
        let hal = RealAudioHal {
            epoch: Arc::new(AtomicU64::new(0)),
            watching: true,
        };
        let no_run_loop: *const c_void = std::ptr::null();
        set(
            "SetRunLoop",
            SYSTEM,
            global(kAudioHardwarePropertyRunLoop),
            &no_run_loop,
        )?;
        for (i, sel) in WATCHED.iter().enumerate() {
            let a = global(*sel);
            // SAFETY: the counter pointer stays valid until `Drop`, which removes every listener first.
            let status = unsafe {
                AudioObjectAddPropertyListener(
                    SYSTEM,
                    NonNull::from(&a),
                    Some(on_change),
                    Arc::as_ptr(&hal.epoch).cast_mut().cast(),
                )
            };
            if status != 0 {
                for sel in &WATCHED[..i] {
                    hal.remove_listener(*sel);
                }
                return Err(error("AudioObjectAddPropertyListener", status));
            }
        }
        Ok(hal)
    }

    fn remove_listener(&self, selector: u32) {
        let a = global(selector);
        // SAFETY: same function and client pointer as at registration.
        unsafe {
            AudioObjectRemovePropertyListener(
                SYSTEM,
                NonNull::from(&a),
                Some(on_change),
                Arc::as_ptr(&self.epoch).cast_mut().cast(),
            );
        }
    }

    fn scope_state(&self, object: u32, scope: Scope) -> ScopeState {
        let channels = channel_count(
            object,
            scoped(kAudioDevicePropertyStreamConfiguration, scope, MAIN),
        );
        if channels == 0 {
            return ScopeState::default();
        }
        let (volume, volume_settable) = self.read_volume(object, scope, channels);
        let mute_addr = scoped(kAudioDevicePropertyMute, scope, MAIN);
        let muted = get::<u32>("Mute", object, mute_addr).ok().map(|m| m != 0);
        let stream = self.first_stream(object, scope);
        let format = stream.and_then(|s| {
            get::<AudioStreamBasicDescription>(
                "PhysicalFormat",
                s,
                global(kAudioStreamPropertyPhysicalFormat),
            )
            .ok()
        });
        let formats = stream
            .and_then(|s| {
                get_vec::<AudioStreamRangedDescription>(
                    "AvailablePhysicalFormats",
                    s,
                    global(kAudioStreamPropertyAvailablePhysicalFormats),
                )
                .ok()
            })
            .unwrap_or_default();
        ScopeState {
            channels,
            volume,
            volume_settable,
            muted,
            mute_settable: muted.is_some() && settable(object, mute_addr),
            format: format.map(to_format),
            formats: formats.iter().flat_map(ranged_formats).collect(),
        }
    }

    fn first_stream(&self, object: u32, scope: Scope) -> Option<u32> {
        get_vec::<u32>(
            "Streams",
            object,
            scoped(kAudioDevicePropertyStreams, scope, MAIN),
        )
        .ok()?
        .first()
        .copied()
    }

    /// The elements carrying a volume: the main element, else every channel.
    fn volume_elements(&self, object: u32, scope: Scope, channels: u32) -> Vec<u32> {
        if has(
            object,
            scoped(kAudioDevicePropertyVolumeScalar, scope, MAIN),
        ) {
            return vec![MAIN];
        }
        (1..=channels.min(8))
            .filter(|c| has(object, scoped(kAudioDevicePropertyVolumeScalar, scope, *c)))
            .collect()
    }

    fn read_volume(&self, object: u32, scope: Scope, channels: u32) -> (Option<f32>, bool) {
        let elements = self.volume_elements(object, scope, channels);
        let values: Vec<f32> = elements
            .iter()
            .filter_map(|e| {
                get::<f32>(
                    "VolumeScalar",
                    object,
                    scoped(kAudioDevicePropertyVolumeScalar, scope, *e),
                )
                .ok()
            })
            .collect();
        let avg = (!values.is_empty() && values.len() == elements.len())
            .then(|| values.iter().sum::<f32>() / values.len() as f32);
        let all_settable = !elements.is_empty()
            && elements
                .iter()
                .all(|e| settable(object, scoped(kAudioDevicePropertyVolumeScalar, scope, *e)));
        (avg, all_settable)
    }

    fn device(&self, object: u32) -> Option<RawDevice> {
        let uid = get_string("DeviceUID", object, global(kAudioDevicePropertyDeviceUID)).ok()?;
        let class = get::<u32>("Class", object, global(kAudioObjectPropertyClass)).unwrap_or(0);
        let transport = get::<u32>(
            "TransportType",
            object,
            global(kAudioDevicePropertyTransportType),
        )
        .unwrap_or(0);
        let kind = match (class == kAudioAggregateDeviceClassID, &*fourcc(transport)) {
            (true, _) => DeviceKind::Aggregate,
            (false, "virt") => DeviceKind::Virtual,
            _ => DeviceKind::Physical,
        };
        let members = if kind == DeviceKind::Aggregate {
            get_strings(
                "FullSubDeviceList",
                object,
                global(kAudioAggregateDevicePropertyFullSubDeviceList),
            )
            .unwrap_or_default()
        } else {
            vec![]
        };
        let ranges: Vec<AudioValueRange> = get_vec(
            "AvailableNominalSampleRates",
            object,
            global(kAudioDevicePropertyAvailableNominalSampleRates),
        )
        .unwrap_or_default();
        Some(RawDevice {
            object: ObjectId(object),
            uid,
            name: get_string("Name", object, global(kAudioObjectPropertyName)).unwrap_or_default(),
            manufacturer: get_string(
                "Manufacturer",
                object,
                global(kAudioObjectPropertyManufacturer),
            )
            .ok()
            .filter(|m| !m.is_empty()),
            transport: transport_name(transport),
            kind,
            input: self.scope_state(object, Scope::Input),
            output: self.scope_state(object, Scope::Output),
            sample_rate: get::<f64>(
                "NominalSampleRate",
                object,
                global(kAudioDevicePropertyNominalSampleRate),
            )
            .ok(),
            sample_rates: ranges
                .iter()
                .map(|r| RateRange {
                    min: r.mMinimum,
                    max: r.mMaximum,
                })
                .collect(),
            members,
        })
    }

    fn default_selector(scope: Scope) -> u32 {
        match scope {
            Scope::Input => kAudioHardwarePropertyDefaultInputDevice,
            Scope::Output => kAudioHardwarePropertyDefaultOutputDevice,
        }
    }
}

impl Drop for RealAudioHal {
    fn drop(&mut self) {
        if self.watching {
            for sel in WATCHED {
                self.remove_listener(sel);
            }
        }
    }
}

fn transport_name(code: u32) -> String {
    match &*fourcc(code) {
        "bltn" => "builtin",
        "usb " => "usb",
        "blue" => "bluetooth",
        "blea" => "bluetooth_le",
        "hdmi" => "hdmi",
        "dprt" => "displayport",
        "airp" => "airplay",
        "thun" => "thunderbolt",
        "virt" => "virtual",
        "grup" => "aggregate",
        "pci " => "pci",
        "1394" => "firewire",
        other => return other.to_owned(),
    }
    .to_owned()
}

fn to_format(d: AudioStreamBasicDescription) -> StreamFormat {
    StreamFormat {
        rate: d.mSampleRate,
        bits: d.mBitsPerChannel,
        channels: d.mChannelsPerFrame,
    }
}

/// One entry per distinct rate the ranged description spans (usually one).
fn ranged_formats(r: &AudioStreamRangedDescription) -> Vec<StreamFormat> {
    let base = to_format(r.mFormat);
    let (lo, hi) = (r.mSampleRateRange.mMinimum, r.mSampleRateRange.mMaximum);
    let mut v = vec![StreamFormat { rate: lo, ..base }];
    if (hi - lo).abs() > 0.5 {
        v.push(StreamFormat { rate: hi, ..base });
    }
    v
}

impl AudioHal for RealAudioHal {
    fn snapshot(&self) -> Result<HalSnapshot, HalError> {
        let ids: Vec<u32> = get_vec("Devices", SYSTEM, global(kAudioHardwarePropertyDevices))?;
        // A device that vanishes while we read it simply drops out of the list.
        let devices = ids.into_iter().filter_map(|id| self.device(id)).collect();
        let default = |s: Scope| -> Option<ObjectId> {
            get::<u32>("DefaultDevice", SYSTEM, global(Self::default_selector(s)))
                .ok()
                .filter(|o| *o != 0)
                .map(ObjectId)
        };
        Ok(HalSnapshot {
            devices,
            default_input: default(Scope::Input),
            default_output: default(Scope::Output),
        })
    }

    fn device_uid(&self, object: ObjectId) -> Result<String, HalError> {
        get_string("DeviceUID", object.0, global(kAudioDevicePropertyDeviceUID))
    }

    fn default_device(&self, scope: Scope) -> Result<Option<ObjectId>, HalError> {
        let id: u32 = get(
            "DefaultDevice",
            SYSTEM,
            global(Self::default_selector(scope)),
        )?;
        Ok((id != 0).then_some(ObjectId(id)))
    }

    fn set_default_device(&self, scope: Scope, object: ObjectId) -> Result<(), HalError> {
        set(
            "SetDefaultDevice",
            SYSTEM,
            global(Self::default_selector(scope)),
            &object.0,
        )?;
        if scope == Scope::Output {
            // System Settings moves the alert/system-sound device along with the output.
            let _ = set(
                "SetDefaultSystemOutput",
                SYSTEM,
                global(kAudioHardwarePropertyDefaultSystemOutputDevice),
                &object.0,
            );
        }
        Ok(())
    }

    fn volume(&self, object: ObjectId, scope: Scope) -> Result<Option<f32>, HalError> {
        let channels = channel_count(
            object.0,
            scoped(kAudioDevicePropertyStreamConfiguration, scope, MAIN),
        );
        Ok(self.read_volume(object.0, scope, channels).0)
    }

    fn set_volume(&self, object: ObjectId, scope: Scope, value: f32) -> Result<(), HalError> {
        let channels = channel_count(
            object.0,
            scoped(kAudioDevicePropertyStreamConfiguration, scope, MAIN),
        );
        let elements = self.volume_elements(object.0, scope, channels);
        if elements.is_empty() {
            return Err(HalError::new(
                HalErrorKind::NotSupported,
                "SetVolume",
                "no volume control",
            ));
        }
        for e in elements {
            set(
                "SetVolume",
                object.0,
                scoped(kAudioDevicePropertyVolumeScalar, scope, e),
                &value,
            )?;
        }
        Ok(())
    }

    fn mute(&self, object: ObjectId, scope: Scope) -> Result<Option<bool>, HalError> {
        Ok(get::<u32>(
            "Mute",
            object.0,
            scoped(kAudioDevicePropertyMute, scope, MAIN),
        )
        .ok()
        .map(|m| m != 0))
    }

    fn set_mute(&self, object: ObjectId, scope: Scope, muted: bool) -> Result<(), HalError> {
        set(
            "SetMute",
            object.0,
            scoped(kAudioDevicePropertyMute, scope, MAIN),
            &u32::from(muted),
        )
    }

    fn sample_rate(&self, object: ObjectId) -> Result<f64, HalError> {
        get(
            "NominalSampleRate",
            object.0,
            global(kAudioDevicePropertyNominalSampleRate),
        )
    }

    fn set_sample_rate(&self, object: ObjectId, hz: f64) -> Result<(), HalError> {
        set(
            "SetNominalSampleRate",
            object.0,
            global(kAudioDevicePropertyNominalSampleRate),
            &hz,
        )
    }

    fn format(&self, object: ObjectId, scope: Scope) -> Result<Option<StreamFormat>, HalError> {
        let Some(stream) = self.first_stream(object.0, scope) else {
            return Ok(None);
        };
        get::<AudioStreamBasicDescription>(
            "PhysicalFormat",
            stream,
            global(kAudioStreamPropertyPhysicalFormat),
        )
        .map(|d| Some(to_format(d)))
    }

    fn set_format(
        &self,
        object: ObjectId,
        scope: Scope,
        format: StreamFormat,
    ) -> Result<(), HalError> {
        let stream = self.first_stream(object.0, scope).ok_or_else(|| {
            HalError::new(HalErrorKind::NotSupported, "SetPhysicalFormat", "no stream")
        })?;
        let offered: Vec<AudioStreamRangedDescription> = get_vec(
            "AvailablePhysicalFormats",
            stream,
            global(kAudioStreamPropertyAvailablePhysicalFormats),
        )?;
        // Use the device's own description of the format, with the requested rate.
        let mut asbd = offered
            .iter()
            .find(|r| {
                let f = to_format(r.mFormat);
                f.bits == format.bits
                    && f.channels == format.channels
                    && format.rate >= r.mSampleRateRange.mMinimum - 0.5
                    && format.rate <= r.mSampleRateRange.mMaximum + 0.5
            })
            .map(|r| r.mFormat)
            .ok_or_else(|| {
                HalError::new(
                    HalErrorKind::NotSupported,
                    "SetPhysicalFormat",
                    "format not offered",
                )
            })?;
        asbd.mSampleRate = format.rate;
        set(
            "SetPhysicalFormat",
            stream,
            global(kAudioStreamPropertyPhysicalFormat),
            &asbd,
        )
    }

    fn create_aggregate(&self, spec: &AggregateSpec) -> Result<ObjectId, HalError> {
        let key = |k: &std::ffi::CStr| NSString::from_str(k.to_str().unwrap_or_default());
        let text = |s: &str| NSString::from_str(s);
        let dict = new_obj("NSMutableDictionary")
            .map_err(|e| HalError::new(HalErrorKind::Other, "CreateAggregate", &e))?;
        let (yes, no) = (NSNumber::new_bool(true), NSNumber::new_bool(false));
        dict_set(&dict, &key(kAudioAggregateDeviceNameKey), &text(&spec.name));
        dict_set(&dict, &key(kAudioAggregateDeviceUIDKey), &text(&spec.uid));
        dict_set(
            &dict,
            &key(kAudioAggregateDeviceMainSubDeviceKey),
            &text(&spec.main_uid),
        );
        dict_set(&dict, &key(kAudioAggregateDeviceIsPrivateKey), &no);
        dict_set(
            &dict,
            &key(kAudioAggregateDeviceIsStackedKey),
            if spec.stacked { &yes } else { &no },
        );
        let mut subs: Vec<Retained<AnyObject>> = Vec::new();
        for uid in &spec.member_uids {
            let sub = new_obj("NSMutableDictionary")
                .map_err(|e| HalError::new(HalErrorKind::Other, "CreateAggregate", &e))?;
            dict_set(&sub, &key(kAudioSubDeviceUIDKey), &text(uid));
            // The main device is the clock; every other member follows it with drift correction.
            let drift = if *uid == spec.main_uid { &no } else { &yes };
            dict_set(&sub, &key(kAudioSubDeviceDriftCompensationKey), drift);
            subs.push(sub);
        }
        let refs: Vec<&AnyObject> = subs.iter().map(|s| &**s).collect();
        let list = array_of(&refs)
            .map_err(|e| HalError::new(HalErrorKind::Other, "CreateAggregate", &e))?;
        dict_set(&dict, &key(kAudioAggregateDeviceSubDeviceListKey), &list);
        let mut id: AudioObjectID = 0;
        // SAFETY: NSMutableDictionary is toll-free bridged to CFDictionary and `dict` outlives the call;
        // `id` is a live local.
        let status = unsafe {
            let cf = &*Retained::as_ptr(&dict).cast::<CFDictionary>();
            AudioHardwareCreateAggregateDevice(cf, NonNull::from(&mut id))
        };
        if status == 0 {
            Ok(ObjectId(id))
        } else {
            Err(error("AudioHardwareCreateAggregateDevice", status))
        }
    }

    fn aggregate_members(&self, object: ObjectId) -> Result<Vec<String>, HalError> {
        get_strings(
            "FullSubDeviceList",
            object.0,
            global(kAudioAggregateDevicePropertyFullSubDeviceList),
        )
    }

    fn destroy_aggregate(&self, object: ObjectId) -> Result<(), HalError> {
        // SAFETY: plain object id; the HAL validates it.
        let status = unsafe { AudioHardwareDestroyAggregateDevice(object.0) };
        if status == 0 {
            Ok(())
        } else {
            Err(error("AudioHardwareDestroyAggregateDevice", status))
        }
    }

    fn change_epoch(&self) -> u64 {
        self.epoch.load(Ordering::SeqCst)
    }
}
