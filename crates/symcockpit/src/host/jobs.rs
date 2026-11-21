//! Finder context-action jobs (R72, architecture 6.3), processed by the agent.
//!
//! The FinderSync extension writes `jobs/<uuid>.json` into the app group container; the app
//! starts the agent with that directory (`--finder-jobs-dir`). A thread looks at it once a
//! second, runs each valid job exactly once (`core::finder::Inbox` claims by hard link, expires
//! after 60 s, refuses duplicates) and writes `<uuid>.result.json`. File names are data: they
//! never reach a shell. Nothing here is reachable from the CLI, MCP or the protocol; the agent
//! only reports counts in `services`.
//!
//! shortcut: a one-second directory poll instead of kqueue/FSEvents, so an action takes up to
//! a second to start; upgrade when that is noticeable.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use serde_json::{Value, json};
use symcockpit_core::finder::{FinderPlatform, Inbox, JobReport, Runner};
use symcockpit_core::plan::{Clock, SystemClock};

use super::actor::{Actor, Service};

pub type MakePlatform = Arc<dyn Fn() -> Box<dyn FinderPlatform> + Send + Sync>;

pub const POLL: Duration = Duration::from_secs(1);
/// The sweep removes old results and leftovers; once a minute is plenty.
const SWEEP_EVERY: u64 = 60;

#[derive(Default)]
struct Counts {
    succeeded: AtomicU64,
    failed: AtomicU64,
    rejected: AtomicU64,
}

struct Jobs {
    inbox: Inbox,
    platform: Box<dyn FinderPlatform>,
    interval: Duration,
    ticks: u64,
    counts: Arc<Counts>,
}

pub enum Req {
    /// Process what is queued now (the poll does the same on its own).
    Drain,
}

impl Jobs {
    fn drain(&mut self) -> Vec<JobReport> {
        let now = SystemClock.now();
        let reports = self.inbox.process_pending(
            now,
            &Runner {
                platform: &*self.platform,
            },
        );
        for report in &reports {
            let counter = match report.state {
                "succeeded" => &self.counts.succeeded,
                "failed" => &self.counts.failed,
                _ => &self.counts.rejected,
            };
            counter.fetch_add(1, Ordering::Relaxed);
            // Names and counts only: paths in a log line would leak what the user clicked.
            eprintln!("symcockpit: finder job {}: {}", report.id, report.state);
        }
        reports
    }
}

impl Service for Jobs {
    type Req = Req;
    type Resp = usize;

    fn handle(&mut self, Req::Drain: Req) -> usize {
        self.drain().len()
    }

    fn wake_in(&self) -> Option<Duration> {
        Some(self.interval)
    }

    fn tick(&mut self) {
        self.drain();
        self.ticks += 1;
        let every = (Duration::from_secs(SWEEP_EVERY).as_millis()
            / self.interval.as_millis().max(1))
        .max(1) as u64;
        if self.ticks.is_multiple_of(every) {
            self.inbox.sweep(SystemClock.now());
        }
    }
}

pub struct JobsHandle {
    dir: PathBuf,
    actor: Actor<Jobs>,
    counts: Arc<Counts>,
}

impl JobsHandle {
    pub fn spawn(dir: PathBuf, make: MakePlatform, interval: Duration) -> Self {
        let counts = Arc::new(Counts::default());
        let (inbox_dir, shared) = (dir.clone(), Arc::clone(&counts));
        let actor = Actor::spawn("symcockpit-finder-jobs", move || Jobs {
            inbox: Inbox::new(inbox_dir),
            platform: make(),
            interval,
            ticks: 0,
            counts: shared,
        });
        Self { dir, actor, counts }
    }

    /// Processes the queue now and returns how many jobs were handled (tests, and `services`).
    pub fn drain(&self) -> usize {
        self.actor
            .request(Req::Drain, Duration::from_secs(30))
            .unwrap_or(0)
    }

    pub fn status(&self) -> Value {
        json!({
            "directory": self.dir,
            "succeeded": self.counts.succeeded.load(Ordering::Relaxed),
            "failed": self.counts.failed.load(Ordering::Relaxed),
            "rejected": self.counts.rejected.load(Ordering::Relaxed),
        })
    }

