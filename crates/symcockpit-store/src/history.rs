//! Reading `history.ndjson` (`CanonicalHistoryStore.read` in
//! `history/Sources/SymCockpitHistory/CanonicalHistory.swift`). The envelope is
//! `{"schema_version":1,"source","timestamp","action","payload":{...}}`; two
//! older flat shapes are migrated in memory. Unlike Swift this never creates
//! the file, its directory or the lock file.

use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

use serde_json::{Map, Value};

use crate::redact::redact;
use crate::state_perms::{self, Owner};

#[derive(Clone, Debug, PartialEq)]
pub struct HistoryRecord {
    pub source: String,
    pub timestamp: String,
    pub action: String,
    pub payload: Map<String, Value>,
}

const CURRENT_SCHEMA_VERSION: i64 = 1;

fn decode_record(line: &[u8]) -> Option<HistoryRecord> {
    let value: Value = serde_json::from_slice(line).ok()?;
    let object = value.as_object()?;
    let string = |key: &str| object.get(key)?.as_str().map(str::to_owned);
    if let (
        Some(version),
        Some(source),
        Some(timestamp),
        Some(action),
        Some(Value::Object(payload)),
    ) = (
        object.get("schema_version").and_then(Value::as_i64),
        string("source"),
        string("timestamp"),
        string("action"),
        object.get("payload"),
    ) && version <= CURRENT_SCHEMA_VERSION
    {
        return Some(HistoryRecord {
            source,
            timestamp,
            action,
            payload: payload.clone(),
        });
    }
    // Legacy flat event: the whole object is the payload.
    Some(HistoryRecord {
        source: "legacy".into(),
        timestamp: string("timestamp")?,
        action: string("action")?,
        payload: object.clone(),
    })
}

/// Decodable records in file order. `limit > 0` keeps the last `limit`;
/// zero, negative or `None` keeps all. Invalid lines are skipped. A missing
/// or unreadable file is an empty history.
pub fn read_history_records(path: &Path, limit: Option<i64>) -> Vec<HistoryRecord> {
    let Ok(bytes) = std::fs::read(path) else {
        return Vec::new();
    };
    let records: Vec<HistoryRecord> = bytes
        .split(|b| *b == b'\n')
        .filter(|line| !line.is_empty())
        .filter_map(decode_record)
        .collect();
    match limit {
        Some(n) if n > 0 => {
            let keep = usize::try_from(n).unwrap_or(usize::MAX);
            let skip = records.len().saturating_sub(keep);
            records.into_iter().skip(skip).collect()
        }
        _ => records,
    }
}

/// `CanonicalHistoryStore.isWritable`, minus the directory creation Swift does
/// first: when the file is absent, the nearest existing ancestor decides.
/// `test -w` is access(2) without `unsafe`; a failure to run it means "no".
pub fn history_writable(path: &Path) -> bool {
    let writable = |p: &Path| {
        std::process::Command::new("/bin/test")
            .arg("-w")
            .arg(p)
            .status()
            .is_ok_and(|s| s.success())
    };
    if path.exists() {
        return writable(path);
    }
    path.ancestors()
        .skip(1)
        .find(|a| a.exists())
        .is_some_and(writable)
}

