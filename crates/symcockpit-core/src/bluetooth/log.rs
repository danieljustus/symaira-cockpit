//! BLE log and its export (R53): CSV after RFC 4180, JSON with raw bytes.
//!
//! The log exists in memory only; nothing is written until a caller exports
//! explicitly (Q08, architecture §10).

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use symcockpit_contract::Error;

use super::write::to_hex;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LogKind {
    Seen,
    Connect,
    Disconnect,
    Read,
    Notify,
    WriteRequested,
    WriteAcknowledged,
    WriteReadback,
    Error,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct LogEntry {
    pub t_ms: u64,
    pub kind: LogKind,
    pub device_id: String,
    pub service: String,
    pub characteristic: String,
    /// Raw bytes exactly as seen on the wire.
    pub bytes: Vec<u8>,
    pub detail: String,
}

/// Bounded in-memory log; the oldest entry makes room for a new one.
pub struct BleLog {
    cap: usize,
    entries: std::collections::VecDeque<LogEntry>,
    clock: Box<dyn Fn() -> u64>,
}

impl BleLog {
    /// Timestamps are Unix milliseconds from the system clock.
    pub fn new(cap: usize) -> BleLog {
        BleLog::with_clock(cap, || {
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_millis() as u64)
        })
    }

    pub fn with_clock(cap: usize, clock: impl Fn() -> u64 + 'static) -> BleLog {
        BleLog {
            cap: cap.max(1),
            entries: Default::default(),
            clock: Box::new(clock),
        }
    }

    /// Appends an entry stamped by the log's clock.
    pub fn record(
        &mut self,
        kind: LogKind,
        device_id: &str,
        service: &str,
        characteristic: &str,
        bytes: &[u8],
        detail: &str,
    ) {
        let entry = LogEntry {
            t_ms: (self.clock)(),
            kind,
            device_id: device_id.to_owned(),
            service: service.to_owned(),
            characteristic: characteristic.to_owned(),
            bytes: bytes.to_vec(),
            detail: detail.to_owned(),
        };
        self.push(entry);
    }

    pub fn push(&mut self, entry: LogEntry) {
        if self.entries.len() == self.cap {
            self.entries.pop_front();
        }
        self.entries.push_back(entry);
    }

    pub fn entries(&self) -> impl Iterator<Item = &LogEntry> {
        self.entries.iter()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ExportFormat {
    Csv,
    Json,
}

impl ExportFormat {
    pub fn parse(text: &str) -> Result<ExportFormat, Error> {
        match text {
            "csv" => Ok(ExportFormat::Csv),
            "json" => Ok(ExportFormat::Json),
            other => Err(Error::Usage(format!(
                "unknown export format {other:?} (csv or json)"
            ))),
        }
    }
}

const CSV_HEADER: [&str; 8] = [
    "t_ms",
    "kind",
    "device_id",
    "service",
    "characteristic",
    "value_hex",
    "length",
    "detail",
];

fn kind_name(kind: LogKind) -> String {
    serde_json::to_value(kind)
        .ok()
        .and_then(|v| v.as_str().map(str::to_owned))
        .unwrap_or_default()
}

/// RFC 4180: CRLF line ends, fields with comma, quote, CR or LF are quoted,
/// quotes doubled. The raw value is hex so binary data survives any text channel.
pub fn export_csv(log: &BleLog) -> String {
    fn field(out: &mut String, text: &str) {
        if text.contains([',', '"', '\r', '\n']) {
            out.push('"');
            out.push_str(&text.replace('"', "\"\""));
            out.push('"');
        } else {
            out.push_str(text);
        }
    }
    let mut out = CSV_HEADER.join(",");
    out.push_str("\r\n");
    for e in log.entries() {
        let cells = [
            e.t_ms.to_string(),
            kind_name(e.kind),
            e.device_id.clone(),
            e.service.clone(),
            e.characteristic.clone(),
            to_hex(&e.bytes),
            e.bytes.len().to_string(),
            e.detail.clone(),
        ];
        for (i, cell) in cells.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            field(&mut out, cell);
        }
        out.push_str("\r\n");
    }
    out
}

/// JSON with a schema version; `bytes` holds the raw bytes as integers.
pub fn export_json(log: &BleLog) -> Value {
    let entries: Vec<Value> = log
        .entries()
        .map(|e| {
            json!({
                "t_ms": e.t_ms,
                "kind": kind_name(e.kind),
                "device_id": e.device_id,
                "service": e.service,
                "characteristic": e.characteristic,
                "bytes": e.bytes,
                "value_hex": to_hex(&e.bytes),
                "detail": e.detail,
            })
        })
        .collect();
    json!({"schema": 1, "entries": entries})
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(detail: &str, bytes: &[u8]) -> LogEntry {
        LogEntry {
            t_ms: 1_700_000_000_123,
            kind: LogKind::Notify,
            device_id: "dev,1".into(),
            service: "180D".into(),
            characteristic: "2A37".into(),
            bytes: bytes.to_vec(),
            detail: detail.into(),
        }
    }

    /// Fields RFC 4180 requires to be quoted: comma, quote, CR, LF, CRLF, plus
    /// empty and non-ASCII text.
    fn awkward_log() -> BleLog {
        let mut log = BleLog::new(100);
        for (detail, bytes) in [
            ("plain", &[0u8, 255, 16][..]),
            ("with,comma", &[][..]),
            ("say \"hi\"", &[1][..]),
            ("line\nfeed", &[2][..]),
            ("carriage\rreturn", &[3][..]),
            ("crlf\r\nin text", &[4][..]),
            ("", &[5][..]),
            ("ümläut, \"mixed\"\n", &[6, 7][..]),
        ] {
            log.push(entry(detail, bytes));
        }
        log
    }

    #[test]
    fn csv_round_trips_through_an_independent_parser() {
        let log = awkward_log();
        let text = export_csv(&log);
        assert!(text.ends_with("\r\n"));
        let mut reader = csv::ReaderBuilder::new().from_reader(text.as_bytes());
        assert_eq!(
            reader.headers().unwrap().iter().collect::<Vec<_>>(),
            CSV_HEADER
        );
        let rows: Vec<csv::StringRecord> = reader.records().map(Result::unwrap).collect();
        assert_eq!(rows.len(), log.len());
        for (row, e) in rows.iter().zip(log.entries()) {
            assert_eq!(row.len(), CSV_HEADER.len());
            assert_eq!(&row[0], e.t_ms.to_string());
            assert_eq!(&row[2], e.device_id);
            assert_eq!(&row[5], to_hex(&e.bytes));
            assert_eq!(&row[6], e.bytes.len().to_string());
            assert_eq!(&row[7], e.detail, "detail must survive byte for byte");
        }
    }

    #[test]
    fn csv_quotes_exactly_where_rfc_4180_requires() {
        let mut log = BleLog::new(4);
        log.push(entry("a\"b", &[]));
        let text = export_csv(&log);
        let line = text.split("\r\n").nth(1).unwrap();
        assert_eq!(
            line,
            "1700000000123,notify,\"dev,1\",180D,2A37,,0,\"a\"\"b\""
        );
    }

    #[test]
    fn json_keeps_raw_bytes() {
        let v = export_json(&awkward_log());
        assert_eq!(v["schema"], 1);
        assert_eq!(v["entries"][0]["bytes"], json!([0, 255, 16]));
        assert_eq!(v["entries"][0]["value_hex"], "00ff10");
        assert_eq!(v["entries"][5]["detail"], "crlf\r\nin text");
    }

    #[test]
    fn log_drops_the_oldest_entry_when_full() {
        let mut log = BleLog::new(2);
        for i in 0..3u8 {
            log.push(entry("x", &[i]));
        }
        let kept: Vec<u8> = log.entries().map(|e| e.bytes[0]).collect();
        assert_eq!(kept, [1, 2]);
    }

    #[test]
    fn format_parsing() {
        assert_eq!(ExportFormat::parse("csv").unwrap(), ExportFormat::Csv);
        assert!(ExportFormat::parse("xml").is_err());
    }
}
