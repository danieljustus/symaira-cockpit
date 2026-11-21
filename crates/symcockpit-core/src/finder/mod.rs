//! Finder context actions (R72, architecture 6.3 and trust boundary 4).
//!
//! The FinderSync extension writes a job file `jobs/<uuid>.json` into the app group container;
//! the app agent validates it, runs it once and writes `jobs/<uuid>.result.json`. Everything
//! here is `human_only`. File names are data throughout: they travel as JSON strings and
//! argument-list entries, never through a shell.

mod actions;
mod inbox;
mod job;

pub use actions::{Executor, FinderPlatform, Runner, new_file_in};
pub use inbox::{Inbox, JobReport, RESULT_KEEP_SECS};
pub use job::{Action, Job, Reject, new_job_id, parse_job};

/// The jobs directory inside the app group container (macOS: `~/Library/Group Containers/<group>/jobs`).
pub fn jobs_dir(home: &std::path::Path, app_group: &str) -> std::path::PathBuf {
    home.join("Library/Group Containers")
        .join(app_group)
        .join("jobs")
}

#[cfg(test)]
mod tests;
