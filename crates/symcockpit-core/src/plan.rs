//! Two-step plan engine for risky actions (D10, architecture §6.1).
//!
//! 1. [`Engine::create`] records a plan: items with the identity of every
//!    object they touch, a digest over the items and an expiry of
//!    [`PLAN_TTL_SECS`]. Nothing is changed.
//! 2. [`Engine::confirm`] loads the plan, rejects it when it is unknown,
//!    expired, already confirmed or tampered with, claims it exactly once,
//!    re-checks every item and only then acts. Each item ends in one
//!    [`Outcome`]; the whole plan reports the worst of them.
//!
//! The engine is generic: an item is a JSON object with an `"action"` kind and
//! a `"target"` label, and an [`Action`] registered for that kind checks and
//! runs it. [`FsAction`] (move to the Trash / delete) is the first one; process
//! kill, fan and BLE writes register their own. Plans live in a [`PlanStore`]
//! (SQLite in `symcockpit-store`, memory in the testkit).
//!
//! Files are never followed through symlinks: identities come from `lstat`,
//! directory trees are fingerprinted without descending into links.

use std::{
    collections::{BTreeMap, HashSet},
    fs, io,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use symcockpit_contract::{Error, Outcome, Plan, PlanId};

/// How long a plan can be confirmed after it was created.
pub const PLAN_TTL_SECS: i64 = 300;

/// Unix seconds; a port so tests control expiry.
pub trait Clock {
    fn now(&self) -> i64;
}

pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs() as i64)
    }
}

/// A plan as persisted. Timestamps are Unix seconds; [`StoredPlan::to_plan`]
/// renders the contract type with RFC 3339 strings.
#[derive(Clone, Debug, PartialEq)]
pub struct StoredPlan {
    pub id: String,
    pub kind: String,
    pub created_at: i64,
    pub expires_at: i64,
    pub digest: String,
    pub items: Vec<Value>,
    pub confirmed_at: Option<i64>,
    pub results: Option<Value>,
}

impl StoredPlan {
    pub fn to_plan(&self) -> Plan {
        Plan {
            id: PlanId(self.id.clone()),
            created_at: rfc3339(self.created_at),
            expires_at: rfc3339(self.expires_at),
            items: self.items.clone(),
            digest: self.digest.clone(),
        }
    }

    pub fn state(&self, now: i64) -> &'static str {
        if self.confirmed_at.is_some() {
            "confirmed"
        } else if now >= self.expires_at {
            "expired"
        } else {
            "pending"
        }
    }
}

/// Persistence of plans. `claim` must be atomic: of two concurrent callers
/// exactly one gets `true`.
pub trait PlanStore {
    fn insert(&self, plan: &StoredPlan) -> Result<(), Error>;
    fn load(&self, id: &str) -> Result<Option<StoredPlan>, Error>;
    /// Marks the plan confirmed at `at`; `false` if it already was.
    fn claim(&self, id: &str, at: i64) -> Result<bool, Error>;
    fn finish(&self, id: &str, results: &Value) -> Result<(), Error>;
}

/// What an [`Action`] reports for one item.
#[derive(Clone, Debug, PartialEq)]
pub struct ItemResult {
    pub outcome: Outcome,
    pub detail: Option<String>,
}

impl ItemResult {
    pub fn new(outcome: Outcome, detail: impl Into<Option<String>>) -> Self {
        Self {
            outcome,
            detail: detail.into(),
        }
    }
}

