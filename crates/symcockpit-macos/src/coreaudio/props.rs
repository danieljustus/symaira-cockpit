//! Safe wrappers over `AudioObject*PropertyData`. Every `unsafe` block here
//! states why the call is sound; callers see only `Result`s.

use std::mem::{MaybeUninit, size_of};
use std::ptr::{NonNull, null};

use objc2::rc::Retained;
use objc2_core_audio::{
    AudioObjectGetPropertyData, AudioObjectGetPropertyDataSize, AudioObjectHasProperty,
    AudioObjectID, AudioObjectIsPropertySettable, AudioObjectPropertyAddress,
    AudioObjectSetPropertyData, kAudioHardwareBadObjectError, kAudioHardwareIllegalOperationError,
    kAudioHardwareUnsupportedOperationError, kAudioObjectPropertyElementMain,
    kAudioObjectPropertyScopeGlobal, kAudioObjectSystemObject,
};
use objc2_foundation::{NSArray, NSString};
use symcockpit_core::audio::{HalError, HalErrorKind, Scope};

pub(super) const SYSTEM: AudioObjectID = kAudioObjectSystemObject as AudioObjectID;
pub(super) type Addr = AudioObjectPropertyAddress;

// kAudioHardwareBadDeviceError, kAudioHardwareUnknownPropertyError ('who?'),
// kAudioHardwareBadPropertySizeError ('!siz'): not exported as constants we need elsewhere.
const BAD_DEVICE: i32 = 0x2164_6576;
const UNKNOWN_PROPERTY: i32 = 0x7768_6f3f;

pub(super) fn addr(selector: u32, scope: u32, element: u32) -> Addr {
    Addr {
        mSelector: selector,
        mScope: scope,
        mElement: element,
    }
}

pub(super) fn global(selector: u32) -> Addr {
    addr(
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    )
}

pub(super) fn scoped(selector: u32, scope: Scope, element: u32) -> Addr {
    use objc2_core_audio::{kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput};
    let s = match scope {
        Scope::Input => kAudioObjectPropertyScopeInput,
        Scope::Output => kAudioObjectPropertyScopeOutput,
    };
    addr(selector, s, element)
}

pub(super) fn fourcc(v: u32) -> String {
    let b = v.to_be_bytes();
    if b.iter().all(|c| (0x20..0x7f).contains(c)) {
        String::from_utf8_lossy(&b).into_owned()
    } else {
        v.to_string()
    }
}

/// Map an `OSStatus` to the coarse kind the core reasons about.
pub(super) fn error(op: &str, status: i32) -> HalError {
    let kind = match status {
        s if s == kAudioHardwareBadObjectError || s == BAD_DEVICE => HalErrorKind::NoSuchObject,
        s if s == kAudioHardwareUnsupportedOperationError
            || s == kAudioHardwareIllegalOperationError
            || s == UNKNOWN_PROPERTY =>
        {
            HalErrorKind::NotSupported
        }
        _ => HalErrorKind::Other,
    };
    HalError {
        kind,
        op: op.to_owned(),
        status: Some(status),
        message: format!("'{}'", fourcc(status as u32)),
    }
}

fn check(op: &str, status: i32) -> Result<(), HalError> {
    if status == 0 {
        Ok(())
    } else {
        Err(error(op, status))
    }
}

pub(super) fn has(object: AudioObjectID, a: Addr) -> bool {
    // SAFETY: `a` outlives the call and the pointer is non-null.
    unsafe { AudioObjectHasProperty(object, NonNull::from(&a)) }
}

pub(super) fn settable(object: AudioObjectID, a: Addr) -> bool {
    let mut flag: u8 = 0;
    // SAFETY: both pointers are to live locals of the sizes the API expects.
    let status = unsafe {
        AudioObjectIsPropertySettable(object, NonNull::from(&a), NonNull::from(&mut flag))
    };
    status == 0 && flag != 0
}

pub(super) fn size(op: &str, object: AudioObjectID, a: Addr) -> Result<u32, HalError> {
    let mut size = 0u32;
    // SAFETY: no qualifier; `a` and `size` are live locals.
    let status = unsafe {
        AudioObjectGetPropertyDataSize(
            object,
            NonNull::from(&a),
            0,
            null(),
            NonNull::from(&mut size),
        )
    };
    check(op, status).map(|()| size)
}

