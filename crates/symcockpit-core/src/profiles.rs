//! `profile list` / MCP `list_profiles` (`ProfileList` of v0.12). Saving,
//! loading and deleting profiles are writes and stay with the Swift core.

use std::path::Path;

use serde_json::{Map, Value, json};
use symcockpit_store::{Profile, read_profiles};

pub const HELP: &str = "Usage: symcockpit profile save <name>   Save current settings\n       symcockpit profile load <name>   Apply saved settings\n       symcockpit profile list          List saved profiles\n       symcockpit profile delete <name> Delete a saved profile\n";

fn profile_json(p: &Profile) -> Value {
    let mut o = Map::new();
    o.insert("name".into(), json!(p.name));
    o.insert("created_at".into(), json!(p.created_at));
    o.insert("updated_at".into(), json!(p.updated_at));
    for (key, value) in [
        ("brightness", p.brightness),
        ("dim", p.dim),
        ("warmth", p.warmth),
    ] {
        if let Some(v) = value {
            o.insert(key.into(), json!(v));
        }
    }
    if let Some(v) = &p.version {
        o.insert("version".into(), json!(v));
    }
    Value::Object(o)
}

pub fn list_json(data_dir: &Path) -> Value {
    json!({"profiles": read_profiles(data_dir).iter().map(profile_json).collect::<Vec<_>>()})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn help_matches_the_oracle_fixture() {
        assert_eq!(
            HELP,
            include_str!("../../../oracle/v0.12/cases/profile-help.stdout")
        );
    }

    #[test]
    fn list_matches_the_swift_output_for_recorded_files() {
        let tmp = tempfile::tempdir().unwrap();
        let put = |n: &str, t: &str| std::fs::write(tmp.path().join(n), t).unwrap();
        put(
            "profile-work.json",
            "{\"brightness\":0.7,\"createdAt\":785000000.5,\"dim\":1,\"name\":\"work\",\"updatedAt\":785000100,\"version\":\"0.12.2\"}",
        );
        put(
            "profile-a.json",
            "{\"name\":\"a\",\"createdAt\":1,\"updatedAt\":2,\"warmth\":0.3}",
        );
        put("profile-bad.json", "{\"name\":\"bad\"}");
        assert_eq!(
            list_json(tmp.path()),
            json!({"profiles": [
                {"created_at": 1.0, "name": "a", "updated_at": 2.0, "warmth": 0.3},
                {"brightness": 0.7, "created_at": 785_000_000.5, "dim": 1.0, "name": "work", "updated_at": 785_000_100.0, "version": "0.12.2"}
            ]})
        );
        assert_eq!(
            list_json(&tmp.path().join("missing")),
            json!({"profiles": []})
        );
    }
}
