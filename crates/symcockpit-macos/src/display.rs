//! Live display adapters: `NSScreen` enumeration and `DisplayServices` brightness.
//! Read-only: no gamma table, brightness write or overlay is reachable from here.

use std::ffi::{CStr, c_int, c_void};

use objc2::MainThreadMarker;
use objc2_app_kit::NSScreen;
use objc2_core_graphics::CGDisplayIsBuiltin;
use objc2_foundation::{NSNumber, NSString};
use symcockpit_contract::Error;
use symcockpit_core::display::{BrightnessSource, DisplayEnumerator, ScreenSnapshot};

/// `NSScreen.screens`. AppKit wants the main thread, so construction proves it.
pub struct LiveDisplays {
    mtm: MainThreadMarker,
}

impl LiveDisplays {
    /// Fails off the main thread (the CLI's `main` and `symcockpit serve`'s
    /// dispatch thread are fine; a spawned worker thread is not).
    pub fn new() -> Result<Self, Error> {
        MainThreadMarker::new()
            .map(|mtm| Self { mtm })
            .ok_or_else(|| Error::Failed("display enumeration must run on the main thread".into()))
    }
}

impl DisplayEnumerator for LiveDisplays {
    fn enumerate_screens(&self) -> Vec<ScreenSnapshot> {
        let key = NSString::from_str("NSScreenNumber");
        NSScreen::screens(self.mtm)
            .iter()
            .map(|screen| {
                // Same rule as `DisplayHelpers.screenDisplayID`: missing or 0 means id 0.
                let display_id = screen
                    .deviceDescription()
                    .objectForKey(&key)
                    .and_then(|v| v.downcast_ref::<NSNumber>().map(NSNumber::unsignedIntValue))
                    .unwrap_or(0);
                ScreenSnapshot {
                    name: screen.localizedName().to_string(),
                    display_id,
                    is_builtin: display_id != 0 && CGDisplayIsBuiltin(display_id),
                    max_edr_headroom: screen.maximumExtendedDynamicRangeColorComponentValue(),
                    potential_edr_headroom: screen
                        .maximumPotentialExtendedDynamicRangeColorComponentValue(),
                    backing_scale_factor: screen.backingScaleFactor(),
                }
            })
            .collect()
    }
}

type GetBrightnessFn = unsafe extern "C" fn(u32, *mut f32) -> c_int;

const DISPLAY_SERVICES: &CStr =
    c"/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices";

/// Private `DisplayServicesGetBrightness`, resolved with `dlopen`/`dlsym`
/// (ADR 0004: private symbols are probed one by one, a missing one is a named
/// error and never a crash).
pub struct DisplayServicesBrightness {
    get: Option<GetBrightnessFn>,
}

impl DisplayServicesBrightness {
    pub fn new() -> Self {
        Self {
            get: load_get_brightness(),
        }
    }
}

impl Default for DisplayServicesBrightness {
    fn default() -> Self {
        Self::new()
    }
}

fn load_get_brightness() -> Option<GetBrightnessFn> {
    // SAFETY: `DISPLAY_SERVICES` and the symbol name are NUL-terminated C
    // strings. The handle is never closed, so the resolved pointer stays valid.
    // The symbol is declared with the signature Swift uses for it
    // (`(CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32`).
    unsafe {
        let handle = libc::dlopen(DISPLAY_SERVICES.as_ptr(), libc::RTLD_NOW);
        if handle.is_null() {
            return None;
        }
        let sym: *mut c_void = libc::dlsym(handle, c"DisplayServicesGetBrightness".as_ptr());
        if sym.is_null() {
            return None;
        }
        Some(std::mem::transmute::<*mut c_void, GetBrightnessFn>(sym))
    }
}

impl BrightnessSource for DisplayServicesBrightness {
    fn brightness(&self, display_id: u32) -> Result<f64, Error> {
        let get = self.get.ok_or_else(|| {
            // shortcut: Swift falls back to IOKit's IODisplayGetFloatParameter here
            // (Intel Macs); not ported, upgrade when an Intel target needs it.
            Error::Unsupported("DisplayServicesGetBrightness is not available".into())
        })?;
        let mut value: f32 = 0.0;
        // SAFETY: `get` is the DisplayServices function resolved above; `value`
        // is a valid, writable f32 for the duration of the call.
        let status = unsafe { get(display_id, &mut value) };
        if status == 0 {
            Ok(f64::from(value))
        } else {
            Err(Error::Failed(format!(
                "DisplayServicesGetBrightness failed: {status}"
            )))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;
    use symcockpit_core::display::{brightness_get_json, displays_json};
    use symcockpit_oracle::shape;

    /// Live, read-only: `cargo test -p symcockpit-macos -- --ignored --nocapture`.
    /// libtest runs tests on a worker thread, so this bypasses the main-thread
    /// check of `LiveDisplays::new` (production code keeps it).
    #[test]
    #[ignore = "reads the real displays"]
    fn live_reports_match_oracle_shape() {
        // SAFETY: test only. The calls made through this marker are read-only
        // property reads of NSScreen; nothing is created, shown or mutated.
        let mtm = unsafe { MainThreadMarker::new_unchecked() };
        let displays = LiveDisplays { mtm };
        let report = displays_json(&displays).unwrap();
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../oracle/v0.12/cases");
        let check = |case: &str, value: &serde_json::Value| {
            let expected: serde_json::Value = serde_json::from_str(
                &std::fs::read_to_string(dir.join(format!("{case}.shape.json"))).unwrap(),
            )
            .unwrap();
            let diff = shape::compare(&expected, &shape::derive(value).unwrap());
            assert!(diff.errors.is_empty(), "{case}: {:?}", diff.errors);
        };
        check("displays-json", &report);
        check("mcp-call-list_displays", &report);
        let count = report["displays"].as_array().unwrap().len();
        eprintln!("live: {count} display(s); is_builtin/edr_capable per display:");
        for d in report["displays"].as_array().unwrap() {
            eprintln!(
                "  id={} builtin={} edr_capable={} max={} potential={} scale={}",
                d["display_id"],
                d["is_builtin"],
                d["edr_capable"],
                d["max_edr_headroom"],
                d["potential_edr_headroom"],
                d["backing_scale_factor"]
            );
        }
        match brightness_get_json(&displays, &DisplayServicesBrightness::new()) {
            Ok(b) => {
                check("brightness-get", &b);
                check("mcp-call-get_brightness", &b);
                eprintln!("live: brightness = {}", b["brightness"]);
            }
            Err(e) => eprintln!("live: brightness error (exit {}): {e}", e.exit_code()),
        }
    }
}
