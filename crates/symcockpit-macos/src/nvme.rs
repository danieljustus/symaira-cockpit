//! NVMe SMART through `IONVMeSMARTInterface` (public SDK header
//! `NVMeSMARTLibExternal.h`), readable without root (spike S3). Capability
//! tier: `documented`. Only `SMARTReadData` and `GetIdentifyData` are ever
//! called; nothing writes to the device. The serial number in the identify
//! block is never copied out.
//!
//! Order matters: read first, then release the interface, then destroy the
//! plug-in. Destroying earlier closes the user client (`0x10000003`).

use std::ffi::{CStr, CString, c_char, c_void};
use std::ptr;

use symcockpit_contract::Error;
use symcockpit_core::storage::health::{Location, NvmeDevice, NvmeSource, SmartReadError};

type IoReturn = i32;
type CfRef = *const c_void;
const UTF8: u32 = 0x0800_0100;

#[repr(C)]
#[derive(Clone, Copy)]
struct UuidBytes([u8; 16]);

// Two frameworks on one block: clippy reads the two `kind` keys as a duplicate.
// Same C symbols as gpu.rs, typed with raw pointers here: identical ABI.
#[allow(clippy::duplicated_attributes, clashing_extern_declarations)]
#[link(name = "IOKit", kind = "framework")]
#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFBooleanTrue: CfRef;
    fn CFRelease(c: CfRef);
    fn CFStringCreateWithCString(alloc: CfRef, s: *const c_char, enc: u32) -> CfRef;
    fn CFStringGetCString(s: CfRef, buf: *mut c_char, len: isize, enc: u32) -> u8;
    fn CFDictionaryGetValue(d: CfRef, k: CfRef) -> CfRef;
    fn CFDictionaryCreateMutable(alloc: CfRef, cap: isize, kcb: CfRef, vcb: CfRef) -> CfRef;
    fn CFDictionarySetValue(d: CfRef, k: CfRef, v: CfRef);
    #[allow(clippy::too_many_arguments)]
    fn CFUUIDGetConstantUUIDWithBytes(
        alloc: CfRef,
        b0: u8,
        b1: u8,
        b2: u8,
        b3: u8,
        b4: u8,
        b5: u8,
        b6: u8,
        b7: u8,
        b8: u8,
        b9: u8,
        b10: u8,
        b11: u8,
        b12: u8,
        b13: u8,
        b14: u8,
        b15: u8,
    ) -> CfRef;
    fn CFUUIDGetUUIDBytes(u: CfRef) -> UuidBytes;
    fn IOServiceMatching(name: *const c_char) -> CfRef;
    fn IOServiceGetMatchingServices(port: u32, matching: CfRef, it: *mut u32) -> i32;
    fn IOIteratorNext(it: u32) -> u32;
    fn IOObjectRelease(o: u32) -> i32;
    fn IORegistryEntryCreateCFProperty(e: u32, key: CfRef, alloc: CfRef, opts: u32) -> CfRef;
    fn IOCreatePlugInInterfaceForService(
        svc: u32,
        plugin_type: CfRef,
        iface_type: CfRef,
        out: *mut *mut *mut PlugIn,
        score: *mut i32,
    ) -> i32;
    fn IODestroyPlugInInterface(p: *mut *mut PlugIn) -> i32;
}

/// `IOCFPlugInInterface` (IOCFPlugIn.h): IUnknown guts, then version/Probe/Start/Stop (unused).
#[repr(C)]
struct PlugIn {
    _reserved: *mut c_void,
    query_interface: unsafe extern "C" fn(*mut c_void, UuidBytes, *mut *mut c_void) -> i32,
    _add_ref: unsafe extern "C" fn(*mut c_void) -> u32,
    _release: unsafe extern "C" fn(*mut c_void) -> u32,
}

/// `IONVMeSMARTInterface`, field order as in the header.
#[repr(C)]
struct SmartIface {
    _reserved: *mut c_void,
    _query_interface: unsafe extern "C" fn(*mut c_void, UuidBytes, *mut *mut c_void) -> i32,
    _add_ref: unsafe extern "C" fn(*mut c_void) -> u32,
    release: unsafe extern "C" fn(*mut c_void) -> u32,
    _version: u16,
    _revision: u16,
    smart_read_data: unsafe extern "C" fn(*mut c_void, *mut u8) -> IoReturn,
    get_identify_data: unsafe extern "C" fn(*mut c_void, *mut u8, u32) -> IoReturn,
}

/// An owned CoreFoundation object (released on drop).
struct Cf(CfRef);

impl Drop for Cf {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: we own one reference obtained from a Create/Copy function.
            unsafe { CFRelease(self.0) }
        }
    }
}

