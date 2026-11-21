//! C ABI for the Quick Look and FinderSync extensions (ADR 0004, architecture 5.2).
//!
//! Every function returns JSON text, never a panic across the boundary:
//! `{"ok":true,"format":..,"entries":[..],"truncated":bool,"notices":[..]}` or
//! `{"ok":false,"error":"..."}`. Strings returned by `*_json` belong to the caller and go
//! back through `symcockpit_free_string`. The header is `include/symcockpit_ffi.h`.

mod archive;
mod dir;
mod limits;

use std::path::Path;

use limits::Limits;
use serde_json::{Value, json};

/// Bumped on every incompatible change of the C ABI or the JSON shape.
pub const ABI_VERSION: u32 = 1;

/// Safe core: path and options in, JSON out. Used by the C wrappers and by tests.
pub fn list_dir(path: &str, options: Option<&str>) -> Value {
    run(|| dir::list(Path::new(path), Limits::DIR.with_options(options)?))
}

pub fn list_archive(path: &str, options: Option<&str>) -> Value {
    run(|| archive::list(Path::new(path), Limits::ARCHIVE.with_options(options)?))
}

fn run(f: impl FnOnce() -> Result<Value, String> + std::panic::UnwindSafe) -> Value {
    std::panic::catch_unwind(f)
        .unwrap_or_else(|_| Err("internal error".to_owned()))
        .unwrap_or_else(|error| json!({"ok": false, "error": error}))
}

#[allow(unsafe_code)] // the only unsafe in the crate: raw pointers at the C boundary
pub(crate) mod ffi {
    use std::ffi::{CStr, CString, c_char};

    use serde_json::{Value, json};

    /// Reads an optional UTF-8 C string; `Err` is a JSON error ready to return.
    ///
    /// SAFETY contract (header): non-null pointers are NUL-terminated and stay valid for the call.
    fn arg<'a>(p: *const c_char, what: &str) -> Result<Option<&'a str>, Value> {
        if p.is_null() {
            return Ok(None);
        }
        // SAFETY: see the contract above.
        unsafe { CStr::from_ptr(p) }
            .to_str()
            .map(Some)
            .map_err(|_| json!({"ok": false, "error": format!("{what} is not UTF-8")}))
    }

    fn call(
        path: *const c_char,
        options: *const c_char,
        f: fn(&str, Option<&str>) -> Value,
    ) -> *mut c_char {
        let value =
            std::panic::catch_unwind(|| match (arg(path, "path"), arg(options, "options")) {
                (Ok(Some(p)), Ok(o)) => f(p, o),
                (Ok(None), _) => json!({"ok": false, "error": "path is null"}),
                (Err(e), _) | (_, Err(e)) => e,
            })
            .unwrap_or_else(|_| json!({"ok": false, "error": "internal error"}));
        // serde_json escapes NUL as \u0000, so the text has no interior NUL.
        CString::new(value.to_string()).map_or(std::ptr::null_mut(), CString::into_raw)
    }

    /// Folder listing. `options` may be NULL (defaults) or a JSON object of limits.
    #[unsafe(no_mangle)]
    pub extern "C" fn symcockpit_list_dir_json(
        path: *const c_char,
        options: *const c_char,
    ) -> *mut c_char {
        call(path, options, crate::list_dir)
    }

    /// ZIP, TAR or 7z listing without unpacking (format detected from the file's bytes).
    #[unsafe(no_mangle)]
    pub extern "C" fn symcockpit_list_archive_json(
        path: *const c_char,
        options: *const c_char,
    ) -> *mut c_char {
        call(path, options, crate::list_archive)
    }

    /// Frees a string returned by this library; NULL is allowed.
    #[unsafe(no_mangle)]
    pub extern "C" fn symcockpit_free_string(s: *mut c_char) {
        if !s.is_null() {
            // SAFETY: non-null pointers come from `CString::into_raw` in `call`.
            drop(unsafe { CString::from_raw(s) });
        }
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn symcockpit_ffi_abi_version() -> u32 {
        crate::ABI_VERSION
    }

    /// Crate version, static; do not free.
    #[unsafe(no_mangle)]
    pub extern "C" fn symcockpit_ffi_version() -> *const c_char {
        concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr().cast()
    }
}

#[cfg(test)]
#[allow(unsafe_code)] // tests read the strings the C ABI returns
mod tests;