/// Executes one kind of plan item.
pub trait Action {
    /// The `"action"` value of the items this handles.
    fn kind(&self) -> &'static str;
    /// Re-checks the item against the current state; `Err(reason)` means it
    /// changed since planning and must be skipped.
    fn still_valid(&self, item: &Value) -> Result<(), String>;
    /// Acts and checks the post-condition (Q01).
    fn execute(&self, item: &Value) -> ItemResult;
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct ItemReport {
    pub index: usize,
    pub action: String,
    pub target: String,
    pub outcome: Outcome,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Report {
    pub plan_id: String,
    pub status: Outcome,
    pub results: Vec<ItemReport>,
}

impl Report {
    pub fn to_json(&self) -> Value {
        let mut counts = BTreeMap::<String, usize>::new();
        for r in &self.results {
            *counts.entry(outcome_name(r.outcome)).or_default() += 1;
        }
        json!({
            "plan_id": self.plan_id,
            "status": self.status,
            "counts": counts,
            "results": self.results,
        })
    }
}

fn outcome_name(o: Outcome) -> String {
    serde_json::to_value(o)
        .ok()
        .and_then(|v| v.as_str().map(str::to_owned))
        .unwrap_or_default()
}

/// The worst outcome wins: failed, unconfirmed, skipped_changed, unsupported.
/// An empty plan is confirmed.
pub fn overall(outcomes: &[Outcome]) -> Outcome {
    for worst in [
        Outcome::Failed,
        Outcome::Unconfirmed,
        Outcome::SkippedChanged,
        Outcome::Unsupported,
    ] {
        if outcomes.contains(&worst) {
            return worst;
        }
    }
    Outcome::Confirmed
}

/// Process exit code for a confirmed plan (AGENTS.md: 0 ok, 1 error,
/// 4 unsupported).
pub fn outcome_exit_code(o: Outcome) -> u8 {
    match o {
        Outcome::Confirmed => symcockpit_contract::exit::OK,
        Outcome::Unsupported => symcockpit_contract::exit::UNSUPPORTED,
        _ => symcockpit_contract::exit::ERROR,
    }
}

pub struct Engine<'a> {
    store: &'a dyn PlanStore,
    clock: &'a dyn Clock,
    actions: Vec<&'a dyn Action>,
}

impl<'a> Engine<'a> {
    pub fn new(store: &'a dyn PlanStore, clock: &'a dyn Clock) -> Self {
        Self {
            store,
            clock,
            actions: Vec::new(),
        }
    }

    pub fn register(mut self, action: &'a dyn Action) -> Self {
        self.actions.push(action);
        self
    }

    /// Records a plan. Every item needs string fields `action` and `target`.
    pub fn create(&self, kind: &str, items: Vec<Value>) -> Result<StoredPlan, Error> {
        for item in &items {
            if item["action"].as_str().is_none() || item["target"].as_str().is_none() {
                return Err(Error::Failed(
                    "plan item without action or target".to_owned(),
                ));
            }
        }
        let now = self.clock.now();
        let plan = StoredPlan {
            id: new_id()?,
            kind: kind.to_owned(),
            created_at: now,
            expires_at: now + PLAN_TTL_SECS,
            digest: digest_items(kind, &items),
            items,
            confirmed_at: None,
            results: None,
        };
        self.store.insert(&plan)?;
        Ok(plan)
    }

    pub fn get(&self, id: &str) -> Result<StoredPlan, Error> {
        self.store
            .load(id)?
            .ok_or_else(|| Error::Usage(format!("unknown plan {id}")))
    }

    /// Confirms a plan once. Rejections (unknown, expired, already
    /// confirmed, digest mismatch) are errors and do not touch any item.
    pub fn confirm(&self, id: &str) -> Result<Report, Error> {
        let plan = self.get(id)?;
        let now = self.clock.now();
        if plan.confirmed_at.is_some() {
            return Err(Error::Usage(format!("plan {id} was already confirmed")));
        }
        if now >= plan.expires_at {
            return Err(Error::Usage(format!(
                "plan {id} expired; create a new plan"
            )));
        }
        if digest_items(&plan.kind, &plan.items) != plan.digest {
            return Err(Error::Failed(format!(
                "plan {id} does not match its digest"
            )));
        }
        if !self.store.claim(id, now)? {
            return Err(Error::Usage(format!("plan {id} was already confirmed")));
        }
        let results: Vec<ItemReport> = plan
            .items
            .iter()
            .enumerate()
            .map(|(index, item)| self.run_item(index, item))
            .collect();
        let outcomes: Vec<Outcome> = results.iter().map(|r| r.outcome).collect();
        let report = Report {
            plan_id: plan.id.clone(),
            status: overall(&outcomes),
            results,
        };
        self.store.finish(id, &report.to_json())?;
        Ok(report)
    }