fn cfstr(s: &str) -> Cf {
    let c = CString::new(s).expect("literal without NUL");
    // SAFETY: `c` is a valid NUL-terminated string; a null allocator means the default one.
    Cf(unsafe { CFStringCreateWithCString(ptr::null(), c.as_ptr(), UTF8) })
}

/// Text of a CFString we do not own; empty when null or not convertible.
fn cf_string(s: CfRef) -> String {
    let mut buf = [0 as c_char; 128];
    // SAFETY: `s` is null-checked; the buffer length passed is its real size.
    if s.is_null()
        || unsafe { CFStringGetCString(s, buf.as_mut_ptr(), buf.len() as isize, UTF8) } == 0
    {
        return String::new();
    }
    // SAFETY: CFStringGetCString NUL-terminated the buffer on success.
    unsafe { CStr::from_ptr(buf.as_ptr()) }
        .to_string_lossy()
        .into_owned()
}

/// An owned IOKit object (released on drop).
struct Service(u32);

impl Drop for Service {
    fn drop(&mut self) {
        // SAFETY: we own one reference to this io_object_t.
        unsafe { IOObjectRelease(self.0) };
    }
}

/// `Physical Interconnect Location` of the service (`Internal` / `External`).
fn location(svc: &Service) -> Location {
    let (key, sub) = (
        cfstr("Protocol Characteristics"),
        cfstr("Physical Interconnect Location"),
    );
    // SAFETY: valid service and CFString; null allocator; the result is owned (Create rule).
    let dict = Cf(unsafe { IORegistryEntryCreateCFProperty(svc.0, key.0, ptr::null(), 0) });
    if dict.0.is_null() {
        return Location::Unknown;
    }
    // SAFETY: `dict` is a CFDictionary for this key; the value is borrowed (Get rule) and used within this scope.
    match cf_string(unsafe { CFDictionaryGetValue(dict.0, sub.0) }).as_str() {
        "Internal" => Location::Internal,
        "External" => Location::External,
        _ => Location::Unknown,
    }
}

/// The plug-in and its SMART interface; releases them in the order that works.
struct Client {
    plug: *mut *mut PlugIn,
    this: *mut c_void,
}

impl Client {
    fn open(svc: &Service) -> Result<Client, SmartReadError> {
        // SAFETY: constant UUID lookups, null allocator.
        let (ty, plug_id, if_id) = unsafe {
            (
                CFUUIDGetConstantUUIDWithBytes(
                    ptr::null(),
                    0xAA,
                    0x0F,
                    0xA6,
                    0xF9,
                    0xC2,
                    0xD6,
                    0x45,
                    0x7F,
                    0xB1,
                    0x0B,
                    0x59,
                    0xA1,
                    0x32,
                    0x53,
                    0x29,
                    0x2F,
                ),
                CFUUIDGetConstantUUIDWithBytes(
                    ptr::null(),
                    0xC2,
                    0x44,
                    0xE8,
                    0x58,
                    0x10,
                    0x9C,
                    0x11,
                    0xD4,
                    0x91,
                    0xD4,
                    0x00,
                    0x50,
                    0xE4,
                    0xC6,
                    0x42,
                    0x6F,
                ),
                CFUUIDGetConstantUUIDWithBytes(
                    ptr::null(),
                    0xCC,
                    0xD1,
                    0xDB,
                    0x19,
                    0xFD,
                    0x9A,
                    0x4D,
                    0xAF,
                    0xBF,
                    0x95,
                    0x12,
                    0x45,
                    0x4B,
                    0x23,
                    0x0A,
                    0xB6,
                ),
            )
        };
        let (mut plug, mut score) = (ptr::null_mut(), 0);
        // SAFETY: out-pointers are valid for writes; the service is live.
        let kr =
            unsafe { IOCreatePlugInInterfaceForService(svc.0, ty, plug_id, &mut plug, &mut score) };
        if kr != 0 || plug.is_null() {
            return Err(SmartReadError {
                stage: "IOCreatePlugInInterfaceForService",
                code: kr,
            });
        }
        let mut this: *mut c_void = ptr::null_mut();
        // SAFETY: `plug` is a live plug-in interface; QueryInterface takes the interface pointer itself and returns an owned interface.
        let hr = unsafe {
            ((**plug).query_interface)(plug.cast(), CFUUIDGetUUIDBytes(if_id), &mut this)
        };
        if hr != 0 || this.is_null() {
            // SAFETY: `plug` came from IOCreatePlugInInterfaceForService and is destroyed once.
            unsafe { IODestroyPlugInInterface(plug) };
            return Err(SmartReadError {
                stage: "QueryInterface",
                code: hr,
            });
        }
        Ok(Client { plug, this })
    }

    fn iface(&self) -> *mut *mut SmartIface {
        self.this.cast()
    }

