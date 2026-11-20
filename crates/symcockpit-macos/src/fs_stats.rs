//! Filesystem adapters: clock, volume free space, uncached test files for the
//! speed test and the `lstat` walker for the space analysis.
//!
//! The only `unsafe` here is two libc calls (`statfs`, `fcntl(F_NOCACHE)`)
//! behind safe functions. Capability tier: `documented` (POSIX / Darwin libc).

use std::ffi::CString;
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, Read, Write};
use std::mem::MaybeUninit;
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use symcockpit_core::storage::health::Clock;
use symcockpit_core::storage::space::{FsEntry, Kind, SpaceFs};
use symcockpit_core::storage::speedtest::{CacheMode, SpeedHost, TestFile};

/// Wall clock.
pub struct SystemClock;

impl Clock for SystemClock {
    fn now_unix(&self) -> i64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_secs() as i64)
    }
}

/// Bytes available to a normal user on the volume holding `path`.
pub fn available_bytes(path: &Path) -> io::Result<u64> {
    let c = CString::new(path.as_os_str().as_bytes()).map_err(|_| io::ErrorKind::InvalidInput)?;
    let mut st = MaybeUninit::<libc::statfs>::zeroed();
    // SAFETY: `c` is NUL-terminated; `st` is a valid, writable statfs.
    if unsafe { libc::statfs(c.as_ptr(), st.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: statfs returned 0, so it filled the struct.
    let st = unsafe { st.assume_init() };
    Ok(st.f_bavail.saturating_mul(u64::from(st.f_bsize)))
}

/// Ask the OS not to cache this file's data (`F_NOCACHE`). A best-effort request.
pub fn set_no_cache(file: &File) -> io::Result<()> {
    // SAFETY: the descriptor stays valid for the borrowed `File`; F_NOCACHE takes an int.
    if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_NOCACHE, 1) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

struct LiveFile {
    file: File,
    cache_applied: bool,
}

impl TestFile for LiveFile {
    fn write_all(&mut self, buf: &[u8]) -> io::Result<()> {
        Write::write_all(&mut self.file, buf)
    }

    /// `sync_all` is `F_FULLFSYNC` on Apple platforms: it waits for the device cache too.
    fn sync(&mut self) -> io::Result<()> {
        self.file.sync_all()
    }

    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        Read::read(&mut self.file, buf)
    }

    fn cache_applied(&self) -> bool {
        self.cache_applied
    }
}

/// Live speed-test host: real files, `O_EXCL` creation, monotonic clock.
pub struct LiveSpeedHost {
    start: Instant,
}

impl Default for LiveSpeedHost {
    fn default() -> Self {
        LiveSpeedHost {
            start: Instant::now(),
        }
    }
}

fn live(file: File, mode: CacheMode) -> Box<dyn TestFile> {
    let cache_applied = mode == CacheMode::Cached || set_no_cache(&file).is_ok();
    Box::new(LiveFile {
        file,
        cache_applied,
    })
}

impl SpeedHost for LiveSpeedHost {
    fn default_target(&self) -> io::Result<PathBuf> {
        std::env::var_os("HOME")
            .map(PathBuf::from)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "HOME is not set"))
    }

    fn canonicalize(&self, path: &Path) -> io::Result<PathBuf> {
        fs::canonicalize(path)
    }

    fn available_bytes(&self, dir: &Path) -> io::Result<u64> {
        available_bytes(dir)
    }

    fn monotonic_nanos(&self) -> u64 {
        self.start.elapsed().as_nanos() as u64
    }

    fn session_id(&self) -> String {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos());
        format!("{:x}-{nanos:x}", std::process::id())
    }

    fn create_dir(&self, dir: &Path) -> io::Result<()> {
        DirBuilder::new().mode(0o700).create(dir)
    }

    fn create_file(&self, path: &Path, mode: CacheMode) -> io::Result<Box<dyn TestFile>> {
        let file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(path)?;
        Ok(live(file, mode))
    }

    fn open_file(&self, path: &Path, mode: CacheMode) -> io::Result<Box<dyn TestFile>> {
        Ok(live(File::open(path)?, mode))
    }

    fn remove_file(&self, path: &Path) -> io::Result<()> {
        fs::remove_file(path)
    }

    fn remove_dir(&self, dir: &Path) -> io::Result<()> {
        fs::remove_dir(dir)
    }
}

/// `lstat`-based walker input: never follows symlinks.
pub struct StdSpaceFs;

fn entry(name: String, m: &fs::Metadata) -> FsEntry {
    let t = m.file_type();
    let kind = if t.is_dir() {
        Kind::Dir
    } else if t.is_symlink() {
        Kind::Symlink
    } else if t.is_file() {
        Kind::File
    } else {
        Kind::Other
    };
    FsEntry {
        name,
        kind,
        device: m.dev(),
        inode: m.ino(),
        links: m.nlink(),
        allocated: m.blocks() * 512,
        apparent: m.len(),
    }
}

