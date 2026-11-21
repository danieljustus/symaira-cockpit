//! Reading `profile-<name>.json` (`ProfileService.listProfiles`). The files
//! are written by Swift's default `JSONEncoder`: camelCase keys, dates as
//! seconds since 2001-01-01.

use std::path::Path;

use serde_json::Value;

#[derive(Clone, Debug, PartialEq)]
pub struct Profile {
    pub name: String,
    pub brightness: Option<f64>,
    pub dim: Option<f64>,
    pub warmth: Option<f64>,
    pub version: Option<String>,
    /// Seconds since 2001-01-01 (Foundation reference date).
    pub created_at: f64,
    pub updated_at: f64,
}

/// `Some(None)` is absent/null, `None` is a value of the wrong type.
fn optional<T>(
    object: &serde_json::Map<String, Value>,
    key: &str,
    get: impl Fn(&Value) -> Option<T>,
) -> Option<Option<T>> {
    match object.get(key) {
        None | Some(Value::Null) => Some(None),
        Some(v) => get(v).map(Some),
    }
}

fn decode(bytes: &[u8]) -> Option<Profile> {
    let value: Value = serde_json::from_slice(bytes).ok()?;
    let o = value.as_object()?;
    Some(Profile {
        name: o.get("name")?.as_str()?.to_owned(),
        brightness: optional(o, "brightness", Value::as_f64)?,
        dim: optional(o, "dim", Value::as_f64)?,
        warmth: optional(o, "warmth", Value::as_f64)?,
        version: optional(o, "version", |v| v.as_str().map(str::to_owned))?,
        created_at: o.get("createdAt")?.as_f64()?,
        updated_at: o.get("updatedAt")?.as_f64()?,
    })
}

/// `TuneProfile.isValidProfileName`: letters, digits, `-` and `_` only.
pub fn is_valid_profile_name(name: &str) -> bool {
    !name.is_empty()
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn profile_file(dir: &Path, name: &str) -> std::path::PathBuf {
    dir.join(format!("profile-{name}.json"))
}

/// The file `ProfileService.saveProfile` writes: sorted keys, camelCase,
/// dates as seconds since 2001-01-01, absent optionals omitted.
pub fn write_profile(dir: &Path, profile: &Profile, is_root: bool) -> std::io::Result<()> {
    let mut o = serde_json::Map::new();
    o.insert("name".into(), profile.name.clone().into());
    o.insert("createdAt".into(), profile.created_at.into());
    o.insert("updatedAt".into(), profile.updated_at.into());
    for (key, value) in [
        ("brightness", profile.brightness),
        ("dim", profile.dim),
        ("warmth", profile.warmth),
    ] {
        if let Some(v) = value {
            o.insert(key.into(), v.into());
        }
    }
    if let Some(v) = &profile.version {
        o.insert("version".into(), v.clone().into());
    }
    let text = serde_json::to_string_pretty(&Value::Object(o)).map_err(std::io::Error::other)?;
    crate::state::write_private_atomic(&profile_file(dir, &profile.name), text.as_bytes(), is_root)
}

/// One profile by name. `NotFound` for a missing file, `InvalidData` for one
/// that does not decode. The name must already be valid.
pub fn read_profile(dir: &Path, name: &str) -> std::io::Result<Profile> {
    let bytes = std::fs::read(profile_file(dir, name))?;
    decode(&bytes)
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidData, "undecodable profile"))
}

/// Deletes a profile; a missing one is fine (`fileExists` guard in Swift).
pub fn delete_profile(dir: &Path, name: &str) -> std::io::Result<()> {
    match std::fs::remove_file(profile_file(dir, name)) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        other => other,
    }
}

