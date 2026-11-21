//! The macOS charge limit through `PowerUISmartChargeClient` (private class of
//! `PowerUI.framework`), for Macs whose firmware has no SMC charge-limit key
//! (macOS 27, spike S8). Port of the spike's `charge.rs`.
//!
//! Private API, so it fails closed: the framework must load, the class must
//! exist and every selector used must have exactly the encoding S8 measured
//! (`isMCLCurrentlyEnabled:` returns an NSUInteger, not a BOOL;
//! `setMCLLimit:error:` takes a `uint8`). Anything else and
//! [`PowerUiClient::connect`] answers `None`, which the caller reports as
//! `unsupported`.
//!
//! **The getters are proven on hardware (S8, no root needed). The setters
//! (`enableMCL:`, `disableMCL:`, `setMCLLimit:error:`) are NOT:** whether they
//! work without root is exactly what S8's pending write test decides. Nothing
//! in this crate's tests calls them on the real class; they run against
//! `symcockpit-testkit`'s fake.

use std::ffi::{CStr, c_char, c_int, c_void};
use std::ptr::null_mut;
use std::sync::Mutex;

use objc2::msg_send;
use objc2::runtime::{AnyClass, AnyObject, Sel};
use objc2_foundation::{NSError, NSString};
use symcockpit_core::charge_limit::MacChargeLimit;

const FRAMEWORK: &CStr = c"/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI";
const CLASS: &CStr = c"PowerUISmartChargeClient";
const CLIENT_NAME: &str = "symcockpit";

/// Selectors this module calls and the encodings S8 measured for them
/// (`raw/03_s8_introspect.txt`, macOS 27.2.1).
const ENCODINGS: [(&str, &str); 7] = [
    ("initWithClientName:", "@24@0:8@16"),
    ("isMCLSupported", "B16@0:8"),
    ("isMCLCurrentlyEnabled:", "Q24@0:8^@16"),
    ("getMCLLimitWithError:", "C24@0:8^@16"),
    ("enableMCL:", "B24@0:8^@16"),
    ("disableMCL:", "B24@0:8^@16"),
    ("setMCLLimit:error:", "B28@0:8C16^@20"),
];

unsafe extern "C" {
    fn dlopen(path: *const c_char, mode: c_int) -> *mut c_void;
}

fn encoding_of(class: &AnyClass, selector: Sel) -> Option<String> {
    let method = class.instance_method(selector)?;
    // SAFETY: `method` is a live `Method` from the runtime; the returned C string
    // is owned by the runtime and read immediately.
    let ptr = unsafe {
        objc2::ffi::method_getTypeEncoding((method as *const objc2::runtime::Method).cast())
    };
    // SAFETY: non-null NUL-terminated encoding string (checked) from the runtime.
    (!ptr.is_null()).then(|| {
        unsafe { CStr::from_ptr(ptr) }
            .to_string_lossy()
            .into_owned()
    })
}

/// A connected client. All calls are serialised: the class makes no thread-safety promise.
pub struct PowerUiClient {
    client: *mut AnyObject,
    lock: Mutex<()>,
}

// SAFETY: the pointer is only used through `&self` methods that hold `lock`.
unsafe impl Send for PowerUiClient {}
// SAFETY: as above; all access is serialised by `lock`.
unsafe impl Sync for PowerUiClient {}

fn error_text(error: *mut NSError) -> String {
    if error.is_null() {
        return "no NSError".into();
    }
    // SAFETY: a non-null NSError the callee handed back (autoreleased, alive for this call).
    unsafe {
        format!(
            "domain={} code={} desc={}",
            (*error).domain(),
            (*error).code(),
            (*error).localizedDescription()
        )
    }
}

impl PowerUiClient {
    /// Load the framework and the class, verify every encoding, create a client.
    pub fn connect() -> Option<Self> {
        // SAFETY: `FRAMEWORK` is a valid C string; RTLD_LAZY = 1.
        if unsafe { dlopen(FRAMEWORK.as_ptr(), 1) }.is_null() {
            return None;
        }
        let class = AnyClass::get(CLASS)?;
        for (name, expected) in ENCODINGS {
            let selector = Sel::register(&std::ffi::CString::new(name).ok()?);
            if encoding_of(class, selector).as_deref() != Some(expected) {
                return None;
            }
        }
        let name = NSString::from_str(CLIENT_NAME);
        // SAFETY: `alloc` on the class, then the init selector verified above with
        // one NSString argument; the result is checked for nil.
        let client: *mut AnyObject = unsafe {
            let allocated: *mut AnyObject = msg_send![class, alloc];
            msg_send![allocated, initWithClientName: &*name]
        };
        (!client.is_null()).then(|| Self {
            client,
            lock: Mutex::new(()),
        })
    }

