//! Fakes and scenario tests for the plan engine and the storage cleanup area
//! (R34, R35, R37, Q03). Everything runs in a temporary directory; the fake
//! [`Remover`] refuses any path outside it, so no real user file can be hit.

use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
    sync::{
        Mutex,
        atomic::{AtomicI64, Ordering},
    },
};

use symcockpit_contract::Error;
use symcockpit_core::{
    plan::{Action, Clock, Engine, FsAction, PlanStore, Remover, Running, StoredPlan},
    storage::uninstall::{AppInfo, Apps, Receipt},
};

/// A clock the test moves by hand.
pub struct FixedClock(AtomicI64);

impl FixedClock {
    pub fn new(now: i64) -> Self {
        Self(AtomicI64::new(now))
    }

    pub fn advance(&self, secs: i64) {
        self.0.fetch_add(secs, Ordering::SeqCst);
    }
}

impl Clock for FixedClock {
    fn now(&self) -> i64 {
        self.0.load(Ordering::SeqCst)
    }
}

/// Plans in memory; `claim` is atomic like the SQLite store.
#[derive(Default)]
pub struct MemoryStore(Mutex<HashMap<String, StoredPlan>>);

impl MemoryStore {
    pub fn len(&self) -> usize {
        self.0.lock().unwrap().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Lets a test tamper with a stored plan.
    pub fn edit(&self, id: &str, f: impl FnOnce(&mut StoredPlan)) {
        f(self.0.lock().unwrap().get_mut(id).unwrap());
    }
}

impl PlanStore for MemoryStore {
    fn insert(&self, plan: &StoredPlan) -> Result<(), Error> {
        self.0.lock().unwrap().insert(plan.id.clone(), plan.clone());
        Ok(())
    }

    fn load(&self, id: &str) -> Result<Option<StoredPlan>, Error> {
        Ok(self.0.lock().unwrap().get(id).cloned())
    }

    fn claim(&self, id: &str, at: i64) -> Result<bool, Error> {
        let mut map = self.0.lock().unwrap();
        let plan = map
            .get_mut(id)
            .ok_or_else(|| Error::Failed("gone".into()))?;
        Ok(plan.confirmed_at.replace(at).is_none())
    }

    fn finish(&self, id: &str, results: &serde_json::Value) -> Result<(), Error> {
        self.0.lock().unwrap().get_mut(id).unwrap().results = Some(results.clone());
        Ok(())
    }
}

#[derive(Clone, Copy, Default, PartialEq)]
pub enum RemoverMode {
    #[default]
    Works,
    /// Reports success without doing anything.
    Lies,
    Fails,
}

/// Moves files into a fake Trash directory (rename; never follows links) or
/// deletes them, but only inside `sandbox`.
pub struct FakeRemover {
    sandbox: PathBuf,
    trash_dir: PathBuf,
    pub mode: Mutex<RemoverMode>,
    pub calls: Mutex<Vec<(String, PathBuf)>>,
}

impl FakeRemover {
    pub fn new(sandbox: &Path, trash_dir: &Path) -> Self {
        Self {
            sandbox: sandbox.to_owned(),
            trash_dir: trash_dir.to_owned(),
            mode: Mutex::default(),
            calls: Mutex::default(),
        }
    }

    pub fn calls(&self) -> Vec<(String, PathBuf)> {
        self.calls.lock().unwrap().clone()
    }

    fn act(&self, what: &str, path: &Path) -> Result<(), String> {
        if !path.starts_with(&self.sandbox) {
            return Err("fake remover refuses paths outside the sandbox".to_owned());
        }
        self.calls
            .lock()
            .unwrap()
            .push((what.to_owned(), path.to_owned()));
        match *self.mode.lock().unwrap() {
            RemoverMode::Fails => Err("simulated failure".to_owned()),
            RemoverMode::Lies => Ok(()),
            RemoverMode::Works => {
                let n = self.calls.lock().unwrap().len();
                let name = path.file_name().unwrap().to_string_lossy().into_owned();
                if what == "trash" {
                    fs::create_dir_all(&self.trash_dir).map_err(|e| e.to_string())?;
                    fs::rename(path, self.trash_dir.join(format!("{n}-{name}")))
                        .map_err(|e| e.to_string())
                } else if fs::symlink_metadata(path)
                    .map_err(|e| e.to_string())?
                    .is_dir()
                {
                    fs::remove_dir_all(path).map_err(|e| e.to_string())
                } else {
                    fs::remove_file(path).map_err(|e| e.to_string())
                }
            }
        }
    }
}

impl Remover for FakeRemover {
    fn trash(&self, path: &Path) -> Result<(), String> {
        self.act("trash", path)
    }

    fn delete(&self, path: &Path) -> Result<(), String> {
        self.act("delete", path)
    }
}

/// Installed apps, receipts and running processes, all made up.
#[derive(Default)]
pub struct FakeApps {
    pub apps: Vec<(PathBuf, String, String, Option<String>)>,
    pub receipts: HashMap<String, Vec<PathBuf>>,
    pub running: Mutex<Vec<PathBuf>>,
}

impl FakeApps {
    pub fn add(&mut self, path: &Path, bundle_id: &str, name: &str, team: Option<&str>) {
        self.apps.push((
            path.to_owned(),
            bundle_id.to_owned(),
            name.to_owned(),
            team.map(str::to_owned),
        ));
    }
}

impl Running for FakeApps {
    fn is_running(&self, bundle: &Path) -> bool {
        self.running.lock().unwrap().iter().any(|p| p == bundle)
    }
}

impl Apps for FakeApps {
    fn resolve(&self, app: &str) -> Result<AppInfo, Error> {
        self.apps
            .iter()
            .find(|(p, id, ..)| p == Path::new(app) || id == app)
            .map(|(path, id, name, team)| AppInfo {
                path: path.clone(),
                bundle_id: id.clone(),
                name: name.clone(),
                team_id: team.clone(),
            })
            .ok_or_else(|| Error::Usage(format!("no app {app}")))
    }

