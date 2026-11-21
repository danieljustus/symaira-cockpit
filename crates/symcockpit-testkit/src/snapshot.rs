//! Shape snapshots: the keys and types of a command's JSON output, kept in
//! `snapshots/<area>/<id>.shape.json`. One helper for every area, so a
//! changed wire shape fails the same way everywhere and is updated the same
//! way: `SYMCOCKPIT_UPDATE_SNAPSHOTS=1 cargo test`, then review the diff.

use std::path::{Path, PathBuf};

use serde_json::Value;
use symcockpit_oracle::shape;

pub fn dir(area: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../snapshots")
        .join(area)
}

/// Compares the shape of `value` with the snapshot `id` of `area` (rewrites it
/// when the update variable is set). Missing keys, type changes and keys that
/// appeared all fail: a snapshot is the contract of the wire format.
pub fn check(area: &str, id: &str, value: &Value) {
    let path = dir(area).join(format!("{id}.shape.json"));
    let actual = shape::derive(value).unwrap_or_else(|e| panic!("{area}/{id}: {e}"));
    if std::env::var_os("SYMCOCKPIT_UPDATE_SNAPSHOTS").is_some() {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, serde_json::to_string_pretty(&actual).unwrap() + "\n").unwrap();
    }
    let expected: Value = serde_json::from_slice(
        &std::fs::read(&path)
            .unwrap_or_else(|e| panic!("missing snapshot {}: {e}", path.display())),
    )
    .unwrap();
    let diff = shape::compare(&expected, &actual);
    assert!(
        diff.errors.is_empty() && diff.hints.is_empty(),
        "{area}/{id}: {:?} {:?}",
        diff.errors,
        diff.hints
    );
}

#[cfg(test)]
mod tests {
    use symcockpit_contract::area_commands;

    use super::*;

    /// Every CLI command of an area has a shape snapshot for its output, and no
    /// snapshot belongs to nothing. File stems are the command name (`audio.devices`),
    /// or with underscores (`storage_health`), as the area tests wrote them; a
    /// few commands print more than one shape (`ble.read.services`, `ble.write.plan`, ...).
    #[test]
    fn every_area_command_has_a_snapshot_and_no_snapshot_is_orphaned() {
        let mut stems = Vec::new();
        for area in std::fs::read_dir(dir("")).unwrap().flatten() {
            if !area.path().is_dir() || area.file_name() == "mcp" {
                continue;
            }
            for file in std::fs::read_dir(area.path()).unwrap().flatten() {
                let name = file.file_name().to_string_lossy().into_owned();
                let stem = name
                    .strip_suffix(".shape.json")
                    .unwrap_or_else(|| panic!("{}: not a shape snapshot", file.path().display()));
                stems.push(stem.to_owned());
            }
        }
        let owner = |stem: &str| {
            area_commands().iter().find(|c| {
                [c.name.to_owned(), c.name.replace('.', "_")]
                    .iter()
                    .any(|n| stem == n || stem.starts_with(&format!("{n}.")))
            })
        };
        for spec in area_commands() {
            let wanted = [spec.name.to_owned(), spec.name.replace('.', "_")];
            assert!(
                stems.iter().any(|s| wanted.contains(s)),
                "{} has no output snapshot",
                spec.name
            );
        }
        for stem in &stems {
            assert!(owner(stem).is_some(), "orphaned snapshot {stem}");
        }
    }
}