    fn call_bool(
        &self,
        call: impl FnOnce(*mut AnyObject, *mut *mut NSError) -> bool,
    ) -> Result<(), String> {
        let _guard = self.lock.lock().ok();
        let mut error: *mut NSError = null_mut();
        if call(self.client, &mut error) {
            Ok(())
        } else {
            Err(error_text(error))
        }
    }
}

impl Drop for PowerUiClient {
    fn drop(&mut self) {
        // SAFETY: balances the +1 from `alloc`/`init`; the pointer is not used afterwards.
        unsafe {
            let _: () = msg_send![self.client, release];
        }
    }
}

impl MacChargeLimit for PowerUiClient {
    fn is_supported(&self) -> bool {
        let _guard = self.lock.lock().ok();
        // SAFETY: `isMCLSupported` has the verified encoding `B16@0:8` (no arguments, BOOL).
        unsafe { msg_send![self.client, isMCLSupported] }
    }

    fn is_enabled(&self) -> Option<bool> {
        let _guard = self.lock.lock().ok();
        let mut error: *mut NSError = null_mut();
        // SAFETY: verified encoding `Q24@0:8^@16`: one NSError** argument, NSUInteger result.
        let enabled: u64 = unsafe {
            msg_send![self.client, isMCLCurrentlyEnabled: &mut error as *mut *mut NSError]
        };
        error.is_null().then_some(enabled != 0)
    }

    fn limit(&self) -> Option<u8> {
        let _guard = self.lock.lock().ok();
        let mut error: *mut NSError = null_mut();
        // SAFETY: verified encoding `C24@0:8^@16`: one NSError** argument, uint8 result.
        let limit: u8 = unsafe {
            msg_send![self.client, getMCLLimitWithError: &mut error as *mut *mut NSError]
        };
        error.is_null().then_some(limit)
    }

    fn enable(&self) -> Result<(), String> {
        // SAFETY: verified encoding `B24@0:8^@16`.
        self.call_bool(|client, error| unsafe { msg_send![client, enableMCL: error] })
    }

    fn disable(&self) -> Result<(), String> {
        // SAFETY: verified encoding `B24@0:8^@16`.
        self.call_bool(|client, error| unsafe { msg_send![client, disableMCL: error] })
    }

    fn set_limit(&self, percent: u8) -> Result<(), String> {
        // SAFETY: verified encoding `B28@0:8C16^@20`: a uint8 then NSError**.
        self.call_bool(|client, error| unsafe {
            msg_send![client, setMCLLimit: percent, error: error]
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Reads the real class (getters only; the setters are never called).
    /// `cargo test -p symcockpit-macos -- --ignored --nocapture live_powerui`
    #[test]
    #[ignore = "loads the private PowerUI framework and calls its read-only getters"]
    fn live_powerui_getters_read_only() {
        let client = PowerUiClient::connect().expect(
            "PowerUISmartChargeClient: framework, class and all encodings as measured in S8",
        );
        let supported = client.is_supported();
        let (enabled, limit) = (client.is_enabled(), client.limit());
        println!("LIVE powerui supported={supported} enabled={enabled:?} limit={limit:?}");
        // The measured encodings made it through `connect`; a value is a plain percentage.
        assert!(limit.is_none_or(|l| (1..=100).contains(&l)), "{limit:?}");
    }

    #[test]
    fn the_encodings_are_the_ones_s8_measured() {
        // Evidence: S8 `raw/03_s8_introspect.txt` (instance_method lines).
        let table: std::collections::HashMap<_, _> = ENCODINGS.into_iter().collect();
        assert_eq!(table["isMCLCurrentlyEnabled:"], "Q24@0:8^@16"); // NSUInteger, not BOOL
        assert_eq!(table["setMCLLimit:error:"], "B28@0:8C16^@20"); // uint8, not NSInteger
        assert_eq!(table["getMCLLimitWithError:"], "C24@0:8^@16");
        // Only the selectors the port needs: nothing that sets an override or a handler variant.
        let names: Vec<&str> = ENCODINGS.iter().map(|(n, _)| *n).collect();
        assert!(
            !names
                .iter()
                .any(|n| n.contains("temporarily") || n.contains("Handler"))
        );
    }
}
