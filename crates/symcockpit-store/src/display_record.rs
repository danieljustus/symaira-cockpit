//! The record of a display override that outlives the process that made it
//! (Q05). Of everything the display write commands touch, only the backlight
//! brightness survives the process: gamma tables, the dim window and the EDR
//! trigger are dropped by macOS when their owner exits or dies. So the record
//! holds what is needed to put the brightness back after a crash: the
//! original value, the display and the owning process.

use std::io;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use crate::state::write_private_atomic;

pub const FILE_NAME: &str = "display-restore.json";

#[derive(Clone, Debug, PartialEq)]
pub struct DisplayRestoreRecord {
    pub pid: u32,
    pub display_id: u32,
    /// The brightness (0.0–1.0) before the first override.
    pub brightness: f64,
}

fn file(dir: &Path) -> PathBuf {
    dir.join(FILE_NAME)
}

pub fn write_record(dir: &Path, record: &DisplayRestoreRecord, is_root: bool) -> io::Result<()> {
    let value = json!({"pid": record.pid, "display_id": record.display_id, "brightness": record.brightness});
    write_private_atomic(&file(dir), value.to_string().as_bytes(), is_root)
}

/// `Ok(None)` when there is no record; an undecodable one is an error so the
/// caller can discard it.
pub fn read_record(dir: &Path) -> io::Result<Option<DisplayRestoreRecord>> {
    let bytes = match std::fs::read(file(dir)) {
        Ok(b) => b,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e),
    };
    let bad = || {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "undecodable display restore record",
        )
    };
    let value: Value = serde_json::from_slice(&bytes).map_err(|_| bad())?;
    let int = |key: &str| value.get(key)?.as_u64()?.try_into().ok();
    Ok(Some(DisplayRestoreRecord {
        pid: int("pid").ok_or_else(bad)?,
        display_id: int("display_id").ok_or_else(bad)?,
        brightness: value
            .get("brightness")
            .and_then(Value::as_f64)
            .ok_or_else(bad)?,
    }))
}

pub fn clear_record(dir: &Path) {
    let _ = std::fs::remove_file(file(dir));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_and_clears() {
        let tmp = tempfile::tempdir().unwrap();
        assert_eq!(read_record(tmp.path()).unwrap(), None);
        let record = DisplayRestoreRecord {
            pid: 42,
            display_id: 1,
            brightness: 0.5,
        };
        write_record(tmp.path(), &record, false).unwrap();
        assert_eq!(read_record(tmp.path()).unwrap(), Some(record));
        clear_record(tmp.path());
        assert_eq!(read_record(tmp.path()).unwrap(), None);
        clear_record(tmp.path());
    }

    #[test]
    fn an_undecodable_record_is_an_error_not_a_default() {
        let tmp = tempfile::tempdir().unwrap();
        for text in [
            "",
            "{",
            "[]",
            "{\"pid\":1}",
            "{\"pid\":-1,\"display_id\":1,\"brightness\":0.5}",
        ] {
            std::fs::write(tmp.path().join(FILE_NAME), text).unwrap();
            assert!(read_record(tmp.path()).is_err(), "{text:?}");
        }
    }
}
