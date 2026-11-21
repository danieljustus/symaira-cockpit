//! Sequential speed test (R32): one test file in an own session directory,
//! written and read back with timings, then removed.
//!
//! Units are explicit: `mib_per_s` is 2^20 bytes per second, `mb_per_s` is
//! 10^6 bytes per second. Only the session directory and the file this run
//! created are removed; anything else inside is left alone and reported.

use std::io;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use symcockpit_contract::Error;
use symcockpit_contract::areas::storage_health::{MCP_SPEEDTEST_MAX_MIB, SPEEDTEST_DEFAULT_MIB};

use super::health::{bounded, number, rfc3339};
use crate::plan::Clock;

pub const MIB: u64 = 1 << 20;
pub const MB: u64 = 1_000_000;
/// Transfer block: 4 MiB.
pub const BLOCK_BYTES: usize = 4 * MIB as usize;
/// The test file may use at most this share of the available space.
const MAX_FREE_SHARE_PERCENT: u64 = 50;
const CLI_MAX_MIB: u64 = 65_536;
const SESSION_PREFIX: &str = ".symcockpit-speedtest-";
const FILE_NAME: &str = "test.bin";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CacheMode {
    /// Ask the OS to bypass its file cache (F_NOCACHE).
    Uncached,
    Cached,
}

impl CacheMode {
    pub fn as_str(self) -> &'static str {
        match self {
            CacheMode::Uncached => "uncached",
            CacheMode::Cached => "cached",
        }
    }

    fn parse(s: &str) -> Result<Self, Error> {
        match s {
            "uncached" => Ok(CacheMode::Uncached),
            "cached" => Ok(CacheMode::Cached),
            other => Err(Error::Usage(format!(
                "cache mode must be uncached or cached, got '{other}'"
            ))),
        }
    }
}

/// Who may run the test where. `allowed_roots` empty means anywhere.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Limits {
    pub max_size_mib: u64,
    pub allowed_roots: Vec<PathBuf>,
}

impl Limits {
    pub fn cli() -> Self {
        Limits {
            max_size_mib: CLI_MAX_MIB,
            allowed_roots: vec![],
        }
    }

