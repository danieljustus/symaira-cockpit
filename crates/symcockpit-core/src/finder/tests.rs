use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    thread,
};

use tempfile::TempDir;

use super::*;

const NOW: i64 = 1_800_000_000;

fn job(action: Action, paths: &[&str], created: i64) -> Job {
    Job {
        id: new_job_id(),
        action,
        paths: paths.iter().map(|p| (*p).to_owned()).collect(),
        created_at: created,
        expires_at: created + 60,
    }
}

/// Port fake: records what the platform would have done.
#[derive(Default)]
struct FakePlatform {
    copied: Mutex<Vec<String>>,
    terminals: Mutex<Vec<PathBuf>>,
}

impl FinderPlatform for FakePlatform {
    fn copy_text(&self, text: &str) -> Result<(), String> {
        self.copied.lock().unwrap().push(text.to_owned());
        Ok(())
    }
    fn open_in_terminal(&self, dir: &Path) -> Result<(), String> {
        self.terminals.lock().unwrap().push(dir.to_path_buf());
        Ok(())
    }
}

/// Counts how often each job id ran.
#[derive(Default)]
struct Counting(Mutex<HashMap<String, u32>>);

impl Executor for Counting {
    fn run(&self, job: &Job) -> Result<String, String> {
        *self.0.lock().unwrap().entry(job.id.clone()).or_default() += 1;
        thread::yield_now();
        Ok("ran".into())
    }
}

fn listing(dir: &Path) -> Vec<String> {
    let mut v: Vec<String> = fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    v.sort();
    v
}

fn epoch_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}

#[test]
fn a_job_runs_once_and_leaves_one_succeeded_result() {
    let d = TempDir::new().unwrap();
    let inbox = Inbox::new(d.path().join("jobs"));
    let platform = FakePlatform::default();
    let j = job(Action::CopyPath, &["/tmp/x"], NOW);
    inbox.submit(&j).unwrap();
    let reports = inbox.process_pending(
        NOW,
        &Runner {
            platform: &platform,
        },
    );
    assert_eq!(reports.len(), 1);
    assert_eq!(reports[0].state, "succeeded");
    assert_eq!(*platform.copied.lock().unwrap(), ["/tmp/x"]);
    let r = inbox.result(&j.id).unwrap();
    assert_eq!(r["state"], "succeeded");
    assert_eq!(r["id"], j.id.as_str());
    assert_eq!(
        listing(&d.path().join("jobs")),
        [format!("{}.result.json", j.id)]
    );
}

#[test]
fn a_replayed_job_is_rejected_and_the_original_result_survives() {
    let d = TempDir::new().unwrap();
    let inbox = Inbox::new(d.path());
    let counting = Counting::default();
    let j = job(Action::CopyPath, &["/tmp/x"], NOW);
    inbox.submit(&j).unwrap();
    assert_eq!(inbox.process_pending(NOW, &counting)[0].state, "succeeded");
    let before = fs::read(d.path().join(format!("{}.result.json", j.id))).unwrap();
    inbox.submit(&j).unwrap(); // the id is free again once the job file was consumed
    let again = inbox.process_pending(NOW + 1, &counting);
    assert_eq!(
        (again[0].state, again[0].detail.as_str()),
        ("rejected", "duplicate job")
    );
    assert_eq!(counting.0.lock().unwrap()[&j.id], 1, "ran exactly once");
    assert_eq!(
        fs::read(d.path().join(format!("{}.result.json", j.id))).unwrap(),
        before
    );
}

#[test]
fn queueing_an_id_that_is_still_queued_is_refused() {
    let d = TempDir::new().unwrap();
    let inbox = Inbox::new(d.path());
    let j = job(Action::CopyPath, &["/tmp/x"], NOW);
    inbox.submit(&j).unwrap();
    assert!(
        inbox
            .submit(&j)
            .unwrap_err()
            .to_string()
            .contains("duplicate")
    );
}

