//! Production wiring: the real process environment, the bounded `symbrain`
//! runner and the system time zone. Areas that need hardware extend
//! [`app`] (or build their own [`App`]) with their handlers and ports.

use std::collections::BTreeMap;
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use symcockpit_core::ai_usage::{CommandOutput, UsageError, UsageRunner};
use symcockpit_store::Paths;

use crate::app::{App, Handlers, Services};
use crate::{legacy, live};

/// The `symbrain usage` budget of v0.12.
const TIMEOUT: Duration = Duration::from_secs(30);
const MAX_OUTPUT: usize = 8 * 1024 * 1024;

/// Install roots searched after `PATH`, as `BoundedProcessRunner` does: a GUI
/// launched by launchd has no Homebrew on its `PATH`.
fn fallback_dirs(home: &str) -> Vec<String> {
    let mut dirs: Vec<String> = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
    ]
    .map(str::to_owned)
    .into();
    if !home.is_empty() {
        dirs.push(format!("{home}/.symaira/bin"));
    }
    dirs
}

fn is_executable(path: &Path) -> bool {
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// Every executable `name` on `PATH` and the fallback roots, in search order
/// without duplicates (`BoundedProcessRunner.resolveCandidates`).
pub fn executable_candidates(name: &str, env: &BTreeMap<String, String>) -> Vec<PathBuf> {
    let path = env.get("PATH").cloned().unwrap_or_default();
    let mut seen = std::collections::BTreeSet::new();
    path.split(':')
        .filter(|d| !d.is_empty())
        .map(str::to_owned)
        .chain(fallback_dirs(env.get("HOME").map_or("", String::as_str)))
        .map(|dir| Path::new(&dir).join(name))
        .filter(|candidate| seen.insert(candidate.clone()) && is_executable(candidate))
        .collect()
}

/// PATH-first resolution of a bare executable name.
pub fn resolve_executable(name: &str, env: &BTreeMap<String, String>) -> Option<PathBuf> {
    executable_candidates(name, env).into_iter().next()
}

/// Reads at most `MAX_OUTPUT` bytes, then keeps draining so the child never blocks.
fn drain(mut stream: impl Read + Send + 'static) -> std::thread::JoinHandle<Vec<u8>> {
    std::thread::spawn(move || {
        let mut kept = Vec::new();
        let mut chunk = [0u8; 16 * 1024];
        while let Ok(n) = stream.read(&mut chunk) {
            if n == 0 {
                break;
            }
            let room = MAX_OUTPUT.saturating_sub(kept.len());
            kept.extend_from_slice(&chunk[..n.min(room)]);
        }
        kept
    })
}

/// Why a bounded run produced no exit status.
#[derive(Debug)]
pub enum RunFailure {
    Launch(String),
    TimedOut,
}

/// Runs `path` without a shell, with a cleared environment, a deadline and a
/// bounded output. Its own process group, like the Swift runner.
pub fn run_bounded(
    path: &Path,
    args: &[String],
    env: &BTreeMap<String, String>,
    timeout: Duration,
) -> Result<CommandOutput, RunFailure> {
    let launch = |e: std::io::Error| RunFailure::Launch(e.to_string());
    let mut child = Command::new(path)
        .args(args)
        .env_clear()
        .envs(env)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .spawn()
        .map_err(launch)?;
    let missing = || RunFailure::Launch("no output pipe".into());
    let stdout = drain(child.stdout.take().ok_or_else(missing)?);
    let stderr = drain(child.stderr.take().ok_or_else(missing)?);
    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
            // shortcut: only the child is killed, not a grandchild that
            // keeps the pipes open; the readers then end at EOF anyway.
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(RunFailure::TimedOut);
            }
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(launch(e));
            }
        }
    };
    Ok(CommandOutput {
        stdout: stdout.join().unwrap_or_default(),
        stderr: stderr.join().unwrap_or_default(),
        status: status.code().unwrap_or(-1),
    })
}

/// Runs `symbrain` without a shell, with a deadline and a bounded output.
pub struct SymbrainRunner {
    pub binary: String,
}

impl UsageRunner for SymbrainRunner {
    fn run(
        &self,
        args: &[String],
        env: &BTreeMap<String, String>,
    ) -> Result<CommandOutput, UsageError> {
        let path = resolve_executable(&self.binary, env).ok_or(UsageError::BinaryUnavailable)?;
        run_bounded(&path, args, env, TIMEOUT).map_err(|failure| match failure {
            RunFailure::Launch(_) => UsageError::BinaryUnavailable,
            RunFailure::TimedOut => UsageError::CommandFailed(-1),
        })
    }
}

/// Unix seconds as `yyyy-MM-dd HH:mm:ss` in the system time zone (`TZ` wins).
pub fn local_time(unix: f64) -> String {
    jiff::Timestamp::from_second(unix.floor() as i64)
        .map(|t| {
            t.to_zoned(jiff::tz::TimeZone::system())
                .strftime("%Y-%m-%d %H:%M:%S")
                .to_string()
        })
        .unwrap_or_default()
}

/// The process environment as a sorted map; non-UTF-8 entries are dropped.
pub fn process_env() -> BTreeMap<String, String> {
    std::env::vars().collect()
}

/// The production app: the live read areas of [`live::wire`] on top of the
/// real environment. Write commands are still forwarded to the Swift core.
pub fn app() -> App {
    let env = process_env();
    let lookup = |key: &str| env.get(key).cloned();
    let paths = Paths::from_process(&lookup, symcockpit_macos::system::running_as_root());
    let exe = std::env::current_exe()
        .map(|p| p.canonicalize().unwrap_or(p))
        .unwrap_or_default();
    let legacy = legacy::resolve_legacy(std::env::var_os(legacy::LEGACY_ENV), &exe);
    let mut app = App {
        env,
        paths,
        handlers: Handlers::default(),
        services: Services {
            hardware: None,
            overrides: None,
            usage_runner: Box::new(SymbrainRunner {
                binary: "symbrain".into(),
            }),
            vault_entry_paths: BTreeMap::new(),
            local_time: Box::new(local_time),
        },
        legacy,
    };
    live::wire(&mut app);
    app
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_time_honours_the_formatting_and_utc_epoch() {
        // TZ is process-wide, so only an unambiguous UTC instant is asserted.
        assert_eq!(
            jiff::Timestamp::from_second(0)
                .unwrap()
                .to_zoned(jiff::tz::TimeZone::UTC)
                .strftime("%Y-%m-%d %H:%M:%S")
                .to_string(),
            "1970-01-01 00:00:00"
        );
        assert_eq!(
            local_time(f64::MAX).len(),
            0,
            "out-of-range timestamps give an empty string, not a panic"
        );
    }

    #[test]
    fn executables_resolve_path_first_and_skip_non_executables() {
        let tmp = tempfile::tempdir().unwrap();
        let (a, b) = (tmp.path().join("a"), tmp.path().join("b"));
        std::fs::create_dir_all(&a).unwrap();
        std::fs::create_dir_all(&b).unwrap();
        let put = |dir: &Path, mode: u32| {
            let f = dir.join("symbrain");
            std::fs::write(&f, "#!/bin/sh\n").unwrap();
            std::fs::set_permissions(&f, std::fs::Permissions::from_mode(mode)).unwrap();
            f
        };
        put(&a, 0o644);
        let wanted = put(&b, 0o755);
        let env = BTreeMap::from([(
            "PATH".to_owned(),
            format!("{}:{}", a.display(), b.display()),
        )]);
        assert_eq!(resolve_executable("symbrain", &env), Some(wanted));
        assert_eq!(resolve_executable("no-such-tool", &env), None);
    }
}