    fn run_item(&self, index: usize, item: &Value) -> ItemReport {
        let kind = item["action"].as_str().unwrap_or_default();
        let (outcome, detail) = match self.actions.iter().find(|a| a.kind() == kind) {
            None => (
                Outcome::Unsupported,
                Some(format!("no handler for action {kind}")),
            ),
            Some(action) => match action.still_valid(item) {
                Err(reason) => (Outcome::SkippedChanged, Some(reason)),
                Ok(()) => {
                    let r = action.execute(item);
                    (r.outcome, r.detail)
                }
            },
        };
        ItemReport {
            index,
            action: kind.to_owned(),
            target: item["target"].as_str().unwrap_or_default().to_owned(),
            outcome,
            detail,
        }
    }

    /// Wire form of a plan for `plan show` and the `plan_*` tools.
    pub fn plan_json(&self, plan: &StoredPlan) -> Value {
        plan_json(plan, self.clock.now())
    }
}

pub fn plan_json(plan: &StoredPlan, now: i64) -> Value {
    let total: u64 = plan.items.iter().filter_map(|i| i["bytes"].as_u64()).sum();
    let mut v = json!({
        "id": plan.id,
        "kind": plan.kind,
        "state": plan.state(now),
        "created_at": rfc3339(plan.created_at),
        "expires_at": rfc3339(plan.expires_at),
        "expires_in_s": (plan.expires_at - now).max(0),
        "digest": plan.digest,
        "item_count": plan.items.len(),
        "total_bytes": total,
        "items": plan.items,
    });
    if let Some(r) = &plan.results {
        v["results"] = r.clone();
    }
    v
}

/// `get_plan` / `plan show`.
pub fn get_plan_json(engine: &Engine, id: &str) -> Result<Value, Error> {
    Ok(engine.plan_json(&engine.get(id)?))
}

/// `confirm_plan` / `plan confirm`.
pub fn confirm_plan_json(engine: &Engine, id: &str) -> Result<Value, Error> {
    Ok(engine.confirm(id)?.to_json())
}

pub fn digest_items(kind: &str, items: &[Value]) -> String {
    let bytes = serde_json::to_vec(&json!([kind, items])).unwrap_or_default();
    hex(&Sha256::digest(bytes))
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn new_id() -> Result<String, Error> {
    let mut b = [0u8; 8];
    getrandom::fill(&mut b)
        .map_err(|e| Error::Failed(format!("no randomness for plan id: {e}")))?;
    Ok(format!("pl_{}", hex(&b)))
}

/// `2026-11-20T10:00:00Z` for Unix seconds (proleptic Gregorian, UTC).
pub fn rfc3339(unix: i64) -> String {
    let days = unix.div_euclid(86_400);
    let secs = unix.rem_euclid(86_400);
    // Howard Hinnant's civil_from_days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        secs / 3600,
        secs % 3600 / 60,
        secs % 60
    )
}

// ---------------------------------------------------------------------------
// Filesystem items

/// What `lstat` (plus a tree fingerprint for directories) says about a path.
/// Two identities are equal only if the object is the same, in the same
/// place, with the same content metadata.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FsIdentity {
    /// `file`, `dir`, `symlink` or `other`.
    pub kind: String,
    pub dev: u64,
    pub ino: u64,
    pub mtime_s: i64,
    pub mtime_ns: i64,
    pub size: u64,
    /// Digest over every entry below a directory (path, kind, inode, size,
    /// mtime); `None` for non-directories.
    pub tree: Option<String>,
}

/// Facts gathered with the identity, for display and for the helper rule.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TreeInfo {
    pub bytes: u64,
    pub files: u64,
    /// Some entry is owned by a different user than `uid`.
    pub foreign_owner: bool,
}

fn kind_of(ft: fs::FileType) -> &'static str {
    if ft.is_symlink() {
        "symlink"
    } else if ft.is_dir() {
        "dir"
    } else if ft.is_file() {
        "file"
    } else {
        "other"
    }
}

fn identity_of_meta(m: &fs::Metadata) -> FsIdentity {
    FsIdentity {
        kind: kind_of(m.file_type()).to_owned(),
        dev: m.dev(),
        ino: m.ino(),
        mtime_s: m.mtime(),
        mtime_ns: m.mtime_nsec(),
        size: m.len(),
        tree: None,
    }
}

