//! Space analysis (R33): a sorted size tree of a directory with hardlinks
//! counted once.
//!
//! Own walker instead of a crate: the semantics that matter here (count a
//! file with several links once, by `(device, inode)`; stay on one device;
//! never follow symlinks; report what could not be read) are about 100 lines,
//! and `dua-cli` would bring a terminal UI and a parallel scheduler with it.
//!
//! Sizes are *allocated* bytes (`st_blocks * 512`, what `du` reports) next to
//! *apparent* bytes (`st_size`). APFS clones and compression are not
//! modelled: two clones count as two files unless they are hardlinks.
//! A file with several links is charged to the first directory (in name
//! order) that reaches it.

use std::collections::HashSet;
use std::fmt::Write as _;
use std::io;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use symcockpit_contract::Error;

use super::health::{bounded, number, rfc3339};
use crate::plan::Clock;

pub const DEFAULT_DEPTH: usize = 2;
pub const MAX_DEPTH: usize = 16;
pub const DEFAULT_LIMIT: usize = 10;
pub const MAX_LIMIT: usize = 200;
/// Entries visited before the walk stops and reports `truncated`.
const MAX_ENTRIES: u64 = 10_000_000;
const MAX_ERRORS_LISTED: usize = 20;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Kind {
    File,
    Dir,
    Symlink,
    Other,
}

impl Kind {
    fn as_str(self) -> &'static str {
        match self {
            Kind::File => "file",
            Kind::Dir => "dir",
            Kind::Symlink => "symlink",
            Kind::Other => "other",
        }
    }
}

/// `lstat` of one entry (symlinks are not followed).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FsEntry {
    pub name: String,
    pub kind: Kind,
    pub device: u64,
    pub inode: u64,
    pub links: u64,
    pub allocated: u64,
    pub apparent: u64,
}

pub trait SpaceFs {
    fn canonicalize(&self, path: &Path) -> io::Result<PathBuf>;
    fn stat(&self, path: &Path) -> io::Result<FsEntry>;
    /// Children of a directory; entries that vanished meanwhile are left out.
    fn read_dir(&self, path: &Path) -> io::Result<Vec<FsEntry>>;
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SpaceParams {
    pub path: PathBuf,
    pub depth: usize,
    pub limit: usize,
}

impl SpaceParams {
    pub fn new(path: PathBuf) -> Self {
        SpaceParams {
            path,
            depth: DEFAULT_DEPTH,
            limit: DEFAULT_LIMIT,
        }
    }

    /// Arguments after `storage space`: `<path> [--depth N] [--limit N] [--json]`.
    pub fn parse_cli(args: &[String]) -> Result<Self, Error> {
        let (mut path, mut depth, mut limit) = (None, DEFAULT_DEPTH, DEFAULT_LIMIT);
        let mut it = args.iter();
        while let Some(a) = it.next() {
            let mut value = || {
                it.next()
                    .ok_or_else(|| Error::Usage(format!("{a} needs a value")))
            };
            match a.as_str() {
                "--depth" => {
                    depth = bounded("--depth", number("--depth", value()?)?, 1, MAX_DEPTH as u64)?
                }
                "--limit" => {
                    limit = bounded("--limit", number("--limit", value()?)?, 1, MAX_LIMIT as u64)?
                }
                "--json" => {}
                s if s.starts_with("--") => {
                    return Err(Error::Usage(format!(
                        "storage space: unknown argument '{s}'"
                    )));
                }
                s if path.replace(PathBuf::from(s)).is_some() => {
                    return Err(Error::Usage("storage space takes one path".into()));
                }
                _ => {}
            }
        }
        let path = path.ok_or_else(|| {
            Error::Usage(
                "usage: symcockpit storage space <path> [--depth N] [--limit N] [--json]".into(),
            )
        })?;
        Ok(SpaceParams { path, depth, limit })
    }

