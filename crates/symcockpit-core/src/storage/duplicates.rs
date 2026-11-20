//! Duplicate files (R35): group by size, then by a hash of the first 64 KiB,
//! then by the full hash. Finding is read-only; a plan is made only for files
//! the caller selects explicitly, and never for every copy of a group.

use std::{
    collections::{BTreeMap, HashSet},
    fs::{self, File},
    io::{self, Read},
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
};

use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use symcockpit_contract::Error;

use crate::plan::{Engine, fs_item, hex, identity_of, user_uid};

const PARTIAL_BYTES: u64 = 64 * 1024;

pub struct Group {
    pub size: u64,
    pub hash: String,
    /// Sorted by path.
    pub files: Vec<PathBuf>,
}

pub struct Scan {
    pub groups: Vec<Group>,
    pub files_seen: u64,
    pub hardlinks_skipped: u64,
    pub unreadable: u64,
}

/// Hash of at most `limit` bytes, read from the file that `lstat` described:
/// if the opened file is not the same regular file any more, it is skipped.
fn hash_file(path: &Path, expect: &fs::Metadata, limit: u64) -> io::Result<String> {
    let file = File::open(path)?;
    let now = file.metadata()?;
    if now.dev() != expect.dev() || now.ino() != expect.ino() || now.len() != expect.len() {
        return Err(io::Error::other("file changed while scanning"));
    }
    let mut hasher = Sha256::new();
    let mut reader = file.take(limit);
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = reader.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hex(&hasher.finalize()))
}

/// Walks `root` (symlinks are never followed, other devices are not entered)
/// and returns groups of byte-identical regular files of at least `min_size`.
/// Hard links to one inode count once: removing one frees nothing.
pub fn find_groups(root: &Path, min_size: u64) -> io::Result<Scan> {
    let root_meta = fs::symlink_metadata(root)?;
    if !root_meta.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "not a directory",
        ));
    }
    let mut scan = Scan {
        groups: Vec::new(),
        files_seen: 0,
        hardlinks_skipped: 0,
        unreadable: 0,
    };
    let mut by_size: BTreeMap<u64, Vec<(PathBuf, fs::Metadata)>> = BTreeMap::new();
    let mut inodes = HashSet::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else {
            scan.unreadable += 1;
            continue;
        };
        for e in entries.filter_map(Result::ok) {
            let Ok(m) = fs::symlink_metadata(e.path()) else {
                scan.unreadable += 1;
                continue;
            };
            if m.is_dir() && m.dev() == root_meta.dev() {
                stack.push(e.path());
            } else if m.is_file() && m.len() >= min_size.max(1) {
                scan.files_seen += 1;
                if inodes.insert((m.dev(), m.ino())) {
                    by_size.entry(m.len()).or_default().push((e.path(), m));
                } else {
                    scan.hardlinks_skipped += 1;
                }
            }
        }
    }
    for (size, files) in by_size.into_iter().filter(|(_, f)| f.len() > 1) {
        let mut partial: BTreeMap<String, Vec<(PathBuf, fs::Metadata)>> = BTreeMap::new();
        for (p, m) in files {
            match hash_file(&p, &m, PARTIAL_BYTES) {
                Ok(h) => partial.entry(h).or_default().push((p, m)),
                Err(_) => scan.unreadable += 1,
            }
        }
        for candidates in partial.into_values().filter(|f| f.len() > 1) {
            let mut full: BTreeMap<String, Vec<PathBuf>> = BTreeMap::new();
            for (p, m) in candidates {
                match hash_file(&p, &m, u64::MAX) {
                    Ok(h) => full.entry(h).or_default().push(p),
                    Err(_) => scan.unreadable += 1,
                }
            }
            for (hash, mut files) in full.into_iter().filter(|(_, f)| f.len() > 1) {
                files.sort();
                scan.groups.push(Group { size, hash, files });
            }
        }
    }
    // Most reclaimable first; ties by first path for a stable order.
    scan.groups.sort_by(|a, b| {
        let (ra, rb) = (
            a.size * (a.files.len() as u64 - 1),
            b.size * (b.files.len() as u64 - 1),
        );
        rb.cmp(&ra).then_with(|| a.files[0].cmp(&b.files[0]))
    });
    Ok(scan)
}

