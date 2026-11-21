//! `ai-usage serve`: the cached usage as a small local HTTP API
//! (`AIUsageLocalAPI.swift`, `AIUsageSnapshotCache.swift`, `AIUsageServeCommand.swift`
//! of v0.12). No socket and no clock in here: the cache reader, the request router and
//! the byte-exact encoder of the answers, so tests need neither.
//!
//! shortcut: the cache numbers are read through f64, so a value with more than 15
//! significant digits is rounded; the arithmetic after that (`remaining`, `utilization`)
//! is exact decimal with Swift's 38 digits.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write as _;
use std::path::Path;

use serde_json::Value;
use symcockpit_contract::Error;

use crate::ai_usage::{CATALOG, REFERENCE_DATE_OFFSET, format_iso8601_utc, redact};

pub const DEFAULT_PORT: u16 = 6737;
/// A snapshot older than this is `stale` (`AIUsageSnapshotCache.freshness`).
pub const FRESHNESS_SECS: f64 = 300.0;
const MAX_CACHE_BYTES: u64 = 262_144;
const MAX_HEADER_BYTES: usize = 8192;

pub const HELP: &str = "Usage: symcockpit ai-usage serve [--port 6737]\nServes cached usage on 127.0.0.1 only. No provider requests. Stop with Ctrl-C.\nOnly providers enabled in the Symaira Cockpit app's AI usage settings are served;\nproviders disabled there, and all providers when none is enabled, are not.\nGET /v1/limits and /v1/usage, optionally followed by /provider-id.\nClients must use the literal host 127.0.0.1:<port> (localhost and [::1] are refused).\nBrowser-origin requests are refused. Other local processes can read the data.\n";

/// `ai-usage serve [--port N]`; `args` follow `serve`.
pub fn parse_port(args: &[String]) -> Result<u16, Error> {
    match args {
        [] => Ok(DEFAULT_PORT),
        [flag, value] if flag == "--port" => value.parse::<u16>().map_err(|_| usage()),
        _ => Err(usage()),
    }
}

fn usage() -> Error {
    Error::Usage("ai-usage serve: expected --port 0...65535".into())
}

// ------------------------------------------------------------------ decimals

/// `Decimal` as far as the API needs it: `mant * 10^exp`, exact for what the cache holds.
#[derive(Clone, Copy, Debug)]
pub struct Dec {
    mant: i128,
    exp: i32,
}

impl PartialEq for Dec {
    fn eq(&self, other: &Self) -> bool {
        self.cmp_value(other) == Some(std::cmp::Ordering::Equal)
    }
}

impl Dec {
    /// The shortest decimal text of `n` (what the cache file holds), as written: `100`
    /// keeps its two zeros in the mantissa, which decides how many digits a division has.
    pub fn from_f64(n: f64) -> Option<Self> {
        if !n.is_finite() {
            return None;
        }
        let text = format!("{n}");
        let digits: String = text.chars().filter(char::is_ascii_digit).collect();
        let fraction = text.split_once('.').map_or(0, |(_, f)| f.len());
        let mant: i128 = digits.parse().ok()?;
        Some(Self {
            mant: if n < 0.0 { -mant } else { mant },
            exp: -i32::try_from(fraction).ok()?,
        })
    }

    fn scaled(self, exp: i32) -> Option<i128> {
        let by = u32::try_from(self.exp - exp).ok()?;
        self.mant.checked_mul(10i128.checked_pow(by)?)
    }

    fn cmp_value(&self, other: &Self) -> Option<std::cmp::Ordering> {
        let exp = self.exp.min(other.exp);
        Some(self.scaled(exp)?.cmp(&other.scaled(exp)?))
    }

    fn sub(self, other: Self) -> Option<Self> {
        let exp = self.exp.min(other.exp);
        Some(Self {
            mant: self.scaled(exp)?.checked_sub(other.scaled(exp)?)?,
            exp,
        })
    }

