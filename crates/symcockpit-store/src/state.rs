//! Writing the small state files this process owns (`StateFilePermissions`):
//! directories 0700, files 0600, atomic replacement, and — when running as
//! root — ownership handed back to the human whose data directory it is.
//!
//! The owner is the nearest existing ancestor that root does not own. That
//! works for `sudo` and for the GUI's `osascript` elevation alike (which sets
//! no `SUDO_*` variables). shortcut: the `SUDO_UID` fallback for a tree that
//! root owns end to end is not ported; add it if such a data directory exists.

use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt, chown};
use std::path::{Path, PathBuf};

/// `ownershipToRestore`: only meaningful while running as root.
fn owner_to_restore(location: &Path, is_root: bool) -> Option<(u32, u32)> {
    if !is_root {
        return None;
    }
    let absolute = if location.is_absolute() {
        location.to_path_buf()
    } else {
        std::env::current_dir().ok()?.join(location)
    };
    absolute
        .ancestors()
        .filter_map(|a| fs::metadata(a).ok())
        .find(|m| m.uid() != 0)
        .map(|m| (m.uid(), m.gid()))
}

fn hand_back(path: &Path, owner: Option<(u32, u32)>) {
    if let Some((uid, gid)) = owner {
        let _ = chown(path, Some(uid), Some(gid));
    }
}

/// Creates `dir` (and parents) with 0700 owned by the data directory's user.
pub fn ensure_private_dir(dir: &Path, is_root: bool) -> io::Result<()> {
    // Resolved before creating, so a directory this call creates cannot be
    // mistaken for evidence that root is the rightful owner.
    let owner = owner_to_restore(dir, is_root);
    DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    let _ = fs::set_permissions(dir, fs::Permissions::from_mode(0o700));
    hand_back(dir, owner);
    Ok(())
}

/// Applies 0600 and the owner of the surrounding data directory.
pub fn secure_file(file: &Path, is_root: bool) {
    let _ = fs::set_permissions(file, fs::Permissions::from_mode(0o600));
    if let Some(parent) = file.parent() {
        hand_back(file, owner_to_restore(parent, is_root));
    }
}

/// Replaces `file` atomically with `bytes` (0600), creating the directory.
pub fn write_private_atomic(file: &Path, bytes: &[u8], is_root: bool) -> io::Result<()> {
    let dir = file
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    ensure_private_dir(dir, is_root)?;
    let name = file
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let temp: PathBuf = dir.join(format!(".{name}.{}.tmp", std::process::id()));
    let result = (|| {
        let mut out = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temp)?;
        out.write_all(bytes)?;
        out.sync_all()?;
        fs::rename(&temp, file)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    } else {
        secure_file(file, is_root);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_atomically_with_private_modes_and_leaves_no_temp_file() {
        let tmp = tempfile::tempdir().unwrap();
        let file = tmp.path().join("a/b/state.json");
        write_private_atomic(&file, b"one", false).unwrap();
        write_private_atomic(&file, b"two", false).unwrap();
        assert_eq!(fs::read(&file).unwrap(), b"two");
        let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&file), 0o600);
        assert_eq!(mode(file.parent().unwrap()), 0o700);
        let names: Vec<_> = fs::read_dir(file.parent().unwrap())
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(names, ["state.json"]);
    }

    #[test]
    fn ownership_is_only_resolved_for_root() {
        let tmp = tempfile::tempdir().unwrap();
        assert_eq!(owner_to_restore(tmp.path(), false), None);
        // As "root" the nearest non-root-owned ancestor is the (user-owned) temp dir.
        let owner = owner_to_restore(&tmp.path().join("missing/leaf"), true).unwrap();
        let meta = fs::metadata(tmp.path()).unwrap();
        assert_eq!(owner, (meta.uid(), meta.gid()));
    }
}
