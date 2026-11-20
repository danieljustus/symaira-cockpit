//! Live process-tap adapter (macOS 14.2+): `TapHal` for the per-app mixer.
//!
//! Listing processes is read-only. Everything else creates system objects and
//! needs the audio-capture permission: it runs only from the mixer, never in
//! tests. Not exercised on hardware yet (spike S4 was never run live).

use std::ffi::c_void;
use std::ptr::NonNull;
use std::sync::Arc;

use objc2::AnyThread;
use objc2::rc::Retained;
use objc2::runtime::{AnyClass, AnyObject};
use objc2_core_audio::{
    AudioDeviceCreateIOProcID, AudioDeviceDestroyIOProcID, AudioDeviceIOProcID, AudioDeviceStart,
    AudioDeviceStop, AudioHardwareCreateAggregateDevice, AudioHardwareCreateProcessTap,
    AudioHardwareDestroyAggregateDevice, AudioHardwareDestroyProcessTap, AudioObjectID,
    CATapDescription, CATapMuteBehavior, kAudioAggregateDeviceIsPrivateKey,
    kAudioAggregateDeviceIsStackedKey, kAudioAggregateDeviceMainSubDeviceKey,
    kAudioAggregateDeviceNameKey, kAudioAggregateDeviceSubDeviceListKey,
    kAudioAggregateDeviceTapAutoStartKey, kAudioAggregateDeviceTapListKey,
    kAudioAggregateDeviceUIDKey, kAudioHardwarePropertyProcessObjectList,
    kAudioProcessPropertyBundleID, kAudioProcessPropertyIsRunningOutput, kAudioProcessPropertyPID,
    kAudioSubDeviceUIDKey, kAudioSubTapDriftCompensationKey, kAudioSubTapUIDKey,
};
use objc2_core_audio_types::{AudioBufferList, AudioTimeStamp};
use objc2_core_foundation::CFDictionary;
use objc2_foundation::{NSArray, NSNumber, NSString, NSUUID};
use symcockpit_core::audio::mixer::{
    AudioProcess, IoHandle, Shared, Tap, TapHal, scale_interleaved,
};
use symcockpit_core::audio::{HalError, HalErrorKind};

use super::objc::{array_of, dict_set, new_obj};
use super::props::{SYSTEM, error, get, get_string, get_vec, global};

pub struct RealTapHal;

impl Default for RealTapHal {
    fn default() -> Self {
        Self::new()
    }
}

impl RealTapHal {
    pub fn new() -> Self {
        RealTapHal
    }
}

/// What the IOProc needs, owned by the `IoHandle` until `destroy_ioproc`.
struct IoCtx {
    proc_id: AudioDeviceIOProcID,
    /// An `Arc<Shared>` turned into a raw pointer; reclaimed after the HAL stopped calling.
    shared: *const Shared,
}

/// Audio callback: scales the tap's stereo mixdown into the aggregate's output.
///
/// Runs on the HAL's real-time thread: no allocation, no locks, no panics.
/// If the aggregate also has input streams (the main device is a headset with a
/// microphone), the tap is the last two-channel input buffer.
unsafe extern "C-unwind" fn io_proc(
    _device: AudioObjectID,
    _now: NonNull<AudioTimeStamp>,
    input: NonNull<AudioBufferList>,
    _input_time: NonNull<AudioTimeStamp>,
    output: NonNull<AudioBufferList>,
    _output_time: NonNull<AudioTimeStamp>,
    client: *mut c_void,
) -> i32 {
    // SAFETY: `client` is the `Arc<Shared>` pointer given at creation, alive until
    // `destroy_ioproc`, which the HAL serialises against running callbacks.
    let shared = unsafe { &*client.cast::<Shared>() };
    // SAFETY: the HAL passes valid buffer lists for the duration of the callback; the
    // buffers' byte sizes are the HAL's own and bound every slice we build.
    unsafe {
        let out_list = output.as_ref();
        let out_bufs = std::slice::from_raw_parts(
            out_list.mBuffers.as_ptr(),
            out_list.mNumberBuffers as usize,
        );
        for b in out_bufs {
            if !b.mData.is_null() {
                std::ptr::write_bytes(b.mData.cast::<u8>(), 0, b.mDataByteSize as usize);
            }
        }
        let in_list = input.as_ref();
        let in_bufs =
            std::slice::from_raw_parts(in_list.mBuffers.as_ptr(), in_list.mNumberBuffers as usize);
        let tap = in_bufs
            .iter()
            .rev()
            .find(|b| b.mNumberChannels == 2 && !b.mData.is_null());
        let out = out_bufs
            .iter()
            .find(|b| b.mNumberChannels >= 1 && !b.mData.is_null());
        let (Some(i), Some(o)) = (tap, out) else {
            shared.record_callback(false);
            return 0;
        };
        let ins = std::slice::from_raw_parts(i.mData.cast::<f32>(), i.mDataByteSize as usize / 4);
        let outs =
            std::slice::from_raw_parts_mut(o.mData.cast::<f32>(), o.mDataByteSize as usize / 4);
        scale_interleaved(
            ins,
            i.mNumberChannels as usize,
            outs,
            o.mNumberChannels as usize,
            shared.gain(),
        );
    }
    shared.record_callback(true);
    0
}

