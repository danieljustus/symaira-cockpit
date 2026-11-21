//! `smc-restore.json`: the on-disk snapshot of the pre-override SMC state
//! (`SMCRestoreRecord.swift`, written by `SMCRestoreTracker.persistIfNeeded`).
//!
//! It is written the moment the originals are captured, so a process that is
//! killed cannot strand the hardware: the next start consumes it. Format
//! (Swift `JSONEncoder` with `.convertToSnakeCase`): `version`,
//! `architecture`, `charge_key_family` (a payload-less enum encodes as
//! `{"chte":{}}`), `fan_originals` of `{fan_index, mode, target_rpm}`,
//! `fs_bitmask` and `charge_inhibit`; absent optionals are omitted.

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use crate::state_perms::{self, Owner};

pub const FILE_NAME: &str = "smc-restore.json";
/// Format version; bump on incompatible changes.
pub const CURRENT_VERSION: i64 = 1;

pub fn path_in(data_dir: &Path) -> PathBuf {
    data_dir.join(FILE_NAME)
}

/// `ChargeLimitKeyFamily` as Swift names its cases.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum KeyFamily {
    Chte,
    Ch0b,
    Chlc,
}

impl KeyFamily {
    fn case(self) -> &'static str {
        match self {
            Self::Chte => "chte",
            Self::Ch0b => "ch0b",
            Self::Chlc => "chlc",
        }
    }

    fn from_case(name: &str) -> Option<Self> {
        [Self::Chte, Self::Ch0b, Self::Chlc]
            .into_iter()
            .find(|f| f.case() == name)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct FanOriginal {
    pub fan_index: i64,
    pub mode: u8,
    pub target_rpm: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Record {
    pub version: i64,
    pub architecture: String,
    pub charge_key_family: Option<KeyFamily>,
    pub fan_originals: Vec<FanOriginal>,
    pub fs_bitmask: Option<u64>,
    pub charge_inhibit: Option<bool>,
}

impl Record {
    pub fn to_json(&self) -> String {
        let mut o = serde_json::Map::new();
        o.insert("version".into(), json!(self.version));
        o.insert("architecture".into(), json!(self.architecture));
        if let Some(f) = self.charge_key_family {
            o.insert("charge_key_family".into(), json!({ f.case(): {} }));
        }
        let fans: Vec<Value> = self
            .fan_originals
            .iter()
            .map(|f| json!({"fan_index": f.fan_index, "mode": f.mode, "target_rpm": f.target_rpm}))
            .collect();
        o.insert("fan_originals".into(), Value::Array(fans));
        if let Some(v) = self.fs_bitmask {
            o.insert("fs_bitmask".into(), json!(v));
        }
        if let Some(v) = self.charge_inhibit {
            o.insert("charge_inhibit".into(), json!(v));
        }
        Value::Object(o).to_string()
    }

    /// `None` for anything Swift would fail to decode too (corrupt leftovers
    /// must never be applied by accident).
    pub fn from_json(bytes: &[u8]) -> Option<Self> {
        let v: Value = serde_json::from_slice(bytes).ok()?;
        let family = match v.get("charge_key_family") {
            None | Some(Value::Null) => None,
            // `{"chte":{}}` is what Swift writes; a bare string is accepted too.
            Some(Value::Object(m)) if m.len() == 1 => Some(KeyFamily::from_case(m.keys().next()?)?),
            Some(Value::String(s)) => Some(KeyFamily::from_case(s)?),
            Some(_) => return None,
        };
        let optional_u64 = |key: &str| match v.get(key) {
            None | Some(Value::Null) => Some(None),
            Some(n) => n.as_u64().map(Some),
        };
        Some(Self {
            version: v.get("version")?.as_i64()?,
            architecture: v.get("architecture")?.as_str()?.to_owned(),
            charge_key_family: family,
            fan_originals: v
                .get("fan_originals")?
                .as_array()?
                .iter()
                .map(|f| {
                    Some(FanOriginal {
                        fan_index: f.get("fan_index")?.as_i64()?,
                        mode: u8::try_from(f.get("mode")?.as_u64()?).ok()?,
                        target_rpm: f.get("target_rpm")?.as_f64()?,
                    })
                })
                .collect::<Option<_>>()?,
            fs_bitmask: optional_u64("fs_bitmask")?,
            charge_inhibit: match v.get("charge_inhibit") {
                None | Some(Value::Null) => None,
                Some(b) => Some(b.as_bool()?),
            },
        })
    }
}

/// Atomic write (temp file + rename), 0600, owned by `owner`; the directory is
/// created 0700 first.
pub fn write(data_dir: &Path, record: &Record, owner: Option<Owner>) -> io::Result<()> {
    state_perms::ensure_directory(data_dir, owner)?;
    let target = path_in(data_dir);
    let tmp = data_dir.join(format!(".{FILE_NAME}.{}.tmp", std::process::id()));
    let result = (|| {
        let mut file = fs::File::create(&tmp)?;
        file.write_all(record.to_json().as_bytes())?;
        file.sync_all()?;
        state_perms::apply_file_permissions(&tmp, owner)?;
        fs::rename(&tmp, &target)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

pub fn read(data_dir: &Path) -> Option<Result<Record, ()>> {
    let bytes = fs::read(path_in(data_dir)).ok()?;
    Some(Record::from_json(&bytes).ok_or(()))
}

pub fn remove(data_dir: &Path) {
    let _ = fs::remove_file(path_in(data_dir));
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn sample() -> Record {
        Record {
            version: CURRENT_VERSION,
            architecture: "arm64".into(),
            charge_key_family: Some(KeyFamily::Chte),
            fan_originals: vec![FanOriginal {
                fan_index: 0,
                mode: 1,
                target_rpm: 2500.0,
            }],
            fs_bitmask: None,
            charge_inhibit: Some(false),
        }
    }

    #[test]
    fn wire_form_is_the_swift_encoding() {
        // `JSONEncoder` + `.convertToSnakeCase`: nil optionals omitted, the
        // payload-less enum as `{"chte":{}}`.
        let v: Value = serde_json::from_str(&sample().to_json()).unwrap();
        assert_eq!(
            v,
            json!({
                "version": 1,
                "architecture": "arm64",
                "charge_key_family": {"chte": {}},
                "fan_originals": [{"fan_index": 0, "mode": 1, "target_rpm": 2500.0}],
                "charge_inhibit": false,
            })
        );
        assert!(v.get("fs_bitmask").is_none());
    }

    #[test]
    fn decodes_the_output_of_a_real_swift_encoder() {
        // Produced by swiftc (Xcode toolchain) running `JSONEncoder` with
        // `.convertToSnakeCase` over a replica of `SMCRestoreRecord` (same
        // members, same Codable synthesis), not by the shipped module.
        let swift = br#"{"architecture":"arm64","version":1,"charge_inhibit":false,"charge_key_family":{"chte":{}},"fan_originals":[{"mode":1,"fan_index":0,"target_rpm":2500}]}"#;
        assert_eq!(Record::from_json(swift), Some(sample()));
    }

    #[test]
    fn decodes_what_swift_writes_and_round_trips() {
        let swift = br#"{"architecture":"arm64","version":1,"fan_originals":[],"charge_inhibit":false,"charge_key_family":{"ch0b":{}}}"#;
        let r = Record::from_json(swift).unwrap();
        assert_eq!(r.charge_key_family, Some(KeyFamily::Ch0b));
        assert_eq!(
            Record::from_json(sample().to_json().as_bytes()),
            Some(sample())
        );
    }

    #[test]
    fn corrupt_content_is_refused() {
        for bad in [
            &b"not json"[..],
            br#"{"version":1}"#,
            br#"{"version":1,"architecture":"arm64","fan_originals":[{"fan_index":0}]}"#,
            br#"{"version":1,"architecture":"arm64","fan_originals":[],"charge_key_family":{"zzz":{}}}"#,
        ] {
            assert_eq!(Record::from_json(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn write_is_atomic_0600_and_removable() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("data");
        write(&dir, &sample(), None).unwrap();
        let mode = fs::metadata(path_in(&dir)).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        assert_eq!(read(&dir), Some(Ok(sample())));
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 1, "no temp file left");
        remove(&dir);
        assert_eq!(read(&dir), None);
    }
}
