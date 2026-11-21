//! The jobs directory: atomic submit, exclusive claim, one result per job.
//!
//! Claiming is `hard_link(<id>.json, <id>.claimed)`: it fails when the target exists, so of any
//! number of consumers exactly one runs a job, and a replay of a running or finished id is
//! refused. The price is at-most-once: a consumer that dies mid-job leaves a `.claimed` file
//! that the sweep removes without running it again.

use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    path::{Path, PathBuf},
    time::UNIX_EPOCH,
};

use serde_json::{Value, json};
use symcockpit_contract::{
    Error,
    areas::finder::{JOB_TTL_SECS, JOB_VERSION},
};

use super::{
    actions::Executor,
    job::{Job, MAX_JOB_BYTES, Reject, is_job_id, parse_job},
};

/// Results stay readable this long (longer than a job's lifetime, so a replay is still a duplicate).
pub const RESULT_KEEP_SECS: i64 = 5 * 60;
const STRAY_SECS: i64 = 2 * JOB_TTL_SECS;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct JobReport {
    pub id: String,
    /// `succeeded`, `failed` or `rejected`.
    pub state: &'static str,
    pub detail: String,
}

pub struct Inbox {
    dir: PathBuf,
}

fn failed(what: &str, e: impl std::fmt::Display) -> Error {
    Error::Failed(format!("finder jobs: {what}: {e}"))
}

/// Writes `bytes` to a hidden temp file, then links it into place without replacing anything.
fn publish_new(dir: &Path, name: &str, bytes: &[u8]) -> io::Result<()> {
    let tmp = dir.join(format!(".{name}.tmp"));
    let mut f = OpenOptions::new().write(true).create_new(true).open(&tmp)?;
    f.write_all(bytes)?;
    f.sync_all()?;
    let linked = fs::hard_link(&tmp, dir.join(name));
    let _ = fs::remove_file(&tmp);
    linked
}

impl Inbox {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self { dir: dir.into() }
    }

    /// Queues a job the way the extension does. A job with an existing id is refused.
    pub fn submit(&self, job: &Job) -> Result<(), Error> {
        fs::create_dir_all(&self.dir).map_err(|e| failed("create dir", e))?;
        let body = json!({
            "version": JOB_VERSION, "id": job.id, "action": job.action.id(), "paths": job.paths,
            "created_at": job.created_at, "expires_at": job.expires_at,
        });
        publish_new(
            &self.dir,
            &format!("{}.json", job.id),
            body.to_string().as_bytes(),
        )
        .map_err(|e| {
            if e.kind() == io::ErrorKind::AlreadyExists {
                Error::Failed(Reject::Duplicate.to_string())
            } else {
                failed("submit", e)
            }
        })
    }

    pub fn result(&self, id: &str) -> Option<Value> {
        if !is_job_id(id) {
            return None;
        }
        serde_json::from_slice(&fs::read(self.dir.join(format!("{id}.result.json"))).ok()?).ok()
    }

    fn write_result(&self, id: &str, state: &str, detail: &str, now: i64) {
        let body = json!({
            "version": JOB_VERSION, "id": id, "state": state, "detail": detail, "finished_at": now,
        });
        // A result that cannot be written leaves the job without an answer; nothing else to do.
        let _ = publish_new(
            &self.dir,
            &format!("{id}.result.json"),
            body.to_string().as_bytes(),
        );
    }

    /// Handles every queued job once. Safe to call from several threads or processes at once.
    pub fn process_pending(&self, now: i64, exec: &dyn Executor) -> Vec<JobReport> {
        let Ok(entries) = fs::read_dir(&self.dir) else {
            return Vec::new();
        };
        let mut ids: Vec<String> = entries
            .filter_map(Result::ok)
            .filter_map(|e| {
                let name = e.file_name().into_string().ok()?;
                let id = name.strip_suffix(".json")?;
                is_job_id(id).then(|| id.to_owned())
            })
            .collect();
        ids.sort();
        ids.iter()
            .filter_map(|id| self.handle(id, now, exec))
            .collect()
    }

    fn handle(&self, id: &str, now: i64, exec: &dyn Executor) -> Option<JobReport> {
        let queued = self.dir.join(format!("{id}.json"));
        let claimed = self.dir.join(format!("{id}.claimed"));
        // Exclusive claim: only one caller gets past this line for a given id.
        fs::hard_link(&queued, &claimed).ok()?;
        let _ = fs::remove_file(&queued);
        let report = |state, detail: String| JobReport {
            id: id.to_owned(),
            state,
            detail,
        };
        let outcome = (|| {
            if self.dir.join(format!("{id}.result.json")).exists() {
                return Err(Reject::Duplicate);
            }
            let mut bytes = Vec::new();
            File::open(&claimed)
                .and_then(|f| f.take(MAX_JOB_BYTES as u64 + 1).read_to_end(&mut bytes))
                .map_err(|e| Reject::Malformed(e.to_string()))?;
            parse_job(id, &bytes, now)
        })();
        let result = match outcome {
            Ok(job) => match exec.run(&job) {
                Ok(detail) => {
                    self.write_result(id, "succeeded", &detail, now);
                    report("succeeded", detail)
                }
                Err(detail) => {
                    self.write_result(id, "failed", &detail, now);
                    report("failed", detail)
                }
            },
            // A duplicate keeps the original result untouched.
            Err(Reject::Duplicate) => report("rejected", Reject::Duplicate.to_string()),
            Err(reject) => {
                self.write_result(id, "rejected", &reject.to_string(), now);
                report("rejected", reject.to_string())
            }
        };
        let _ = fs::remove_file(&claimed);
        Some(result)
    }

    /// Removes what is no longer useful: old results, and leftovers of crashed writers or consumers.
    pub fn sweep(&self, now: i64) {
        let Ok(entries) = fs::read_dir(&self.dir) else {
            return;
        };
        for e in entries.filter_map(Result::ok) {
            let Ok(name) = e.file_name().into_string() else {
                continue;
            };
            let age = e
                .metadata()
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map_or(0, |d| now - d.as_secs() as i64);
            let limit = if name.ends_with(".result.json") {
                RESULT_KEEP_SECS
            } else if name.ends_with(".json") || name.ends_with(".claimed") || name.starts_with('.')
            {
                STRAY_SECS
            } else {
                continue;
            };
            if age > limit {
                let _ = fs::remove_file(e.path());
            }
        }
    }
}
