//! Mounted volumes and boot-volume capacity from native metadata reads
//! (CFURL resource values, the same source as Foundation's `URLResourceValues`).
//! Port of `StorageVolumeService` (adapter part) and `readDisk()`.

use std::ffi::c_void;

use core_foundation::base::{CFType, TCFType};
use core_foundation::boolean::CFBoolean;
use core_foundation::number::CFNumber;
use core_foundation::string::CFString;
use core_foundation::url::CFURL;
use core_foundation_sys::base::{Boolean, CFIndex, CFTypeRef, kCFAllocatorDefault};
use core_foundation_sys::error::CFErrorRef;
use core_foundation_sys::string::CFStringRef;
use core_foundation_sys::url::{
    CFURLCreateFromFileSystemRepresentation, CFURLRef, kCFURLVolumeAvailableCapacityKey,
    kCFURLVolumeIsBrowsableKey, kCFURLVolumeIsInternalKey, kCFURLVolumeIsLocalKey,
    kCFURLVolumeIsReadOnlyKey, kCFURLVolumeNameKey, kCFURLVolumeTotalCapacityKey,
    kCFURLVolumeUUIDStringKey,
};
use symcockpit_core::metrics::{DiskReport, VolumeResourceValues, VolumeSource, disk_statistics};

// Declared here because core-foundation-sys leaves both commented out.
unsafe extern "C" {
    fn CFURLCopyResourcePropertyForKey(
        url: CFURLRef,
        key: CFStringRef,
        property_value_type_ref_ptr: *mut c_void,
        error: *mut CFErrorRef,
    ) -> Boolean;
    static kCFURLVolumeAvailableCapacityForImportantUsageKey: CFStringRef;
}

fn property(url: &CFURL, key: CFStringRef) -> Option<CFType> {
    let mut value: CFTypeRef = std::ptr::null();
    // SAFETY: `url` and `key` are valid CF objects; `value` receives a +1 reference on success.
    let ok = unsafe {
        CFURLCopyResourcePropertyForKey(
            url.as_concrete_TypeRef(),
            key,
            (&mut value as *mut CFTypeRef).cast(),
            std::ptr::null_mut(),
        )
    };
    // SAFETY: on success `value` is an owned (Create/Copy rule) CF object.
    (ok != 0 && !value.is_null()).then(|| unsafe { CFType::wrap_under_create_rule(value) })
}

fn string(url: &CFURL, key: CFStringRef) -> Option<String> {
    property(url, key)?
        .downcast::<CFString>()
        .map(|s| s.to_string())
}

fn boolean(url: &CFURL, key: CFStringRef) -> Option<bool> {
    property(url, key)?.downcast::<CFBoolean>().map(bool::from)
}

fn integer(url: &CFURL, key: CFStringRef) -> Option<i64> {
    property(url, key)?.downcast::<CFNumber>()?.to_i64()
}

/// Volume metadata of `path`; `None` when nothing can be read (missing or unreadable volume).
pub fn resource_values(path: &str) -> Option<VolumeResourceValues> {
    // SAFETY: `path` is valid for `path.len()` bytes for the duration of the call.
    let raw = unsafe {
        CFURLCreateFromFileSystemRepresentation(
            kCFAllocatorDefault,
            path.as_ptr(),
            path.len() as CFIndex,
            1,
        )
    };
    if raw.is_null() {
        return None;
    }
    // SAFETY: `raw` is an owned CFURL (Create rule), non-null as checked.
    let url = unsafe { CFURL::wrap_under_create_rule(raw) };
    // SAFETY: the extern statics are immortal CFStrings provided by CoreFoundation.
    let values = unsafe {
        VolumeResourceValues {
            name: string(&url, kCFURLVolumeNameKey),
            uuid: string(&url, kCFURLVolumeUUIDStringKey),
            is_internal: boolean(&url, kCFURLVolumeIsInternalKey),
            is_local: boolean(&url, kCFURLVolumeIsLocalKey),
            is_read_only: boolean(&url, kCFURLVolumeIsReadOnlyKey),
            is_browsable: boolean(&url, kCFURLVolumeIsBrowsableKey),
            total_capacity: integer(&url, kCFURLVolumeTotalCapacityKey),
            available_capacity: integer(&url, kCFURLVolumeAvailableCapacityKey),
            available_capacity_for_important_usage: integer(
                &url,
                kCFURLVolumeAvailableCapacityForImportantUsageKey,
            ),
        }
    };
    (values.name.is_some() || values.total_capacity.is_some()).then_some(values)
}

