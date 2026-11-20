//! GPU figures the IORegistry publishes without privileges (Swift issue #402).
//!
//! Every `IOAccelerator` service carries `PerformanceStatistics` with `Device
//! Utilization %`, and its user clients carry an `AppUsage` list with
//! `accumulatedGPUTime` counters (ns). Single property keys only, never a whole
//! subtree; every `io_object_t` is released exactly once. Undocumented keys.
//! Port of `IORegistryGPUReader` in `GPURegistry.swift`.

use std::ffi::{c_char, c_void};

use core_foundation::array::CFArray;
use core_foundation::base::{CFType, TCFType};
use core_foundation::dictionary::CFDictionary;
use core_foundation::number::CFNumber;
use core_foundation::string::CFString;
use core_foundation_sys::base::{CFAllocatorRef, CFTypeRef, kCFAllocatorDefault};
use core_foundation_sys::dictionary::CFDictionaryRef;
use core_foundation_sys::string::CFStringRef;
use symcockpit_core::metrics::GpuUtilizationReading;
use symcockpit_core::processes::{GpuClientReading, GpuRegistryClient};

#[allow(non_camel_case_types)]
type io_object_t = u32;

const K_IO_REGISTRY_ITERATE_RECURSIVELY: u32 = 1;

#[link(name = "IOKit", kind = "framework")]
unsafe extern "C" {
    fn IOServiceMatching(name: *const c_char) -> CFDictionaryRef;
    fn IOServiceGetMatchingServices(
        main_port: u32,
        matching: CFDictionaryRef,
        existing: *mut io_object_t,
    ) -> i32;
    fn IOIteratorNext(iterator: io_object_t) -> io_object_t;
    fn IOObjectRelease(object: io_object_t) -> i32;
    fn IORegistryEntryCreateCFProperty(
        entry: io_object_t,
        key: CFStringRef,
        allocator: CFAllocatorRef,
        options: u32,
    ) -> CFTypeRef;
    fn IORegistryEntryCreateIterator(
        entry: io_object_t,
        plane: *const c_char,
        options: u32,
        it: *mut io_object_t,
    ) -> i32;
}

/// Owned registry object, released on drop.
struct Object(io_object_t);

impl Drop for Object {
    fn drop(&mut self) {
        // SAFETY: `self.0` is a live object handed to us by IOKit, released exactly once here.
        unsafe { IOObjectRelease(self.0) };
    }
}

/// Every object an iterator yields, each owned by the returned guard.
fn drain(iterator: &Object) -> impl Iterator<Item = Object> + '_ {
    // SAFETY: `iterator` is a live iterator; IOIteratorNext returns 0 at the end.
    std::iter::from_fn(move || match unsafe { IOIteratorNext(iterator.0) } {
        0 => None,
        object => Some(Object(object)),
    })
}

fn for_each_accelerator(mut body: impl FnMut(&Object)) {
    // SAFETY: the matching dictionary is consumed by IOServiceGetMatchingServices.
    let matching = unsafe { IOServiceMatching(c"IOAccelerator".as_ptr()) };
    if matching.is_null() {
        return;
    }
    let mut iterator = 0;
    // SAFETY: kIOMainPortDefault is MACH_PORT_NULL (0); `iterator` is a valid out-pointer.
    if unsafe { IOServiceGetMatchingServices(0, matching, &mut iterator) } != 0 {
        return;
    }
    let iterator = Object(iterator);
    for service in drain(&iterator) {
        body(&service);
    }
}

fn property(entry: &Object, key: &str) -> Option<CFType> {
    let key = CFString::new(key);
    // SAFETY: `entry` is live and `key` a valid CFString; the result is owned (Create rule) or NULL.
    let value = unsafe {
        IORegistryEntryCreateCFProperty(entry.0, key.as_concrete_TypeRef(), kCFAllocatorDefault, 0)
    };
    // SAFETY: non-null result of a Create call.
    (!value.is_null()).then(|| unsafe { CFType::wrap_under_create_rule(value) })
}

fn dict_value(dict: &CFDictionary, key: &str) -> Option<CFType> {
    let key = CFString::new(key);
    let found = dict.find(key.as_concrete_TypeRef() as *const c_void)?;
    // SAFETY: a dictionary value is a valid CF object; the get rule retains it.
    Some(unsafe { CFType::wrap_under_get_rule(*found as CFTypeRef) })
}

/// `Device Utilization %` clamped to 0-100; `None` when absent, not a number, or not finite.
fn clamp_utilization(value: f64) -> Option<f64> {
    value.is_finite().then(|| value.clamp(0.0, 100.0))
}