    /// MCP arguments of `analyze_space`.
    pub fn from_json(args: &Value) -> Result<Self, Error> {
        let path = args
            .get("path")
            .and_then(Value::as_str)
            .ok_or_else(|| Error::Usage("path is required".into()))?;
        let mut p = SpaceParams::new(PathBuf::from(path));
        let get = |k: &str, min, max| {
            args.get(k)
                .map(|v| {
                    v.as_u64()
                        .ok_or_else(|| Error::Usage(format!("{k} must be a whole number")))
                        .and_then(|n| bounded(k, n, min, max))
                })
                .transpose()
        };
        p.depth = get("depth", 1, MAX_DEPTH as u64)?.unwrap_or(DEFAULT_DEPTH);
        p.limit = get("limit", 1, MAX_LIMIT as u64)?.unwrap_or(DEFAULT_LIMIT);
        Ok(p)
    }
}

struct Node {
    name: String,
    kind: Kind,
    allocated: u64,
    apparent: u64,
    /// Files and symlinks below (not directories), hardlink duplicates excluded.
    files: u64,
    children: Vec<Node>,
    other_count: u64,
    other_allocated: u64,
    other_apparent: u64,
}

struct Walk<'a> {
    fs: &'a dyn SpaceFs,
    device: u64,
    depth: usize,
    limit: usize,
    seen: HashSet<(u64, u64)>,
    visited: u64,
    duplicates: u64,
    duplicate_bytes: u64,
    other_devices: u64,
    errors: Vec<(String, String)>,
    error_count: u64,
    truncated: bool,
}

impl Walk<'_> {
    fn visit(&mut self, path: &Path, e: &FsEntry, level: usize) -> Node {
        self.visited += 1;
        let mut node = Node {
            name: e.name.clone(),
            kind: e.kind,
            allocated: e.allocated,
            apparent: e.apparent,
            files: 0,
            children: vec![],
            other_count: 0,
            other_allocated: 0,
            other_apparent: 0,
        };
        if e.kind != Kind::Dir {
            node.files = 1;
            if e.links > 1 && !self.seen.insert((e.device, e.inode)) {
                self.duplicates += 1;
                self.duplicate_bytes += e.allocated;
                (node.allocated, node.apparent, node.files) = (0, 0, 0);
            }
            return node;
        }
        if self.visited > MAX_ENTRIES {
            self.truncated = true;
            return node;
        }
        let mut entries = match self.fs.read_dir(path) {
            Ok(v) => v,
            Err(err) => {
                self.error_count += 1;
                if self.errors.len() < MAX_ERRORS_LISTED {
                    self.errors
                        .push((path.to_string_lossy().into_owned(), err.to_string()));
                }
                return node;
            }
        };
        entries.sort_by(|a, b| a.name.cmp(&b.name));
        for child in entries {
            if child.kind == Kind::Dir && child.device != self.device {
                self.other_devices += 1;
                continue;
            }
            let c = self.visit(&path.join(&child.name), &child, level + 1);
            node.allocated += c.allocated;
            node.apparent += c.apparent;
            node.files += c.files;
            node.children.push(c);
        }
        if level >= self.depth {
            node.children.clear();
        } else {
            node.children.sort_by(|a, b| {
                b.allocated
                    .cmp(&a.allocated)
                    .then_with(|| a.name.cmp(&b.name))
            });
            for rest in node.children.drain(self.limit.min(node.children.len())..) {
                node.other_count += 1;
                node.other_allocated += rest.allocated;
                node.other_apparent += rest.apparent;
            }
        }
        node
    }
}

fn node_json(n: &Node) -> Value {
    json!({
        "name": n.name,
        "kind": n.kind.as_str(),
        "allocated_bytes": n.allocated,
        "apparent_bytes": n.apparent,
        "files": n.files,
        "children": n.children.iter().map(node_json).collect::<Vec<_>>(),
        "other": {"count": n.other_count, "allocated_bytes": n.other_allocated, "apparent_bytes": n.other_apparent},
    })
}

fn io_err(path: &Path, e: &io::Error) -> Error {
    let what = format!("{}: {e}", path.display());
    match e.kind() {
        io::ErrorKind::PermissionDenied => Error::Permission(what),
        io::ErrorKind::NotFound | io::ErrorKind::NotADirectory => Error::Usage(what),
        _ => Error::Failed(what),
    }
}