/// Valid profiles sorted by name. Unreadable or undecodable files are
/// skipped; a missing directory is an empty list.
pub fn read_profiles(dir: &Path) -> Vec<Profile> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut profiles: Vec<Profile> = entries
        .filter_map(Result::ok)
        .filter(|e| {
            let name = e.file_name();
            let name = name.to_string_lossy();
            name.starts_with("profile-") && name.ends_with(".json")
        })
        .filter_map(|e| std::fs::read(e.path()).ok())
        .filter_map(|bytes| decode(&bytes))
        .collect();
    profiles.sort_by(|a, b| a.name.cmp(&b.name));
    profiles
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lists_valid_profiles_sorted_and_skips_the_rest() {
        let tmp = tempfile::tempdir().unwrap();
        let put = |name: &str, text: &str| std::fs::write(tmp.path().join(name), text).unwrap();
        put(
            "profile-work.json",
            "{\"brightness\":0.7,\"createdAt\":785000000.5,\"dim\":1,\"name\":\"work\",\"updatedAt\":785000100,\"version\":\"0.12.2\"}",
        );
        put(
            "profile-a.json",
            "{\"name\":\"a\",\"createdAt\":1,\"updatedAt\":2,\"warmth\":0.3,\"dim\":null}",
        );
        put("profile-bad.json", "{\"name\":\"bad\"}");
        put(
            "profile-typed.json",
            "{\"name\":\"t\",\"createdAt\":1,\"updatedAt\":2,\"brightness\":\"x\"}",
        );
        put("rules.json", "[]");
        put(
            "profile-x.txt",
            "{\"name\":\"x\",\"createdAt\":1,\"updatedAt\":2}",
        );
        std::fs::create_dir(tmp.path().join("profile-dir.json")).unwrap();
        let profiles = read_profiles(tmp.path());
        assert_eq!(profiles.len(), 2);
        assert_eq!(profiles[0].name, "a");
        assert_eq!(
            (profiles[0].warmth, profiles[0].dim, profiles[0].brightness),
            (Some(0.3), None, None)
        );
        assert_eq!(profiles[1].name, "work");
        assert_eq!(profiles[1].version.as_deref(), Some("0.12.2"));
        assert_eq!(
            (profiles[1].created_at, profiles[1].updated_at),
            (785_000_000.5, 785_000_100.0)
        );
    }

    #[test]
    fn missing_directory_is_an_empty_list() {
        assert!(read_profiles(Path::new("/nonexistent-dir-for-test")).is_empty());
    }

    #[test]
    fn names_follow_the_swift_rule() {
        for ok in ["work", "a-b_C9", "0"] {
            assert!(is_valid_profile_name(ok), "{ok}");
        }
        for bad in ["", "a/b", "..", "a..b", "a b", "a\0b", "ä", "a.json"] {
            assert!(!is_valid_profile_name(bad), "{bad:?}");
        }
    }

    #[test]
    fn written_profiles_read_back_and_delete_is_idempotent() {
        let tmp = tempfile::tempdir().unwrap();
        let profile = Profile {
            name: "work".into(),
            brightness: Some(0.7),
            dim: Some(1.0),
            warmth: None,
            version: Some("0.12.2".into()),
            created_at: 785_000_000.5,
            updated_at: 785_000_000.5,
        };
        write_profile(tmp.path(), &profile, false).unwrap();
        assert_eq!(read_profile(tmp.path(), "work").unwrap(), profile);
        assert_eq!(read_profiles(tmp.path()), std::slice::from_ref(&profile));
        let text = std::fs::read_to_string(tmp.path().join("profile-work.json")).unwrap();
        assert!(
            text.contains("\"createdAt\"") && !text.contains("warmth"),
            "{text}"
        );
        assert_eq!(
            read_profile(tmp.path(), "nope").unwrap_err().kind(),
            std::io::ErrorKind::NotFound
        );
        std::fs::write(tmp.path().join("profile-bad.json"), "{}").unwrap();
        assert_eq!(
            read_profile(tmp.path(), "bad").unwrap_err().kind(),
            std::io::ErrorKind::InvalidData
        );
        delete_profile(tmp.path(), "work").unwrap();
        delete_profile(tmp.path(), "work").unwrap();
        assert!(read_profiles(tmp.path()).is_empty());
    }
}
