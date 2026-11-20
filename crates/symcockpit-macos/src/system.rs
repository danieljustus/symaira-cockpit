//! Process and OS identity facts for `doctor`, `permissions` and path
//! resolution. Read-only.

use std::ffi::CStr;

use objc2_foundation::NSProcessInfo;

/// `geteuid() == 0`: the only thing that makes an SMC write succeed
/// (`PrivilegedElevation.isRunningAsRoot`).
pub fn running_as_root() -> bool {
    // SAFETY: `geteuid` has no preconditions.
    unsafe { libc::geteuid() == 0 }
}

/// `ProcessInfo.operatingSystemVersionString`, e.g. `Version 27.2.1 (Build 26B131)`.
pub fn operating_system_version() -> String {
    NSProcessInfo::processInfo()
        .operatingSystemVersionString()
        .to_string()
}

/// `TuneController.architecture`.
pub const ARCHITECTURE: &str = if cfg!(target_arch = "aarch64") {
    "arm64"
} else if cfg!(target_arch = "x86_64") {
    "x86_64"
} else {
    "unknown"
};

/// The login name of `uid`, or `uid <n>` when the passwd database has none
/// (`BoundedProcessRunner.ownerName`).
pub fn user_name(uid: u32) -> String {
    // SAFETY: the returned record is static storage owned by libc; its name is
    // copied before any other passwd call.
    unsafe {
        let entry = libc::getpwuid(uid);
        if entry.is_null() || (*entry).pw_name.is_null() {
            return format!("uid {uid}");
        }
        CStr::from_ptr((*entry).pw_name)
            .to_str()
            .map_or_else(|_| format!("uid {uid}"), str::to_owned)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn root_is_named_root_and_unknown_uids_fall_back() {
        assert_eq!(user_name(0), "root");
        assert_eq!(user_name(4_000_000_000), "uid 4000000000");
    }

    #[test]
    fn identity_facts_are_plausible() {
        assert!(operating_system_version().starts_with("Version "));
        assert!(matches!(ARCHITECTURE, "arm64" | "x86_64"));
    }
}
