//! `symcockpit version [--json] [--no-update-check]` (also `--version`, `-V`): the version
//! and the one release check of `CockpitUpdatePolicy` / `checkForCockpitUpdateIfEnabled`
//! of v0.12. A check runs only on a terminal or when `SYMCOCKPIT_CHECK_UPDATES` asks for
//! it, and never against an opt-out; the answer is cached for a day in the user's Caches
//! directory, in corekit's file, so v0.12 and this binary share it.

use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::json;
use symcockpit_core::update_check::{self, Report};

use crate::VERSION;
use crate::app::App;
use crate::cli::Outcome;
use crate::json;

const UPDATE_ENV: &str = "SYMCOCKPIT_CHECK_UPDATES";
const TUNE_ENV: &str = "SYMTUNE_CHECK_UPDATES";

fn now_unix() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

fn report(app: &App, args: &[String]) -> Report {
    let env = |key: &str| app.env.get(key).map(String::as_str);
    let config = std::fs::read_to_string(app.paths.config_file()).ok();
    let wanted = update_check::should_check(
        args.iter().any(|a| a == "--no-update-check"),
        app.services.stdout_is_terminal,
        env(UPDATE_ENV),
        env(TUNE_ENV),
        config.as_deref(),
    );
    if !wanted {
        return Report::Skipped;
    }
    let cache_file = app
        .paths
        .home
        .join("Library/Caches")
        .join(update_check::cache_file_name());
    let cached = std::fs::read(&cache_file).ok();
    let (report, store) = update_check::check(VERSION, now_unix(), cached.as_deref(), || {
        app.services.release_source.latest()
    });
    if let Some(bytes) = store {
        // A cache that cannot be written only costs the next call a request.
        if let Some(dir) = cache_file.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let _ = std::fs::write(&cache_file, bytes);
    }
    report
}

pub fn outcome(app: &App, args: &[String]) -> Outcome {
    let report = report(app, args);
    let stdout = if args.iter().any(|a| a == "--json") {
        // Cockpit ships no sub-families, so `families` is empty.
        let document = json!({
            "tool": "symcockpit", "version": VERSION, "schema_version": 1,
            "families": [], "update": report.to_json(),
        });
        format!("{}\n", json::pretty(&document))
    } else {
        format!("symcockpit {VERSION}{}\n", report.text_suffix())
    };
    Outcome {
        stdout,
        ..Outcome::default()
    }
}