    /// `Decimal` division: the quotient of the mantissas is cut after `38 - (digits of its
    /// integer part)` fractional digits, so 1/3 prints 38 threes, 48/7 37 digits after the
    /// 6 and 35/925 keeps its leading zero (checked against the v0.12 binary on 13 ratios).
    /// `None` for a zero divisor or a value beyond the arithmetic.
    fn div(self, other: Self) -> Option<Self> {
        if other.mant <= 0 || self.mant < 0 {
            return None;
        }
        let whole = self.mant / other.mant;
        let integer_digits = if whole == 0 {
            0
        } else {
            whole.to_string().len()
        };
        let mut digits = whole.to_string();
        let mut rest = self.mant % other.mant;
        let mut fraction = 0;
        while rest != 0 && fraction + integer_digits < 38 {
            rest = rest.checked_mul(10)?;
            digits.push_str(&(rest / other.mant).to_string());
            rest %= other.mant;
            fraction += 1;
        }
        Some(Self {
            mant: digits.parse().ok()?,
            exp: self.exp - other.exp - i32::try_from(fraction).ok()?,
        })
    }

    /// `Decimal.description`: plain digits, no exponent.
    pub fn text(self) -> String {
        let (mut mant, mut exp) = (self.mant, self.exp);
        while mant != 0 && mant % 10 == 0 {
            mant /= 10;
            exp += 1;
        }
        let digits = mant.unsigned_abs().to_string();
        let sign = if mant < 0 { "-" } else { "" };
        match exp {
            _ if mant == 0 => "0".to_owned(),
            0.. => format!("{sign}{digits}{}", "0".repeat(exp as usize)),
            _ if digits.len() as i32 > -exp => {
                let at = digits.len() - (-exp) as usize;
                format!("{sign}{}.{}", &digits[..at], &digits[at..])
            }
            _ => format!(
                "{sign}0.{}{digits}",
                "0".repeat((-exp) as usize - digits.len())
            ),
        }
    }
}

// ------------------------------------------------------------------ the rows

#[derive(Clone, Debug, PartialEq)]
pub enum Unit {
    Tokens,
    Requests,
    Credits,
    Currency(String),
    Percent,
}

impl Unit {
    fn label(&self) -> &str {
        match self {
            Self::Tokens => "tokens",
            Self::Requests => "requests",
            Self::Credits => "credits",
            Self::Currency(code) => code,
            Self::Percent => "%",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Meter {
    pub label: String,
    pub used: Option<Dec>,
    pub limit: Option<Dec>,
    pub unit: Unit,
    /// Unix seconds.
    pub resets_at: Option<f64>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Snapshot {
    pub provider_id: String,
    pub meters: Vec<Meter>,
    pub balance: Option<Dec>,
    pub currency: Option<String>,
    /// Unix seconds.
    pub fetched_at: f64,
}

/// `AIUsageService.ProviderResult`.
#[derive(Clone, Debug, PartialEq)]
pub struct Row {
    pub provider_id: String,
    pub snapshot: Option<Snapshot>,
    pub error: Option<String>,
}

fn valid_provider_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'_')
}

/// A date of the cache file: seconds since 2001-01-01, as Swift's default `Date` coding.
fn cache_date(value: &Value) -> Option<f64> {
    value
        .as_f64()
        .filter(|d| d.is_finite())
        .map(|d| d + REFERENCE_DATE_OFFSET)
}

fn cache_unit(value: &Value) -> Option<Unit> {
    let object = value.as_object().filter(|o| o.len() == 1)?;
    let (case, payload) = object.iter().next()?;
    Some(match case.as_str() {
        "tokens" => Unit::Tokens,
        "requests" => Unit::Requests,
        "credits" => Unit::Credits,
        "percent" => Unit::Percent,
        "currency" => Unit::Currency(payload.get("_0")?.as_str()?.to_owned()),
        _ => return None,
    })
}

fn optional_number(value: Option<&Value>) -> Result<Option<Dec>, ()> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(v) => v.as_f64().and_then(Dec::from_f64).map(Some).ok_or(()),
    }
}