    fn receipt(&self, bundle_id: &str) -> Result<Option<Receipt>, Error> {
        Ok(self.receipts.get(bundle_id).map(|files| Receipt {
            pkg_id: bundle_id.to_owned(),
            files: files.clone(),
        }))
    }
}

/// A temporary world: home, a fake `/` and a fake Trash.
pub struct World {
    pub dir: tempfile::TempDir,
    pub home: PathBuf,
    pub system: PathBuf,
    pub store: MemoryStore,
    pub clock: FixedClock,
    pub remover: FakeRemover,
    pub apps: FakeApps,
}

pub const NOW: i64 = 1_795_168_800;

impl Default for World {
    fn default() -> Self {
        Self::new()
    }
}

impl World {
    pub fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let system = dir.path().join("system");
        fs::create_dir_all(&home).unwrap();
        fs::create_dir_all(&system).unwrap();
        let remover = FakeRemover::new(dir.path(), &dir.path().join("fake-trash"));
        Self {
            dir,
            home,
            system,
            store: MemoryStore::default(),
            clock: FixedClock::new(NOW),
            remover,
            apps: FakeApps::default(),
        }
    }

    /// An engine with the trash and delete actions registered.
    pub fn with_engine<R>(&self, f: impl FnOnce(&Engine) -> R) -> R {
        let trash = FsAction::trash(&self.remover).with_running(&self.apps);
        let delete = FsAction::delete(&self.remover);
        let actions: [&dyn Action; 2] = [&trash, &delete];
        let mut engine = Engine::new(&self.store, &self.clock);
        for a in actions {
            engine = engine.register(a);
        }
        f(&engine)
    }

    pub fn write(&self, rel: &str, bytes: &[u8]) -> PathBuf {
        let p = self.dir.path().join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(&p, bytes).unwrap();
        p
    }
}

#[cfg(test)]
mod tests {
    use std::{os::unix::fs::symlink, thread};

    use serde_json::{Value, json};
    use symcockpit_core::{
        plan::{confirm_plan_json, get_plan_json, outcome_exit_code},
        storage::{
            clean::{CATALOG, plan_clean_json},
            duplicates::{find_duplicates_json, plan_remove_duplicates_json},
            uninstall::plan_uninstall_app_json,
        },
    };
    use symcockpit_store::plans::SqlitePlanStore;

    use super::*;

    fn clean(w: &World, cats: &[&str]) -> Value {
        let cats: Vec<String> = cats.iter().map(|c| (*c).to_owned()).collect();
        w.with_engine(|e| plan_clean_json(e, &w.home, &cats))
            .unwrap()
    }

    fn confirm(w: &World, v: &Value) -> Result<Value, Error> {
        w.with_engine(|e| confirm_plan_json(e, v["id"].as_str().unwrap()))
    }

    fn outcomes(report: &Value) -> Vec<String> {
        report["results"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["outcome"].as_str().unwrap().to_owned())
            .collect()
    }