/// `lstat` the path; for a directory also walk it (never through symlinks,
/// not across devices) and fingerprint everything below.
pub fn identity_of(path: &Path, uid: u32) -> io::Result<(FsIdentity, TreeInfo)> {
    let meta = fs::symlink_metadata(path)?;
    let mut id = identity_of_meta(&meta);
    let mut info = TreeInfo {
        bytes: 0,
        files: 0,
        foreign_owner: meta.uid() != uid,
    };
    if id.kind == "file" {
        info.bytes = meta.len();
        info.files = 1;
    }
    if id.kind == "dir" {
        let mut hasher = Sha256::new();
        let mut seen = HashSet::new();
        let mut stack = vec![(path.to_path_buf(), PathBuf::new())];
        while let Some((dir, rel)) = stack.pop() {
            let mut entries = fs::read_dir(&dir)?.collect::<io::Result<Vec<_>>>()?;
            entries.sort_by_key(|e| e.file_name());
            let mut children = Vec::new();
            for e in entries {
                let m = fs::symlink_metadata(e.path())?;
                let child_rel = rel.join(e.file_name());
                let ident = identity_of_meta(&m);
                hasher.update(
                    format!(
                        "{}\0{}\0{}\0{}\0{}\0{}\n",
                        child_rel.display(),
                        ident.kind,
                        ident.ino,
                        ident.size,
                        ident.mtime_s,
                        ident.mtime_ns
                    )
                    .as_bytes(),
                );
                info.foreign_owner |= m.uid() != uid;
                if ident.kind == "file" {
                    info.files += 1;
                    if seen.insert((m.dev(), m.ino())) {
                        info.bytes += m.len();
                    }
                } else if ident.kind == "dir" && m.dev() == meta.dev() {
                    children.push((e.path(), child_rel));
                }
            }
            stack.extend(children.into_iter().rev());
        }
        id.tree = Some(hex(&hasher.finalize()));
    }
    Ok((id, info))
}

/// Current user id, taken from the owner of the home directory (no `unsafe`).
pub fn user_uid(home: &Path) -> io::Result<u32> {
    Ok(fs::metadata(home)?.uid())
}

/// Builds a `trash` or `delete` item for `target`, which must sit directly or
/// deeper under `root`. Fails if the path is gone, unreadable or outside.
pub fn fs_item(
    action: &str,
    target: &Path,
    root: &Path,
    uid: u32,
    category: &str,
    reason: &str,
) -> io::Result<Value> {
    let root = fs::canonicalize(root)?;
    let parent = target
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "no parent"))?;
    let parent_real = fs::canonicalize(parent)?;
    if !parent_real.starts_with(&root) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "target outside its root",
        ));
    }
    let (identity, info) = identity_of(target, uid)?;
    Ok(json!({
        "action": action,
        "target": target.to_string_lossy(),
        "root": root.to_string_lossy(),
        "parent_real": parent_real.to_string_lossy(),
        "category": category,
        "reason": reason,
        "bytes": info.bytes,
        "files": info.files,
        "requires_helper": info.foreign_owner,
        "identity": identity,
    }))
}

/// Moves to / removes from the file system. Live adapter: `symcockpit-macos`.
pub trait Remover {
    /// Move to the Trash (recoverable). Must never fall back to deleting.
    fn trash(&self, path: &Path) -> Result<(), String>;
    /// Permanent removal; never follows symlinks.
    fn delete(&self, path: &Path) -> Result<(), String>;
}

/// Is the app bundle at this path running? Used by uninstall items.
pub trait Running {
    fn is_running(&self, bundle: &Path) -> bool;
}

/// Handler for `trash` and `delete` items built by [`fs_item`].
pub struct FsAction<'a> {
    permanent: bool,
    remover: &'a dyn Remover,
    running: Option<&'a dyn Running>,
}

impl<'a> FsAction<'a> {
    pub fn trash(remover: &'a dyn Remover) -> Self {
        Self {
            permanent: false,
            remover,
            running: None,
        }
    }

    pub fn delete(remover: &'a dyn Remover) -> Self {
        Self {
            permanent: true,
            ..Self::trash(remover)
        }
    }

    /// Items with a `guard_running` bundle path are skipped while it runs.
    pub fn with_running(mut self, running: &'a dyn Running) -> Self {
        self.running = Some(running);
        self
    }
}

