//! Fakes for the storage health ports (NVMe, history, speed test, file tree)
//! and the tests that run the `storage` commands against them, including the
//! shape snapshots under `snapshots/storage_health/`.

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use symcockpit_contract::Error;
use symcockpit_core::storage::health::{
    Clock, HistoryStore, Location, NvmeDevice, NvmeSource, SmartReadError, SmartSample,
};
use symcockpit_core::storage::space::{FsEntry, Kind, SpaceFs};
use symcockpit_core::storage::speedtest::{CacheMode, SpeedHost, TestFile};

/// A clock that always says the same second.
pub struct FixedClock(pub i64);

impl Clock for FixedClock {
    fn now_unix(&self) -> i64 {
        self.0
    }
}

/// 512-byte SMART log page with a healthy baseline (310 K, spare 100 / threshold 10);
/// `edit` changes bytes. Synthetic, not a device recording.
pub fn smart_page(edit: impl FnOnce(&mut [u8; 512])) -> [u8; 512] {
    let mut p = [0u8; 512];
    p[1..3].copy_from_slice(&310u16.to_le_bytes());
    p[3] = 100;
    p[4] = 10;
    p[32..40].copy_from_slice(&2_000u64.to_le_bytes()); // data units read
    p[48..56].copy_from_slice(&1_000u64.to_le_bytes()); // data units written
    edit(&mut p);
    p
}

pub fn nvme_device(
    location: Location,
    model: &str,
    smart: Result<[u8; 512], SmartReadError>,
) -> NvmeDevice {
    NvmeDevice {
        location,
        model: Some(model.into()),
        firmware: Some("FW1".into()),
        smart,
    }
}

pub struct FakeNvme(pub Result<Vec<NvmeDevice>, Error>);

impl NvmeSource for FakeNvme {
    fn devices(&self) -> Result<Vec<NvmeDevice>, Error> {
        self.0.clone()
    }
}

#[derive(Default)]
pub struct MemoryHistory {
    pub samples: RefCell<Vec<SmartSample>>,
    pub fail_record: Cell<bool>,
}

impl HistoryStore for MemoryHistory {
    fn latest(&self, key: &str) -> Result<Option<SmartSample>, Error> {
        Ok(self.list(Some(key), 1)?.pop())
    }

    fn record(&self, s: &SmartSample) -> Result<(), Error> {
        if self.fail_record.get() {
            return Err(Error::Failed("disk full".into()));
        }
        self.samples.borrow_mut().push(s.clone());
        Ok(())
    }

    fn list(&self, key: Option<&str>, limit: usize) -> Result<Vec<SmartSample>, Error> {
        let mut v: Vec<_> = self
            .samples
            .borrow()
            .iter()
            .filter(|s| key.is_none_or(|k| k == s.device_key))
            .cloned()
            .collect();
        v.sort_by_key(|s| std::cmp::Reverse(s.measured_at));
        v.truncate(limit);
        Ok(v)
    }
}

// ---- speed test host ----------------------------------------------------------

/// In-memory directory tree with a virtual monotonic clock: every byte
/// written or read advances time by `1e9 / bytes_per_second` nanoseconds.
pub struct FakeSpeedHost {
    pub dirs: RefCell<BTreeSet<PathBuf>>,
    pub files: Rc<RefCell<BTreeMap<PathBuf, u64>>>,
    pub free: u64,
    pub bytes_per_second: u64,
    pub log: RefCell<Vec<String>>,
    pub nocache_supported: bool,
    now: Rc<Cell<u64>>,
}

impl FakeSpeedHost {
    pub fn new(free: u64, bytes_per_second: u64) -> Self {
        let dirs = ["/", "/Users", "/Users/test", "/Volumes", "/Volumes/ext"].map(PathBuf::from);
        FakeSpeedHost {
            dirs: RefCell::new(dirs.into()),
            files: Rc::default(),
            free,
            bytes_per_second,
            log: RefCell::default(),
            nocache_supported: true,
            now: Rc::default(),
        }
    }
}

struct FakeFile {
    path: PathBuf,
    files: Rc<RefCell<BTreeMap<PathBuf, u64>>>,
    now: Rc<Cell<u64>>,
    rate: u64,
    read_pos: u64,
    cache_applied: bool,
}

