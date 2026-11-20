//! Trackpad haptics through the private MultitouchSupport framework (D09, ADR 0004).
//!
//! Every symbol is looked up with `dlsym` and a missing one becomes a named
//! `HapticLevel`, never a crash. The signatures below come from community
//! documentation of the framework, not from Apple headers: that is why `probe`
//! only checks that the symbols exist and the first real actuation is a
//! hardware acceptance step.

use std::ffi::{CStr, c_char, c_void};

use symcockpit_core::input::{HapticBackend, HapticLevel, HapticPattern};

const FRAMEWORK: &CStr =
    c"/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport";
const RTLD_NOW: i32 = 2;

/// Symbols in the order a failure is reported.
const SYMBOLS: [&str; 6] = [
    "MTDeviceCreateList",
    "MTDeviceGetDeviceID",
    "MTActuatorCreateFromDeviceID",
    "MTActuatorOpen",
    "MTActuatorActuate",
    "MTActuatorClose",
];

unsafe extern "C" {
    fn dlopen(path: *const c_char, mode: i32) -> *mut c_void;
    fn dlsym(handle: *mut c_void, name: *const c_char) -> *mut c_void;
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFArrayGetCount(array: *const c_void) -> isize;
    fn CFArrayGetValueAtIndex(array: *const c_void, index: isize) -> *const c_void;
    fn CFRelease(cf: *const c_void);
}

type CreateList = extern "C" fn() -> *const c_void;
type GetDeviceId = extern "C" fn(*const c_void, *mut u64) -> i32;
type ActuatorCreate = extern "C" fn(u64) -> *mut c_void;
type ActuatorOpen = extern "C" fn(*mut c_void) -> i32;
type ActuatorActuate = extern "C" fn(*mut c_void, i32, u32, f32, f32) -> i32;
type ActuatorClose = extern "C" fn(*mut c_void) -> i32;

struct Symbols {
    create_list: CreateList,
    get_device_id: GetDeviceId,
    create: ActuatorCreate,
    open: ActuatorOpen,
    actuate: ActuatorActuate,
    close: ActuatorClose,
}

/// First missing name according to `exists`, `None` when all are there.
fn first_missing(exists: impl Fn(&str) -> bool) -> Option<&'static str> {
    SYMBOLS.into_iter().find(|name| !exists(name))
}

fn open_framework() -> Result<*mut c_void, HapticLevel> {
    // SAFETY: `FRAMEWORK` is a valid NUL-terminated path; dlopen has no other preconditions.
    let handle = unsafe { dlopen(FRAMEWORK.as_ptr(), RTLD_NOW) };
    if handle.is_null() {
        Err(HapticLevel::FrameworkMissing)
    } else {
        Ok(handle)
    }
}

fn lookup(handle: *mut c_void, name: &str) -> *mut c_void {
    let name = std::ffi::CString::new(name).expect("symbol names have no NUL");
    // SAFETY: `handle` came from dlopen and `name` is NUL-terminated.
    unsafe { dlsym(handle, name.as_ptr()) }
}

fn load() -> Result<Symbols, HapticLevel> {
    let handle = open_framework()?;
    if let Some(missing) = first_missing(|n| !lookup(handle, n).is_null()) {
        return Err(HapticLevel::SymbolMissing(missing.to_owned()));
    }
    // SAFETY: every pointer was just checked to be non-null; the function types
    // are the documented signatures of these C functions (see the module docs).
    unsafe {
        Ok(Symbols {
            create_list: std::mem::transmute::<*mut c_void, CreateList>(lookup(handle, SYMBOLS[0])),
            get_device_id: std::mem::transmute::<*mut c_void, GetDeviceId>(lookup(
                handle, SYMBOLS[1],
            )),
            create: std::mem::transmute::<*mut c_void, ActuatorCreate>(lookup(handle, SYMBOLS[2])),
            open: std::mem::transmute::<*mut c_void, ActuatorOpen>(lookup(handle, SYMBOLS[3])),
            actuate: std::mem::transmute::<*mut c_void, ActuatorActuate>(lookup(
                handle, SYMBOLS[4],
            )),
            close: std::mem::transmute::<*mut c_void, ActuatorClose>(lookup(handle, SYMBOLS[5])),
        })
    }
}

#[derive(Default)]
pub struct MultitouchHaptics;

impl HapticBackend for MultitouchHaptics {
    /// Checks the framework and the six symbols; calls no framework function.
    fn probe(&self) -> HapticLevel {
        match open_framework() {
            Err(level) => level,
            Ok(handle) => match first_missing(|n| !lookup(handle, n).is_null()) {
                Some(missing) => HapticLevel::SymbolMissing(missing.to_owned()),
                None => HapticLevel::Available,
            },
        }
    }

    fn actuate(&self, pattern: HapticPattern) -> Result<(), HapticLevel> {
        let sym = load()?;
        // The list is owned by us (a "Create" function) and released below;
        // elements are borrowed from it and only used while it lives.
        let list = (sym.create_list)();
        if list.is_null() {
            return Err(HapticLevel::NoDevice);
        }
        let mut result = Err(HapticLevel::NoDevice);
        // SAFETY: indices stay below the count; see above for lifetimes.
        let count = unsafe { CFArrayGetCount(list) };
        for i in 0..count {
            let device = unsafe { CFArrayGetValueAtIndex(list, i) };
            let mut id = 0u64;
            if (sym.get_device_id)(device, &mut id) != 0 {
                continue;
            }
            let actuator = (sym.create)(id);
            if actuator.is_null() {
                continue; // this device has no actuator (external mouse, etc.)
            }
            result = if (sym.open)(actuator) != 0 {
                Err(HapticLevel::OpenFailed)
            } else {
                let status = (sym.actuate)(actuator, pattern.actuation_id, 0, 0.0, 0.0);
                let _ = (sym.close)(actuator);
                if status == 0 {
                    Ok(())
                } else {
                    Err(HapticLevel::ActuationFailed)
                }
            };
            if result.is_ok() {
                break;
            }
        }
        // SAFETY: releases the list obtained from `MTDeviceCreateList`.
        unsafe { CFRelease(list) };
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_missing_symbol_is_named() {
        assert_eq!(first_missing(|_| true), None);
        assert_eq!(
            first_missing(|n| n != "MTActuatorOpen"),
            Some("MTActuatorOpen")
        );
        assert_eq!(first_missing(|_| false), Some("MTDeviceCreateList"));
    }

    /// Hardware-independent but system-dependent (private framework): run on
    /// purpose with `cargo test -- --ignored`. Calls dlopen/dlsym only.
    #[test]
    #[ignore = "depends on the macOS version; checks symbols only"]
    fn live_symbols_are_present() {
        assert_eq!(MultitouchHaptics.probe(), HapticLevel::Available);
    }
}
