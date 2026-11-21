//! Code-signing facts through the Security framework: the team identifier of
//! the running binary and whether it satisfies a requirement (port of
//! `CodeSignatureInspector.swift`). Read-only.

use std::ffi::c_void;
use std::ptr::null;

use core_foundation::base::TCFType;
use core_foundation::string::CFString;
use core_foundation_sys::base::{CFRelease, CFTypeRef};
use core_foundation_sys::dictionary::{CFDictionaryGetValue, CFDictionaryRef};
use core_foundation_sys::string::CFStringRef;

type OsStatus = i32;
type SecCodeRef = *const c_void;
type SecRequirementRef = *const c_void;

/// `kSecCSSigningInformation`.
const SIGNING_INFORMATION: u32 = 1 << 1;

#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
    fn SecCodeCopySelf(flags: u32, out: *mut SecCodeRef) -> OsStatus;
    fn SecCodeCopyStaticCode(code: SecCodeRef, flags: u32, out: *mut SecCodeRef) -> OsStatus;
    fn SecCodeCopySigningInformation(
        code: SecCodeRef,
        flags: u32,
        out: *mut CFDictionaryRef,
    ) -> OsStatus;
    fn SecRequirementCreateWithString(
        text: CFStringRef,
        flags: u32,
        out: *mut SecRequirementRef,
    ) -> OsStatus;
    fn SecCodeCheckValidity(
        code: SecCodeRef,
        flags: u32,
        requirement: SecRequirementRef,
    ) -> OsStatus;
    static kSecCodeInfoTeamIdentifier: CFStringRef;
}

/// An owned Core Foundation reference, released on drop.
struct Owned(CFTypeRef);

impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: a non-null reference this value owns (create rule), released once.
        unsafe { CFRelease(self.0) };
    }
}

fn own_code() -> Option<Owned> {
    let mut code: SecCodeRef = null();
    // SAFETY: a valid out-pointer; the copy follows the create rule.
    let status = unsafe { SecCodeCopySelf(0, &mut code) };
    (status == 0 && !code.is_null()).then(|| Owned(code))
}

/// Team identifier of the running process; `None` when it is unsigned or
/// ad-hoc signed (no team).
pub fn own_team_identifier() -> Option<String> {
    let code = own_code()?;
    let mut static_code: SecCodeRef = null();
    // SAFETY: a live code object and a valid out-pointer (create rule).
    if unsafe { SecCodeCopyStaticCode(code.0, 0, &mut static_code) } != 0 || static_code.is_null() {
        return None;
    }
    let static_code = Owned(static_code);
    let mut info: CFDictionaryRef = null();
    // SAFETY: a live static code object and a valid out-pointer (create rule).
    if unsafe { SecCodeCopySigningInformation(static_code.0, SIGNING_INFORMATION, &mut info) } != 0
        || info.is_null()
    {
        return None;
    }
    let info = Owned(info.cast());
    // SAFETY: `info` is a CFDictionary; the key is a framework constant; the value
    // (a CFString or absent) is borrowed from the dictionary and copied out at once.
    let team = unsafe { CFDictionaryGetValue(info.0.cast(), kSecCodeInfoTeamIdentifier.cast()) };
    // SAFETY: a CFString owned by the dictionary (get rule), alive while `info` is.
    (!team.is_null()).then(|| unsafe { CFString::wrap_under_get_rule(team.cast()) }.to_string())
}

fn requirement(text: &str) -> Option<Owned> {
    let text = CFString::new(text);
    let mut out: SecRequirementRef = null();
    // SAFETY: a valid CFString and out-pointer (create rule).
    let status = unsafe { SecRequirementCreateWithString(text.as_concrete_TypeRef(), 0, &mut out) };
    (status == 0 && !out.is_null()).then(|| Owned(out))
}

/// Whether `text` is syntactically valid requirement language.
pub fn is_well_formed(text: &str) -> bool {
    requirement(text).is_some()
}

/// Whether the running process satisfies `text` (`false` when it is not valid).
pub fn self_satisfies(text: &str) -> bool {
    let (Some(code), Some(req)) = (own_code(), requirement(text)) else {
        return false;
    };
    // SAFETY: both are live Security objects.
    unsafe { SecCodeCheckValidity(code.0, 0, req.0) == 0 }
}

#[cfg(test)]
mod tests {
    use symcockpit_helper_proto::signing::{app_requirement, helper_requirement};

    use super::*;

    #[test]
    fn the_requirement_strings_are_valid_requirement_language() {
        // CodeSigningRequirementsTests.testRequirementsAreWellFormed: the real
        // Security framework compiles the text both sides enforce.
        assert!(is_well_formed(&app_requirement("ABCDE12345").unwrap()));
        assert!(is_well_formed(&helper_requirement("ABCDE12345").unwrap()));
        assert!(!is_well_formed("this is ((not a requirement"));
    }

    #[test]
    fn an_unsigned_test_binary_has_no_team_and_satisfies_no_developer_id_requirement() {
        // `cargo test` binaries are ad-hoc signed: no team, not Developer ID.
        assert_eq!(own_team_identifier(), None);
        assert!(!self_satisfies(&helper_requirement("ABCDE12345").unwrap()));
        assert!(!self_satisfies("not a requirement"));
    }
}