fn cache_meter(value: &Value) -> Option<Meter> {
    let o = value.as_object()?;
    Some(Meter {
        label: o.get("label")?.as_str()?.to_owned(),
        used: optional_number(o.get("used")).ok()?,
        limit: optional_number(o.get("limit")).ok()?,
        unit: cache_unit(o.get("unit")?)?,
        resets_at: match o.get("resetsAt") {
            None | Some(Value::Null) => None,
            Some(v) => Some(cache_date(v)?),
        },
    })
}

/// One cache file (`AIUsageSnapshotCache.loadEntry`): the snapshot and whether the last
/// refresh failed; `None` for anything the Swift reader refuses.
pub fn parse_cache_entry(
    bytes: &[u8],
    provider_id: &str,
    now_unix: f64,
) -> Option<(Snapshot, bool)> {
    if bytes.len() as u64 > MAX_CACHE_BYTES {
        return None;
    }
    let entry: Value = serde_json::from_slice(bytes).ok()?;
    if entry.get("version")?.as_i64()? != 1 {
        return None;
    }
    let s = entry.get("snapshot")?.as_object()?;
    if s.get("providerId")?.as_str()? != provider_id {
        return None;
    }
    let fetched_at = cache_date(s.get("fetchedAt")?)?;
    if fetched_at > now_unix + 60.0 {
        return None;
    }
    let meters = s
        .get("meters")?
        .as_array()?
        .iter()
        .map(cache_meter)
        .collect::<Option<Vec<_>>>()?;
    if meters.len() > 256 {
        return None;
    }
    s.get("source")?.as_str()?;
    let snapshot = Snapshot {
        provider_id: provider_id.to_owned(),
        meters,
        balance: optional_number(s.get("balance")).ok()?,
        currency: match s.get("currency") {
            None | Some(Value::Null) => None,
            Some(v) => Some(v.as_str()?.to_owned()),
        },
        fetched_at,
    };
    let failed = entry.get("refreshFailed").and_then(Value::as_bool) == Some(true);
    Some((snapshot, failed))
}

/// `TuneController.cachedAIUsageReport(providerIDs:)`: every enabled catalog provider in
/// catalog order, with its cached snapshot or an empty row. Only files are read.
pub fn cached_rows(dir: &Path, enabled: &BTreeSet<String>, now_unix: f64) -> Vec<Row> {
    CATALOG
        .iter()
        .filter(|(id, _)| enabled.contains(*id))
        .map(|(id, _)| {
            let loaded = (valid_provider_id(id))
                .then(|| dir.join(format!("{id}.json")))
                .filter(|file| {
                    std::fs::symlink_metadata(file)
                        .is_ok_and(|m| m.is_file() && m.len() <= MAX_CACHE_BYTES)
                })
                .and_then(|file| std::fs::read(file).ok())
                .and_then(|bytes| parse_cache_entry(&bytes, id, now_unix));
            let (snapshot, failed) = loaded.unzip();
            Row {
                provider_id: (*id).to_owned(),
                error: (failed == Some(true)).then(|| "Last refresh failed".to_owned()),
                snapshot,
            }
        })
        .collect()
}

// ------------------------------------------------------------------ the answer

#[derive(Debug, Eq, PartialEq)]
pub struct Response {
    pub status: u16,
    pub body: Vec<u8>,
}

impl Response {
    fn error(status: u16, code: &str) -> Self {
        Self {
            status,
            body: format!("{{\"error\":\"{code}\"}}").into_bytes(),
        }
    }