impl FakeFile {
    fn advance(&self, bytes: u64) {
        self.now
            .set(self.now.get() + bytes * 1_000_000_000 / self.rate);
    }
}

impl TestFile for FakeFile {
    fn write_all(&mut self, buf: &[u8]) -> io::Result<()> {
        *self.files.borrow_mut().get_mut(&self.path).unwrap() += buf.len() as u64;
        self.advance(buf.len() as u64);
        Ok(())
    }

    fn sync(&mut self) -> io::Result<()> {
        Ok(())
    }

    /// Hands out at most 1 MiB per call, like a real short read.
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let size = self.files.borrow()[&self.path];
        let n = (size - self.read_pos).min(buf.len() as u64).min(1 << 20);
        self.read_pos += n;
        self.advance(n);
        Ok(n as usize)
    }

    fn cache_applied(&self) -> bool {
        self.cache_applied
    }
}

impl SpeedHost for FakeSpeedHost {
    fn default_target(&self) -> io::Result<PathBuf> {
        Ok("/Users/test".into())
    }

    fn canonicalize(&self, path: &Path) -> io::Result<PathBuf> {
        // Resolves `..` lexically, like a real canonicalize on existing paths.
        let mut out = PathBuf::new();
        for c in path.components() {
            match c {
                std::path::Component::ParentDir => {
                    out.pop();
                }
                std::path::Component::CurDir => {}
                c => out.push(c),
            }
        }
        if self.dirs.borrow().contains(&out) {
            Ok(out)
        } else {
            Err(io::ErrorKind::NotFound.into())
        }
    }

    fn available_bytes(&self, _dir: &Path) -> io::Result<u64> {
        Ok(self.free)
    }

    fn monotonic_nanos(&self) -> u64 {
        self.now.get()
    }

    fn session_id(&self) -> String {
        "s1".into()
    }

    fn create_dir(&self, dir: &Path) -> io::Result<()> {
        self.log
            .borrow_mut()
            .push(format!("mkdir {}", dir.display()));
        if self.dirs.borrow_mut().insert(dir.to_owned()) {
            Ok(())
        } else {
            Err(io::ErrorKind::AlreadyExists.into())
        }
    }

    fn create_file(&self, path: &Path, mode: CacheMode) -> io::Result<Box<dyn TestFile>> {
        self.log
            .borrow_mut()
            .push(format!("create {}", path.display()));
        if self.files.borrow_mut().insert(path.to_owned(), 0).is_some() {
            return Err(io::ErrorKind::AlreadyExists.into());
        }
        Ok(self.file(path, mode))
    }

    fn open_file(&self, path: &Path, mode: CacheMode) -> io::Result<Box<dyn TestFile>> {
        Ok(self.file(path, mode))
    }

    fn remove_file(&self, path: &Path) -> io::Result<()> {
        self.log.borrow_mut().push(format!("rm {}", path.display()));
        self.files
            .borrow_mut()
            .remove(path)
            .map(drop)
            .ok_or_else(|| io::ErrorKind::NotFound.into())
    }

    fn remove_dir(&self, dir: &Path) -> io::Result<()> {
        self.log
            .borrow_mut()
            .push(format!("rmdir {}", dir.display()));
        if self.files.borrow().keys().any(|f| f.starts_with(dir)) {
            return Err(io::Error::other("directory not empty"));
        }
        self.dirs.borrow_mut().remove(dir);
        Ok(())
    }
}

impl FakeSpeedHost {
    fn file(&self, path: &Path, mode: CacheMode) -> Box<dyn TestFile> {
        Box::new(FakeFile {
            path: path.to_owned(),
            files: self.files.clone(),
            now: self.now.clone(),
            rate: self.bytes_per_second,
            read_pos: 0,
            cache_applied: mode == CacheMode::Cached || self.nocache_supported,
        })
    }
}

// ---- file tree ------------------------------------------------------------------

/// In-memory `lstat` tree: path -> entry; children are found by parent path.
#[derive(Default)]
pub struct FakeTree {
    entries: BTreeMap<PathBuf, FsEntry>,
    pub unreadable: BTreeSet<PathBuf>,
    next_inode: Cell<u64>,
}

impl FakeTree {
    pub fn new() -> Self {
        let mut t = FakeTree::default();
        t.dir("/root", 1);
        t
    }

