//! Folder listing, level by level (R70). Symlinks are reported, never followed.

use std::{
    collections::VecDeque,
    fs,
    path::{Path, PathBuf},
};

use serde_json::{Value, json};

use crate::limits::{Deadline, Limits, Notices, clean_name};

struct Item {
    name: String,
    path: String,
    kind: &'static str,
    size: u64,
    depth: usize,
}

pub fn list(root: &Path, limits: Limits) -> Result<Value, String> {
    let deadline = Deadline::start(&limits);
    let mut notices = Notices::default();
    let mut items: Vec<Item> = Vec::new();
    let mut queue: VecDeque<(PathBuf, String, usize)> = VecDeque::new();
    queue.push_back((root.to_path_buf(), String::new(), 1));
    let mut first = true;

    'levels: while let Some((dir, rel, depth)) = queue.pop_front() {
        let reader = match fs::read_dir(&dir) {
            Ok(r) => r,
            Err(e) if first => return Err(e.to_string()),
            Err(_) => {
                notices.add("a subfolder could not be read");
                continue;
            }
        };
        first = false;
        let mut level: Vec<Item> = Vec::new();
        for entry in reader {
            if deadline.passed() {
                notices.add("time limit reached");
                break 'levels;
            }
            if items.len() + level.len() >= limits.max_entries {
                notices.add(format!("entry limit {} reached", limits.max_entries));
                break;
            }
            let Ok(entry) = entry else { continue };
            let name = clean_name(&entry.file_name().to_string_lossy());
            let (kind, size) = match entry.path().symlink_metadata() {
                Ok(m) if m.is_dir() => ("dir", 0),
                Ok(m) if m.is_symlink() => ("symlink", 0),
                Ok(m) if m.is_file() => ("file", m.len()),
                _ => ("other", 0),
            };
            let path = if rel.is_empty() {
                name.clone()
            } else {
                format!("{rel}/{name}")
            };
            level.push(Item {
                name,
                path,
                kind,
                size,
                depth,
            });
        }
        // Folders first, then by lowercase name; stable across calls.
        level.sort_by_cached_key(|i| (i.kind != "dir", i.name.to_lowercase()));
        for item in &level {
            if item.kind == "dir" && depth < limits.max_depth {
                queue.push_back((dir.join(&item.name), item.path.clone(), depth + 1));
            } else if item.kind == "dir" {
                notices.add(format!("not descended below depth {}", limits.max_depth));
            }
        }
        items.extend(level);
        if items.len() >= limits.max_entries {
            break;
        }
    }

    let truncated = !notices.is_empty();
    Ok(json!({
        "ok": true,
        "format": "dir",
        "entries": items.iter().map(|i| json!({
            "name": i.name, "path": i.path, "kind": i.kind, "size": i.size, "depth": i.depth,
        })).collect::<Vec<_>>(),
        "truncated": truncated,
        "notices": notices.into_json(),
    }))
}
