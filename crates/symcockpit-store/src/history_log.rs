//! Appending one tune event to `history.ndjson` in the canonical envelope
//! (`CanonicalHistoryStore.append` + `HistoryService.logEvent` of v0.12):
//! `{"action","payload":{...},"schema_version":1,"source":"tune","timestamp"}`,
//! keys sorted, one line, file mode 0600, directory 0700.
//!
//! shortcut: one `O_APPEND` write of a short line instead of v0.12's
//! flock + torn-tail recovery + 10 000-line trim, and no secret redaction —
//! the `error_reason` of these writers is always one of our own fixed error
//! texts. Move to a shared locked writer when the history area is ported.

use std::fs::OpenOptions;
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

use serde_json::{Map, Value, json};

use crate::state_perms::{self, Owner};

pub const FILE_NAME: &str = "history.ndjson";

/// One tune event; `None` fields are left out like Swift's `encodeIfPresent`.
pub struct Event<'a> {
    pub timestamp: &'a str,
    pub action: &'a str,
    pub requested: Option<f64>,
    pub clamped: Option<f64>,
    pub applied: Option<f64>,
    pub result: &'a str,
    pub error_reason: Option<&'a str>,
}

fn line(event: &Event) -> String {
    let mut payload = Map::new();
    payload.insert("action".into(), json!(event.action));
    payload.insert("result".into(), json!(event.result));
    payload.insert("timestamp".into(), json!(event.timestamp));
    for (key, value) in [
        ("requested_value", event.requested),
        ("clamped_value", event.clamped),
        ("applied_value", event.applied),
    ] {
        if let Some(v) = value {
            // Swift's JSONEncoder writes 80.0 as `80`.
            let number = if v.fract() == 0.0 && v.abs() < 1e15 {
                json!(v as i64)
            } else {
                json!(v)
            };
            payload.insert(key.into(), number);
        }
    }
    if let Some(reason) = event.error_reason {
        payload.insert("error_reason".into(), json!(reason));
    }
    // serde_json's map is ordered by key (BTreeMap), matching `.sortedKeys`.
    let envelope = json!({
        "action": event.action,
        "payload": Value::Object(payload),
        "schema_version": 1,
        "source": "tune",
        "timestamp": event.timestamp,
    });
    format!("{envelope}\n")
}

/// Append `event`; the caller prints a failure as a warning and goes on, as
/// `HistoryService.logEvent` does.
pub fn append(data_dir: &Path, owner: Option<Owner>, event: &Event) -> io::Result<()> {
    state_perms::ensure_directory(data_dir, owner)?;
    let file = data_dir.join(FILE_NAME);
    let mut handle = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(&file)?;
    handle.write_all(line(event).as_bytes())?;
    drop(handle);
    state_perms::apply_file_permissions(&file, owner)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    fn event<'a>(result: &'a str, reason: Option<&'a str>) -> Event<'a> {
        Event {
            timestamp: "2026-11-21T10:00:00Z",
            action: "fan.set",
            requested: Some(0.5),
            clamped: Some(0.5),
            applied: reason.is_none().then_some(0.5),
            result,
            error_reason: reason,
        }
    }

    #[test]
    fn the_line_is_the_canonical_envelope_with_sorted_keys() {
        assert_eq!(
            line(&event("success", None)),
            "{\"action\":\"fan.set\",\"payload\":{\"action\":\"fan.set\",\"applied_value\":0.5,\"clamped_value\":0.5,\"requested_value\":0.5,\"result\":\"success\",\"timestamp\":\"2026-11-21T10:00:00Z\"},\"schema_version\":1,\"source\":\"tune\",\"timestamp\":\"2026-11-21T10:00:00Z\"}\n"
        );
        let whole = Event {
            requested: Some(80.0),
            ..event("success", None)
        };
        assert!(line(&whole).contains("\"requested_value\":80,"));
        let failed = line(&event("failed", Some("SMC rejected manual mode for fan 0")));
        assert!(failed.contains("\"error_reason\":\"SMC rejected manual mode for fan 0\""));
        assert!(!failed.contains("applied_value"));
    }

    #[test]
    fn appends_lines_privately_and_the_reader_decodes_them() {
        let dir = tempfile::tempdir().unwrap();
        let data = dir.path().join("data");
        append(&data, None, &event("success", None)).unwrap();
        append(&data, None, &event("failed", Some("nope"))).unwrap();
        let records = crate::history::read_history_records(&data.join(FILE_NAME), None);
        assert_eq!(records.len(), 2);
        assert_eq!(records[0].source, "tune");
        assert_eq!(records[1].payload["result"], "failed");
        use std::os::unix::fs::PermissionsExt;
        let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&data), 0o700);
        assert_eq!(mode(&data.join(FILE_NAME)), 0o600);
    }
}