/// Mount table via `getmntinfo`; volumes flagged `MNT_DONTBROWSE` (hidden) are skipped,
/// like `skipHiddenVolumes`.
pub struct LiveVolumeSource;

impl VolumeSource for LiveVolumeSource {
    fn mounted_volumes(&self) -> Vec<String> {
        let mut table: *mut libc::statfs = std::ptr::null_mut();
        // SAFETY: `table` receives a pointer to libc-owned storage valid until the next getmntinfo call.
        let count = unsafe { libc::getmntinfo(&mut table, libc::MNT_NOWAIT) };
        if count <= 0 || table.is_null() {
            return Vec::new();
        }
        // SAFETY: getmntinfo returned `count` initialised entries at `table`.
        let entries = unsafe { std::slice::from_raw_parts(table, count as usize) };
        entries
            .iter()
            .filter(|e| e.f_flags as libc::c_int & libc::MNT_DONTBROWSE == 0)
            .filter_map(|e| {
                // SAFETY: `f_mntonname` is a NUL-terminated C string inside the entry.
                let name = unsafe { std::ffi::CStr::from_ptr(e.f_mntonname.as_ptr()) };
                name.to_str().ok().map(String::from)
            })
            .collect()
    }

    fn resource_values(&self, path: &str) -> Option<VolumeResourceValues> {
        resource_values(path)
    }
}

/// Boot-volume capacity as macOS itself reports it: the data volume answers
/// the availability question Finder asks (purgeable space counted as free);
/// `statfs` stays as the fallback.
pub fn read_disk() -> Option<DiskReport> {
    ["/System/Volumes/Data", "/"]
        .iter()
        .find_map(|path| resource_values(path).as_ref().and_then(disk_statistics))
        .or_else(read_disk_statfs)
}

fn read_disk_statfs() -> Option<DiskReport> {
    let mut stats = std::mem::MaybeUninit::<libc::statfs>::zeroed();
    // SAFETY: `stats` is a writable statfs and the path is NUL-terminated.
    if unsafe { libc::statfs(c"/".as_ptr(), stats.as_mut_ptr()) } != 0 {
        return None;
    }
    // SAFETY: fully written by the successful call.
    let stats = unsafe { stats.assume_init() };
    let block = u64::from(stats.f_bsize);
    let (capacity, free) = (stats.f_blocks * block, stats.f_bfree * block);
    Some(DiskReport {
        capacity_bytes: capacity,
        used_bytes: capacity.saturating_sub(free),
        free_bytes: free,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn boot_volume_is_listed_first_with_consistent_capacity() {
        let disk = read_disk().expect("boot disk");
        assert_eq!(disk.used_bytes + disk.free_bytes, disk.capacity_bytes);
        let service =
            symcockpit_core::metrics::StorageVolumeService::new(Box::new(LiveVolumeSource));
        let volumes = service.read();
        assert!(volumes.first().is_some_and(|v| v.is_boot()));
        assert!(
            volumes
                .iter()
                .all(|v| !v.mount_path.starts_with("/System/Volumes/"))
        );
    }

    #[test]
    fn unreadable_path_has_no_values() {
        assert!(resource_values("/definitely/not/a/volume").is_none());
    }
}