    /// Agents: at most [`MCP_SPEEDTEST_MAX_MIB`], only under `home` or `/Volumes`.
    pub fn mcp(home: &Path) -> Self {
        Limits {
            max_size_mib: MCP_SPEEDTEST_MAX_MIB,
            allowed_roots: vec![home.to_owned(), PathBuf::from("/Volumes")],
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SpeedtestParams {
    /// Directory to test; `None` means the host's default (home).
    pub path: Option<PathBuf>,
    pub size_mib: u64,
    pub cache_mode: CacheMode,
    pub limits: Limits,
}

impl SpeedtestParams {
    pub fn new(limits: Limits) -> Self {
        SpeedtestParams {
            path: None,
            size_mib: SPEEDTEST_DEFAULT_MIB,
            cache_mode: CacheMode::Uncached,
            limits,
        }
    }

    /// Arguments after `storage speedtest`: `[--path DIR] [--size MiB] [--cache-mode M] [--json]`.
    pub fn parse_cli(args: &[String], limits: Limits) -> Result<Self, Error> {
        let mut p = SpeedtestParams::new(limits);
        let mut it = args.iter();
        while let Some(a) = it.next() {
            let mut value = || {
                it.next()
                    .ok_or_else(|| Error::Usage(format!("{a} needs a value")))
            };
            match a.as_str() {
                "--path" => p.path = Some(PathBuf::from(value()?)),
                "--size" => p.size_mib = number("--size", value()?)?,
                "--cache-mode" => p.cache_mode = CacheMode::parse(value()?)?,
                "--json" => {}
                other => {
                    return Err(Error::Usage(format!(
                        "storage speedtest: unknown argument '{other}'"
                    )));
                }
            }
        }
        Ok(p)
    }

    /// MCP arguments of `run_speedtest`.
    pub fn from_json(args: &Value, limits: Limits) -> Result<Self, Error> {
        let mut p = SpeedtestParams::new(limits);
        if let Some(v) = args.get("path") {
            p.path =
                Some(PathBuf::from(v.as_str().ok_or_else(|| {
                    Error::Usage("path must be a string".into())
                })?));
        }
        if let Some(v) = args.get("size_mib") {
            p.size_mib = v
                .as_u64()
                .ok_or_else(|| Error::Usage("size_mib must be a whole number".into()))?;
        }
        if let Some(v) = args.get("cache_mode") {
            p.cache_mode = CacheMode::parse(v.as_str().unwrap_or(""))?;
        }
        Ok(p)
    }
}

/// An open test file.
pub trait TestFile {
    fn write_all(&mut self, buf: &[u8]) -> io::Result<()>;
    /// Flush to the device before the write phase ends.
    fn sync(&mut self) -> io::Result<()>;
    /// Like `Read::read`; `Ok(0)` at the end.
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize>;
    /// Whether the OS accepted the requested cache mode.
    fn cache_applied(&self) -> bool;
}

/// Platform side of the test. Implemented by `symcockpit-macos`; faked in the testkit.
pub trait SpeedHost {
    /// Directory used when no path is given.
    fn default_target(&self) -> io::Result<PathBuf>;
    fn canonicalize(&self, path: &Path) -> io::Result<PathBuf>;
    fn available_bytes(&self, dir: &Path) -> io::Result<u64>;
    /// Monotonic nanoseconds from an arbitrary origin.
    fn monotonic_nanos(&self) -> u64;
    /// Unique per run (process and time).
    fn session_id(&self) -> String;
    /// Must fail when the directory already exists.
    fn create_dir(&self, dir: &Path) -> io::Result<()>;
    /// Must fail when the file already exists (O_EXCL).
    fn create_file(&self, path: &Path, mode: CacheMode) -> io::Result<Box<dyn TestFile>>;
    fn open_file(&self, path: &Path, mode: CacheMode) -> io::Result<Box<dyn TestFile>>;
    fn remove_file(&self, path: &Path) -> io::Result<()>;
    /// Non-recursive.
    fn remove_dir(&self, dir: &Path) -> io::Result<()>;
}

fn io_err(what: &str, e: &io::Error) -> Error {
    match e.kind() {
        io::ErrorKind::PermissionDenied => Error::Permission(format!("{what}: {e}")),
        io::ErrorKind::NotFound => Error::Usage(format!("{what}: {e}")),
        _ => Error::Failed(format!("{what}: {e}")),
    }
}

fn round3(x: f64) -> f64 {
    (x * 1000.0).round() / 1000.0
}

fn phase(bytes: u64, nanos: u64) -> Value {
    let secs = nanos.max(1) as f64 / 1e9;
    json!({
        "bytes": bytes,
        "duration_seconds": round3(secs),
        "mib_per_s": round3(bytes as f64 / MIB as f64 / secs),
        "mb_per_s": round3(bytes as f64 / MB as f64 / secs),
    })
}

/// xorshift64* fill: incompressible enough for a sequential test; no crate needed.
fn fill(buf: &mut [u8], mut x: u64) {
    x |= 1;
    for chunk in buf.chunks_mut(8) {
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        let v = x.wrapping_mul(0x2545_F491_4F6C_DD1D).to_le_bytes();
        chunk.copy_from_slice(&v[..chunk.len()]);
    }
}

struct Timed {
    write_nanos: u64,
    read_nanos: u64,
    cache_applied: bool,
}

fn transfer(
    host: &dyn SpeedHost,
    file: &Path,
    bytes: u64,
    mode: CacheMode,
) -> Result<Timed, Error> {
    let mut buf = vec![0u8; BLOCK_BYTES];
    fill(&mut buf, host.monotonic_nanos());

    let mut f = host
        .create_file(file, mode)
        .map_err(|e| io_err("create test file", &e))?;
    let t0 = host.monotonic_nanos();
    let mut left = bytes;
    while left > 0 {
        let n = left.min(BLOCK_BYTES as u64);
        f.write_all(&buf[..n as usize])
            .map_err(|e| io_err("write", &e))?;
        left -= n;
    }
    f.sync().map_err(|e| io_err("sync", &e))?;
    let write_nanos = host.monotonic_nanos() - t0;
    let cache_applied = f.cache_applied();
    drop(f);

    let mut f = host
        .open_file(file, mode)
        .map_err(|e| io_err("open test file", &e))?;
    let (mut total, t0) = (0u64, host.monotonic_nanos());
    loop {
        match f.read(&mut buf).map_err(|e| io_err("read", &e))? {
            0 => break,
            n => total += n as u64,
        }
    }
    let read_nanos = host.monotonic_nanos() - t0;
    if total != bytes {
        return Err(Error::Failed(format!(
            "read back {total} bytes, expected {bytes}"
        )));
    }
    Ok(Timed {
        write_nanos,
        read_nanos,
        cache_applied: cache_applied && f.cache_applied(),
    })
}

/// `storage speedtest`.
pub fn speedtest_json(
    host: &dyn SpeedHost,
    clock: &dyn Clock,
    params: &SpeedtestParams,
) -> Result<Value, Error> {
    let size_mib = bounded("size", params.size_mib, 1, params.limits.max_size_mib)? as u64;
    let bytes = size_mib * MIB;

    let target = match &params.path {
        Some(p) => p.clone(),
        None => host
            .default_target()
            .map_err(|e| io_err("default target", &e))?,
    };
    let target = host
        .canonicalize(&target)
        .map_err(|e| io_err("target", &e))?;
    let roots = &params.limits.allowed_roots;
    if !roots.is_empty()
        && !roots
            .iter()
            .filter_map(|r| host.canonicalize(r).ok())
            .any(|r| target.starts_with(r))
    {
        return Err(Error::Usage(
            "path is outside the allowed locations (home directory or /Volumes)".into(),
        ));
    }
    let free = host
        .available_bytes(&target)
        .map_err(|e| io_err("free space", &e))?;
    if bytes > free / 100 * MAX_FREE_SHARE_PERCENT {
        return Err(Error::Failed(format!(
            "test file of {size_mib} MiB needs at most {MAX_FREE_SHARE_PERCENT} % of the {free} bytes available"
        )));
    }

    let started = rfc3339(clock.now());
    let dir = target.join(format!("{SESSION_PREFIX}{}", host.session_id()));
    host.create_dir(&dir)
        .map_err(|e| io_err("create session directory", &e))?;
    let file = dir.join(FILE_NAME);
    let result = transfer(host, &file, bytes, params.cache_mode);

    // Remove exactly what this run created; never recurse.
    let removal = match host.remove_file(&file) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
    .and_then(|()| host.remove_dir(&dir));
    let cleanup = json!({"removed": removal.is_ok(), "error": removal.as_ref().err().map(ToString::to_string)});

    let timed = result.map_err(|e| match (&removal, e) {
        (Err(c), Error::Failed(m)) => Error::Failed(format!("{m} (cleanup also failed: {c})")),
        (_, e) => e,
    })?;
    Ok(json!({
        "schema": 1,
        "started_at": started,
        "target": target.to_string_lossy(),
        "size_mib": size_mib,
        "block_bytes": BLOCK_BYTES,
        "cache_mode": params.cache_mode.as_str(),
        "cache_mode_applied": timed.cache_applied,
        "units": {"mib_per_s": "2^20 bytes per second", "mb_per_s": "10^6 bytes per second"},
        "write": phase(bytes, timed.write_nanos),
        "read": phase(bytes, timed.read_nanos),
        "cleanup": cleanup,
    }))
}

/// Human-readable form of [`speedtest_json`].
pub fn render_speedtest(v: &Value) -> String {
    let line = |name: &str, p: &Value| {
        format!(
            "{name:<6}{:>10.3} MiB/s {:>10.3} MB/s  ({} bytes in {} s)\n",
            p["mib_per_s"].as_f64().unwrap_or(0.0),
            p["mb_per_s"].as_f64().unwrap_or(0.0),
            p["bytes"],
            p["duration_seconds"]
        )
    };
    format!(
        "Speed test, {} MiB, {} (applied: {})\n{}{}cleanup: {}\n",
        v["size_mib"],
        v["cache_mode"].as_str().unwrap_or("?"),
        v["cache_mode_applied"],
        line("write", &v["write"]),
        line("read", &v["read"]),
        if v["cleanup"]["removed"] == true {
            "test files removed".to_owned()
        } else {
            format!("NOT removed: {}", v["cleanup"]["error"])
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fill_is_deterministic_and_not_constant() {
        let (mut a, mut b) = (vec![0u8; 1003], vec![0u8; 1003]);
        fill(&mut a, 7);
        fill(&mut b, 7);
        assert_eq!(a, b);
        assert!(a.iter().any(|&x| x != a[0]));
        fill(&mut b, 8);
        assert_ne!(a, b);
    }

    #[test]
    fn phase_units_mib_and_mb() {
        // 1 GiB in 1 s: 1024 MiB/s, 1073.742 MB/s.
        let p = phase(1 << 30, 1_000_000_000);
        assert_eq!(p["mib_per_s"], 1024.0);
        assert_eq!(p["mb_per_s"], 1073.742);
        assert_eq!(p["duration_seconds"], 1.0);
    }

    #[test]
    fn cli_and_json_parsing() {
        let a = |v: &[&str]| v.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
        let p = SpeedtestParams::parse_cli(
            &a(&[
                "--path",
                "/Volumes/x",
                "--size",
                "64",
                "--cache-mode",
                "cached",
                "--json",
            ]),
            Limits::cli(),
        )
        .unwrap();
        assert_eq!(
            (p.path, p.size_mib, p.cache_mode),
            (Some(PathBuf::from("/Volumes/x")), 64, CacheMode::Cached)
        );
        for bad in [
            &["--size", "x"][..],
            &["--cache-mode", "fast"],
            &["--path"],
            &["--x"],
        ] {
            assert_eq!(
                SpeedtestParams::parse_cli(&a(bad), Limits::cli())
                    .unwrap_err()
                    .exit_code(),
                2
            );
        }
        let p = SpeedtestParams::from_json(&json!({"size_mib": 8}), Limits::mcp(Path::new("/h")))
            .unwrap();
        assert_eq!(p.size_mib, 8);
        assert_eq!(Limits::mcp(Path::new("/h")).max_size_mib, 1024);
    }
}