    fn put(&mut self, path: &str, kind: Kind, device: u64, inode: u64, links: u64, bytes: u64) {
        let path = PathBuf::from(path);
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        // Allocation is rounded up to 4 KiB blocks, as on APFS.
        let allocated = if kind == Kind::Dir {
            0
        } else {
            bytes.div_ceil(4096) * 4096
        };
        self.entries.insert(
            path,
            FsEntry {
                name,
                kind,
                device,
                inode,
                links,
                allocated,
                apparent: bytes,
            },
        );
    }

    pub fn dir(&mut self, path: &str, device: u64) -> &mut Self {
        let i = self.inode();
        self.put(path, Kind::Dir, device, i, 2, 0);
        self
    }

    fn inode(&self) -> u64 {
        self.next_inode.set(self.next_inode.get() + 1);
        self.next_inode.get() + 1000
    }

    pub fn file(&mut self, path: &str, bytes: u64) -> &mut Self {
        let i = self.inode();
        self.put(path, Kind::File, 1, i, 1, bytes);
        self
    }

    /// A file that has several names: pass the same `inode` for each.
    pub fn linked_file(&mut self, path: &str, inode: u64, links: u64, bytes: u64) -> &mut Self {
        self.put(path, Kind::File, 1, inode, links, bytes);
        self
    }

    pub fn symlink(&mut self, path: &str) -> &mut Self {
        let i = self.inode();
        self.put(path, Kind::Symlink, 1, i, 1, 9);
        self
    }
}

impl SpaceFs for FakeTree {
    fn canonicalize(&self, path: &Path) -> io::Result<PathBuf> {
        if self.entries.contains_key(path) {
            Ok(path.to_owned())
        } else {
            Err(io::ErrorKind::NotFound.into())
        }
    }

    fn stat(&self, path: &Path) -> io::Result<FsEntry> {
        self.entries
            .get(path)
            .cloned()
            .ok_or_else(|| io::ErrorKind::NotFound.into())
    }