#[test]
fn an_expired_job_is_rejected_with_a_result_and_never_runs() {
    let d = TempDir::new().unwrap();
    let inbox = Inbox::new(d.path());
    let counting = Counting::default();
    let j = job(Action::CopyPath, &["/tmp/x"], NOW);
    inbox.submit(&j).unwrap();
    let reports = inbox.process_pending(NOW + 61, &counting);
    assert_eq!(
        (reports[0].state, reports[0].detail.as_str()),
        ("rejected", "job expired")
    );
    assert!(counting.0.lock().unwrap().is_empty());
    assert_eq!(inbox.result(&j.id).unwrap()["state"], "rejected");
}

#[test]
fn malformed_and_foreign_files_never_reach_an_action() {
    let d = TempDir::new().unwrap();
    let inbox = Inbox::new(d.path());
    let counting = Counting::default();
    let id = new_job_id();
    fs::write(
        d.path().join(format!("{id}.json")),
        b"{\"version\":1,\"action\":\"x\"",
    )
    .unwrap();
    for stray in [
        "notes.json",
        "..json",
        "x.claimed",
        "A0B9D7C1-4F4A-4D6E-9A0F-1C2D3E4F5A6B.json",
    ] {
        fs::write(d.path().join(stray), b"{}").unwrap();
    }
    fs::create_dir(d.path().join(format!("{}.json", new_job_id()))).unwrap();
    let reports = inbox.process_pending(NOW, &counting);
    assert!(reports.iter().all(|r| r.state == "rejected"), "{reports:?}");
    // A directory named like a job cannot be claimed (no hard link to a directory): left alone.
    assert_eq!(reports.len(), 1, "{reports:?}");
    assert!(counting.0.lock().unwrap().is_empty());
    assert_eq!(inbox.result(&id).unwrap()["state"], "rejected");
}

