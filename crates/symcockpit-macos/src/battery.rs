//! Live battery adapters: the `AppleSmartBattery` registry node and Apple's
//! health figures from `system_profiler`.
//!
//! Privacy: the registry node and `system_profiler` carry serial numbers. The
//! registry conversion keeps numbers, booleans and nested dictionaries only
//! (strings and data are dropped on the way in), and the profiler output is
//! parsed for two lines and never stored or logged.

use std::ffi::{CStr, c_char};
use std::io::Read;
use std::process::{Command, Stdio};
use std::ptr::NonNull;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use objc2_core_foundation::{
    CFBoolean, CFDictionary, CFMutableDictionary, CFNumber, CFRetained, CFString, CFType,
};
use serde_json::{Map, Number, Value};
use symcockpit_core::battery::{
    AppleBatteryHealth, AppleHealthProvider, BatterySource, BatterySourceResult, CachedAppleHealth,
    parse_apple_health, properties_from_registry,
};

#[link(name = "IOKit", kind = "framework")]
unsafe extern "C" {
    fn IOServiceMatching(name: *const c_char) -> *mut c_void;
    fn IOServiceGetMatchingService(main_port: u32, matching: *mut c_void) -> u32;
    fn IORegistryEntryCreateCFProperties(
        entry: u32,
        properties: *mut *mut CFMutableDictionary,
        allocator: *const std::ffi::c_void,
        options: u32,
    ) -> i32;
    fn IOObjectRelease(object: u32) -> i32;
}

const KERN_SUCCESS: i32 = 0;
/// `kIOMainPortDefault` is `MACH_PORT_NULL`.
const IO_MAIN_PORT_DEFAULT: u32 = 0;

/// Owned IOKit object, released on drop.
struct IoObject(u32);

impl Drop for IoObject {
    fn drop(&mut self) {
        // SAFETY: `self.0` is a live object returned by IOKit and released
        // exactly once, here.
        unsafe { IOObjectRelease(self.0) };
    }
}

/// Reads the `AppleSmartBattery` node, unprivileged.
pub struct LiveBatterySource;

impl BatterySource for LiveBatterySource {
    fn read_properties(&self) -> BatterySourceResult {
        let Some(service) = matching_service(c"AppleSmartBattery") else {
            return BatterySourceResult::Unavailable;
        };
        match registry_properties(&service) {
            Some(props) => BatterySourceResult::Success(properties_from_registry(&props)),
            None => BatterySourceResult::ReadFailed,
        }
    }
}

fn matching_service(class: &CStr) -> Option<IoObject> {
    // SAFETY: `class` is NUL-terminated. `IOServiceGetMatchingService`
    // consumes the matching dictionary (even on failure), so it is not
    // released here; a null dictionary is passed through and yields 0.
    let service = unsafe {
        let matching = IOServiceMatching(class.as_ptr());
        IOServiceGetMatchingService(IO_MAIN_PORT_DEFAULT, matching)
    };
    (service != 0).then_some(IoObject(service))
}

fn registry_properties(service: &IoObject) -> Option<Value> {
    let mut raw: *mut CFMutableDictionary = std::ptr::null_mut();
    // SAFETY: `service` is a live registry entry and `raw` a valid out
    // pointer; a null allocator selects the default one.
    let status =
        unsafe { IORegistryEntryCreateCFProperties(service.0, &mut raw, std::ptr::null(), 0) };
    if status != KERN_SUCCESS {
        return None;
    }
    // SAFETY: on success the call returns a +1 retained dictionary that we own.
    let dict = unsafe { CFRetained::from_raw(NonNull::new(raw)?) };
    Some(dictionary_to_json(&dict))
}

/// Numbers, booleans and nested dictionaries only; everything else (strings,
/// data, arrays) is dropped, which keeps serial numbers out of this process's
/// data structures.
fn dictionary_to_json(dict: &CFDictionary) -> Value {
    // SAFETY: registry property dictionaries are keyed by CFString and hold
    // CF objects; both are only read through checked downcasts below.
    let typed = unsafe { dict.cast_unchecked::<CFString, CFType>() };
    let (keys, values) = typed.to_vecs();
    let mut map = Map::new();
    for (key, value) in keys.iter().zip(&values) {
        if let Some(json) = value_to_json(value) {
            map.insert(key.to_string(), json);
        }
    }
    Value::Object(map)
}

fn value_to_json(value: &CFType) -> Option<Value> {
    if let Some(b) = value.downcast_ref::<CFBoolean>() {
        Some(Value::Bool(b.as_bool()))
    } else if let Some(n) = value.downcast_ref::<CFNumber>() {
        // Like Swift's `as? Int`: an integer when it converts losslessly.
        n.as_i64()
            .map(Value::from)
            .or_else(|| n.as_f64().and_then(Number::from_f64).map(Value::Number))
    } else {
        value.downcast_ref::<CFDictionary>().map(dictionary_to_json)
    }
}