    fn read_dir(&self, path: &Path) -> io::Result<Vec<FsEntry>> {
        if self.unreadable.contains(path) {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        Ok(self
            .entries
            .iter()
            .filter(|(p, _)| p.parent() == Some(path))
            .map(|(_, e)| e.clone())
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use serde_json::{Value, json};
    use symcockpit_core::storage::health::{
        self, Grade, HealthParams, HistoryParams, RULES_VERSION, health_history_json, health_json,
    };
    use symcockpit_core::storage::space::{SpaceParams, space_json};
    use symcockpit_core::storage::speedtest::{Limits, SpeedtestParams, speedtest_json};
    use symcockpit_oracle::shape;

    use super::*;

    const NOW: i64 = 1_700_000_000;
    const MIB: u64 = 1 << 20;

    // ---- shape snapshots ------------------------------------------------------

    /// Compare the shape of `actual` with `snapshots/storage_health/<id>.shape.json`.
    /// `SYMCOCKPIT_UPDATE_SNAPSHOTS=1` rewrites the file instead; review the diff.
    fn check_shape(id: &str, actual: &Value) {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join(format!("../../snapshots/storage_health/{id}.shape.json"));
        let got = shape::derive(actual).unwrap();
        if std::env::var_os("SYMCOCKPIT_UPDATE_SNAPSHOTS").is_some() {
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(&path, serde_json::to_string_pretty(&got).unwrap() + "\n").unwrap();
        }
        let want: Value = serde_json::from_slice(
            &fs::read(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display())),
        )
        .unwrap();
        let diff = shape::compare(&want, &got);
        assert!(
            diff.errors.is_empty() && diff.hints.is_empty(),
            "{id}: {diff:?}"
        );
    }

    fn health_fixture() -> (FakeNvme, MemoryHistory) {
        let bad = SmartReadError {
            stage: "SMARTReadData",
            code: 0x10000003,
        };
        let nvme = FakeNvme(Ok(vec![
            nvme_device(Location::Internal, "TEST INTERNAL", Ok(smart_page(|_| {}))),
            nvme_device(Location::External, "TEST EXTERNAL", Err(bad)),
        ]));
        (nvme, MemoryHistory::default())
    }

    #[test]
    fn health_shape() {
        let (nvme, history) = health_fixture();
        let v = health_json(
            &nvme,
            &FixedClock(NOW),
            Some(&history),
            &HealthParams::default(),
        )
        .unwrap();
        check_shape("storage_health", &v);
    }

    #[test]
    fn health_history_shape() {
        let history = MemoryHistory::default();
        let nvme = FakeNvme(Ok(vec![nvme_device(
            Location::Internal,
            "TEST INTERNAL",
            Ok(smart_page(|_| {})),
        )]));
        health_json(
            &nvme,
            &FixedClock(NOW),
            Some(&history),
            &HealthParams::default(),
        )
        .unwrap();
        let worse = FakeNvme(Ok(vec![nvme_device(
            Location::Internal,
            "TEST INTERNAL",
            Ok(smart_page(|p| p[5] = 85)),
        )]));
        health_json(
            &worse,
            &FixedClock(NOW + 3600),
            Some(&history),
            &HealthParams::default(),
        )
        .unwrap();
        let v = health_history_json(&history, &HistoryParams::default()).unwrap();
        check_shape("storage_health_history", &v);
    }

    fn speedtest_value() -> Value {
        let host = FakeSpeedHost::new(100 << 30, 1000 * MIB);
        let mut p = SpeedtestParams::new(Limits::cli());
        p.size_mib = 8;
        speedtest_json(&host, &FixedClock(NOW), &p).unwrap()
    }

    #[test]
    fn speedtest_shape() {
        check_shape("storage_speedtest", &speedtest_value());
    }

    fn space_tree() -> FakeTree {
        let mut t = FakeTree::new();
        t.dir("/root/a", 1)
            .dir("/root/a/deep", 1)
            .file("/root/a/deep/f", 10_000)
            .file("/root/a/big", 3 << 20)
            .file("/root/b", 5000)
            .symlink("/root/s");
        t
    }

    #[test]
    fn space_shape() {
        let v = space_json(
            &space_tree(),
            &FixedClock(NOW),
            &SpaceParams {
                path: "/root".into(),
                depth: 2,
                limit: 1,
            },
        )
        .unwrap();
        check_shape("storage_space", &v);
    }

    #[test]
    fn snapshots_hold_no_private_data() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../snapshots/storage_health");
        let mut n = 0;
        for e in fs::read_dir(dir).unwrap() {
            let text = fs::read_to_string(e.unwrap().path())
                .unwrap()
                .to_lowercase();
            n += 1;
            for bad in ["/users/", "serial", "eui64", "nguid"] {
                assert!(!text.contains(bad), "{bad}");
            }
        }
        assert_eq!(n, 4);
    }

    // ---- health -----------------------------------------------------------------

    #[test]
    fn health_reports_worst_case_with_reasons_units_and_rules_version() {
        let nvme = FakeNvme(Ok(vec![nvme_device(
            Location::Internal,
            "TEST INTERNAL",
            Ok(smart_page(|p| {
                p[5] = 85;
                p[0] = 1 << 4;
                p[1..3].copy_from_slice(&321u16.to_le_bytes());
            })),
        )]));
        let v = health_json(
            &nvme,
            &FixedClock(NOW),
            None,
            &HealthParams { record: false },
        )
        .unwrap();
        assert_eq!(v["rules_version"], RULES_VERSION);
        assert_eq!(v["overall_grade"], "critical");
        let d = &v["devices"][0];
        assert_eq!(d["grade"], "critical");
        let grade_of = |rule: &str| {
            d["checks"]
                .as_array()
                .unwrap()
                .iter()
                .find(|c| c["rule"] == rule)
                .unwrap()["grade"]
                .clone()
        };
        assert_eq!(
            (
                grade_of("critical_warning"),
                grade_of("percentage_used"),
                grade_of("temperature")
            ),
            (json!("critical"), json!("warning"), json!("good"))
        );
        // Units and quality are explicit; data units are 512 000 bytes.
        let m = &d["metrics"];
        assert_eq!(
            m["temperature_celsius"],
            json!({"value": 48, "unit": "celsius", "at": "2023-11-14T22:13:20Z", "quality": "derived"})
        );
        assert_eq!(
            m["data_written"],
            json!({"value": 1_000u64 * 512_000, "unit": "byte", "at": "2023-11-14T22:13:20Z", "quality": "derived"})
        );
        assert_eq!(m["available_spare"]["unit"], "percent");
        assert_eq!(d["access"]["status"], "ok");
        assert_eq!(d["key"], "internal:TEST INTERNAL");
    }

    #[test]
    fn health_separates_access_status_from_measurements_and_ignores_unreadable_in_overall() {
        let (nvme, _) = health_fixture();
        let v = health_json(&nvme, &FixedClock(NOW), None, &HealthParams::default()).unwrap();
        let ext = &v["devices"][0];
        assert_eq!(ext["location"], "external");
        assert_eq!(
            ext["access"],
            json!({"status": "error", "stage": "SMARTReadData", "code": "0x10000003"})
        );
        assert_eq!(
            (ext["grade"].clone(), ext["metrics"].clone()),
            (json!("unknown"), Value::Null)
        );
        assert_eq!(v["overall_grade"], "good");
        assert_eq!(v["devices"][1]["history"]["status"], "skipped");
    }

    #[test]
    fn health_errors_map_to_exit_codes() {
        let none = FakeNvme(Ok(vec![]));
        assert_eq!(
            health_json(&none, &FixedClock(0), None, &HealthParams::default())
                .unwrap_err()
                .exit_code(),
            4
        );
        let broken = FakeNvme(Err(Error::Failed("IOKit".into())));
        assert_eq!(
            health_json(&broken, &FixedClock(0), None, &HealthParams::default())
                .unwrap_err()
                .exit_code(),
            1
        );
    }

    #[test]
    fn recording_is_opt_out_and_a_failing_store_does_not_fail_the_read() {
        let (nvme, history) = health_fixture();
        health_json(
            &nvme,
            &FixedClock(NOW),
            Some(&history),
            &HealthParams { record: false },
        )
        .unwrap();
        assert!(history.samples.borrow().is_empty());
        history.fail_record.set(true);
        let v = health_json(
            &nvme,
            &FixedClock(NOW),
            Some(&history),
            &HealthParams::default(),
        )
        .unwrap();
        assert_eq!(
            v["devices"][1]["history"],
            json!({"status": "error", "detail": "disk full"})
        );
        history.fail_record.set(false);
        let v = health_json(
            &nvme,
            &FixedClock(NOW),
            Some(&history),
            &HealthParams::default(),
        )
        .unwrap();
        assert_eq!(v["devices"][1]["history"]["status"], "recorded");
        let stored = history.samples.borrow();
        assert_eq!(stored.len(), 1, "unreadable devices are not recorded");
        assert_eq!(
            (
                stored[0].rules_version,
                stored[0].measured_at,
                stored[0].grade
            ),
            (RULES_VERSION, NOW, Grade::Good)
        );
    }

    #[test]
    fn rising_media_errors_turn_critical_through_the_history() {
        let history = MemoryHistory::default();
        let with = |n: u8| {
            FakeNvme(Ok(vec![nvme_device(
                Location::Internal,
                "D",
                Ok(smart_page(|p| p[160] = n)),
            )]))
        };
        let grade = |nvme: &FakeNvme, t| {
            health_json(
                nvme,
                &FixedClock(t),
                Some(&history),
                &HealthParams::default(),
            )
            .unwrap()["devices"][0]["grade"]
                .clone()
        };
        assert_eq!(grade(&with(0), 1), "good");
        assert_eq!(grade(&with(2), 2), "critical");
        assert_eq!(grade(&with(2), 3), "warning");
    }

    #[test]
    fn history_lists_newest_first_with_changes_and_limit() {
        let history = MemoryHistory::default();
        let pages = [
            smart_page(|_| {}),
            smart_page(|p| p[3] = 90),
            smart_page(|p| p[3] = 90),
        ];
        for (i, page) in pages.into_iter().enumerate() {
            let nvme = FakeNvme(Ok(vec![nvme_device(Location::Internal, "D", Ok(page))]));
            health_json(
                &nvme,
                &FixedClock(NOW + i as i64 * 60),
                Some(&history),
                &HealthParams::default(),
            )
            .unwrap();
        }
        let v = health_history_json(&history, &HistoryParams::default()).unwrap();
        let rows = v["samples"].as_array().unwrap();
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[0]["measured_at"], "2023-11-14T22:15:20Z");
        assert_eq!(rows[0]["changes"], json!([]));
        assert_eq!(rows[1]["changes"][0]["kind"], "available_spare");
        assert_eq!(rows[2]["changes"], Value::Null);
        let v = health_history_json(
            &history,
            &HistoryParams {
                limit: 1,
                device: Some("internal:D".into()),
            },
        )
        .unwrap();
        assert_eq!(v["samples"].as_array().unwrap().len(), 1);
        assert_eq!(health::RULES_VERSION, v["rules_version"]);
    }