    /// `Response.httpData()`.
    pub fn http_bytes(&self) -> Vec<u8> {
        let reason = match self.status {
            200 => "OK",
            204 => "No Content",
            400 => "Bad Request",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            408 => "Request Timeout",
            413 => "Content Too Large",
            431 => "Request Header Fields Too Large",
            500 => "Internal Server Error",
            503 => "Service Unavailable",
            _ => "Error",
        };
        let mut head = format!(
            "HTTP/1.1 {} {reason}\r\nContent-Type: application/json\r\n",
            self.status
        );
        // RFC 9110 section 8.6: a 204 response must not carry Content-Length.
        if self.status != 204 {
            head.push_str(&format!("Content-Length: {}\r\n", self.body.len()));
        }
        head.push_str("Connection: close\r\nCache-Control: no-store\r\n");
        head.push_str(
            "X-Content-Type-Options: nosniff\r\nCross-Origin-Resource-Policy: same-origin\r\n",
        );
        if self.status == 405 {
            head.push_str("Allow: GET, OPTIONS\r\n");
        }
        head.push_str("\r\n");
        let mut bytes = head.into_bytes();
        bytes.extend_from_slice(&self.body);
        bytes
    }
}

pub fn error_response(status: u16, code: &str) -> Response {
    Response::error(status, code)
}

/// Foundation's `removingPercentEncoding`: `None` for a bad escape or non-UTF-8 result.
fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = text.get(i + 1..i + 3)?;
            out.push(
                u8::from_str_radix(hex, 16)
                    .ok()
                    .filter(|_| !hex.starts_with('+'))?,
            );
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

fn base64_url(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let n = chunk
            .iter()
            .enumerate()
            .fold(0u32, |n, (i, b)| n | u32::from(*b) << (16 - 8 * i));
        for i in 0..=chunk.len() {
            out.push(ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char);
        }
    }
    out
}

fn exceeds_bounds(snapshot: &Snapshot) -> bool {
    snapshot.meters.len() > 128
        || snapshot.currency.as_deref().is_some_and(|c| c.len() > 32)
        || snapshot
            .meters
            .iter()
            .any(|m| m.label.len() > 256 || m.unit.label().len() > 32)
}

/// A JSON value rendered the way `JSONEncoder` with `.sortedKeys` writes it: no
/// spaces, `/` escaped. Numbers arrive as text so a 38-digit decimal stays whole.
enum Node {
    Raw(String),
    Str(String),
    Arr(Vec<Node>),
    Obj(BTreeMap<String, Node>),
}

impl Node {
    fn str(s: &str) -> Self {
        Self::Str(s.to_owned())
    }

    fn obj<const N: usize>(members: [(&str, Self); N]) -> Self {
        Self::Obj(
            members
                .into_iter()
                .map(|(k, v)| (k.to_owned(), v))
                .collect(),
        )
    }

    fn write(&self, out: &mut String) {
        match self {
            Self::Raw(text) => out.push_str(text),
            Self::Str(text) => {
                out.push('"');
                for c in text.chars() {
                    match c {
                        '"' => out.push_str("\\\""),
                        '\\' => out.push_str("\\\\"),
                        '/' => out.push_str("\\/"),
                        '\n' => out.push_str("\\n"),
                        '\r' => out.push_str("\\r"),
                        '\t' => out.push_str("\\t"),
                        '\u{8}' => out.push_str("\\b"),
                        '\u{c}' => out.push_str("\\f"),
                        c if (c as u32) < 0x20 => {
                            let _ = write!(out, "\\u{:04x}", c as u32);
                        }
                        c => out.push(c),
                    }
                }
                out.push('"');
            }
            Self::Arr(items) => {
                out.push('[');
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    item.write(out);
                }
                out.push(']');
            }
            Self::Obj(members) => {
                out.push('{');
                for (i, (key, value)) in members.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    Self::Str(key.clone()).write(out);
                    out.push(':');
                    value.write(out);
                }
                out.push('}');
            }
        }
    }
}

fn dec(n: Dec) -> Node {
    Node::Raw(n.text())
}

