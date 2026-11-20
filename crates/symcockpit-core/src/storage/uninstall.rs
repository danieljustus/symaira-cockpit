//! App uninstall with an ownership plan (R37).
//!
//! Every file in the plan has a category and the reason it is believed to
//! belong to the app: the exact bundle id in a fixed location, an installer
//! receipt for that bundle id, or the Team ID in the exact name of a group
//! container. A similar name alone never qualifies; such paths, shared
//! containers and documents are listed under `excluded` and are not in the
//! plan. A running app blocks planning and, again, confirmation.

use std::{
    fs, io,
    path::{Path, PathBuf},
};

use serde_json::{Value, json};
use symcockpit_contract::Error;

use crate::plan::{Engine, Running, fs_item, user_uid};

pub struct AppInfo {
    pub path: PathBuf,
    pub bundle_id: String,
    pub name: String,
    pub team_id: Option<String>,
}

/// Files an installer receipt lists for one package id.
pub struct Receipt {
    pub pkg_id: String,
    /// Absolute paths.
    pub files: Vec<PathBuf>,
}

/// Platform facts about apps. Live adapter: `symcockpit-macos`.
pub trait Apps: Running {
    /// `app` is a path to a `.app` bundle or a bundle id.
    fn resolve(&self, app: &str) -> Result<AppInfo, Error>;
    /// The receipt whose package id equals `bundle_id`, if any.
    fn receipt(&self, bundle_id: &str) -> Result<Option<Receipt>, Error>;
}

/// Receipts are capped so a huge installer cannot flood a plan.
const MAX_RECEIPT_FILES: usize = 2000;

/// Directories below the home folder that hold the user's own documents.
const DOCUMENT_ROOTS: &[&str] = &[
    "Documents",
    "Desktop",
    "Downloads",
    "Movies",
    "Music",
    "Pictures",
    "Library/Mobile Documents",
];

struct Candidate {
    path: PathBuf,
    category: &'static str,
    reason: String,
}

fn is_document(home: &Path, path: &Path) -> bool {
    DOCUMENT_ROOTS
        .iter()
        .any(|d| path.starts_with(home.join(d)))
}

fn is_uuid(s: &str) -> bool {
    s.len() == 36
        && s.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}

fn names_in(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir)
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

fn gather(
    apps: &dyn Apps,
    info: &AppInfo,
    home: &Path,
    system: &Path,
) -> Result<(Vec<Candidate>, Vec<Value>), Error> {
    let b = info.bundle_id.as_str();
    let mut inc = vec![Candidate {
        path: info.path.clone(),
        category: "application",
        reason: "the selected app".to_owned(),
    }];
    let mut exc = Vec::new();
    let mut exclude = |path: PathBuf, category: &str, reason: &str| {
        exc.push(json!({"path": path.to_string_lossy(), "category": category, "reason": reason}));
    };

    let lib = home.join("Library");
    let user: [(&str, String, &str); 12] = [
        ("Application Support", b.to_owned(), "app_support"),
        ("Caches", b.to_owned(), "cache"),
        ("Preferences", format!("{b}.plist"), "preferences"),
        (
            "Saved Application State",
            format!("{b}.savedState"),
            "saved_state",
        ),
        ("HTTPStorages", b.to_owned(), "cache"),
        ("HTTPStorages", format!("{b}.binarycookies"), "cache"),
        ("WebKit", b.to_owned(), "cache"),
        ("Cookies", format!("{b}.binarycookies"), "cache"),
        ("Containers", b.to_owned(), "container"),
        ("Application Scripts", b.to_owned(), "container"),
        ("Logs", b.to_owned(), "logs"),
        ("LaunchAgents", format!("{b}.plist"), "launch_agent"),
    ];
    for (dir, name, category) in user {
        inc.push(Candidate {
            path: lib.join(dir).join(name),
            category,
            reason: format!("bundle id {b}"),
        });
    }
    for name in names_in(&lib.join("Preferences/ByHost")) {
        let uuid = name
            .strip_prefix(b)
            .and_then(|r| r.strip_prefix('.'))
            .and_then(|r| r.strip_suffix(".plist"));
        if uuid.is_some_and(is_uuid) {
            inc.push(Candidate {
                path: lib.join("Preferences/ByHost").join(name),
                category: "preferences",
                reason: format!("bundle id {b}"),
            });
        }
    }
    let sys: [(&str, String, &str); 5] = [
        ("Library/Application Support", b.to_owned(), "app_support"),
        ("Library/Preferences", format!("{b}.plist"), "preferences"),
        ("Library/LaunchAgents", format!("{b}.plist"), "launch_agent"),
        (
            "Library/LaunchDaemons",
            format!("{b}.plist"),
            "launch_daemon",
        ),
        ("Library/PrivilegedHelperTools", b.to_owned(), "helper_tool"),
    ];
    for (dir, name, category) in sys {
        inc.push(Candidate {
            path: system.join(dir).join(name),
            category,
            reason: format!("bundle id {b}"),
        });
    }
    // iCloud documents of the app are the user's, never part of an uninstall.
    let icloud = lib
        .join("Mobile Documents")
        .join(format!("iCloud~{}", b.replace('.', "~")));
    if fs::symlink_metadata(&icloud).is_ok() {
        exclude(icloud, "documents", "iCloud documents are never removed");
    }
    if let Some(team) = &info.team_id {
        let groups = lib.join("Group Containers");
        for name in names_in(&groups) {
            let path = groups.join(&name);
            if name == format!("{team}.{b}") {
                inc.push(Candidate {
                    path,
                    category: "group_container",
                    reason: format!("team id {team} and bundle id {b}"),
                });
            } else if name.starts_with(&format!("{team}.")) {
                exclude(
                    path,
                    "group_container",
                    "shared with other apps of the same team",
                );
            }
        }
    }
    // Same name, no proof of ownership: show, never plan.
    for dir in ["Application Support", "Caches", "Logs"] {
        let path = lib.join(dir).join(&info.name);
        if info.name != b && fs::symlink_metadata(&path).is_ok() {
            exclude(path, "name_match", "matches only by name, not by bundle id");
        }
    }
    if let Some(r) = apps.receipt(b)? {
        for f in r.files.into_iter().take(MAX_RECEIPT_FILES) {
            let meta = fs::symlink_metadata(&f);
            if f.starts_with(&info.path) || meta.map(|m| m.is_dir()).unwrap_or(true) {
                continue; // inside the bundle, gone, or a (possibly shared) directory
            }
            inc.push(Candidate {
                path: f,
                category: "installed_file",
                reason: format!("installer receipt {}", r.pkg_id),
            });
        }
    }
    Ok((inc, exc))
}