    // ---- speed test ---------------------------------------------------------------

    #[test]
    fn speedtest_reports_bytes_duration_mib_mb_and_cache_mode() {
        let v = speedtest_value();
        // 8 MiB at 1000 MiB/s: 8 ms; the same rate in MB/s is 1048.576.
        assert_eq!(v["write"]["bytes"], 8 * MIB);
        assert_eq!(v["write"]["duration_seconds"], 0.008);
        assert_eq!(v["write"]["mib_per_s"], 1000.0);
        assert_eq!(v["write"]["mb_per_s"], 1048.576);
        assert_eq!(v["read"]["mib_per_s"], 1000.0);
        assert_eq!(
            (v["cache_mode"].clone(), v["cache_mode_applied"].clone()),
            (json!("uncached"), json!(true))
        );
        assert_eq!(v["units"]["mb_per_s"], "10^6 bytes per second");
        assert_eq!(v["block_bytes"], 4 * MIB);
    }

    #[test]
    fn speedtest_removes_only_its_own_files_and_reports_a_foreign_one() {
        let host = FakeSpeedHost::new(100 << 30, 500 * MIB);
        // Something that looks like another tool's leftovers, in the target and in our session directory.
        host.files
            .borrow_mut()
            .insert("/Users/test/DiskSpeedTestTemp123456".into(), 5);
        let mut p = SpeedtestParams::new(Limits::cli());
        p.size_mib = 4;
        let v = speedtest_json(&host, &FixedClock(NOW), &p).unwrap();
        assert_eq!(v["cleanup"], json!({"removed": true, "error": null}));
        assert!(
            host.files
                .borrow()
                .contains_key(Path::new("/Users/test/DiskSpeedTestTemp123456"))
        );
        assert_eq!(host.files.borrow().len(), 1);
        assert!(
            !host
                .dirs
                .borrow()
                .iter()
                .any(|d| d.to_string_lossy().contains(".symcockpit-speedtest-"))
        );
        assert_eq!(
            host.log
                .borrow()
                .iter()
                .filter(|l| l.starts_with("rm"))
                .count(),
            2
        ); // file + dir, nothing else

        // A foreign file inside the session directory stays; the directory then cannot go.
        let host = FakeSpeedHost::new(100 << 30, 500 * MIB);
        host.dirs
            .borrow_mut()
            .insert("/Users/test/.symcockpit-speedtest-s1".into());
        assert_eq!(
            speedtest_json(&host, &FixedClock(NOW), &p)
                .unwrap_err()
                .exit_code(),
            1,
            "session directory exists already"
        );
        host.dirs.borrow_mut().clear();
        host.dirs.borrow_mut().insert("/Users/test".into());
        // Foreign file appears while we run: simulate by pre-placing it where `remove_dir` looks.
        host.files
            .borrow_mut()
            .insert("/Users/test/.symcockpit-speedtest-s1/foreign".into(), 1);
        let v = speedtest_json(&host, &FixedClock(NOW), &p).unwrap();
        assert_eq!(v["cleanup"]["removed"], false);
        assert!(
            host.files
                .borrow()
                .contains_key(Path::new("/Users/test/.symcockpit-speedtest-s1/foreign"))
        );
    }