const SYSTEM_PROFILER_TTL: Duration = Duration::from_secs(300);
const SYSTEM_PROFILER_TIMEOUT: Duration = Duration::from_secs(10);

/// Process-wide cached provider (like Swift's `SystemProfilerBatteryHealthProvider.shared`).
pub fn shared_apple_health() -> &'static dyn AppleHealthProvider {
    static SHARED: OnceLock<CachedAppleHealth<fn() -> AppleBatteryHealth>> = OnceLock::new();
    SHARED.get_or_init(|| CachedAppleHealth::new(SYSTEM_PROFILER_TTL, run_system_profiler))
}

/// `system_profiler SPPowerDataType` with English labels. A wedged or failing
/// process degrades to absent fields instead of hanging the caller.
fn run_system_profiler() -> AppleBatteryHealth {
    let Ok(mut child) = Command::new("/usr/sbin/system_profiler")
        .arg("SPPowerDataType")
        .env("LC_ALL", "en_US.UTF-8")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    else {
        return AppleBatteryHealth::default();
    };
    let Some(mut stdout) = child.stdout.take() else {
        return AppleBatteryHealth::default();
    };
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = stdout.read_to_end(&mut bytes);
        bytes
    });
    let deadline = Instant::now() + SYSTEM_PROFILER_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(_)) | Err(_) => break,
            Ok(None) if Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                break;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(20)),
        }
    }
    let bytes = reader.join().unwrap_or_default();
    parse_apple_health(&String::from_utf8_lossy(&bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use symcockpit_core::battery::{ChargeLimitProbe, battery_json};

    struct NoLimit;
    impl ChargeLimitProbe for NoLimit {
        fn is_supported(&self) -> bool {
            false
        }
    }

    /// Read-only live check: prints key names and types only, never values.
    /// `dev-external cargo test -p symcockpit-macos -- --ignored --nocapture`
    #[test]
    #[ignore = "reads the real AppleSmartBattery node and runs system_profiler"]
    fn live_battery_read() {
        let value =
            battery_json(&LiveBatterySource, &NoLimit, Some(shared_apple_health())).unwrap();
        let keys: Vec<_> = value.as_object().unwrap().keys().collect();
        eprintln!("battery keys: {keys:?}");
        assert!(value.get("present").is_some());
    }

    /// Compares the live value with the Swift v0.12 binary on this machine.
    /// `SYMCOCKPIT_SWIFT_BIN=<symcockpit> dev-external cargo test -p symcockpit-macos live_matches_swift -- --ignored --nocapture`
    #[test]
    #[ignore = "needs SYMCOCKPIT_SWIFT_BIN and a real battery"]
    fn live_matches_swift() {
        let bin =
            std::env::var_os("SYMCOCKPIT_SWIFT_BIN").expect("SYMCOCKPIT_SWIFT_BIN is not set");
        let home = std::env::temp_dir().join(format!("symcockpit-live-{}", std::process::id()));
        std::fs::create_dir_all(&home).unwrap();
        let out = Command::new(bin)
            .args(["battery", "--json"])
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("HOME", &home)
            .env("CFFIXED_USER_HOME", &home)
            .env("XDG_CONFIG_HOME", &home)
            .env("XDG_DATA_HOME", &home)
            .env("XDG_CACHE_HOME", &home)
            .env("SYMTUNE_CHECK_UPDATES", "0")
            .env("SYMCOCKPIT_CHECK_UPDATES", "0")
            .env("LC_ALL", "C")
            .env("TZ", "UTC")
            .output()
            .unwrap();
        let _ = std::fs::remove_dir_all(&home);
        assert!(out.status.success());
        let swift: Value = serde_json::from_slice(&out.stdout).unwrap();
        let rust = battery_json(&LiveBatterySource, &NoLimit, Some(shared_apple_health())).unwrap();
        // `charge_limit_supported` comes from the SMC probe the coordinator wires;
        // the fake says false, as Swift does on this machine.
        for key in swift
            .as_object()
            .unwrap()
            .keys()
            .chain(rust.as_object().unwrap().keys())
        {
            let (s, r) = (&swift[key], &rust[key]);
            // Charge state may move between the two reads; report instead of failing.
            if s != r {
                eprintln!("DIFF {key}: swift={s} rust={r}");
            }
        }
        let stable = [
            "design_capacity_mah",
            "max_capacity_mah",
            "cycle_count",
            "health_percent",
            "apple_maximum_capacity_percent",
            "apple_condition",
            "present",
            "notes",
        ];
        for key in stable {
            assert_eq!(swift[key], rust[key], "{key}");
        }
        assert_eq!(
            swift.as_object().unwrap().keys().collect::<Vec<_>>(),
            rust.as_object().unwrap().keys().collect::<Vec<_>>()
        );
        eprintln!(
            "live battery matches Swift on {} keys",
            swift.as_object().unwrap().len()
        );
    }
}