/// `plan_uninstall_app` / `apps uninstall`: builds the ownership plan.
/// `system` is the file system root (`/`; a temporary tree in tests).
pub fn plan_uninstall_app_json(
    engine: &Engine,
    apps: &dyn Apps,
    home: &Path,
    system: &Path,
    app: &str,
) -> Result<Value, Error> {
    let info = apps.resolve(app)?;
    if info.bundle_id.starts_with("com.apple.") || info.path.starts_with("/System") {
        return Err(Error::Usage(format!("{} is a system app", info.name)));
    }
    if apps.is_running(&info.path) {
        return Err(Error::Failed(format!(
            "{} is running; quit it first",
            info.name
        )));
    }
    let uid = user_uid(home).map_err(|e| Error::Failed(format!("home directory: {e}")))?;
    let (candidates, mut excluded) = gather(apps, &info, home, system)?;
    let mut items: Vec<Value> = Vec::new();
    let mut kept: Vec<PathBuf> = Vec::new();
    for c in candidates {
        match fs::symlink_metadata(&c.path) {
            Ok(_) => {}
            Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
            Err(e) => {
                excluded.push(json!({"path": c.path.to_string_lossy(), "category": c.category, "reason": e.to_string()}));
                continue;
            }
        }
        if is_document(home, &c.path) {
            excluded.push(json!({"path": c.path.to_string_lossy(), "category": c.category, "reason": "documents are never removed"}));
            continue;
        }
        if kept.iter().any(|k| c.path.starts_with(k)) {
            continue; // equal to, or inside, an entry that is already in
        }
        let Some(root) = c.path.parent() else {
            continue;
        };
        match fs_item("trash", &c.path, root, uid, c.category, &c.reason) {
            Ok(mut item) => {
                item["guard_running"] = json!(info.path.to_string_lossy());
                kept.push(c.path);
                items.push(item);
            }
            Err(e) => excluded.push(json!({"path": c.path.to_string_lossy(), "category": c.category, "reason": e.to_string()})),
        }
    }
    let plan = engine.create("uninstall_app", items)?;
    let mut v = engine.plan_json(&plan);
    v["app"] = json!({
        "name": info.name,
        "bundle_id": info.bundle_id,
        "path": info.path.to_string_lossy(),
        "team_id": info.team_id,
    });
    v["excluded"] = Value::Array(excluded);
    Ok(v)
}
