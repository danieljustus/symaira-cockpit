//! `history` / MCP `get_history`: the write-operations log, read from
//! `history.ndjson` (`HistoryService.readEvents`, `HistoryOptions.swift`).

use std::path::Path;

use serde_json::{Map, Value, json};
use symcockpit_contract::Error;
use symcockpit_store::{HistoryRecord, parse_iso8601, read_history_records};

use crate::ai_usage::REFERENCE_DATE_OFFSET;

pub const HELP: &str = "Usage: symcockpit history [--json] [--limit N | -n N]\nShow recorded write operations. Default limit: 100 events.\n--json prints structured events instead of the text table.\n";

pub const DEFAULT_LIMIT: i64 = 100;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Options {
    pub json: bool,
    pub limit: i64,
}

/// `history [--json] [--limit N | -n N]`; the caller handles `--help` first.
pub fn parse_options(args: &[String]) -> Result<Options, Error> {
    let mut options = Options {
        json: false,
        limit: DEFAULT_LIMIT,
    };
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--json" => options.json = true,
            "--limit" | "-n" => {
                i += 1;
                options.limit = args.get(i).and_then(|v| v.parse().ok()).ok_or_else(|| {
                    Error::Usage("history: --limit requires an integer value".into())
                })?;
            }
            other => return Err(Error::Usage(format!("history: unknown option '{other}'"))),
        }
        i += 1;
    }
    Ok(options)
}

#[derive(Clone, Debug, PartialEq)]
pub struct Event {
    /// Seconds since 2001-01-01, how the Swift CLI encodes a `Date`.
    pub timestamp: f64,
    pub action: String,
    pub requested_value: Option<f64>,
    pub clamped_value: Option<f64>,
    pub applied_value: Option<f64>,
    pub result: String,
    pub error_reason: Option<String>,
}

/// `Some(None)` is absent or null; `None` is a wrong type. Swift's
/// `convertFromSnakeCase` also accepts the camelCase spelling.
fn field<'a>(
    payload: &'a Map<String, Value>,
    snake: &str,
    camel: &str,
) -> Option<Option<&'a Value>> {
    match payload.get(snake).or_else(|| payload.get(camel)) {
        None | Some(Value::Null) => Some(None),
        Some(v) => Some(Some(v)),
    }
}

fn decode_event(payload: &Map<String, Value>) -> Option<Event> {
    let required = |key: &str| payload.get(key)?.as_str().map(str::to_owned);
    let number = |snake: &str, camel: &str| -> Option<Option<f64>> {
        field(payload, snake, camel)?
            .map(|v| v.as_f64())
            .map_or(Some(None), |n| n.map(Some))
    };
    Some(Event {
        timestamp: parse_iso8601(payload.get("timestamp")?.as_str()?)? - REFERENCE_DATE_OFFSET,
        action: required("action")?,
        requested_value: number("requested_value", "requestedValue")?,
        clamped_value: number("clamped_value", "clampedValue")?,
        applied_value: number("applied_value", "appliedValue")?,
        result: required("result")?,
        error_reason: match field(payload, "error_reason", "errorReason")? {
            None => None,
            Some(v) => Some(v.as_str()?.to_owned()),
        },
    })
}

/// The newest `limit` records (all when `limit <= 0`), decoded as events.
/// The limit applies to records first, so a skipped undecodable record still
/// uses up a slot, exactly like `HistoryService.readEvents`.
pub fn read_events(path: &Path, limit: i64) -> Vec<Event> {
    read_history_records(path, Some(limit))
        .iter()
        .filter_map(|r: &HistoryRecord| decode_event(&r.payload))
        .collect()
}

pub fn events_json(events: &[Event]) -> Value {
    events
        .iter()
        .map(|e| {
            let mut o = Map::new();
            o.insert("action".into(), json!(e.action));
            o.insert("result".into(), json!(e.result));
            o.insert("timestamp".into(), json!(e.timestamp));
            for (key, value) in [
                ("requested_value", e.requested_value),
                ("clamped_value", e.clamped_value),
                ("applied_value", e.applied_value),
            ] {
                if let Some(v) = value {
                    o.insert(key.into(), json!(v));
                }
            }
            if let Some(reason) = &e.error_reason {
                o.insert("error_reason".into(), json!(reason));
            }
            Value::Object(o)
        })
        .collect()
}