/// `storage space`: the size tree of `params.path`, `depth` levels deep with
/// the `limit` largest children per directory; the rest is summed in `other`.
pub fn space_json(
    fs: &dyn SpaceFs,
    clock: &dyn Clock,
    params: &SpaceParams,
) -> Result<Value, Error> {
    let root = fs
        .canonicalize(&params.path)
        .map_err(|e| io_err(&params.path, &e))?;
    let mut entry = fs.stat(&root).map_err(|e| io_err(&root, &e))?;
    entry.name = root.to_string_lossy().into_owned();
    let mut walk = Walk {
        fs,
        device: entry.device,
        depth: params.depth,
        limit: params.limit,
        seen: HashSet::new(),
        visited: 0,
        duplicates: 0,
        duplicate_bytes: 0,
        other_devices: 0,
        errors: vec![],
        error_count: 0,
        truncated: false,
    };
    let tree = walk.visit(&root, &entry, 0);
    Ok(json!({
        "schema": 1,
        "measured_at": rfc3339(clock.now()),
        "path": entry.name,
        "unit": "byte",
        "depth": params.depth,
        "limit": params.limit,
        "tree": node_json(&tree),
        "hardlinks": {"duplicates_skipped": walk.duplicates, "allocated_bytes_not_counted": walk.duplicate_bytes},
        "skipped_other_devices": walk.other_devices,
        "entries_visited": walk.visited,
        "truncated": walk.truncated,
        "error_count": walk.error_count,
        "errors": walk.errors.iter().map(|(p, m)| json!({"path": p, "error": m})).collect::<Vec<_>>(),
    }))
}

/// Human-readable form of [`space_json`]: the tree, sizes in MiB (2^20 bytes).
pub fn render_space(v: &Value) -> String {
    fn rec(n: &Value, indent: usize, out: &mut String) {
        let mib = n["allocated_bytes"].as_u64().unwrap_or(0) as f64 / (1u64 << 20) as f64;
        let _ = writeln!(
            out,
            "{:>12.1} MiB  {}{}{}",
            mib,
            "  ".repeat(indent),
            n["name"].as_str().unwrap_or("?"),
            if n["kind"] == "dir" { "/" } else { "" }
        );
        for c in n["children"].as_array().into_iter().flatten() {
            rec(c, indent + 1, out);
        }
        if n["other"]["count"].as_u64().unwrap_or(0) > 0 {
            let _ = writeln!(
                out,
                "{:>12.1} MiB  {}… {} more",
                n["other"]["allocated_bytes"].as_u64().unwrap_or(0) as f64 / (1u64 << 20) as f64,
                "  ".repeat(indent + 1),
                n["other"]["count"]
            );
        }
    }
    let mut out = String::new();
    rec(&v["tree"], 0, &mut out);
    let _ = writeln!(
        out,
        "hardlinks counted once: {} duplicate links skipped ({} bytes)",
        v["hardlinks"]["duplicates_skipped"], v["hardlinks"]["allocated_bytes_not_counted"]
    );
    if v["error_count"] != 0 {
        let _ = writeln!(out, "{} directories could not be read", v["error_count"]);
    }
    if v["truncated"] == true {
        out.push_str("walk stopped at the entry limit; sizes are partial\n");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_cli_and_json() {
        let a = |v: &[&str]| v.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
        let p =
            SpaceParams::parse_cli(&a(&["/x", "--depth", "3", "--limit", "5", "--json"])).unwrap();
        assert_eq!(
            p,
            SpaceParams {
                path: "/x".into(),
                depth: 3,
                limit: 5
            }
        );
        for bad in [
            &[][..],
            &["/a", "/b"],
            &["/a", "--depth", "0"],
            &["/a", "--depth", "17"],
            &["/a", "--limit"],
            &["/a", "--x"],
        ] {
            assert_eq!(
                SpaceParams::parse_cli(&a(bad)).unwrap_err().exit_code(),
                2,
                "{bad:?}"
            );
        }
        assert_eq!(
            SpaceParams::from_json(&json!({"path": "/x", "limit": 7}))
                .unwrap()
                .limit,
            7
        );
        assert!(SpaceParams::from_json(&json!({})).is_err());
        assert!(SpaceParams::from_json(&json!({"path": "/x", "depth": 99})).is_err());
    }
}
