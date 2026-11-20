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
}