/// Read a plain-old-data property (`u32`, `f32`, `f64`, `AudioStreamBasicDescription`, ...).
/// Only call with types for which every bit pattern is valid.
pub(super) fn get<T: Copy>(op: &str, object: AudioObjectID, a: Addr) -> Result<T, HalError> {
    let mut value = MaybeUninit::<T>::zeroed();
    let mut len = size_of::<T>() as u32;
    // SAFETY: `value` is a writable buffer of `len` bytes; the HAL writes at most `len`.
    let status = unsafe {
        AudioObjectGetPropertyData(
            object,
            NonNull::from(&a),
            0,
            null(),
            NonNull::from(&mut len),
            NonNull::from(&mut value).cast(),
        )
    };
    check(op, status)?;
    if len as usize != size_of::<T>() {
        return Err(HalError::new(
            HalErrorKind::Other,
            op,
            "unexpected property size",
        ));
    }
    // SAFETY: zero-initialised, then filled by the HAL; T is POD by this function's contract.
    Ok(unsafe { value.assume_init() })
}

/// Read an array-valued POD property.
pub(super) fn get_vec<T: Copy>(
    op: &str,
    object: AudioObjectID,
    a: Addr,
) -> Result<Vec<T>, HalError> {
    let mut len = size(op, object, a)?;
    let mut out: Vec<T> = Vec::with_capacity(len as usize / size_of::<T>().max(1));
    // SAFETY: the buffer holds `len` bytes of capacity; we set the length only to what was written.
    let status = unsafe {
        AudioObjectGetPropertyData(
            object,
            NonNull::from(&a),
            0,
            null(),
            NonNull::from(&mut len),
            NonNull::new(out.as_mut_ptr().cast()).unwrap_or(NonNull::dangling()),
        )
    };
    check(op, status)?;
    // SAFETY: the HAL initialised `len` bytes, T is POD.
    unsafe { out.set_len(len as usize / size_of::<T>().max(1)) };
    Ok(out)
}

pub(super) fn set<T: Copy>(
    op: &str,
    object: AudioObjectID,
    a: Addr,
    value: &T,
) -> Result<(), HalError> {
    // SAFETY: `value` is a readable buffer of exactly `size_of::<T>()` bytes.
    let status = unsafe {
        AudioObjectSetPropertyData(
            object,
            NonNull::from(&a),
            0,
            null(),
            size_of::<T>() as u32,
            NonNull::from(value).cast(),
        )
    };
    check(op, status)
}

/// A `CFStringRef` property (returned retained). CFString and NSString are toll-free bridged.
pub(super) fn get_string(op: &str, object: AudioObjectID, a: Addr) -> Result<String, HalError> {
    let raw: *mut NSString = get(op, object, a)?;
    // SAFETY: the HAL returns a +1 CFString; ownership moves into `Retained`.
    let s = unsafe { Retained::from_raw(raw) }
        .ok_or_else(|| HalError::new(HalErrorKind::Other, op, "null string"))?;
    Ok(s.to_string())
}

/// A `CFArrayRef` of `CFStringRef` property (returned retained).
pub(super) fn get_strings(
    op: &str,
    object: AudioObjectID,
    a: Addr,
) -> Result<Vec<String>, HalError> {
    let raw: *mut NSArray<NSString> = get(op, object, a)?;
    // SAFETY: as above, the HAL returns a +1 CFArray; NSArray is its toll-free twin.
    let array = unsafe { Retained::from_raw(raw) }
        .ok_or_else(|| HalError::new(HalErrorKind::Other, op, "null array"))?;
    Ok(array.to_vec().iter().map(|s| s.to_string()).collect())
}

/// Total channel count of an `AudioBufferList` property (stream configuration).
pub(super) fn channel_count(object: AudioObjectID, a: Addr) -> u32 {
    use objc2_core_audio_types::AudioBufferList;
    let Ok(mut len) = size("StreamConfiguration", object, a) else {
        return 0;
    };
    // u64 elements: the list needs 8-byte alignment.
    let mut buf = vec![0u64; (len as usize).div_ceil(8)];
    // SAFETY: `buf` has at least `len` bytes.
    let status = unsafe {
        AudioObjectGetPropertyData(
            object,
            NonNull::from(&a),
            0,
            null(),
            NonNull::from(&mut len),
            NonNull::new(buf.as_mut_ptr().cast()).unwrap_or(NonNull::dangling()),
        )
    };
    if status != 0 || (len as usize) < size_of::<u32>() {
        return 0;
    }
    let list = buf.as_ptr().cast::<AudioBufferList>();
    // SAFETY: the HAL wrote a well-formed list; we read `mNumberBuffers` entries,
    // bounded by the bytes it reported, from an 8-byte aligned buffer.
    unsafe {
        let n = (*list).mNumberBuffers as usize;
        let max =
            (len as usize).saturating_sub(8) / size_of::<objc2_core_audio_types::AudioBuffer>();
        (0..n.min(max))
            .map(|i| (*list).mBuffers.as_ptr().add(i).read().mNumberChannels)
            .sum()
    }
}