/// The text table. `local_time` formats Unix seconds as `yyyy-MM-dd HH:mm:ss`
/// in the user's time zone. Columns are *not* padded: `String(format: "%-20@")`
/// ignores widths on Apple platforms, and the output must stay identical.
pub fn events_text(events: &[Event], local_time: &dyn Fn(f64) -> String) -> String {
    if events.is_empty() {
        return "No history events recorded.\n".into();
    }
    let mut out = String::from("Timestamp Action Requested Clamped Applied Result Reason/Error\n");
    out.push_str(&"-".repeat(90));
    out.push('\n');
    let value = |v: Option<f64>| v.map_or_else(|| "n/a".to_owned(), |v| format!("{v:.2}"));
    for e in events {
        out.push_str(&format!(
            "{} {} {} {} {} {} {}\n",
            local_time(e.timestamp + REFERENCE_DATE_OFFSET),
            e.action,
            value(e.requested_value),
            value(e.clamped_value),
            value(e.applied_value),
            e.result,
            e.error_reason.as_deref().unwrap_or("")
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn options_match_swift() {
        assert_eq!(
            parse_options(&[]).unwrap(),
            Options {
                json: false,
                limit: 100
            }
        );
        assert_eq!(
            parse_options(&args(&["--json", "-n", "5"])).unwrap(),
            Options {
                json: true,
                limit: 5
            }
        );
        assert_eq!(parse_options(&args(&["--limit", "-3"])).unwrap().limit, -3);
        for bad in [&["--limit"][..], &["--limit", "x"], &["-n", "1.5"]] {
            assert_eq!(
                parse_options(&args(bad)).unwrap_err().to_string(),
                "history: --limit requires an integer value"
            );
        }
        let unknown = parse_options(&args(&["--bogus"])).unwrap_err();
        assert_eq!(
            (unknown.to_string(), unknown.exit_code()),
            ("history: unknown option '--bogus'".into(), 2)
        );
    }

    #[test]
    fn help_matches_the_oracle_fixture() {
        assert_eq!(
            HELP,
            include_str!("../../../oracle/v0.12/cases/history-help.stdout")
        );
    }

    // Fixture lines and expected values come from running the v0.12 Swift
    // binary (history --json / history) on this synthetic file.
    const FILE: &str = r#"{"action":"brightness.set","payload":{"action":"brightness.set","applied_value":0.5,"clamped_value":0.5,"requested_value":0.5,"result":"success","timestamp":"2026-11-19T08:30:00Z"},"schema_version":1,"source":"tune","timestamp":"2026-11-19T08:30:00Z"}
not json at all
{"action":"fan.set","payload":{"action":"fan.set","error_reason":"permission error: x","requested_value":2,"clamped_value":1,"result":"failed","timestamp":"2026-11-19T09:00:00Z"},"schema_version":1,"source":"tune","timestamp":"2026-11-19T09:00:00Z"}
{"action":"legacy.thing","timestamp":"2026-11-18T07:00:00Z","result":"success","requested_value":0.123456}
{"action":"other","payload":{"x":1},"schema_version":1,"source":"brain","timestamp":"2026-11-19T10:00:00Z"}
{"action":"dim.set","payload":{"action":"dim.set","result":"success","timestamp":"2026-11-19T11:00:00Z","applied_value":0.25},"schema_version":2,"source":"tune","timestamp":"2026-11-19T11:00:00Z"}
"#;

    fn file() -> (tempfile::TempDir, std::path::PathBuf) {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("history.ndjson");
        std::fs::write(&path, FILE).unwrap();
        (tmp, path)
    }

    #[test]
    fn json_matches_the_swift_output_for_the_recorded_file() {
        let (_tmp, path) = file();
        let events = read_events(&path, 100);
        assert_eq!(
            events_json(&events),
            json!([
                {"action":"brightness.set","applied_value":0.5,"clamped_value":0.5,"requested_value":0.5,"result":"success","timestamp":816_769_800.0},
                {"action":"fan.set","clamped_value":1.0,"error_reason":"permission error: x","requested_value":2.0,"result":"failed","timestamp":816_771_600.0},
                {"action":"legacy.thing","requested_value":0.123_456,"result":"success","timestamp":816_678_000.0}
            ])
        );
        // The limit counts records, not decodable events: the last two
        // records (another source, a newer schema) are undecodable.
        assert!(read_events(&path, 2).is_empty());
        assert_eq!(read_events(&path, 0).len(), 3);
        assert_eq!(read_events(&path, -1).len(), 3);
    }

    #[test]
    fn text_table_is_unpadded_with_n_a_and_two_decimals() {
        let (_tmp, path) = file();
        let text = events_text(&read_events(&path, 100), &|unix| format!("T{unix}"));
        let want = format!(
            "Timestamp Action Requested Clamped Applied Result Reason/Error\n{}\nT1795077000 brightness.set 0.50 0.50 0.50 success \nT1795078800 fan.set 2.00 1.00 n/a failed permission error: x\nT1794985200 legacy.thing 0.12 n/a n/a success \n",
            "-".repeat(90)
        );
        assert_eq!(text, want);
        assert_eq!(
            events_text(&[], &|_| unreachable!()),
            "No history events recorded.\n"
        );
    }

    #[test]
    fn decoding_follows_the_swift_decoder() {
        let ev = |payload: Value| decode_event(payload.as_object().unwrap());
        let base = json!({"action":"a","result":"r","timestamp":"2026-11-19T08:30:00Z"});
        assert!(ev(base.clone()).is_some());
        let with = |k: &str, v: Value| {
            let mut b = base.clone();
            b[k] = v;
            ev(b)
        };
        // Verified against Swift: fractional seconds and offsets parse, a
        // string in a numeric field drops the event, nulls and extras are fine.
        assert_eq!(
            with("timestamp", json!("2026-11-19T08:30:00.250Z"))
                .unwrap()
                .timestamp,
            816_769_800.25
        );
        assert_eq!(
            with("timestamp", json!("2026-11-19T08:30:00+01:00"))
                .unwrap()
                .timestamp,
            816_766_200.0
        );
        assert!(with("requested_value", json!("x")).is_none());
        assert_eq!(
            with("requested_value", json!(3)).unwrap().requested_value,
            Some(3.0)
        );
        assert_eq!(
            with("requestedValue", json!(0.5)).unwrap().requested_value,
            Some(0.5)
        );
        assert_eq!(
            with("requested_value", Value::Null)
                .unwrap()
                .requested_value,
            None
        );
        assert_eq!(
            with("error_reason", Value::Null).unwrap().error_reason,
            None
        );
        assert!(with("error_reason", json!(5)).is_none());
        assert!(with("unknown_extra", json!(9)).is_some());
        assert!(ev(json!({"action":"a","timestamp":"2026-11-19T08:30:00Z"})).is_none());
    }
}