    #[test]
    fn speedtest_limits_for_agents() {
        let host = FakeSpeedHost::new(100 << 30, 500 * MIB);
        let run = |path: &str, size: u64| {
            let mut p = SpeedtestParams::new(Limits::mcp(Path::new("/Users/test")));
            p.path = Some(path.into());
            p.size_mib = size;
            speedtest_json(&host, &FixedClock(NOW), &p)
        };
        assert!(run("/Users/test", 4).is_ok());
        assert!(run("/Volumes/ext", 4).is_ok());
        assert_eq!(run("/Users/test", 1025).unwrap_err().exit_code(), 2);
        assert_eq!(run("/Users/test", 0).unwrap_err().exit_code(), 2);
        assert_eq!(run("/", 4).unwrap_err().exit_code(), 2);
        assert_eq!(
            run("/Users/test/../../", 4).unwrap_err().exit_code(),
            2,
            "`..` is resolved before the check"
        );
        assert_eq!(run("/nowhere", 4).unwrap_err().exit_code(), 2);
        // The CLI is not restricted to home or /Volumes.
        let mut p = SpeedtestParams::new(Limits::cli());
        (p.path, p.size_mib) = (Some("/".into()), 4);
        assert!(speedtest_json(&host, &FixedClock(NOW), &p).is_ok());
    }