fn resource(id: &str, label: &str, kind: &str, unit: String) -> BTreeMap<String, Node> {
    BTreeMap::from([
        ("resource_id".to_owned(), Node::str(id)),
        ("label".to_owned(), Node::str(label)),
        ("kind".to_owned(), Node::str(kind)),
        ("unit".to_owned(), Node::Str(unit)),
    ])
}

/// The meters as `[(resource id, resource)]` in Swift's dictionary-key order.
fn resources(snapshot: &Snapshot) -> BTreeMap<String, Node> {
    let mut sorted: Vec<&Meter> = snapshot.meters.iter().collect();
    let text = |n: Option<Dec>| n.map(Dec::text).unwrap_or_default();
    let key = |m: &Meter| {
        [
            m.label.clone(),
            m.unit.label().to_owned(),
            text(m.used),
            text(m.limit),
            m.resets_at.map(swift_double_text).unwrap_or_default(),
        ]
    };
    sorted.sort_by_key(|m| key(m));
    let mut result = BTreeMap::new();
    let mut occurrences: BTreeMap<String, u32> = BTreeMap::new();
    for meter in sorted {
        let label = redact(&meter.label);
        let base = base64_url(label.as_bytes());
        let count = occurrences.entry(base.clone()).or_insert(0);
        *count += 1;
        let id = format!("meter_{base}~{count}");
        if meter.used.is_none() && meter.limit.is_none() {
            continue;
        }
        let unit = if meter.unit == Unit::Percent {
            "percent".to_owned()
        } else {
            redact(meter.unit.label())
        };
        let mut r = resource(&id, &label, "consumption", unit);
        for (name, value) in [("used", meter.used), ("limit", meter.limit)] {
            if let Some(v) = value {
                r.insert(name.to_owned(), dec(v));
            }
        }
        if let (Some(used), Some(limit)) = (meter.used, meter.limit) {
            let zero = Dec { mant: 0, exp: 0 };
            let one = Dec { mant: 1, exp: 0 };
            if used.cmp_value(&zero).is_some_and(|o| o.is_ge())
                && limit.cmp_value(&zero).is_some_and(|o| o.is_gt())
                && let Some(left) = limit.sub(used)
                && let Some(ratio) = used.div(limit)
            {
                let left = if left.cmp_value(&zero).is_some_and(|o| o.is_lt()) {
                    zero
                } else {
                    left
                };
                let ratio = if ratio.cmp_value(&one).is_some_and(|o| o.is_gt()) {
                    one
                } else {
                    ratio
                };
                r.insert("remaining".to_owned(), dec(left));
                r.insert("utilization".to_owned(), dec(ratio));
            }
        }
        if let Some(at) = meter.resets_at {
            r.insert("resets_at".to_owned(), Node::Str(format_iso8601_utc(at)));
        }
        result.insert(id, Node::Obj(r));
    }
    if let Some(balance) = snapshot.balance {
        let unit = redact(snapshot.currency.as_deref().unwrap_or("unknown"));
        let mut r = resource("balance", "Balance", "balance", unit);
        r.insert("available".to_owned(), dec(balance));
        result.insert("balance".into(), Node::Obj(r));
    }
    result
}

/// The sort key uses Swift's `Double.description`: a whole number keeps its `.0`.
fn swift_double_text(n: f64) -> String {
    let text = format!("{n}");
    if text.contains('.') {
        text
    } else {
        format!("{text}.0")
    }
}