#[test]
fn file_names_are_data_never_a_command_line() {
    let d = TempDir::new().unwrap();
    let nasty = d
        .path()
        .join(r#"a b; echo hi > pwned $(touch pwned) `x` "q" 'r' -n *"#);
    fs::create_dir(&nasty).unwrap();
    let nasty = nasty.to_str().unwrap().to_owned();
    let platform = FakePlatform::default();
    let runner = Runner {
        platform: &platform,
    };
    let inbox = Inbox::new(d.path().join("jobs"));
    for action in [Action::CopyPath, Action::NewFile, Action::OpenInTerminal] {
        inbox.submit(&job(action, &[&nasty], NOW)).unwrap();
    }
    let reports = inbox.process_pending(NOW, &runner);
    assert!(
        reports.iter().all(|r| r.state == "succeeded"),
        "{reports:?}"
    );
    assert_eq!(
        *platform.copied.lock().unwrap(),
        std::slice::from_ref(&nasty)
    );
    assert_eq!(*platform.terminals.lock().unwrap(), [PathBuf::from(&nasty)]);
    assert!(Path::new(&nasty).join("untitled.txt").exists());
    assert!(!d.path().join("pwned").exists() && !Path::new(&nasty).join("pwned").exists());
}

#[test]
fn new_file_never_overwrites_and_files_use_their_parent_folder() {
    let d = TempDir::new().unwrap();
    fs::write(d.path().join("untitled.txt"), b"keep me").unwrap();
    let made = new_file_in(d.path()).unwrap();
    assert_eq!(made.file_name().unwrap(), "untitled 2.txt");
    assert_eq!(fs::read(d.path().join("untitled.txt")).unwrap(), b"keep me");
    let platform = FakePlatform::default();
    let file = d.path().join("untitled.txt");
    let inbox = Inbox::new(d.path().join("jobs"));
    inbox
        .submit(&job(Action::OpenInTerminal, &[file.to_str().unwrap()], NOW))
        .unwrap();
    inbox.process_pending(
        NOW,
        &Runner {
            platform: &platform,
        },
    );
    assert_eq!(
        *platform.terminals.lock().unwrap(),
        [d.path().to_path_buf()]
    );
}

/// R72: two actions at once are neither lost nor run twice, with writers and consumers racing.
#[test]
fn concurrent_jobs_are_neither_lost_nor_run_twice() {
    for (writers, per_writer, consumers) in [(2, 1, 3), (2, 25, 4)] {
        let d = TempDir::new().unwrap();
        let dir = d.path().join("jobs");
        fs::create_dir_all(&dir).unwrap();
        let counting = Arc::new(Counting::default());
        let ids = Arc::new(Mutex::new(Vec::new()));
        let writers_done = Arc::new(AtomicUsize::new(0));
        let mut handles = Vec::new();
        for _ in 0..writers {
            let (dir, ids, done) = (dir.clone(), ids.clone(), writers_done.clone());
            handles.push(thread::spawn(move || {
                let inbox = Inbox::new(dir);
                for _ in 0..per_writer {
                    let j = job(Action::CopyPath, &["/tmp/x"], NOW);
                    inbox.submit(&j).unwrap();
                    ids.lock().unwrap().push(j.id);
                }
                done.fetch_add(1, Ordering::SeqCst);
            }));
        }
        for _ in 0..consumers {
            let (dir, counting, done) = (dir.clone(), counting.clone(), writers_done.clone());
            handles.push(thread::spawn(move || {
                let inbox = Inbox::new(dir);
                // Poll until the writers are finished, plus one last pass that sees everything.
                loop {
                    let finished = done.load(Ordering::SeqCst) == writers;
                    inbox.process_pending(NOW, &*counting);
                    if finished {
                        break;
                    }
                }
            }));
        }
        for h in handles {
            h.join().unwrap();
        }
        let ids = ids.lock().unwrap();
        assert_eq!(ids.len(), writers * per_writer);
        let counts = counting.0.lock().unwrap();
        let inbox = Inbox::new(&dir);
        for id in ids.iter() {
            assert_eq!(counts.get(id), Some(&1), "job {id} must run exactly once");
            assert_eq!(inbox.result(id).unwrap()["state"], "succeeded");
        }
        assert_eq!(counts.len(), ids.len());
    }
}

#[test]
fn sweep_removes_old_results_and_leftovers_but_not_fresh_files() {
    let d = TempDir::new().unwrap();
    let inbox = Inbox::new(d.path());
    let real_now = epoch_now();
    let j = job(Action::CopyPath, &["/tmp/x"], real_now);
    inbox.submit(&j).unwrap();
    inbox.process_pending(real_now, &Counting::default());
    let id2 = new_job_id();
    fs::write(d.path().join(format!("{id2}.claimed")), b"{}").unwrap(); // a consumer that died
    fs::write(d.path().join(".half.tmp"), b"{").unwrap();
    inbox.sweep(real_now);
    assert_eq!(
        fs::read_dir(d.path()).unwrap().count(),
        3,
        "everything is fresh"
    );
    inbox.sweep(real_now + 130);
    assert_eq!(
        fs::read_dir(d.path()).unwrap().count(),
        1,
        "leftovers gone, result kept"
    );
    inbox.sweep(real_now + RESULT_KEEP_SECS + 5);
    assert_eq!(fs::read_dir(d.path()).unwrap().count(), 0);
}

#[test]
fn the_menu_in_the_extension_names_exactly_the_allowed_actions() {
    use symcockpit_contract::areas::finder::{ACTIONS, JOB_TTL_SECS, JOB_VERSION};
    let swift = include_str!("../../../../extensions/findersync/FinderSync.swift");
    let mut ids: Vec<&str> = swift
        .lines()
        .map(str::trim)
        .filter(|l| l.starts_with("(\"") && l.contains("\", \""))
        .filter_map(|l| l[2..].split('"').next())
        .collect();
    ids.sort_unstable();
    let mut allowed = ACTIONS.to_vec();
    allowed.sort_unstable();
    assert_eq!(ids, allowed);
    // The writer's schema constants must equal the reader's.
    assert!(swift.contains(&format!("jobVersion = {JOB_VERSION}")));
    assert!(swift.contains(&format!("lifetime: TimeInterval = {JOB_TTL_SECS}")));
}
