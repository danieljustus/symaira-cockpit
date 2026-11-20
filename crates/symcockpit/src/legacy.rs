//! The Swift core during the strangler migration (ADR 0003): where it lives,
//! how a whole invocation is handed over (`exec`), and how the MCP server
//! runs it as a subprocess and collects the result.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use symcockpit_contract::{Error, exit};

/// Environment variable naming the legacy binary explicitly.
pub const LEGACY_ENV: &str = "SYMCOCKPIT_LEGACY_BIN";

/// Where the legacy Swift binary lives: the environment override, then next to
/// this executable, then in the Homebrew-style `libexec` layout.
pub fn resolve_legacy(override_path: Option<OsString>, exe: &Path) -> Option<PathBuf> {
    if let Some(path) = override_path.filter(|p| !p.is_empty()) {
        // An explicit override is never second-guessed by falling through.
        return Some(PathBuf::from(path)).filter(|p| p.is_file());
    }
    let dir = exe.parent()?;
    [
        dir.join("symcockpit-legacy"),
        dir.join("../libexec/symcockpit/symcockpit-legacy"),
    ]
    .into_iter()
    .find(|p| p.is_file())
}

/// Replace this process with the legacy binary. Returns only on failure.
pub fn forward(args: Vec<OsString>) -> u8 {
    use std::os::unix::process::CommandExt;

    let exe = std::env::current_exe()
        .map(|p| p.canonicalize().unwrap_or(p))
        .unwrap_or_default();
    let Some(legacy) = resolve_legacy(std::env::var_os(LEGACY_ENV), &exe) else {
        eprintln!(
            "symcockpit: legacy binary not found; set {LEGACY_ENV} or install symcockpit-legacy next to symcockpit"
        );
        return exit::UNSUPPORTED;
    };
    let error = std::process::Command::new(&legacy).args(args).exec();
    eprintln!("symcockpit: cannot start {}: {error}", legacy.display());
    exit::ERROR
}

pub struct Captured {
    pub code: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

/// Runs the legacy binary to completion with the inherited environment and no
/// stdin. A signal death is reported as code `-1`.
pub fn capture(legacy: &Path, args: &[String]) -> Result<Captured, Error> {
    let output = std::process::Command::new(legacy)
        .args(args)
        .stdin(std::process::Stdio::null())
        .output()
        .map_err(|e| Error::Failed(format!("cannot start {}: {e}", legacy.display())))?;
    Ok(Captured {
        code: output.status.code().unwrap_or(-1),
        stdout: output.stdout,
        stderr: output.stderr,
    })
}

/// The error text of a failed run: the last `symcockpit: <message>` line the
/// CLI printed without its prefix, else the whole of stderr.
pub fn failure_message(captured: &Captured) -> String {
    let stderr = String::from_utf8_lossy(&captured.stderr);
    let message = stderr
        .lines()
        .rev()
        .find_map(|line| line.strip_prefix("symcockpit: "))
        .map_or_else(|| stderr.trim().to_owned(), str::to_owned);
    if message.is_empty() {
        format!("symcockpit exited with status {}", captured.code)
    } else {
        message
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolution_order_is_override_then_sibling_then_libexec() {
        let tmp = tempfile::tempdir().unwrap();
        let bin = tmp.path().join("bin");
        let libexec = tmp.path().join("libexec/symcockpit");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::create_dir_all(&libexec).unwrap();
        let exe = bin.join("symcockpit");
        let sibling = bin.join("symcockpit-legacy");
        let far = libexec.join("symcockpit-legacy");
        let custom = tmp.path().join("custom");
        assert_eq!(resolve_legacy(None, &exe), None);
        std::fs::write(&far, "").unwrap();
        assert_eq!(
            resolve_legacy(None, &exe).unwrap().canonicalize().unwrap(),
            far.canonicalize().unwrap()
        );
        std::fs::write(&sibling, "").unwrap();
        assert_eq!(resolve_legacy(None, &exe), Some(sibling.clone()));
        std::fs::write(&custom, "").unwrap();
        assert_eq!(
            resolve_legacy(Some(custom.clone().into()), &exe),
            Some(custom)
        );
        // A missing override does not fall back to the sibling.
        assert_eq!(
            resolve_legacy(Some(tmp.path().join("gone").into()), &exe),
            None
        );
        // An empty override counts as unset.
        assert_eq!(resolve_legacy(Some(OsString::new()), &exe), Some(sibling));
    }
}