    fn targets(w: &World, plan: &Value) -> Vec<String> {
        let mut t: Vec<String> = plan["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|i| {
                Path::new(i["target"].as_str().unwrap())
                    .strip_prefix(w.dir.path())
                    .unwrap()
                    .to_string_lossy()
                    .into_owned()
            })
            .collect();
        t.sort();
        t
    }

    // ---- plan engine ------------------------------------------------------

    #[test]
    fn plan_changes_nothing_and_confirm_moves_to_trash() {
        let w = World::new();
        let a = w.write("home/Library/Caches/org.example.app/blob", b"cache");
        let log = w.write("home/Library/Logs/app.log", b"log");
        let plan = clean(&w, &[]);
        assert_eq!(plan["state"], "pending");
        assert_eq!(plan["item_count"], 2);
        assert_eq!(plan["expires_in_s"], 300);
        assert!(a.exists() && log.exists(), "planning must not touch files");
        assert!(w.remover.calls().is_empty());

        let report = confirm(&w, &plan).unwrap();
        assert_eq!(report["status"], "confirmed");
        assert_eq!(outcomes(&report), ["confirmed", "confirmed"]);
        assert_eq!(
            outcome_exit_code(symcockpit_contract::Outcome::Confirmed),
            0
        );
        assert!(!a.exists() && !log.exists());
        assert!(
            w.remover.calls().iter().all(|(what, _)| what == "trash"),
            "the Trash is the default"
        );
        let shown = w
            .with_engine(|e| get_plan_json(e, plan["id"].as_str().unwrap()))
            .unwrap();
        assert_eq!(shown["state"], "confirmed");
        assert_eq!(shown["results"]["status"], "confirmed");
    }

    #[test]
    fn expired_plan_is_rejected_and_nothing_is_touched() {
        let w = World::new();
        let f = w.write("home/Library/Logs/x.log", b"x");
        let plan = clean(&w, &["user_logs"]);
        w.clock.advance(300);
        let err = confirm(&w, &plan).unwrap_err();
        assert!(
            matches!(&err, Error::Usage(m) if m.contains("expired")),
            "{err}"
        );
        assert_eq!(err.exit_code(), 2);
        assert!(f.exists() && w.remover.calls().is_empty());
        let shown = w
            .with_engine(|e| get_plan_json(e, plan["id"].as_str().unwrap()))
            .unwrap();
        assert_eq!(shown["state"], "expired");
    }

    #[test]
    fn plan_is_valid_until_the_last_second() {
        let w = World::new();
        w.write("home/Library/Logs/x.log", b"x");
        let plan = clean(&w, &["user_logs"]);
        w.clock.advance(299);
        assert_eq!(confirm(&w, &plan).unwrap()["status"], "confirmed");
    }

    #[test]
    fn second_confirmation_is_rejected() {
        let w = World::new();
        w.write("home/Library/Logs/x.log", b"x");
        let plan = clean(&w, &["user_logs"]);
        confirm(&w, &plan).unwrap();
        let err = confirm(&w, &plan).unwrap_err();
        assert!(
            matches!(&err, Error::Usage(m) if m.contains("already confirmed")),
            "{err}"
        );
        assert_eq!(w.remover.calls().len(), 1);
    }

    #[test]
    fn unknown_plan_is_a_usage_error() {
        let w = World::new();
        let err = w
            .with_engine(|e| confirm_plan_json(e, "pl_nope"))
            .unwrap_err();
        assert!(matches!(err, Error::Usage(_)));
    }

    #[test]
    fn tampered_plan_is_rejected() {
        let w = World::new();
        w.write("home/Library/Logs/x.log", b"x");
        let plan = clean(&w, &["user_logs"]);
        w.store.edit(plan["id"].as_str().unwrap(), |p| {
            p.items[0]["target"] = json!("/etc/hosts");
        });
        let err = confirm(&w, &plan).unwrap_err();
        assert!(
            matches!(&err, Error::Failed(m) if m.contains("digest")),
            "{err}"
        );
        assert!(w.remover.calls().is_empty());
    }

    #[test]
    fn concurrent_confirmations_run_the_plan_once() {
        let dir = tempfile::tempdir().unwrap();
        let w = World::new();
        for i in 0..5 {
            w.write(&format!("home/Library/Logs/{i}.log"), b"x");
        }
        let store = SqlitePlanStore::open(&dir.path().join("db/cockpit.sqlite")).unwrap();
        let clock = FixedClock::new(NOW);
        let id = {
            let trash = FsAction::trash(&w.remover);
            let e = Engine::new(&store, &clock).register(&trash);
            let cats = vec!["user_logs".to_owned()];
            plan_clean_json(&e, &w.home, &cats).unwrap()["id"]
                .as_str()
                .unwrap()
                .to_owned()
        };
        let results: Vec<Result<Value, Error>> = thread::scope(|s| {
            let handles: Vec<_> = (0..4)
                .map(|_| {
                    s.spawn(|| {
                        let trash = FsAction::trash(&w.remover);
                        let e = Engine::new(&store, &clock).register(&trash);
                        confirm_plan_json(&e, &id)
                    })
                })
                .collect();
            handles.into_iter().map(|h| h.join().unwrap()).collect()
        });
        assert_eq!(results.iter().filter(|r| r.is_ok()).count(), 1);
        assert!(
            results
                .iter()
                .filter_map(|r| r.as_ref().err())
                .all(|e| matches!(e, Error::Usage(_)))
        );
        assert_eq!(
            w.remover.calls().len(),
            5,
            "each item acted on exactly once"
        );
    }

    /// Two confirmers that both loaded the plan as pending: the atomic claim,
    /// not the earlier state check, must let only one of them act.
    #[test]
    fn the_atomic_claim_stops_a_confirmer_holding_a_stale_plan() {
        struct Stale<'a>(&'a MemoryStore);
        impl PlanStore for Stale<'_> {
            fn insert(&self, p: &StoredPlan) -> Result<(), Error> {
                self.0.insert(p)
            }
            fn load(&self, id: &str) -> Result<Option<StoredPlan>, Error> {
                Ok(self.0.load(id)?.map(|mut p| {
                    p.confirmed_at = None;
                    p
                }))
            }
            fn claim(&self, id: &str, at: i64) -> Result<bool, Error> {
                self.0.claim(id, at)
            }
            fn finish(&self, id: &str, r: &Value) -> Result<(), Error> {
                self.0.finish(id, r)
            }
        }
        let w = World::new();
        w.write("home/Library/Logs/x.log", b"x");
        let stale = Stale(&w.store);
        let trash = FsAction::trash(&w.remover);
        let e = Engine::new(&stale, &w.clock).register(&trash);
        let cats = vec!["user_logs".to_owned()];
        let id = plan_clean_json(&e, &w.home, &cats).unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        assert_eq!(confirm_plan_json(&e, &id).unwrap()["status"], "confirmed");
        assert!(
            matches!(confirm_plan_json(&e, &id), Err(Error::Usage(m)) if m.contains("already"))
        );
        assert_eq!(w.remover.calls().len(), 1);
    }

    #[test]
    fn plans_survive_reopening_the_database() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("cockpit.sqlite");
        let w = World::new();
        w.write("home/Library/Logs/x.log", b"x");
        let clock = FixedClock::new(NOW);
        let id = {
            let store = SqlitePlanStore::open(&db).unwrap();
            let e = Engine::new(&store, &clock);
            let cats = vec!["user_logs".to_owned()];
            plan_clean_json(&e, &w.home, &cats).unwrap()["id"]
                .as_str()
                .unwrap()
                .to_owned()
        };
        let store = SqlitePlanStore::open(&db).unwrap();
        let trash = FsAction::trash(&w.remover);
        let e = Engine::new(&store, &clock).register(&trash);
        assert_eq!(get_plan_json(&e, &id).unwrap()["state"], "pending");
        assert_eq!(confirm_plan_json(&e, &id).unwrap()["status"], "confirmed");
        assert!(matches!(confirm_plan_json(&e, &id), Err(Error::Usage(_))));
    }

    #[test]
    fn outcomes_reflect_the_post_condition() {
        for (mode, want, exit) in [
            (RemoverMode::Lies, "unconfirmed", 1),
            (RemoverMode::Fails, "failed", 1),
        ] {
            let w = World::new();
            let f = w.write("home/Library/Logs/x.log", b"x");
            *w.remover.mode.lock().unwrap() = mode;
            let plan = clean(&w, &["user_logs"]);
            let report = confirm(&w, &plan).unwrap();
            assert_eq!(report["status"], want);
            assert_eq!(
                outcome_exit_code(serde_json::from_value(report["status"].clone()).unwrap()),
                exit
            );
            assert!(f.exists());
        }
    }

    #[test]
    fn unknown_action_is_unsupported() {
        let w = World::new();
        let plan = w
            .with_engine(|e| e.create("x", vec![json!({"action": "kill", "target": "pid 1"})]))
            .unwrap();
        let report = w.with_engine(|e| e.confirm(&plan.id)).unwrap().to_json();
        assert_eq!(report["status"], "unsupported");
        assert_eq!(
            outcome_exit_code(symcockpit_contract::Outcome::Unsupported),
            4
        );
    }

    // ---- race tests (acceptance stage 3) ---------------------------------

    /// Plans `Library/Caches` (one item per child), applies `mutate`, confirms.
    fn race(w: &World, mutate: impl FnOnce(&World)) -> Value {
        let plan = clean(w, &["user_caches"]);
        mutate(w);
        confirm(w, &plan).unwrap()
    }

    #[test]
    fn symlink_swapped_in_for_a_file_is_skipped_and_never_followed() {
        let w = World::new();
        let victim = w.write("home/outside/secret.txt", b"precious");
        let f = w.write("home/Library/Caches/a.bin", b"cache");
        let report = race(&w, |_| {
            fs::remove_file(&f).unwrap();
            symlink(&victim, &f).unwrap();
        });
        assert_eq!(outcomes(&report), ["skipped_changed"]);
        assert_eq!(report["status"], "skipped_changed");
        assert!(w.remover.calls().is_empty());
        assert_eq!(fs::read(&victim).unwrap(), b"precious");
        assert!(fs::symlink_metadata(&f).unwrap().is_symlink());
    }

    #[test]
    fn symlink_swapped_in_for_a_directory_is_skipped() {
        let w = World::new();
        let outside = w.write("home/outside/keep/file", b"precious");
        let d = w.dir.path().join("home/Library/Caches/app");
        w.write("home/Library/Caches/app/x", b"x");
        let report = race(&w, |_| {
            fs::remove_dir_all(&d).unwrap();
            symlink(outside.parent().unwrap(), &d).unwrap();
        });
        assert_eq!(outcomes(&report), ["skipped_changed"]);
        assert!(outside.exists());
    }

    #[test]
    fn renamed_away_or_replaced_by_a_new_file_is_skipped() {
        let w = World::new();
        let a = w.write("home/Library/Caches/a.bin", b"a");
        let b = w.write("home/Library/Caches/b.bin", b"b");
        let report = race(&w, |_| {
            fs::rename(&a, w.dir.path().join("home/moved.bin")).unwrap();
            fs::remove_file(&b).unwrap();
            fs::write(&b, b"b").unwrap(); // same name and bytes, new object
        });
        assert_eq!(outcomes(&report), ["skipped_changed", "skipped_changed"]);
        assert!(w.dir.path().join("home/moved.bin").exists() && b.exists());
        assert!(w.remover.calls().is_empty());
    }

    #[test]
    fn change_deep_inside_a_directory_item_is_skipped() {
        let w = World::new();
        w.write("home/Library/Caches/app/sub/x", b"x");
        let report = race(&w, |_| {
            let p = w.dir.path().join("home/Library/Caches/app/sub");
            fs::rename(p.join("x"), p.join("y")).unwrap();
        });
        assert_eq!(outcomes(&report), ["skipped_changed"]);
    }

    #[test]
    fn rewritten_file_is_skipped() {
        let w = World::new();
        let f = w.write("home/Library/Caches/a.bin", b"short");
        let report = race(&w, |_| fs::write(&f, b"much longer content").unwrap());
        assert_eq!(outcomes(&report), ["skipped_changed"]);
    }

    #[test]
    fn swapped_parent_directory_is_skipped() {
        let w = World::new();
        w.write("home/Library/Caches/app/x", b"x");
        let root = w.dir.path().join("home/Library/Caches");
        let plan = clean(&w, &["user_caches"]);
        // Move the whole Caches folder away and put a link to it in its place.
        let moved = w.dir.path().join("home/Library/Caches-moved");
        fs::rename(&root, &moved).unwrap();
        symlink(&moved, &root).unwrap();
        let report = confirm(&w, &plan).unwrap();
        assert_eq!(outcomes(&report), ["skipped_changed"]);
        assert!(moved.join("app/x").exists());
    }

    #[test]
    fn one_changed_item_does_not_block_the_others() {
        let w = World::new();
        let a = w.write("home/Library/Caches/a.bin", b"a");
        let b = w.write("home/Library/Caches/b.bin", b"b");
        let report = race(&w, |_| fs::write(&a, b"changed!").unwrap());
        assert_eq!(outcomes(&report), ["skipped_changed", "confirmed"]);
        assert_eq!(report["status"], "skipped_changed");
        assert_eq!(report["counts"]["confirmed"], 1);
        assert!(a.exists() && !b.exists());
    }

    // ---- cleanup (R34) ---------------------------------------------------

    #[test]
    fn catalog_matches_the_contract_and_gives_a_reason_per_category() {
        let ids: Vec<&str> = CATALOG.iter().map(|c| c.id).collect();
        assert_eq!(
            ids,
            symcockpit_contract::areas::storage_clean::CLEAN_CATEGORIES
        );
        assert!(CATALOG.iter().all(|c| c.reason.len() > 20));
        let permanent: Vec<_> = CATALOG
            .iter()
            .filter(|c| c.permanent)
            .map(|c| c.id)
            .collect();
        assert_eq!(permanent, ["empty_trash"]);
        assert!(CATALOG.iter().filter(|c| c.permanent).all(|c| !c.default));
    }

    #[test]
    fn default_selection_skips_apple_caches_and_the_trash() {
        let w = World::new();
        w.write("home/Library/Caches/com.apple.Safari/x", b"x");
        w.write("home/Library/Caches/org.example/x", b"x");
        w.write("home/.Trash/old.txt", b"x");
        let plan = clean(&w, &[]);
        assert_eq!(targets(&w, &plan), ["home/Library/Caches/org.example"]);
        assert_eq!(plan["catalog_version"], 1);
        assert_eq!(plan["categories"].as_array().unwrap().len(), 3);
        let err = w
            .with_engine(|e| plan_clean_json(e, &w.home, &["nope".to_owned()]))
            .unwrap_err();
        assert!(matches!(err, Error::Usage(m) if m.contains("known:")));
    }

    #[test]
    fn emptying_the_trash_is_its_own_category_and_deletes_for_good() {
        let w = World::new();
        let t = w.write("home/.Trash/old.txt", b"x");
        let plan = clean(&w, &["empty_trash"]);
        assert_eq!(plan["items"][0]["action"], "delete");
        let report = confirm(&w, &plan).unwrap();
        assert_eq!(report["status"], "confirmed");
        assert!(!t.exists());
        assert_eq!(w.remover.calls()[0].0, "delete");
    }

    #[test]
    fn symlinked_root_is_not_followed_and_symlink_children_stay_links() {
        let w = World::new();
        let real = w.write("home/elsewhere/Logs/x.log", b"x");
        fs::create_dir_all(w.home.join("Library")).unwrap();
        symlink(real.parent().unwrap(), w.home.join("Library/Logs")).unwrap();
        let plan = clean(&w, &["user_logs"]);
        assert_eq!(plan["item_count"], 0);
        assert!(
            plan["skipped"][0]["reason"]
                .as_str()
                .unwrap()
                .contains("symlink")
        );

        // A link child is trashed as a link; its target survives.
        let secret = w.write("home/outside/secret", b"precious");
        fs::create_dir_all(w.home.join("Library/Caches")).unwrap();
        symlink(&secret, w.home.join("Library/Caches/link")).unwrap();
        let plan = clean(&w, &["user_caches"]);
        assert_eq!(plan["items"][0]["identity"]["kind"], "symlink");
        let report = confirm(&w, &plan).unwrap();
        assert_eq!(report["status"], "confirmed");
        assert_eq!(fs::read(&secret).unwrap(), b"precious");
    }

    // ---- duplicates (R35) ------------------------------------------------

    fn dup_world() -> World {
        let w = World::new();
        let big = |tail: u8| {
            let mut v = vec![7u8; 70_000];
            v.push(tail); // same first 64 KiB, different end
            v
        };
        w.write("home/d/a1.bin", &big(1));
        w.write("home/d/sub/a2.bin", &big(1));
        w.write("home/d/b.bin", &big(2));
        w.write("home/d/small1", b"same");
        w.write("home/d/small2", b"same");
        w.write("home/d/unique", b"different!");
        w.write("home/d/empty1", b"");
        w.write("home/d/empty2", b"");
        fs::hard_link(w.home.join("d/small1"), w.home.join("d/small1-hardlink")).unwrap();
        symlink(w.home.join("d/small1"), w.home.join("d/small-link")).unwrap();
        w
    }

    #[test]
    fn duplicates_are_grouped_by_size_partial_and_full_hash() {
        let w = dup_world();
        let v = find_duplicates_json(&w.home.join("d"), 1).unwrap();
        let groups = v["groups"].as_array().unwrap();
        assert_eq!(groups.len(), 2, "{v}");
        let files: Vec<Vec<String>> = groups
            .iter()
            .map(|g| {
                g["files"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|f| {
                        Path::new(f.as_str().unwrap())
                            .file_name()
                            .unwrap()
                            .to_string_lossy()
                            .into_owned()
                    })
                    .collect()
            })
            .collect();
        assert_eq!(
            files[0],
            ["a1.bin", "a2.bin"],
            "large pair first; b.bin differs at the end"
        );
        assert_eq!(
            files[1],
            ["small1", "small2"],
            "hard link and symlink are not copies"
        );
        assert_eq!(v["hardlinks_skipped"], 1);
        assert_eq!(v["reclaimable_bytes"], 70_001 + 4);
        assert!(w.store.is_empty(), "finding creates no plan");
    }

    #[test]
    fn only_selected_files_are_planned_and_every_group_keeps_a_copy() {
        let w = dup_world();
        let root = w.home.join("d");
        let plan = |sel: &[&str]| {
            let sel: Vec<PathBuf> = sel.iter().map(|s| root.join(s)).collect();
            w.with_engine(|e| plan_remove_duplicates_json(e, &w.home, &root, &sel, 1))
        };
        assert!(
            matches!(plan(&[]), Err(Error::Usage(_))),
            "no selection, no plan"
        );
        assert!(matches!(plan(&["unique"]), Err(Error::Usage(m)) if m.contains("not a duplicate")));
        assert!(
            matches!(plan(&["small-link"]), Err(Error::Usage(_))),
            "a link is no copy"
        );
        let all = plan(&["small1", "small2"]).unwrap_err();
        assert!(
            matches!(&all, Error::Usage(m) if m.contains("keep at least one")),
            "{all}"
        );
        assert!(w.store.is_empty());

        let p = plan(&["small2", "sub/a2.bin"]).unwrap();
        assert_eq!(targets(&w, &p), ["home/d/small2", "home/d/sub/a2.bin"]);
        let report = confirm(&w, &p).unwrap();
        assert_eq!(report["status"], "confirmed");
        assert!(root.join("small1").exists() && root.join("a1.bin").exists());
        assert!(!root.join("small2").exists());
    }

    #[test]
    fn removal_is_skipped_when_the_kept_copy_disappears() {
        let w = dup_world();
        let root = w.home.join("d");
        let p = w
            .with_engine(|e| {
                plan_remove_duplicates_json(e, &w.home, &root, &[root.join("small2")], 1)
            })
            .unwrap();
        fs::remove_file(root.join("small1")).unwrap(); // the only other copy
        let report = confirm(&w, &p).unwrap();
        assert_eq!(outcomes(&report), ["skipped_changed"]);
        assert!(root.join("small2").exists());
    }

    // ---- uninstall (R37) -------------------------------------------------

    const TEAM: &str = "AB12CD34EF";
    const UUID: &str = "01234567-89AB-CDEF-0123-456789ABCDEF";

    /// Two similar apps, `com.example.foo` ("Foo") and `com.example.foopro`
    /// ("Foo Pro"), plus `com.example.foo.lite`, each with files, and
    /// look-alike files that must not be claimed.
    fn two_apps() -> World {
        let mut w = World::new();
        for (rel, id, name) in [
            ("system/Applications/Foo.app", "com.example.foo", "Foo"),
            (
                "system/Applications/Foo Pro.app",
                "com.example.foopro",
                "Foo Pro",
            ),
        ] {
            w.write(&format!("{rel}/Contents/MacOS/bin"), b"x");
            let path = w.dir.path().join(rel);
            w.apps.add(&path, id, name, Some(TEAM));
        }
        let lib = "home/Library";
        for f in [
            // Foo's own files.
            "Application Support/com.example.foo/data",
            "Caches/com.example.foo/c",
            "Preferences/com.example.foo.plist",
            &format!("Preferences/ByHost/com.example.foo.{UUID}.plist"),
            "Saved Application State/com.example.foo.savedState/w",
            "Containers/com.example.foo/Data/x",
            &format!("Group Containers/{TEAM}.com.example.foo/g"),
            "LaunchAgents/com.example.foo.plist",
            // Not Foo's.
            "Application Support/com.example.foopro/data",
            "Caches/com.example.foo.lite/c",
            "Preferences/com.example.foopro.plist",
            &format!("Preferences/ByHost/com.example.foo.lite.{UUID}.plist"),
            &format!("Group Containers/{TEAM}.shared/s"),
            "Group Containers/ZZZZZZZZZZ.com.example.foo/z",
            // Similar by name only.
            "Application Support/Foo/n",
            "Application Support/Foo Pro/n",
        ] {
            w.write(&format!("{lib}/{f}"), b"data");
        }
        w.write("system/Library/LaunchDaemons/com.example.foo.plist", b"d");
        w
    }

    fn uninstall(w: &World, app: &str) -> Result<Value, Error> {
        w.with_engine(|e| plan_uninstall_app_json(e, &w.apps, &w.home, &w.system, app))
    }

    #[test]
    fn two_similar_apps_never_share_files() {
        let w = two_apps();
        let plan = uninstall(&w, "com.example.foo").unwrap();
        let mut want: Vec<String> = [
            "system/Applications/Foo.app",
            "system/Library/LaunchDaemons/com.example.foo.plist",
            "home/Library/Application Support/com.example.foo",
            "home/Library/Caches/com.example.foo",
            "home/Library/Preferences/com.example.foo.plist",
            &format!("home/Library/Preferences/ByHost/com.example.foo.{UUID}.plist"),
            "home/Library/Saved Application State/com.example.foo.savedState",
            "home/Library/Containers/com.example.foo",
            &format!("home/Library/Group Containers/{TEAM}.com.example.foo"),
            "home/Library/LaunchAgents/com.example.foo.plist",
        ]
        .map(str::to_owned)
        .to_vec();
        want.sort();
        assert_eq!(targets(&w, &plan), want);

        // Every item says why, by bundle id, team id or receipt.
        for i in plan["items"].as_array().unwrap() {
            assert!(i["category"].as_str().is_some() && i["reason"].as_str().is_some());
        }
        let reason_of = |suffix: &str| {
            plan["items"]
                .as_array()
                .unwrap()
                .iter()
                .find(|i| i["target"].as_str().unwrap().ends_with(suffix))
                .unwrap()["reason"]
                .as_str()
                .unwrap()
                .to_owned()
        };
        assert!(reason_of(&format!("{TEAM}.com.example.foo")).contains("team id"));
        assert!(reason_of("Caches/com.example.foo").contains("bundle id com.example.foo"));

        // Name matches and shared containers are shown but not planned.
        let excluded: Vec<(String, String)> = plan["excluded"]
            .as_array()
            .unwrap()
            .iter()
            .map(|x| {
                (
                    Path::new(x["path"].as_str().unwrap())
                        .strip_prefix(w.dir.path())
                        .unwrap()
                        .to_string_lossy()
                        .into_owned(),
                    x["category"].as_str().unwrap().to_owned(),
                )
            })
            .collect();
        assert!(excluded.contains(&(
            "home/Library/Application Support/Foo".into(),
            "name_match".into()
        )));
        assert!(excluded.contains(&(
            format!("home/Library/Group Containers/{TEAM}.shared"),
            "group_container".into()
        )));

        // Confirming removes Foo's files and leaves everything else alone.
        let report = confirm(&w, &plan).unwrap();
        assert_eq!(report["status"], "confirmed", "{report}");
        for kept in [
            "system/Applications/Foo Pro.app",
            "home/Library/Application Support/com.example.foopro/data",
            "home/Library/Caches/com.example.foo.lite/c",
            "home/Library/Application Support/Foo/n",
            "home/Library/Application Support/Foo Pro/n",
            &format!("home/Library/Group Containers/{TEAM}.shared/s"),
            "home/Library/Group Containers/ZZZZZZZZZZ.com.example.foo/z",
        ] {
            assert!(w.dir.path().join(kept).exists(), "{kept} must survive");
        }
        assert!(!w.dir.path().join("system/Applications/Foo.app").exists());
    }

    #[test]
    fn the_other_similar_app_gets_only_its_own_files() {
        let w = two_apps();
        let plan = uninstall(&w, "com.example.foopro").unwrap();
        assert_eq!(
            targets(&w, &plan),
            [
                "home/Library/Application Support/com.example.foopro",
                "home/Library/Preferences/com.example.foopro.plist",
                "system/Applications/Foo Pro.app",
            ]
        );
    }

    #[test]
    fn a_running_app_blocks_planning_and_confirmation() {
        let w = two_apps();
        let app = w.dir.path().join("system/Applications/Foo.app");
        w.apps.running.lock().unwrap().push(app.clone());
        let err = uninstall(&w, "com.example.foo").unwrap_err();
        assert!(
            matches!(&err, Error::Failed(m) if m.contains("running")),
            "{err}"
        );
        assert!(w.store.is_empty());

        w.apps.running.lock().unwrap().clear();
        let plan = uninstall(&w, "com.example.foo").unwrap();
        w.apps.running.lock().unwrap().push(app);
        let report = confirm(&w, &plan).unwrap();
        assert!(
            outcomes(&report).iter().all(|o| o == "skipped_changed"),
            "{report}"
        );
        assert!(w.remover.calls().is_empty());
    }

    #[test]
    fn documents_are_excluded_whatever_claims_them() {
        let mut w = two_apps();
        let doc = w.write("home/Documents/Foo notes.txt", b"mine");
        w.write(
            "home/Library/Mobile Documents/iCloud~com~example~foo/doc",
            b"mine",
        );
        let usr = w.write("system/usr/local/bin/foo-tool", b"x");
        w.apps.receipts.insert(
            "com.example.foo".to_owned(),
            vec![
                doc.clone(),
                usr.clone(),
                w.dir.path().join("system/usr/local/bin"),
            ],
        );
        let plan = uninstall(&w, "com.example.foo").unwrap();
        let t = targets(&w, &plan);
        assert!(!t.iter().any(|p| p.contains("Documents")), "{t:?}");
        assert!(
            t.contains(&"system/usr/local/bin/foo-tool".to_owned()),
            "receipt file is planned"
        );
        assert!(
            !t.contains(&"system/usr/local/bin".to_owned()),
            "receipt directories are not"
        );
        let item = plan["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|i| i["category"] == "installed_file")
            .unwrap();
        assert!(
            item["reason"]
                .as_str()
                .unwrap()
                .starts_with("installer receipt")
        );
        let ex: Vec<&str> = plan["excluded"]
            .as_array()
            .unwrap()
            .iter()
            .map(|x| x["reason"].as_str().unwrap())
            .collect();
        assert!(ex.iter().any(|r| r.contains("documents")), "{ex:?}");
        confirm(&w, &plan).unwrap();
        assert!(doc.exists());
        assert!(
            w.home
                .join("Library/Mobile Documents/iCloud~com~example~foo/doc")
                .exists()
        );
    }

    #[test]
    fn files_of_another_owner_need_the_helper_and_are_never_touched() {
        let mut w = two_apps();
        // `true` is root-owned on macOS and Linux; it is only read, never moved.
        let root_owned = PathBuf::from("/usr/bin/true");
        assert!(root_owned.exists());
        w.apps
            .receipts
            .insert("com.example.foo".to_owned(), vec![root_owned.clone()]);
        let plan = uninstall(&w, "com.example.foo").unwrap();
        let item = plan["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|i| i["target"] == "/usr/bin/true")
            .expect("planned so the user sees it");
        assert_eq!(item["requires_helper"], true);
        let report = confirm(&w, &plan).unwrap();
        let r = report["results"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["target"] == "/usr/bin/true")
            .unwrap();
        assert_eq!(r["outcome"], "unsupported");
        assert_eq!(report["status"], "unsupported");
        assert!(w.remover.calls().iter().all(|(_, p)| p != &root_owned));
        assert!(root_owned.exists());
    }

    #[test]
    fn system_apps_cannot_be_planned() {
        let mut w = World::new();
        let p = w.write("system/System/Applications/Mail.app/Contents/x", b"x");
        let app = p.ancestors().nth(2).unwrap().to_owned();
        w.apps.add(&app, "com.apple.mail", "Mail", None);
        assert!(matches!(
            uninstall(&w, "com.apple.mail"),
            Err(Error::Usage(_))
        ));
    }

    // ---- wire shapes (snapshots) -----------------------------------------

    fn snapshot(id: &str, value: &Value) {
        use symcockpit_oracle::shape;
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../snapshots/storage_clean")
            .join(format!("{id}.shape.json"));
        let actual = shape::derive(value).unwrap();
        if std::env::var_os("SYMCOCKPIT_UPDATE_SNAPSHOTS").is_some() {
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(&path, serde_json::to_string_pretty(&actual).unwrap() + "\n").unwrap();
        }
        let expected: Value = serde_json::from_slice(
            &fs::read(&path).unwrap_or_else(|e| panic!("missing snapshot {}: {e}", path.display())),
        )
        .unwrap();
        let diff = shape::equal(&expected, &actual);
        assert!(diff.is_empty(), "{id}: {diff:?}");
    }

    #[test]
    fn wire_shapes_match_the_snapshots() {
        let w = two_apps();
        w.write("home/Library/Caches/org.example/x", b"x");
        w.write("home/Library/Logs/x.log", b"x");
        let dup = dup_world();
        let root = dup.home.join("d");

        let clean_plan = clean(&w, &["user_caches", "user_logs"]);
        snapshot("storage.clean", &clean_plan);
        snapshot(
            "storage.duplicates",
            &find_duplicates_json(&root, 1).unwrap(),
        );
        let rm = dup
            .with_engine(|e| {
                plan_remove_duplicates_json(e, &dup.home, &root, &[root.join("small2")], 1)
            })
            .unwrap();
        snapshot("storage.duplicates.remove", &rm);
        let un = uninstall(&w, "com.example.foo").unwrap();
        snapshot("apps.uninstall", &un);
        let shown = w
            .with_engine(|e| get_plan_json(e, clean_plan["id"].as_str().unwrap()))
            .unwrap();
        snapshot("plan.show", &shown);
        snapshot("plan.confirm", &confirm(&w, &clean_plan).unwrap());
    }

    // ---- live probes (read-only; run by hand) ------------------------------

    /// Plans (never confirms) the uninstall of the app at `SYMCOCKPIT_LIVE_APP`
    /// with the real adapters, the real home folder (read only) and a plan
    /// store inside `SYMCOCKPIT_SANDBOX`. Prints counts, no paths.
    #[test]
    #[ignore = "reads the real home folder; needs SYMCOCKPIT_LIVE_APP and SYMCOCKPIT_SANDBOX"]
    fn live_uninstall_plan_is_read_only() {
        use symcockpit_core::plan::{SystemClock, user_uid};
        use symcockpit_macos::{apps::SystemApps, trash::SystemRemover};
        let app = std::env::var("SYMCOCKPIT_LIVE_APP").expect("SYMCOCKPIT_LIVE_APP");
        let sandbox =
            PathBuf::from(std::env::var("SYMCOCKPIT_SANDBOX").expect("SYMCOCKPIT_SANDBOX"));
        let home = PathBuf::from(std::env::var("HOME").unwrap());
        let _ = user_uid(&home).unwrap();
        let store = SqlitePlanStore::open(&sandbox.join("live-plans/cockpit.sqlite")).unwrap();
        let apps = SystemApps::new(&home);
        let remover = SystemRemover;
        let trash = FsAction::trash(&remover).with_running(&apps);
        let engine = Engine::new(&store, &SystemClock).register(&trash);
        let plan = plan_uninstall_app_json(&engine, &apps, &home, Path::new("/"), &app).unwrap();
        let mut per_category = std::collections::BTreeMap::<String, u64>::new();
        for i in plan["items"].as_array().unwrap() {
            *per_category
                .entry(i["category"].as_str().unwrap().to_owned())
                .or_default() += 1;
        }
        let helper = plan["items"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|i| i["requires_helper"] == true)
            .count();
        println!(
            "LIVE uninstall plan: state={} items={} per_category={per_category:?} requires_helper={helper} excluded={} team_id_found={} total_bytes={}",
            plan["state"],
            plan["item_count"],
            plan["excluded"].as_array().unwrap().len(),
            !plan["app"]["team_id"].is_null(),
            plan["total_bytes"],
        );
        assert_eq!(plan["state"], "pending");
    }
}