    pub fn stop(&self) {
        self.actor.stop();
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;
    use std::sync::Mutex;
    use std::time::Instant;

    use symcockpit_core::finder::{Action, Job, new_job_id};

    use super::*;

    #[derive(Clone, Default)]
    struct Recorder(Arc<Mutex<Vec<String>>>);

    impl FinderPlatform for Recorder {
        fn copy_text(&self, text: &str) -> Result<(), String> {
            self.0.lock().unwrap().push(format!("copy:{text}"));
            Ok(())
        }
        fn open_in_terminal(&self, dir: &Path) -> Result<(), String> {
            self.0
                .lock()
                .unwrap()
                .push(format!("terminal:{}", dir.display()));
            Ok(())
        }
    }

    fn job(action: Action, paths: &[&str], now: i64) -> Job {
        Job {
            id: new_job_id(),
            action,
            paths: paths.iter().map(|p| (*p).to_owned()).collect(),
            created_at: now,
            expires_at: now + 60,
        }
    }

    fn handle(dir: &Path, rec: &Recorder, interval: Duration) -> JobsHandle {
        let rec = rec.clone();
        JobsHandle::spawn(
            dir.to_path_buf(),
            Arc::new(move || Box::new(rec.clone())),
            interval,
        )
    }

    fn wait_for(what: &str, check: impl Fn() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !check() {
            assert!(Instant::now() < deadline, "timed out waiting for: {what}");
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn a_queued_job_runs_once_and_leaves_a_result_file() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("jobs");
        let inbox = Inbox::new(&dir);
        let rec = Recorder::default();
        let jobs = handle(&dir, &rec, Duration::from_millis(5));
        let j = job(
            Action::CopyPath,
            &["/a/with space", "/b/$(touch x)"],
            SystemClock.now(),
        );
        inbox.submit(&j).unwrap();
        wait_for("the job's result", || inbox.result(&j.id).is_some());
        let result = inbox.result(&j.id).unwrap();
        assert_eq!(result["state"], "succeeded");
        // File names are data: the paths arrive untouched, one per line.
        assert_eq!(
            *rec.0.lock().unwrap(),
            ["copy:/a/with space\n/b/$(touch x)"]
        );
        // The counter is bumped just after the result file appears: wait for it, don't race it.
        wait_for("the succeeded counter", || jobs.status()["succeeded"] == 1);
        jobs.stop();
    }

    #[test]
    fn a_replayed_expired_or_malformed_job_does_not_run() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("jobs");
        let inbox = Inbox::new(&dir);
        let rec = Recorder::default();
        // A long interval: the test drives the processing itself, deterministically.
        let jobs = handle(&dir, &rec, Duration::from_secs(3600));
        let now = SystemClock.now();
        let expired = job(Action::CopyPath, &["/x"], now - 3600);
        inbox.submit(&expired).unwrap();
        std::fs::write(dir.join(format!("{}.json", new_job_id())), b"{not json").unwrap();
        assert_eq!(jobs.drain(), 2);
        assert!(rec.0.lock().unwrap().is_empty());
        assert_eq!(inbox.result(&expired.id).unwrap()["state"], "rejected");
        assert_eq!(jobs.status()["rejected"], 2);
        // The same id again: the original result stays, nothing runs.
        let ok = job(Action::OpenInTerminal, &[tmp.path().to_str().unwrap()], now);
        inbox.submit(&ok).unwrap();
        assert_eq!(jobs.drain(), 1);
        assert!(
            inbox.submit(&ok).is_ok(),
            "the queue file is gone, the result stays"
        );
        assert_eq!(jobs.drain(), 1);
        assert_eq!(
            rec.0.lock().unwrap().len(),
            1,
            "the replay did not run again"
        );
        assert_eq!(inbox.result(&ok.id).unwrap()["state"], "succeeded");
        jobs.stop();
    }

    #[test]
    fn a_missing_directory_is_not_an_error_and_not_created() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("never-made");
        let jobs = handle(&dir, &Recorder::default(), Duration::from_secs(3600));
        assert_eq!(jobs.drain(), 0);
        assert!(!dir.exists());
        jobs.stop();
    }
}