/// `route(header:port:now:snapshots:)`: the whole decision for one request header
/// (everything up to and including the blank line).
pub fn route(
    header: &[u8],
    port: u16,
    now_unix: f64,
    snapshots: impl FnOnce() -> Vec<Row>,
) -> Response {
    if header.len() > MAX_HEADER_BYTES {
        return Response::error(431, "headers_too_large");
    }
    let bad = || Response::error(400, "bad_request");
    let Ok(text) = std::str::from_utf8(header) else {
        return bad();
    };
    if !text.ends_with("\r\n\r\n")
        || !text
            .bytes()
            .all(|b| b == 13 || b == 10 || (32..=126).contains(&b))
    {
        return bad();
    }
    let lines: Vec<&str> = text.split("\r\n").collect();
    let request: Vec<&str> = lines[0].split(' ').collect();
    if request.len() != 3 || request[2] != "HTTP/1.1" {
        return bad();
    }
    let mut fields: BTreeMap<String, String> = BTreeMap::new();
    for line in &lines[1..lines.len() - 2] {
        let Some((name, value)) = line.split_once(':') else {
            return bad();
        };
        let name = name.to_lowercase();
        if name.is_empty()
            || !name
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
            || fields.contains_key(&name)
        {
            return bad();
        }
        fields.insert(name, value.trim_matches([' ', '\t']).to_owned());
    }
    if fields.contains_key("origin")
        || fields.keys().any(|k| k.starts_with("sec-fetch-"))
        || fields.get("host").map(String::as_str) != Some(&format!("127.0.0.1:{port}"))
    {
        return Response::error(403, "forbidden");
    }
    if fields.contains_key("transfer-encoding")
        || fields.get("content-length").is_some_and(|v| v != "0")
    {
        return Response::error(413, "body_not_allowed");
    }
    if request[0] != "GET" && request[0] != "OPTIONS" {
        return Response::error(405, "method_not_allowed");
    }
    let parts: Vec<&str> = request[1].split('/').collect();
    if !(parts.len() == 3 || parts.len() == 4)
        || !parts[0].is_empty()
        || parts[1] != "v1"
        || !(parts[2] == "limits" || parts[2] == "usage")
    {
        return Response::error(404, "not_found");
    }
    let mut filter = None;
    if parts.len() == 4 {
        match percent_decode(parts[3]) {
            Some(id) if !id.is_empty() && !id.contains(['/', '?', '#']) => filter = Some(id),
            _ => return Response::error(400, "bad_provider_id"),
        }
    }
    if request[0] == "OPTIONS" {
        return Response {
            status: 204,
            body: Vec::new(),
        };
    }
    let all = snapshots();
    if all.len() > 64 {
        return Response::error(503, "snapshot_too_large");
    }
    let rows: Vec<&Row> = all
        .iter()
        .filter(|r| valid_provider_id(&r.provider_id))
        .collect();
    if let Some(filter) = &filter
        && !rows.iter().any(|r| &r.provider_id == filter)
    {
        return Response::error(404, "provider_not_found");
    }
    // provider id -> (fetched_at, stale, resources)
    let mut providers = BTreeMap::new();
    let mut failures: Vec<Node> = Vec::new();
    let mut seen = BTreeSet::new();
    for row in rows
        .iter()
        .filter(|r| filter.as_ref().is_none_or(|f| &r.provider_id == f))
    {
        if !seen.insert(row.provider_id.as_str()) {
            continue;
        }
        let failure = |code: &str| {
            Node::obj([
                ("code", Node::str(code)),
                ("provider_id", Node::str(&row.provider_id)),
            ])
        };
        if row.snapshot.as_ref().is_some_and(exceeds_bounds) {
            failures.push(failure("snapshot_too_large"));
            continue;
        }
        if row.error.is_some() {
            failures.push(failure("usage_unavailable"));
        }
        let Some(snapshot) = row
            .snapshot
            .as_ref()
            .filter(|s| s.provider_id == row.provider_id)
        else {
            continue;
        };
        let stale = row.error.is_some() || now_unix - snapshot.fetched_at >= FRESHNESS_SECS;
        providers.insert(
            row.provider_id.clone(),
            (snapshot.fetched_at, stale, resources(snapshot)),
        );
    }
    let flag = |b: bool| Node::Raw(b.to_string());
    let generated = Node::Str(format_iso8601_utc(now_unix));
    let document = if parts[2] == "limits" {
        let providers = providers
            .into_iter()
            .map(|(id, (fetched, stale, resources))| {
                let member = Node::obj([
                    ("fetched_at", Node::Str(format_iso8601_utc(fetched))),
                    ("stale", flag(stale)),
                    ("resources", Node::Obj(resources)),
                ]);
                (id, member)
            })
            .collect();
        Node::obj([
            ("schema", Node::str("symaira.cockpit.limits.v1")),
            ("generated_at", generated),
            ("providers", Node::Obj(providers)),
            ("errors", Node::Arr(failures)),
        ])
    } else {
        let snapshots = providers
            .into_iter()
            .map(|(id, (fetched, stale, resources))| {
                Node::obj([
                    ("provider_id", Node::Str(id)),
                    ("fetched_at", Node::Str(format_iso8601_utc(fetched))),
                    ("stale", flag(stale)),
                    ("meters", Node::Arr(resources.into_values().collect())),
                ])
            })
            .collect();
        Node::obj([
            ("schema", Node::str("symaira.cockpit.usage.v1")),
            ("generated_at", generated),
            ("snapshots", Node::Arr(snapshots)),
            ("errors", Node::Arr(failures)),
        ])
    };
    let mut body = String::new();
    document.write(&mut body);
    if body.len() > 1_048_576 {
        return Response::error(503, "snapshot_too_large");
    }
    Response {
        status: 200,
        body: body.into_bytes(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(n: f64) -> Dec {
        Dec::from_f64(n).unwrap()
    }

    #[test]
    fn decimals_print_plain_and_divide_like_swifts() {
        assert_eq!(d(12.5).text(), "12.5");
        assert_eq!(d(100.0).text(), "100");
        assert_eq!(d(0.0000001).text(), "0.0000001");
        assert_eq!(d(0.0).text(), "0");
        assert_eq!(d(-3.25).text(), "-3.25");
        assert_eq!(d(100.0).sub(d(12.3)).unwrap().text(), "87.7");
        // Values checked against the v0.12 binary (see tests/ai_usage_api.rs).
        let ratio = |a, b| d(a).div(d(b)).unwrap().text();
        assert_eq!(ratio(1.0, 3.0), "0.33333333333333333333333333333333333333");
        assert_eq!(ratio(2.0, 3.0), "0.66666666666666666666666666666666666666");
        assert_eq!(ratio(3.5, 9.25), "0.3783783783783783783783783783783783783");
        assert_eq!(ratio(0.0, 5.0), "0");
        assert_eq!(ratio(150.0, 100.0), "1.5");
        assert!(d(1.0).div(d(0.0)).is_none());
    }

    #[test]
    fn the_port_and_its_errors_follow_swift() {
        let args = |l: &[&str]| l.iter().map(ToString::to_string).collect::<Vec<_>>();
        assert_eq!(parse_port(&args(&[])), Ok(6737));
        assert_eq!(parse_port(&args(&["--port", "0"])), Ok(0));
        assert_eq!(parse_port(&args(&["--port", "65535"])), Ok(65535));
        for bad in [
            &["--port", "65536"][..],
            &["--port"],
            &["--port", "-1"],
            &["--port", "x"],
            &["6737"],
            &["--port", "1", "2"],
        ] {
            assert_eq!(
                parse_port(&args(bad)).unwrap_err().to_string(),
                "ai-usage serve: expected --port 0...65535",
                "{bad:?}"
            );
        }
    }

    #[test]
    fn resource_ids_encode_the_exact_label_in_base64url_without_padding() {
        assert_eq!(base64_url(b"Over"), "T3Zlcg");
        assert_eq!(base64_url(b"Session (5h)"), "U2Vzc2lvbiAoNWgp");
        assert_eq!(base64_url("Übergröße é".as_bytes()), "w5xiZXJncsO2w59lIMOp");
        assert_eq!(base64_url(b""), "");
    }
}