fn other(op: &str, message: &str) -> HalError {
    HalError::new(HalErrorKind::Other, op, message)
}

impl TapHal for RealTapHal {
    fn supported(&self) -> bool {
        AnyClass::get(c"CATapDescription").is_some()
    }

    fn processes(&self) -> Result<Vec<AudioProcess>, HalError> {
        let objects: Vec<u32> = get_vec(
            "ProcessObjectList",
            SYSTEM,
            global(kAudioHardwarePropertyProcessObjectList),
        )?;
        Ok(objects
            .into_iter()
            .filter_map(|object| {
                let pid =
                    get::<i32>("ProcessPID", object, global(kAudioProcessPropertyPID)).ok()?;
                Some(AudioProcess {
                    object,
                    pid,
                    bundle_id: get_string(
                        "ProcessBundleID",
                        object,
                        global(kAudioProcessPropertyBundleID),
                    )
                    .ok()
                    .filter(|b| !b.is_empty()),
                    running_output: get::<u32>(
                        "ProcessRunningOutput",
                        object,
                        global(kAudioProcessPropertyIsRunningOutput),
                    )
                    .is_ok_and(|v| v != 0),
                })
            })
            .collect())
    }

    fn create_tap(&self, process_object: u32) -> Result<Tap, HalError> {
        let processes: Retained<NSArray<NSNumber>> =
            NSArray::from_retained_slice(&[NSNumber::new_u32(process_object)]);
        let uuid = NSUUID::new();
        // SAFETY: plain Objective-C calls on a freshly allocated CATapDescription with valid arguments.
        let desc = unsafe {
            let d = CATapDescription::initStereoMixdownOfProcesses(
                CATapDescription::alloc(),
                &processes,
            );
            d.setName(&NSString::from_str("Symaira Cockpit app volume"));
            d.setUUID(&uuid);
            // Private: visible to this process only and gone when it exits.
            d.setPrivate(true);
            // Muted: the app's own output is silenced while the tap exists, we replay it scaled.
            d.setMuteBehavior(CATapMuteBehavior::Muted);
            d
        };
        let mut id: AudioObjectID = 0;
        // SAFETY: `desc` is a valid description and `id` a live local.
        let status = unsafe { AudioHardwareCreateProcessTap(Some(&desc), &mut id) };
        if status != 0 {
            return Err(error("AudioHardwareCreateProcessTap", status));
        }
        Ok(Tap {
            id,
            uid: uuid.UUIDString().to_string(),
        })
    }