    fn smart(&self) -> Result<[u8; 512], SmartReadError> {
        let mut page = [0u8; 512];
        // SAFETY: the interface is live; SMARTReadData fills exactly 512 bytes into the buffer.
        match unsafe { ((**self.iface()).smart_read_data)(self.this, page.as_mut_ptr()) } {
            0 => Ok(page),
            code => Err(SmartReadError {
                stage: "SMARTReadData",
                code,
            }),
        }
    }

    /// Model (bytes 24..64) and firmware (64..72) from the identify block; never the serial (4..24).
    fn identify(&self) -> Option<(String, String)> {
        let mut buf = vec![0u8; 4096];
        // SAFETY: the interface is live; identify data is 4096 bytes, namespace 0 is the controller.
        let rc = unsafe { ((**self.iface()).get_identify_data)(self.this, buf.as_mut_ptr(), 0) };
        let text = |b: &[u8]| {
            String::from_utf8_lossy(b)
                .trim_matches(|c: char| c == ' ' || c == '\0')
                .to_owned()
        };
        (rc == 0).then(|| (text(&buf[24..64]), text(&buf[64..72])))
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        // SAFETY: release the interface first, then destroy the plug-in; each exactly once.
        unsafe {
            ((**self.iface()).release)(self.this);
            IODestroyPlugInInterface(self.plug);
        }
    }
}

/// Every service that advertises `NVMe SMART Capable = true`.
fn smart_capable_services() -> Result<Vec<Service>, IoReturn> {
    // SAFETY: all CF objects are checked for ownership below; the matching dictionary is
    // consumed by IOServiceGetMatchingServices; the property dictionary and keys are
    // kept alive (Cf guards) until after that call.
    unsafe {
        let matching = IOServiceMatching(c"IOService".as_ptr());
        if matching.is_null() {
            return Err(-1);
        }
        let props = Cf(CFDictionaryCreateMutable(
            ptr::null(),
            0,
            ptr::null(),
            ptr::null(),
        ));
        let (key, pm) = (cfstr("NVMe SMART Capable"), cfstr("IOPropertyMatch"));
        CFDictionarySetValue(props.0.cast_mut(), key.0, kCFBooleanTrue);
        CFDictionarySetValue(matching.cast_mut(), pm.0, props.0);
        let mut it = 0;
        let kr = IOServiceGetMatchingServices(0, matching, &mut it);
        if kr != 0 {
            return Err(kr);
        }
        let iterator = Service(it);
        let mut out = Vec::new();
        loop {
            match IOIteratorNext(iterator.0) {
                0 => break,
                svc => out.push(Service(svc)),
            }
        }
        Ok(out)
    }
}

/// Live NVMe source: internal and external SMART-capable devices.
pub struct IoKitNvme;

impl NvmeSource for IoKitNvme {
    fn devices(&self) -> Result<Vec<NvmeDevice>, Error> {
        let services = smart_capable_services()
            .map_err(|kr| Error::Failed(format!("IOServiceGetMatchingServices failed: {kr:#x}")))?;
        Ok(services
            .iter()
            .map(|svc| {
                let location = location(svc);
                match Client::open(svc) {
                    Err(e) => NvmeDevice {
                        location,
                        model: None,
                        firmware: None,
                        smart: Err(e),
                    },
                    Ok(client) => {
                        let smart = client.smart();
                        let id = client.identify();
                        NvmeDevice {
                            location,
                            model: id.as_ref().map(|i| i.0.clone()),
                            firmware: id.map(|i| i.1),
                            smart,
                        }
                    }
                }
            })
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fs_stats::SystemClock;
    use symcockpit_core::storage::health::{HealthParams, health_json};

    /// Real internal (and any external) NVMe: read-only, as the current user.
    /// `cargo test -p symcockpit-macos -- --ignored live_smart --nocapture`
    #[test]
    #[ignore = "reads the real NVMe devices (read-only, no root)"]
    fn live_smart_read_without_root() {
        // SAFETY: geteuid has no preconditions.
        assert_ne!(
            unsafe { libc::geteuid() },
            0,
            "run this test as a normal user"
        );
        let v = health_json(
            &IoKitNvme,
            &SystemClock,
            None,
            &HealthParams { record: false },
        )
        .unwrap();
        let devices = v["devices"].as_array().unwrap();
        assert!(
            devices.iter().any(|d| d["location"] == "internal"),
            "no internal NVMe found"
        );
        for d in devices {
            println!(
                "{} access={} grade={} checks={}",
                d["location"],
                d["access"]["status"],
                d["grade"],
                d["checks"].as_array().unwrap().len()
            );
            assert_eq!(d["access"]["status"], "ok", "{}", d["access"]);
            assert!(d["metrics"]["temperature_celsius"]["value"].is_number());
        }
        let text = v.to_string();
        assert!(!text.to_lowercase().contains("serial"));
        println!(
            "overall={} rules_version={}",
            v["overall_grade"], v["rules_version"]
        );
    }
}
