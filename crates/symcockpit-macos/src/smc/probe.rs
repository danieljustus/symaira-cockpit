//! Read-only probes behind `fan status`: the stored fan selection and a running governor.

use std::ffi::{CStr, CString};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use symcockpit_core::sensors::{FanSelection, FanSelectionSource, GovernorProbe};

/// `~/.symtune/fan-profile.json` (grandfathered path, format unchanged).
pub struct FileFanSelection {
    path: PathBuf,
}

impl FileFanSelection {
    pub fn at(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    /// The default file of the *invoking* user: under `sudo` that is the
    /// `SUDO_USER`'s home, not `/var/root` (a governor reading root's empty
    /// home would see `system` and never touch a fan). Otherwise
    /// `CFFIXED_USER_HOME` wins like in Foundation, then `$HOME`/passwd.
    pub fn default_location() -> Self {
        let home = invoking_user_home().unwrap_or_default();
        Self::at(home.join(".symtune/fan-profile.json"))
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl FanSelectionSource for FileFanSelection {
    /// Missing, unreadable or corrupt files are `system`: never override.
    fn selection(&self) -> FanSelection {
        std::fs::read(&self.path).map_or(FanSelection::SYSTEM, |b| FanSelection::from_json(&b))
    }
}

fn invoking_user_home() -> Option<PathBuf> {
    // SAFETY: `geteuid` has no preconditions.
    if unsafe { libc::geteuid() } == 0
        && let Some(home) = std::env::var("SUDO_USER")
            .ok()
            .and_then(|u| passwd_home(&u))
    {
        return Some(home);
    }
    std::env::var_os("CFFIXED_USER_HOME")
        .map(PathBuf::from)
        .or_else(std::env::home_dir)
}

fn passwd_home(user: &str) -> Option<PathBuf> {
    let user = CString::new(user).ok()?;
    // SAFETY: `user` is NUL-terminated; the returned record is static storage
    // owned by libc, read immediately and copied before any other passwd call.
    unsafe {
        let entry = libc::getpwnam(user.as_ptr());
        if entry.is_null() || (*entry).pw_dir.is_null() {
            return None;
        }
        let dir = CStr::from_ptr((*entry).pw_dir).to_str().ok()?;
        Some(PathBuf::from(dir))
    }
}

/// Whether a standalone `fan governor` process runs (`pgrep -f`, which matches
/// the direct and the deprecated `tune` spelling). A probe that cannot run, or
/// takes longer than 5 s, answers `false`. The helper-governed case (#405) is
/// not covered here: it belongs to the helper stage.
pub struct PgrepGovernorProbe;

impl GovernorProbe for PgrepGovernorProbe {
    fn is_running(&self) -> bool {
        let Ok(mut child) = Command::new("/usr/bin/pgrep")
            .args(["-f", "fan governor"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        else {
            return false;
        };
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            match child.try_wait() {
                Ok(Some(status)) => return status.success(),
                Ok(None) if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(10));
                }
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return false;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use symcockpit_core::sensors::FanProfile;

    #[test]
    fn missing_or_corrupt_file_is_system() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("fan-profile.json");
        let source = FileFanSelection::at(&path);
        assert_eq!(source.selection(), FanSelection::SYSTEM);
        std::fs::write(&path, "garbage").unwrap();
        assert_eq!(source.selection(), FanSelection::SYSTEM);
        std::fs::write(&path, r#"{"profile":"comfort","cool_target_celsius":62.5}"#).unwrap();
        assert_eq!(
            source.selection(),
            FanSelection::new(FanProfile::Comfort, Some(62.5))
        );
    }
}