fn utilization_of(service: &Object) -> Option<f64> {
    let statistics = property(service, "PerformanceStatistics")?.downcast::<CFDictionary>()?;
    let number = dict_value(&statistics, "Device Utilization %")?.downcast::<CFNumber>()?;
    clamp_utilization(number.to_f64()?)
}

/// Splits an `IOUserClientCreator` such as `"pid 417, WindowServer"`.
pub fn parse_creator(creator: &str) -> Option<(i32, String)> {
    let rest = creator.strip_prefix("pid ")?;
    let (pid, name) = rest.split_once(',').unwrap_or((rest, ""));
    let pid: i32 = pid.trim().parse().ok().filter(|p| *p > 0)?;
    let name = name.trim();
    Some((
        pid,
        if name.is_empty() {
            format!("pid {pid}")
        } else {
            name.to_string()
        },
    ))
}

/// `accumulatedGPUTime` of every `AppUsage` entry; `None` when any element is not a dictionary
/// (Swift's `as? [[String: Any]]` fails as a whole then).
fn accumulated_times(usage: CFType) -> Option<Vec<u64>> {
    let entries = usage.downcast::<CFArray>()?;
    let mut times = Vec::new();
    for entry in entries.iter() {
        // SAFETY: array elements are valid CF objects; the get rule retains them.
        let entry = unsafe { CFType::wrap_under_get_rule(*entry as CFTypeRef) }
            .downcast::<CFDictionary>()?;
        let time = dict_value(&entry, "accumulatedGPUTime")
            .and_then(|v| v.downcast::<CFNumber>()?.to_i64());
        times.extend(time.and_then(|t| u64::try_from(t).ok()));
    }
    Some(times)
}

fn client_of(entry: &Object) -> Option<GpuRegistryClient> {
    let creator = property(entry, "IOUserClientCreator")?
        .downcast::<CFString>()?
        .to_string();
    let (pid, name) = parse_creator(&creator)?;
    let accumulated_gpu_time_nanoseconds = property(entry, "AppUsage").and_then(accumulated_times);
    Some(GpuRegistryClient {
        pid,
        name,
        accumulated_gpu_time_nanoseconds,
    })
}

/// IOKit-backed reader for GPU utilization and per-process GPU clients.
pub struct IoRegistryGpuReader;

impl GpuUtilizationReading for IoRegistryGpuReader {
    /// The maximum `Device Utilization %` across accelerators.
    fn read_utilization_percent(&self) -> Option<f64> {
        let mut best: Option<f64> = None;
        for_each_accelerator(|service| {
            if let Some(value) = utilization_of(service) {
                best = Some(best.map_or(value, |b| b.max(value)));
            }
        });
        best
    }
}

impl GpuClientReading for IoRegistryGpuReader {
    fn read_clients(&self) -> Vec<GpuRegistryClient> {
        let mut clients = Vec::new();
        for_each_accelerator(|accelerator| {
            let mut iterator = 0;
            // SAFETY: `accelerator` is live; `iterator` is a valid out-pointer; the plane name is NUL-terminated.
            let rc = unsafe {
                IORegistryEntryCreateIterator(
                    accelerator.0,
                    c"IOService".as_ptr(),
                    K_IO_REGISTRY_ITERATE_RECURSIVELY,
                    &mut iterator,
                )
            };
            if rc != 0 {
                return;
            }
            let iterator = Object(iterator);
            clients.extend(drain(&iterator).filter_map(|child| client_of(&child)));
        });
        clients
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Vectors: tuning/Tests/SymCockpitCoreTests/GPURegistryTests.swift (GPUParsingTests)
    #[test]
    fn parses_the_creator_string() {
        assert_eq!(
            parse_creator("pid 417, WindowServer"),
            Some((417, "WindowServer".into()))
        );
        assert_eq!(
            parse_creator("pid 12, Name, With Comma"),
            Some((12, "Name, With Comma".into()))
        );
        assert_eq!(parse_creator("pid 12"), Some((12, "pid 12".into())));
        assert_eq!(parse_creator("kernel"), None);
        assert_eq!(parse_creator("pid x, nope"), None);
        assert_eq!(parse_creator("pid 0, root"), None);
    }

    #[test]
    fn utilization_is_clamped_and_must_be_finite() {
        assert_eq!(clamp_utilization(37.0), Some(37.0));
        assert_eq!(clamp_utilization(250.0), Some(100.0));
        assert_eq!(clamp_utilization(-4.0), Some(0.0));
        assert_eq!(clamp_utilization(f64::NAN), None);
        assert_eq!(clamp_utilization(f64::INFINITY), None);
    }
}