/// Seconds since 1970 for `YYYY-MM-DDThh:mm:ss[.fff](Z|±hh:mm|±hhmm)`, the
/// strings the Swift `.iso8601` strategy accepts for history events.
pub fn parse_iso8601(text: &str) -> Option<f64> {
    let b = text.as_bytes();
    let num = |from: usize, len: usize| -> Option<i64> {
        let s = text.get(from..from + len)?;
        s.bytes()
            .all(|c| c.is_ascii_digit())
            .then(|| s.parse().ok())?
    };
    if b.len() < 20
        || b[4] != b'-'
        || b[7] != b'-'
        || b[10] != b'T'
        || b[13] != b':'
        || b[16] != b':'
    {
        return None;
    }
    let (y, mo, d, h, mi, s) = (
        num(0, 4)?,
        num(5, 2)?,
        num(8, 2)?,
        num(11, 2)?,
        num(14, 2)?,
        num(17, 2)?,
    );
    if !(1..=12).contains(&mo) || h > 23 || mi > 59 || s > 59 {
        return None;
    }
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let month_days = [
        31,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    if d < 1 || d > month_days[usize::try_from(mo - 1).ok()?] {
        return None;
    }
    let mut at = 19;
    let mut fraction = 0.0;
    if b[at] == b'.' {
        let start = at + 1;
        at = start;
        while at < b.len() && b[at].is_ascii_digit() {
            at += 1;
        }
        if at == start {
            return None;
        }
        fraction = format!("0.{}", &text[start..at]).parse().ok()?;
    }
    let offset = match text.get(at..)? {
        "Z" => 0,
        zone if zone.len() == 6 || zone.len() == 5 => {
            let sign = match zone.as_bytes()[0] {
                b'+' => 1,
                b'-' => -1,
                _ => return None,
            };
            let digits: String = zone[1..].chars().filter(|c| *c != ':').collect();
            if (zone.len() == 6) != zone.contains(':') || digits.len() != 4 {
                return None;
            }
            let (oh, om) = (
                digits[..2].parse::<i64>().ok()?,
                digits[2..].parse::<i64>().ok()?,
            );
            if oh > 23 || om > 59 {
                return None;
            }
            sign * (oh * 3600 + om * 60)
        }
        _ => return None,
    };
    // Days from civil date (Howard Hinnant's algorithm).
    let (yy, mm) = if mo <= 2 {
        (y - 1, mo + 9)
    } else {
        (y, mo - 3)
    };
    let era = yy.div_euclid(400);
    let yoe = yy - era * 400;
    let doy = (153 * mm + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some((days * 86_400 + h * 3600 + mi * 60 + s - offset) as f64 + fraction)
}

/// One tune write event, as `HistoryService.logEvent` records it.
#[derive(Clone, Debug, PartialEq)]
pub struct HistoryEvent {
    /// `yyyy-MM-ddTHH:mm:ssZ` (UTC), as Swift's `.iso8601` writes it.
    pub timestamp: String,
    pub action: String,
    pub requested_value: Option<f64>,
    pub clamped_value: Option<f64>,
    pub applied_value: Option<f64>,
    pub result: String,
    pub error_reason: Option<String>,
}

/// Events kept in the file (`CanonicalHistoryStore.maxEvents`).
const MAX_EVENTS: usize = 1000;

/// Swift's `JSONEncoder` writes 80.0 as `80`.
fn number(v: f64) -> Value {
    if v.fract() == 0.0 && v.abs() < 1e15 {
        Value::from(v as i64)
    } else {
        Value::from(v)
    }
}

/// The canonical line; every string passes `SecretRedactor` first
/// (`CanonicalHistoryEvent.redacted()`).
fn envelope(event: &HistoryEvent) -> String {
    let (timestamp, action) = (redact(&event.timestamp), redact(&event.action));
    let mut payload = Map::new();
    payload.insert("timestamp".into(), timestamp.clone().into());
    payload.insert("action".into(), action.clone().into());
    payload.insert("result".into(), redact(&event.result).into());
    for (key, value) in [
        ("requested_value", event.requested_value),
        ("clamped_value", event.clamped_value),
        ("applied_value", event.applied_value),
    ] {
        if let Some(v) = value {
            payload.insert(key.into(), number(v));
        }
    }
    if let Some(reason) = &event.error_reason {
        payload.insert("error_reason".into(), redact(reason).into());
    }
    // Keys sort alphabetically (serde_json's map is ordered), like Swift's `.sortedKeys`.
    serde_json::json!({
        "schema_version": CURRENT_SCHEMA_VERSION,
        "source": "tune",
        "timestamp": timestamp,
        "action": action,
        "payload": payload,
    })
    .to_string()
}

/// The one history writer (`CanonicalHistoryStore.append`): one NDJSON line
/// under an exclusive lock on `<file>.lock`, a torn last line repaired first,
/// the file trimmed to its newest `MAX_EVENTS`, directory 0700, files 0600
/// (handed to `owner` when a root process writes into a user's directory).
pub fn append_history_event(
    file: &Path,
    event: &HistoryEvent,
    owner: Option<Owner>,
) -> std::io::Result<()> {
    let dir = file
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    state_perms::ensure_directory(dir, owner)?;
    let mut lock_name = file.as_os_str().to_owned();
    lock_name.push(".lock");
    let lock_path = std::path::PathBuf::from(lock_name);
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(&lock_path)?;
    lock.lock()?;
    let result = {
        let mut contents = std::fs::read(file).unwrap_or_default();
        if contents.last().is_some_and(|b| *b != b'\n') {
            let tail_start = contents
                .iter()
                .rposition(|b| *b == b'\n')
                .map_or(0, |i| i + 1);
            if decode_record(&contents[tail_start..]).is_some() {
                contents.push(b'\n');
            } else {
                contents.truncate(tail_start);
            }
        }
        contents.extend_from_slice(envelope(event).as_bytes());
        contents.push(b'\n');
        let lines: Vec<&[u8]> = contents
            .split(|b| *b == b'\n')
            .filter(|l| !l.is_empty())
            .collect();
        if lines.len() > MAX_EVENTS {
            let mut trimmed = Vec::new();
            for line in &lines[lines.len() - MAX_EVENTS..] {
                trimmed.extend_from_slice(line);
                trimmed.push(b'\n');
            }
            contents = trimmed;
        }
        replace_atomic(file, &contents, owner)
    };
    let _ = state_perms::apply_file_permissions(&lock_path, owner);
    let _ = lock.unlock();
    result
}

/// Temp file next to `file` (0600), then `rename`, then the owner.
fn replace_atomic(file: &Path, bytes: &[u8], owner: Option<Owner>) -> std::io::Result<()> {
    let temp = file.with_file_name(format!(
        ".{}.{}.tmp",
        file.file_name()
            .map(|n| n.to_string_lossy())
            .unwrap_or_default(),
        std::process::id()
    ));
    let written = (|| {
        let mut out = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temp)?;
        out.write_all(bytes)?;
        out.sync_all()?;
        std::fs::rename(&temp, file)
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&temp);
        return written;
    }
    state_perms::apply_file_permissions(file, owner)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(dir: &Path, text: &str) -> std::path::PathBuf {
        let path = dir.join("history.ndjson");
        std::fs::write(&path, text).unwrap();
        path
    }

    const CANONICAL: &str = r#"{"action":"brightness.set","payload":{"action":"brightness.set","result":"success","timestamp":"2026-11-19T08:30:00Z"},"schema_version":1,"source":"tune","timestamp":"2026-11-19T08:30:00Z"}"#;

    #[test]
    fn reads_canonical_and_legacy_records_and_skips_garbage() {
        let tmp = tempfile::tempdir().unwrap();
        let text = format!(
            "{CANONICAL}\nnot json\n\n{{\"action\":\"old\",\"timestamp\":\"2026-11-18T07:00:00Z\",\"result\":\"success\"}}\n{{\"action\":\"x\",\"schema_version\":2,\"source\":\"tune\",\"timestamp\":\"t\",\"payload\":{{}}}}\n{{\"schema_version\":1}}\n[1]\n"
        );
        let records = read_history_records(&write(tmp.path(), &text), None);
        let sources: Vec<_> = records
            .iter()
            .map(|r| (r.source.as_str(), r.action.as_str()))
            .collect();
        // A newer schema version is read as a legacy flat object, like Swift.
        assert_eq!(
            sources,
            [
                ("tune", "brightness.set"),
                ("legacy", "old"),
                ("legacy", "x")
            ]
        );
        assert_eq!(records[1].payload["result"], "success");
    }

    #[test]
    fn limit_keeps_the_tail_and_non_positive_keeps_everything() {
        let tmp = tempfile::tempdir().unwrap();
        let line = |n: u32| format!("{{\"action\":\"a{n}\",\"timestamp\":\"t\"}}\n");
        let path = write(tmp.path(), &(1..=5).map(line).collect::<String>());
        let actions = |limit| {
            read_history_records(&path, limit)
                .into_iter()
                .map(|r| r.action)
                .collect::<Vec<_>>()
        };
        assert_eq!(actions(Some(2)), ["a4", "a5"]);
        assert_eq!(actions(Some(0)).len(), 5);
        assert_eq!(actions(Some(-3)).len(), 5);
        assert_eq!(actions(None).len(), 5);
        assert_eq!(actions(Some(99)).len(), 5);
        assert_eq!(actions(Some(i64::MAX)).len(), 5);
    }

    #[test]
    fn missing_file_is_an_empty_history_and_is_not_created() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("nope/history.ndjson");
        assert!(read_history_records(&path, None).is_empty());
        assert!(!path.exists() && !path.parent().unwrap().exists());
    }

    #[test]
    fn writable_follows_the_file_or_the_nearest_existing_directory() {
        let tmp = tempfile::tempdir().unwrap();
        assert!(history_writable(&tmp.path().join("a/b/history.ndjson")));
        let path = write(tmp.path(), "");
        assert!(history_writable(&path));
        let mut perms = std::fs::metadata(&path).unwrap().permissions();
        perms.set_readonly(true);
        std::fs::set_permissions(&path, perms).unwrap();
        assert!(!history_writable(&path));
        // `/` is not writable for the current user (or `test -w` is false for it).
        assert!(!history_writable(Path::new(
            "/nonexistent-root-dir/x/history.ndjson"
        )));
    }

    #[test]
    fn iso8601_accepts_z_offsets_and_fractions() {
        // 2001-01-01T00:00:00Z is 978307200 s after the Unix epoch.
        assert_eq!(parse_iso8601("2001-01-01T00:00:00Z"), Some(978_307_200.0));
        assert_eq!(parse_iso8601("2026-11-19T08:30:00Z"), Some(1_795_077_000.0));
        assert_eq!(
            parse_iso8601("2026-11-19T08:30:00+01:00"),
            Some(1_795_073_400.0)
        );
        assert_eq!(
            parse_iso8601("2026-11-19T08:30:00+0100"),
            Some(1_795_073_400.0)
        );
        assert_eq!(
            parse_iso8601("2026-11-19T08:30:00.25Z"),
            Some(1_795_077_000.25)
        );
        assert_eq!(parse_iso8601("2024-02-29T00:00:00Z"), Some(1_709_164_800.0));
        for bad in [
            "2026-11-19 08:30:00Z",
            "2026-11-19T08:30:00",
            "2026-13-01T00:00:00Z",
            "2025-02-29T00:00:00Z",
            "2026-11-19T24:00:00Z",
            "2026-11-19T08:30:00.Z",
            "2026-11-19T08:30:00+01:0",
            "",
            "x",
        ] {
            assert_eq!(parse_iso8601(bad), None, "{bad}");
        }
    }

    fn event(n: u32) -> HistoryEvent {
        HistoryEvent {
            timestamp: "2026-11-21T10:00:00Z".into(),
            action: format!("brightness.set.{n}"),
            requested_value: Some(2.0),
            clamped_value: Some(1.0),
            applied_value: None,
            result: "success".into(),
            error_reason: None,
        }
    }

    #[test]
    fn appended_events_read_back_as_canonical_records() {
        let tmp = tempfile::tempdir().unwrap();
        let file = tmp.path().join("data/history.ndjson");
        let mut failed = event(1);
        failed.error_reason = Some("boom".into());
        append_history_event(&file, &failed, None).unwrap();
        append_history_event(&file, &event(2), None).unwrap();
        let records = read_history_records(&file, None);
        assert_eq!(records.len(), 2);
        assert_eq!(
            (records[0].source.as_str(), records[0].action.as_str()),
            ("tune", "brightness.set.1")
        );
        assert_eq!(records[0].payload["error_reason"], "boom");
        assert_eq!(records[1].payload["requested_value"], 2.0);
        assert!(
            !records[1].payload.contains_key("applied_value"),
            "nil is omitted like Swift"
        );
        let line = std::fs::read_to_string(&file).unwrap();
        assert!(
            line.starts_with("{\"action\":\"brightness.set.1\",\"payload\":{"),
            "{line}"
        );
    }

    #[test]
    fn a_torn_last_line_is_repaired_and_the_file_is_trimmed() {
        let tmp = tempfile::tempdir().unwrap();
        let file = tmp.path().join("history.ndjson");
        std::fs::write(&file, b"{\"torn\":").unwrap();
        append_history_event(&file, &event(1), None).unwrap();
        assert_eq!(read_history_records(&file, None).len(), 1);
        let mut many = String::new();
        for n in 0..1000 {
            many.push_str(&envelope(&event(n)));
            many.push('\n');
        }
        std::fs::write(&file, many).unwrap();
        append_history_event(&file, &event(1000), None).unwrap();
        let records = read_history_records(&file, None);
        assert_eq!(records.len(), 1000);
        assert_eq!(records[0].action, "brightness.set.1");
        assert_eq!(records[999].action, "brightness.set.1000");
    }

    #[test]
    fn numbers_are_swift_numbers_and_strings_are_redacted() {
        let mut e = event(1);
        e.requested_value = Some(80.0);
        e.clamped_value = Some(0.5);
        e.error_reason = Some("denied, token=abcdefghijklmnop1234".into());
        let line = envelope(&e);
        assert!(line.contains("\"requested_value\":80,"), "{line}");
        assert!(line.contains("\"clamped_value\":0.5"), "{line}");
        assert!(
            line.contains("\"error_reason\":\"denied, <redacted>\""),
            "{line}"
        );
        assert!(!line.contains("abcdefghijklmnop"));
    }

    #[test]
    fn the_file_is_private_and_parallel_writers_lose_no_line() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        let file = tmp.path().join("data/history.ndjson");
        let threads: Vec<_> = (0..8)
            .map(|t| {
                let file = file.clone();
                std::thread::spawn(move || {
                    for n in 0..10 {
                        append_history_event(&file, &event(t * 10 + n), None).unwrap();
                    }
                })
            })
            .collect();
        for t in threads {
            t.join().unwrap();
        }
        assert_eq!(read_history_records(&file, None).len(), 80);
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(file.parent().unwrap()), 0o700);
        assert_eq!(mode(&file), 0o600);
    }
}