fn io_err(e: io::Error) -> Error {
    Error::Failed(e.to_string())
}

/// `find_duplicates` / `storage duplicates`. Read-only.
pub fn find_duplicates_json(root: &Path, min_size: u64) -> Result<Value, Error> {
    let root = fs::canonicalize(root).map_err(io_err)?;
    let scan = find_groups(&root, min_size).map_err(io_err)?;
    let mut reclaimable = 0u64;
    let groups: Vec<Value> = scan
        .groups
        .iter()
        .map(|g| {
            let r = g.size * (g.files.len() as u64 - 1);
            reclaimable += r;
            json!({
                "size": g.size,
                "hash": g.hash,
                "reclaimable_bytes": r,
                "files": g.files.iter().map(|f| f.to_string_lossy()).collect::<Vec<_>>(),
            })
        })
        .collect();
    Ok(json!({
        "root": root.to_string_lossy(),
        "min_size": min_size,
        "files_seen": scan.files_seen,
        "hardlinks_skipped": scan.hardlinks_skipped,
        "unreadable": scan.unreadable,
        "group_count": groups.len(),
        "reclaimable_bytes": reclaimable,
        "groups": groups,
    }))
}

/// `plan_remove_duplicates`: plans moving exactly the `select`ed files to the
/// Trash. Each must be a member of a duplicate group under `root` and every
/// group must keep at least one copy. The kept copy is re-checked at confirm.
pub fn plan_remove_duplicates_json(
    engine: &Engine,
    home: &Path,
    root: &Path,
    select: &[PathBuf],
    min_size: u64,
) -> Result<Value, Error> {
    if select.is_empty() {
        return Err(Error::Usage(
            "nothing selected: name the files to remove".to_owned(),
        ));
    }
    let root = fs::canonicalize(root).map_err(io_err)?;
    let uid = user_uid(home).map_err(io_err)?;
    let scan = find_groups(&root, min_size).map_err(io_err)?;
    // Selected paths are resolved through their parent only: a symlink at the
    // file itself must never be followed.
    let mut chosen = Vec::new();
    for s in select {
        let abs = std::path::absolute(s).map_err(io_err)?;
        let (Some(parent), Some(name)) = (abs.parent(), abs.file_name()) else {
            return Err(Error::Usage(format!("not a file path: {}", s.display())));
        };
        let real = fs::canonicalize(parent).map_err(io_err)?.join(name);
        if !chosen.contains(&real) {
            chosen.push(real);
        }
    }
    let mut items = Vec::new();
    let mut used = HashSet::new();
    for g in &scan.groups {
        let picked: Vec<&PathBuf> = g.files.iter().filter(|f| chosen.contains(f)).collect();
        if picked.is_empty() {
            continue;
        }
        let Some(keeper) = g.files.iter().find(|f| !chosen.contains(f)) else {
            return Err(Error::Usage(format!(
                "every copy of a group is selected (first: {}); keep at least one",
                g.files[0].display()
            )));
        };
        let (keeper_id, _) = identity_of(keeper, uid).map_err(io_err)?;
        for f in picked {
            used.insert(f.clone());
            let reason = format!(
                "identical to {} (sha256 {})",
                keeper.display(),
                &g.hash[..16]
            );
            let mut item = fs_item("trash", f, &root, uid, "duplicate", &reason).map_err(io_err)?;
            item["keep"] = json!([{"path": keeper.to_string_lossy(), "identity": keeper_id}]);
            item["hash"] = json!(g.hash);
            items.push(item);
        }
    }
    if let Some(missing) = chosen.iter().find(|c| !used.contains(*c)) {
        return Err(Error::Usage(format!(
            "not a duplicate under the scanned folder: {}",
            missing.display()
        )));
    }
    let plan = engine.create("remove_duplicates", items)?;
    Ok(engine.plan_json(&plan))
}
