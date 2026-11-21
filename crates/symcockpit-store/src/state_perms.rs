//! Ownership and modes of state a root process writes into a user's data
//! directory (port of `StateFilePermissions.swift`).
//!
//! The GUI elevates through `osascript`, which sets no `SUDO_*` variables, so
//! ownership is taken from the directory the state lives in (the human
//! already owns it) and only falls back to the sudo environment when every
//! ancestor is root-owned. All platform facts are injected; the std calls
//! used here (`chown`, `set_permissions`) are safe.

use std::fs;
use std::io;
use std::os::unix::fs::{MetadataExt, PermissionsExt, chown};
use std::path::{Component, Path, PathBuf};

pub type Owner = (u32, u32);

/// `SUDO_UID`/`SUDO_GID`, else `SUDO_USER` through `lookup_user`; only while root.
pub fn sudo_owner(
    is_root: bool,
    env: &dyn Fn(&str) -> Option<String>,
    lookup_user: &dyn Fn(&str) -> Option<Owner>,
) -> Option<Owner> {
    if !is_root {
        return None;
    }
    if let (Some(uid), Some(gid)) = (
        env("SUDO_UID").and_then(|v| v.parse().ok()),
        env("SUDO_GID").and_then(|v| v.parse().ok()),
    ) {
        return Some((uid, gid));
    }
    env("SUDO_USER").and_then(|user| lookup_user(&user))
}

/// Ownership to restore for state written under `location`: the nearest
/// existing directory at or above it that is not root-owned names the human
/// whose data this is. Walks the components of the absolute path, which is
/// bounded by construction (a relative path would never reach `/`).
pub fn ownership_to_restore(
    location: &Path,
    is_root: bool,
    owner_of: &dyn Fn(&Path) -> Option<Owner>,
    sudo: Option<Owner>,
) -> Option<Owner> {
    if !is_root {
        return None;
    }
    let absolute = if location.is_absolute() {
        location.to_path_buf()
    } else {
        std::env::current_dir().ok()?.join(location)
    };
    let mut path = PathBuf::new();
    let mut chain = Vec::new();
    for component in absolute.components() {
        match component {
            Component::ParentDir => {
                path.pop();
            }
            Component::CurDir => continue,
            other => path.push(other),
        }
        chain.push(path.clone());
    }
    chain
        .iter()
        .rev()
        .find_map(|candidate| owner_of(candidate).filter(|(uid, _)| *uid != 0))
        .or(sudo)
}

/// `stat` the path: `(uid, gid)` when it exists.
pub fn owner_of_path(path: &Path) -> Option<Owner> {
    fs::metadata(path).ok().map(|m| (m.uid(), m.gid()))
}

/// Create `dir` with mode 0700 (re-assert it when present) and give it to the
/// rightful owner. Ownership is resolved first so a directory created here
/// cannot be mistaken for evidence that root is the rightful owner.
pub fn ensure_directory(dir: &Path, owner: Option<Owner>) -> io::Result<()> {
    if dir.exists() {
        let _ = fs::set_permissions(dir, fs::Permissions::from_mode(0o700));
    } else {
        // `create_dir_all` honours the umask; the mode is fixed up right after.
        fs::create_dir_all(dir)?;
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    }
    if let Some((uid, gid)) = owner {
        chown(dir, Some(uid), Some(gid))?;
    }
    Ok(())
}

/// 0600 and the rightful owner for a file this process wrote.
pub fn apply_file_permissions(file: &Path, owner: Option<Owner>) -> io::Result<()> {
    fs::set_permissions(file, fs::Permissions::from_mode(0o600))?;
    if let Some((uid, gid)) = owner {
        chown(file, Some(uid), Some(gid))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // Vectors: tuning/Tests/SymCockpitCoreTests/ElevatedStateOwnershipTests.swift

    fn owners(table: &[(&str, Owner)]) -> impl Fn(&Path) -> Option<Owner> {
        let table: Vec<(PathBuf, Owner)> =
            table.iter().map(|(p, o)| (PathBuf::from(p), *o)).collect();
        move |path: &Path| table.iter().find(|(p, _)| p == path).map(|(_, o)| *o)
    }

    #[test]
    fn user_owned_ancestor_wins_without_any_sudo_variable() {
        // The GUI's osascript path: no SUDO_*, but the data directory is the user's.
        let owner_of = owners(&[
            ("/", (0, 0)),
            ("/Users", (0, 80)),
            ("/Users/ada", (501, 20)),
            ("/Users/ada/.local/share/symtune", (501, 20)),
        ]);
        let got = ownership_to_restore(
            Path::new("/Users/ada/.local/share/symtune"),
            true,
            &owner_of,
            None,
        );
        assert_eq!(got, Some((501, 20)));
        // A directory that does not exist yet falls through to the nearest existing user-owned one.
        let got = ownership_to_restore(
            Path::new("/Users/ada/.local/share/symtune/new"),
            true,
            &owner_of,
            None,
        );
        assert_eq!(got, Some((501, 20)));
    }

    #[test]
    fn sudo_environment_is_only_the_fallback() {
        let all_root = owners(&[("/", (0, 0)), ("/var", (0, 0))]);
        assert_eq!(
            ownership_to_restore(Path::new("/var/db/x"), true, &all_root, Some((502, 20))),
            Some((502, 20))
        );
        assert_eq!(
            ownership_to_restore(Path::new("/var/db/x"), true, &all_root, None),
            None
        );
        let user = owners(&[("/Users/ada", (501, 20))]);
        assert_eq!(
            ownership_to_restore(Path::new("/Users/ada/x"), true, &user, Some((999, 1))),
            Some((501, 20))
        );
    }

    #[test]
    fn unprivileged_never_chowns_and_a_relative_path_terminates() {
        let user = owners(&[("/Users/ada", (501, 20))]);
        assert_eq!(
            ownership_to_restore(Path::new("/Users/ada/x"), false, &user, Some((1, 1))),
            None
        );
        let nothing = |_: &Path| Some((0u32, 0u32));
        assert_eq!(
            ownership_to_restore(Path::new("relative/dir"), true, &nothing, None),
            None
        );
    }

    #[test]
    fn sudo_owner_reads_ids_then_user() {
        let env = |k: &str| match k {
            "SUDO_UID" => Some("501".to_string()),
            "SUDO_GID" => Some("20".to_string()),
            "SUDO_USER" => Some("ada".to_string()),
            _ => None,
        };
        let lookup = |u: &str| (u == "ada").then_some((777, 7));
        assert_eq!(sudo_owner(true, &env, &lookup), Some((501, 20)));
        let only_user = |k: &str| (k == "SUDO_USER").then(|| "ada".to_string());
        assert_eq!(sudo_owner(true, &only_user, &lookup), Some((777, 7)));
        assert_eq!(sudo_owner(false, &env, &lookup), None);
    }

    #[test]
    fn directory_is_0700_and_file_0600() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("a/b");
        ensure_directory(&dir, None).unwrap();
        assert_eq!(
            fs::metadata(&dir).unwrap().permissions().mode() & 0o777,
            0o700
        );
        let file = dir.join("f");
        fs::write(&file, b"x").unwrap();
        apply_file_permissions(&file, None).unwrap();
        assert_eq!(
            fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}