    #[test]
    fn speedtest_refuses_to_fill_the_volume_and_reports_cache_mode_not_applied() {
        let small = FakeSpeedHost::new(100 * MIB, 500 * MIB);
        let mut p = SpeedtestParams::new(Limits::cli());
        p.size_mib = 64;
        assert_eq!(
            speedtest_json(&small, &FixedClock(NOW), &p)
                .unwrap_err()
                .exit_code(),
            1
        );
        assert!(
            small.files.borrow().is_empty() && small.log.borrow().is_empty(),
            "nothing is created before the space check"
        );
        p.size_mib = 50;
        assert!(speedtest_json(&small, &FixedClock(NOW), &p).is_ok());

        let mut host = FakeSpeedHost::new(100 << 30, 500 * MIB);
        host.nocache_supported = false;
        p.size_mib = 4;
        let v = speedtest_json(&host, &FixedClock(NOW), &p).unwrap();
        assert_eq!(
            (v["cache_mode"].clone(), v["cache_mode_applied"].clone()),
            (json!("uncached"), json!(false))
        );
        p.cache_mode = CacheMode::Cached;
        assert_eq!(
            speedtest_json(&host, &FixedClock(NOW), &p).unwrap()["cache_mode_applied"],
            true
        );
    }

    #[test]
    fn speedtest_size_that_is_not_a_block_multiple_is_written_completely() {
        let host = FakeSpeedHost::new(100 << 30, 500 * MIB);
        let mut p = SpeedtestParams::new(Limits::cli());
        p.size_mib = 5; // one 4 MiB block and a 1 MiB rest
        let v = speedtest_json(&host, &FixedClock(NOW), &p).unwrap();
        assert_eq!(
            (v["write"]["bytes"].clone(), v["read"]["bytes"].clone()),
            (json!(5 * MIB), json!(5 * MIB))
        );
    }

    // ---- space ----------------------------------------------------------------------

    fn space(t: &FakeTree, depth: usize, limit: usize) -> Value {
        space_json(
            t,
            &FixedClock(NOW),
            &SpaceParams {
                path: "/root".into(),
                depth,
                limit,
            },
        )
        .unwrap()
    }

