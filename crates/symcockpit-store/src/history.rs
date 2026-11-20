//! Reading `history.ndjson` (`CanonicalHistoryStore.read` in
//! `history/Sources/SymCockpitHistory/CanonicalHistory.swift`). The envelope is
//! `{"schema_version":1,"source","timestamp","action","payload":{...}}`; two
//! older flat shapes are migrated in memory. Unlike Swift this never creates
//! the file, its directory or the lock file.

use std::path::Path;

use serde_json::{Map, Value};

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
}
