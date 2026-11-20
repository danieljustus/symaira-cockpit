//! Cleanup by catalog (R34): a versioned list of harmless categories, each
//! with the reason it is safe. Scan, then plan, then confirm; the Trash is
//! the default and permanent removal exists only for the category that says so.

use std::{fs, io, path::Path};

use serde_json::{Value, json};
use symcockpit_contract::Error;

use crate::plan::{Engine, fs_item, user_uid};

/// Bump when a category is added, removed or its scope changes.
pub const CATALOG_VERSION: u32 = 1;

/// One cleanable location. Every entry directly below `root` is one plan
/// item, so the user can see (and the identity check can guard) each of them.
pub struct Category {
    pub id: &'static str,
    pub title: &'static str,
    /// Why removing this is harmless; shown with the plan.
    pub reason: &'static str,
    /// Relative to the home directory.
    pub root: &'static str,
    /// Included when no category is named.
    pub default: bool,
    /// Removed for good instead of moved to the Trash.
    pub permanent: bool,
    /// Entries whose name starts with one of these are left alone.
    pub skip_prefixes: &'static [&'static str],
}

pub const CATALOG: &[Category] = &[
    Category {
        id: "user_caches",
        title: "User caches",
        reason: "Apps rebuild their caches on demand. Apple's own caches (com.apple.*) are left alone.",
        root: "Library/Caches",
        default: true,
        permanent: false,
        skip_prefixes: &["com.apple."],
    },
    Category {
        id: "user_logs",
        title: "User logs",
        reason: "Log and crash report files; nothing reads them back.",
        root: "Library/Logs",
        default: true,
        permanent: false,
        skip_prefixes: &[],
    },
    Category {
        id: "xcode_derived_data",
        title: "Xcode DerivedData",
        reason: "Build products and indexes that Xcode regenerates on the next build.",
        root: "Library/Developer/Xcode/DerivedData",
        default: true,
        permanent: false,
        skip_prefixes: &[],
    },
    Category {
        id: "empty_trash",
        title: "Empty the Trash",
        reason: "Removes what is already in the Trash for good. Never part of the default selection.",
        root: ".Trash",
        default: false,
        permanent: true,
        skip_prefixes: &[],
    },
];

fn note(category: &str, target: Option<&Path>, reason: impl ToString) -> Value {
    json!({
        "category": category,
        "target": target.map(|t| t.to_string_lossy().into_owned()),
        "reason": reason.to_string(),
    })
}

/// `plan_clean` / `storage clean`: scans the chosen categories (all default
/// ones when `categories` is empty) under `home` and records a plan.
pub fn plan_clean_json(
    engine: &Engine,
    home: &Path,
    categories: &[String],
) -> Result<Value, Error> {
    let chosen: Vec<&Category> = if categories.is_empty() {
        CATALOG.iter().filter(|c| c.default).collect()
    } else {
        let mut out: Vec<&Category> = Vec::new();
        for id in categories {
            let c = CATALOG.iter().find(|c| c.id == id).ok_or_else(|| {
                let known: Vec<_> = CATALOG.iter().map(|c| c.id).collect();
                Error::Usage(format!(
                    "unknown category {id}; known: {}",
                    known.join(", ")
                ))
            })?;
            if !out.iter().any(|o| o.id == c.id) {
                out.push(c);
            }
        }
        out
    };
    let uid = user_uid(home).map_err(|e| Error::Failed(format!("home directory: {e}")))?;
    let (mut items, mut skipped, mut summary) = (Vec::new(), Vec::new(), Vec::new());
    for c in chosen {
        let before = items.len();
        scan(c, home, uid, &mut items, &mut skipped);
        let bytes: u64 = items[before..]
            .iter()
            .filter_map(|i| i["bytes"].as_u64())
            .sum();
        summary.push(json!({
            "id": c.id,
            "title": c.title,
            "reason": c.reason,
            "permanent": c.permanent,
            "items": items.len() - before,
            "bytes": bytes,
        }));
    }
    let plan = engine.create("clean", items)?;
    let mut v = engine.plan_json(&plan);
    v["catalog_version"] = json!(CATALOG_VERSION);
    v["categories"] = Value::Array(summary);
    v["skipped"] = Value::Array(skipped);
    Ok(v)
}

fn scan(c: &Category, home: &Path, uid: u32, items: &mut Vec<Value>, skipped: &mut Vec<Value>) {
    let root = home.join(c.root);
    match fs::symlink_metadata(&root) {
        Ok(m) if m.is_dir() => {}
        Ok(m) if m.file_type().is_symlink() => {
            return skipped.push(note(c.id, None, "root is a symlink; not followed"));
        }
        Ok(_) => return skipped.push(note(c.id, None, "root is not a directory")),
        Err(e) if e.kind() == io::ErrorKind::NotFound => return,
        Err(e) => return skipped.push(note(c.id, None, e)),
    }
    let entries = match fs::read_dir(&root) {
        Ok(rd) => rd,
        Err(e) => return skipped.push(note(c.id, None, e)),
    };
    let mut paths: Vec<_> = entries.filter_map(Result::ok).map(|e| e.path()).collect();
    paths.sort();
    for path in paths {
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned());
        if name
            .as_deref()
            .is_some_and(|n| c.skip_prefixes.iter().any(|p| n.starts_with(p)))
        {
            continue;
        }
        let action = if c.permanent { "delete" } else { "trash" };
        match fs_item(action, &path, &root, uid, c.id, c.reason) {
            Ok(item) => items.push(item),
            Err(e) => skipped.push(note(c.id, Some(&path), e)),
        }
    }
}