    fn child<'a>(n: &'a Value, name: &str) -> &'a Value {
        n["children"]
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["name"] == name)
            .unwrap_or_else(|| panic!("no {name}"))
    }

    #[test]
    fn space_tree_is_sorted_by_allocated_size_with_apparent_size_alongside() {
        let v = space(&space_tree(), 3, 10);
        let t = &v["tree"];
        let names: Vec<_> = t["children"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["name"].as_str().unwrap().to_owned())
            .collect();
        assert_eq!(names, ["a", "b", "s"]);
        assert_eq!(t["allocated_bytes"], (3 << 20) + 12_288 + 8192 + 4096);
        assert_eq!(t["apparent_bytes"], (3 << 20) + 10_000 + 5000 + 9);
        assert_eq!(child(t, "b")["allocated_bytes"], 8192);
        assert_eq!(child(child(t, "a"), "deep")["children"][0]["name"], "f");
        assert_eq!(t["files"], 4);
        assert_eq!(v["unit"], "byte");
    }

    #[test]
    fn space_depth_and_limit_fold_the_rest_into_other_without_changing_totals() {
        let full = space(&space_tree(), 3, 10)["tree"]["allocated_bytes"].clone();
        let v = space(&space_tree(), 1, 1);
        let t = &v["tree"];
        assert_eq!(t["allocated_bytes"], full);
        assert_eq!(t["children"].as_array().unwrap().len(), 1);
        assert_eq!(t["children"][0]["name"], "a");
        assert_eq!(
            t["other"],
            json!({"count": 2, "allocated_bytes": 8192 + 4096, "apparent_bytes": 5009})
        );
        // depth 1: `a` is listed but its children are not.
        assert_eq!(t["children"][0]["children"], json!([]));
        assert_eq!(t["children"][0]["allocated_bytes"], (3 << 20) + 12_288);
    }

    #[test]
    fn hardlinks_are_counted_once_in_first_name_order() {
        let mut t = FakeTree::new();
        t.dir("/root/a", 1).dir("/root/b", 1);
        t.linked_file("/root/a/x", 77, 3, 1 << 20)
            .linked_file("/root/b/y", 77, 3, 1 << 20)
            .linked_file("/root/b/z", 77, 3, 1 << 20)
            .file("/root/b/own", 100);
        let v = space(&t, 2, 10);
        assert_eq!(child(&v["tree"], "a")["allocated_bytes"], 1 << 20);
        assert_eq!(child(&v["tree"], "b")["allocated_bytes"], 4096);
        assert_eq!(v["tree"]["allocated_bytes"], (1 << 20) + 4096);
        assert_eq!(
            v["hardlinks"],
            json!({"duplicates_skipped": 2, "allocated_bytes_not_counted": 2 << 20})
        );
        // Files counted: the shared inode once plus `own`.
        assert_eq!(v["tree"]["files"], 2);
    }

    #[test]
    fn same_inode_on_another_device_is_a_different_file_and_single_links_are_never_merged() {
        let mut t = FakeTree::new();
        t.dir("/root/a", 1);
        t.linked_file("/root/a/x", 5, 1, 4096)
            .linked_file("/root/a/y", 5, 1, 4096);
        let v = space(&t, 2, 10);
        assert_eq!(
            v["tree"]["allocated_bytes"], 8192,
            "nlink 1 means no sharing"
        );
        assert_eq!(v["hardlinks"]["duplicates_skipped"], 0);
    }

    #[test]
    fn other_devices_are_not_crossed_and_unreadable_directories_are_reported() {
        let mut t = space_tree();
        t.dir("/root/mnt", 2).file("/root/mnt/huge", 1 << 30);
        t.unreadable.insert("/root/a/deep".into());
        let v = space(&t, 3, 10);
        assert_eq!(v["skipped_other_devices"], 1);
        assert!(
            v["tree"]["children"]
                .as_array()
                .unwrap()
                .iter()
                .all(|c| c["name"] != "mnt")
        );
        assert_eq!(v["error_count"], 1);
        assert_eq!(v["errors"][0]["path"], "/root/a/deep");
        assert_eq!(v["truncated"], false);
        // Symlinks count their own bytes, never the target.
        assert_eq!(child(&v["tree"], "s")["kind"], "symlink");
    }

    #[test]
    fn space_errors_map_to_exit_codes() {
        let t = space_tree();
        let err = |p: &str| {
            space_json(&t, &FixedClock(0), &SpaceParams::new(p.into()))
                .unwrap_err()
                .exit_code()
        };
        assert_eq!(err("/missing"), 2);
        let mut t = space_tree();
        t.unreadable.insert("/root".into());
        // An unreadable root yields an empty tree with an error entry, not a failure.
        let v = space_json(&t, &FixedClock(0), &SpaceParams::new("/root".into())).unwrap();
        assert_eq!(v["error_count"], 1);
    }

    #[test]
    fn renderers_produce_text() {
        let (nvme, _) = health_fixture();
        let v = health_json(&nvme, &FixedClock(NOW), None, &HealthParams::default()).unwrap();
        let text = health::render_health(&v);
        assert!(
            text.contains("internal:TEST INTERNAL")
                && text.contains("not readable at SMARTReadData")
        );
        assert!(
            symcockpit_core::storage::speedtest::render_speedtest(&speedtest_value())
                .contains("MiB/s")
        );
        assert!(
            symcockpit_core::storage::space::render_space(&space(&space_tree(), 2, 10))
                .contains("hardlinks counted once")
        );
    }
}