fn text<'v>(item: &'v Value, key: &str) -> Result<&'v str, String> {
    item[key]
        .as_str()
        .ok_or_else(|| format!("plan item without {key}"))
}

impl Action for FsAction<'_> {
    fn kind(&self) -> &'static str {
        if self.permanent { "delete" } else { "trash" }
    }

    fn still_valid(&self, item: &Value) -> Result<(), String> {
        let target = Path::new(text(item, "target")?);
        let root = Path::new(text(item, "root")?);
        let parent_real = Path::new(text(item, "parent_real")?);
        let expected: FsIdentity = serde_json::from_value(item["identity"].clone())
            .map_err(|e| format!("plan item without identity: {e}"))?;
        if !parent_real.starts_with(root) {
            return Err("target is outside its root".to_owned());
        }
        match fs::canonicalize(target.parent().unwrap_or(Path::new("/"))) {
            Ok(p) if p == parent_real => {}
            _ => return Err("parent directory changed".to_owned()),
        }
        // Ownership is not part of the identity, so the uid argument is moot.
        match identity_of(target, 0) {
            Ok((now, _)) if now == expected => {}
            Ok(_) => return Err("changed since the plan was made".to_owned()),
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                return Err("no longer exists".to_owned());
            }
            Err(e) => return Err(format!("cannot verify: {e}")),
        }
        // Files that must still exist unchanged for this removal to be safe
        // (the kept copy of a duplicate).
        for keep in item["keep"].as_array().into_iter().flatten() {
            let path = Path::new(keep["path"].as_str().unwrap_or_default());
            let expected: Option<FsIdentity> =
                serde_json::from_value(keep["identity"].clone()).ok();
            match (identity_of(path, 0), expected) {
                (Ok((now, _)), Some(exp)) if now == exp => {}
                _ => return Err("the copy to keep changed or is gone".to_owned()),
            }
        }
        if let (Some(app), Some(running)) = (item["guard_running"].as_str(), self.running)
            && running.is_running(Path::new(app))
        {
            return Err("the app is running".to_owned());
        }
        Ok(())
    }

    fn execute(&self, item: &Value) -> ItemResult {
        if item["requires_helper"].as_bool() == Some(true) {
            return ItemResult::new(
                Outcome::Unsupported,
                "owned by another user; needs the privileged helper".to_owned(),
            );
        }
        let Some(target) = item["target"].as_str().map(Path::new) else {
            return ItemResult::new(Outcome::Failed, "plan item without target".to_owned());
        };
        let done = if self.permanent {
            self.remover.delete(target)
        } else {
            self.remover.trash(target)
        };
        match (done, fs::symlink_metadata(target)) {
            (Ok(()), Err(e)) if e.kind() == io::ErrorKind::NotFound => {
                ItemResult::new(Outcome::Confirmed, None)
            }
            (Ok(()), Ok(_)) => ItemResult::new(
                Outcome::Unconfirmed,
                "reported done but the path still exists".to_owned(),
            ),
            (Ok(()), Err(e)) => ItemResult::new(
                Outcome::Unconfirmed,
                format!("reported done but cannot verify: {e}"),
            ),
            (Err(msg), Err(e)) if e.kind() == io::ErrorKind::NotFound => ItemResult::new(
                Outcome::Unconfirmed,
                format!("failed ({msg}) but the path is gone"),
            ),
            (Err(msg), _) => ItemResult::new(Outcome::Failed, msg),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rfc3339_known_dates() {
        assert_eq!(rfc3339(0), "1970-01-01T00:00:00Z");
        assert_eq!(rfc3339(1_795_168_800), "2026-11-20T10:00:00Z");
        assert_eq!(rfc3339(951_782_400), "2000-02-29T00:00:00Z");
        assert_eq!(rfc3339(-1), "1969-12-31T23:59:59Z");
    }

    #[test]
    fn worst_outcome_wins() {
        use Outcome::*;
        assert_eq!(overall(&[]), Confirmed);
        assert_eq!(overall(&[Confirmed, SkippedChanged]), SkippedChanged);
        assert_eq!(overall(&[Unsupported, Confirmed]), Unsupported);
        assert_eq!(overall(&[Unsupported, Failed, Unconfirmed]), Failed);
    }
}