    fn create_aggregate(&self, output_uid: &str, tap_uid: &str) -> Result<u32, HalError> {
        let key = |k: &std::ffi::CStr| NSString::from_str(k.to_str().unwrap_or_default());
        let text = |s: &str| NSString::from_str(s);
        let build = || -> Result<Retained<AnyObject>, String> {
            let dict = new_obj("NSMutableDictionary")?;
            let (yes, no) = (NSNumber::new_bool(true), NSNumber::new_bool(false));
            dict_set(
                &dict,
                &key(kAudioAggregateDeviceNameKey),
                &text("Symaira Cockpit app volume"),
            );
            dict_set(
                &dict,
                &key(kAudioAggregateDeviceUIDKey),
                &NSUUID::new().UUIDString(),
            );
            dict_set(
                &dict,
                &key(kAudioAggregateDeviceMainSubDeviceKey),
                &text(output_uid),
            );
            dict_set(&dict, &key(kAudioAggregateDeviceIsPrivateKey), &yes);
            dict_set(&dict, &key(kAudioAggregateDeviceIsStackedKey), &no);
            dict_set(&dict, &key(kAudioAggregateDeviceTapAutoStartKey), &yes);
            let sub = new_obj("NSMutableDictionary")?;
            dict_set(&sub, &key(kAudioSubDeviceUIDKey), &text(output_uid));
            dict_set(
                &dict,
                &key(kAudioAggregateDeviceSubDeviceListKey),
                &array_of(&[&*sub])?,
            );
            let tap = new_obj("NSMutableDictionary")?;
            dict_set(&tap, &key(kAudioSubTapUIDKey), &text(tap_uid));
            dict_set(&tap, &key(kAudioSubTapDriftCompensationKey), &yes);
            dict_set(
                &dict,
                &key(kAudioAggregateDeviceTapListKey),
                &array_of(&[&*tap])?,
            );
            Ok(dict)
        };
        let dict = build().map_err(|e| other("CreateAggregate", &e))?;
        let mut id: AudioObjectID = 0;
        // SAFETY: NSMutableDictionary is toll-free bridged to CFDictionary; `dict` outlives the call.
        let status = unsafe {
            let cf = &*Retained::as_ptr(&dict).cast::<CFDictionary>();
            AudioHardwareCreateAggregateDevice(cf, NonNull::from(&mut id))
        };
        if status == 0 {
            Ok(id)
        } else {
            Err(error("AudioHardwareCreateAggregateDevice", status))
        }
    }

    fn create_ioproc(&self, aggregate: u32, shared: Arc<Shared>) -> Result<IoHandle, HalError> {
        let raw = Arc::into_raw(shared);
        let mut proc_id: AudioDeviceIOProcID = None;
        // SAFETY: `io_proc` matches the callback type; `raw` stays valid until `destroy_ioproc`.
        let status = unsafe {
            AudioDeviceCreateIOProcID(
                aggregate,
                Some(io_proc),
                raw.cast_mut().cast(),
                NonNull::from(&mut proc_id),
            )
        };
        if status != 0 {
            // SAFETY: the HAL did not keep the pointer; take the reference back.
            drop(unsafe { Arc::from_raw(raw) });
            return Err(error("AudioDeviceCreateIOProcID", status));
        }
        Ok(Box::into_raw(Box::new(IoCtx {
            proc_id,
            shared: raw,
        })) as usize)
    }

    fn start(&self, aggregate: u32, io: IoHandle) -> Result<(), HalError> {
        // SAFETY: `io` came from `create_ioproc` and has not been destroyed (the core's state machine).
        let status = unsafe { AudioDeviceStart(aggregate, (*(io as *const IoCtx)).proc_id) };
        if status == 0 {
            Ok(())
        } else {
            Err(error("AudioDeviceStart", status))
        }
    }

    fn stop(&self, aggregate: u32, io: IoHandle) -> Result<(), HalError> {
        // SAFETY: as in `start`.
        let status = unsafe { AudioDeviceStop(aggregate, (*(io as *const IoCtx)).proc_id) };
        if status == 0 {
            Ok(())
        } else {
            Err(error("AudioDeviceStop", status))
        }
    }

    fn destroy_ioproc(&self, aggregate: u32, io: IoHandle) -> Result<(), HalError> {
        // SAFETY: as in `start`.
        let status =
            unsafe { AudioDeviceDestroyIOProcID(aggregate, (*(io as *const IoCtx)).proc_id) };
        if status != 0 {
            return Err(error("AudioDeviceDestroyIOProcID", status));
        }
        // SAFETY: after a successful destroy the HAL calls the proc no more; reclaim both boxes.
        let ctx = unsafe { Box::from_raw(io as *mut IoCtx) };
        drop(unsafe { Arc::from_raw(ctx.shared) });
        Ok(())
    }

    fn destroy_aggregate(&self, aggregate: u32) -> Result<(), HalError> {
        // SAFETY: plain object id.
        let status = unsafe { AudioHardwareDestroyAggregateDevice(aggregate) };
        if status == 0 {
            Ok(())
        } else {
            Err(error("AudioHardwareDestroyAggregateDevice", status))
        }
    }

    fn destroy_tap(&self, tap: u32) -> Result<(), HalError> {
        // SAFETY: plain object id.
        let status = unsafe { AudioHardwareDestroyProcessTap(tap) };
        if status == 0 {
            Ok(())
        } else {
            Err(error("AudioHardwareDestroyProcessTap", status))
        }
    }
}