impl SpaceFs for StdSpaceFs {
    fn canonicalize(&self, path: &Path) -> io::Result<PathBuf> {
        fs::canonicalize(path)
    }

    fn stat(&self, path: &Path) -> io::Result<FsEntry> {
        let name = path
            .file_name()
            .map_or_else(String::new, |n| n.to_string_lossy().into_owned());
        Ok(entry(name, &fs::symlink_metadata(path)?))
    }

    fn read_dir(&self, path: &Path) -> io::Result<Vec<FsEntry>> {
        let mut out = Vec::new();
        for e in fs::read_dir(path)? {
            let e = e?;
            match e.metadata() {
                Ok(m) => out.push(entry(e.file_name().to_string_lossy().into_owned(), &m)),
                // Removed between listing and lstat: it is gone, not unreadable.
                Err(err) if err.kind() == io::ErrorKind::NotFound => {}
                Err(err) => return Err(err),
            }
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use symcockpit_core::storage::space::{SpaceParams, space_json};
    use symcockpit_core::storage::speedtest::{Limits, SpeedtestParams, speedtest_json};

    /// Live tests work only in a fresh temporary directory under `$SYMCOCKPIT_LIVE_DIR`
    /// (default: the system temp directory) and remove it afterwards.
    fn live_dir() -> tempfile::TempDir {
        match std::env::var_os("SYMCOCKPIT_LIVE_DIR") {
            Some(base) => tempfile::tempdir_in(base).unwrap(),
            None => tempfile::tempdir().unwrap(),
        }
    }

    #[test]
    fn available_bytes_reports_something_for_the_temp_dir() {
        assert!(available_bytes(&std::env::temp_dir()).unwrap() > 0);
    }

    /// Writes and reads 256 MiB at most, in its own session directory.
    #[test]
    #[ignore = "writes a 256 MiB test file in a temporary directory"]
    fn live_speedtest_256_mib() {
        let dir = live_dir();
        let mut p = SpeedtestParams::new(Limits::cli());
        p.path = Some(dir.path().to_owned());
        p.size_mib = 256;
        let v = speedtest_json(&LiveSpeedHost::default(), &SystemClock, &p).unwrap();
        println!(
            "write {} MiB/s ({} MB/s), read {} MiB/s ({} MB/s), cache {} applied={}",
            v["write"]["mib_per_s"],
            v["write"]["mb_per_s"],
            v["read"]["mib_per_s"],
            v["read"]["mb_per_s"],
            v["cache_mode"],
            v["cache_mode_applied"]
        );
        assert_eq!(v["write"]["bytes"], 256u64 << 20);
        assert_eq!(v["read"]["bytes"], 256u64 << 20);
        assert!(
            v["write"]["mib_per_s"].as_f64().unwrap() > 0.0
                && v["read"]["mib_per_s"].as_f64().unwrap() > 0.0
        );
        assert_eq!(v["cleanup"]["removed"], true);
        assert_eq!(
            fs::read_dir(dir.path()).unwrap().count(),
            0,
            "the session directory must be gone"
        );
    }

    /// A real hardlink and a symlink in an own test folder.
    #[test]
    #[ignore = "creates files in a temporary directory"]
    fn live_space_counts_hardlinks_once() {
        let dir = live_dir();
        let root = dir.path();
        fs::create_dir_all(root.join("a")).unwrap();
        fs::create_dir_all(root.join("b")).unwrap();
        fs::write(root.join("a/big"), vec![7u8; 1 << 20]).unwrap();
        fs::hard_link(root.join("a/big"), root.join("b/big-link")).unwrap();
        fs::write(root.join("b/small"), b"x").unwrap();
        std::os::unix::fs::symlink(root.join("a"), root.join("link-to-a")).unwrap();
        let v = space_json(
            &StdSpaceFs,
            &SystemClock,
            &SpaceParams::new(root.to_owned()),
        )
        .unwrap();
        println!("{}", symcockpit_core::storage::space::render_space(&v));
        assert_eq!(v["hardlinks"]["duplicates_skipped"], 1);
        let size = |name: &str| {
            v["tree"]["children"]
                .as_array()
                .unwrap()
                .iter()
                .find(|c| c["name"] == name)
                .unwrap()["apparent_bytes"]
                .as_u64()
                .unwrap()
        };
        // 1 MiB charged to `a` (first by name), none to `b`; the symlink is its own few bytes, not 1 MiB.
        assert!(size("a") >= 1 << 20 && size("b") < 1 << 20 && size("link-to-a") < 1 << 10);
        assert!(
            v["hardlinks"]["allocated_bytes_not_counted"]
                .as_u64()
                .unwrap()
                >= 1 << 20
        );
        assert_eq!(v["error_count"], 0);
    }
}
