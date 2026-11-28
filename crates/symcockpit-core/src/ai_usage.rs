//! `ai-usage` / MCP `get_ai_usage`: one `symbrain usage --output json`
//! subprocess, normalised to the v0.12 per-provider result form
//! (`SymBrainUsageClient.swift`, `AIUsageService.swift`).
//!
//! Credential boundary (AGENTS.md): this module never reads a credential. The
//! child environment only ever carries opaque `symvault://` references, which
//! `symbrain` resolves itself. The process runner is a port, so tests use a
//! fake and nothing here can reach a keychain.
//!
//! Left out on purpose (documented v0.12 differences): the on-disk snapshot
//! cache (so every call asks symbrain, like `--force`), the stale-snapshot
//! fallback that depends on it, and the recorded-history extension (it needs
//! per-provider consent flags no read command sets).

use std::collections::{BTreeMap, BTreeSet};
use std::sync::LazyLock;

use regex::Regex;
use serde_json::{Map, Value, json};
use symcockpit_contract::Error;
use symcockpit_store::parse_iso8601;

/// Seconds between 1970-01-01 and Foundation's reference date 2001-01-01.
pub const REFERENCE_DATE_OFFSET: f64 = 978_307_200.0;

pub const NOT_CONFIGURED: &str = "not configured";

/// `(id, display name)` in the stable catalog order of the v0.12 responses.
pub const CATALOG: [(&str, &str); 14] = [
    ("claude", "Claude"),
    ("codex", "Codex"),
    ("copilot", "GitHub Copilot"),
    ("cursor", "Cursor"),
    ("kimi", "Kimi Code"),
    ("moonshot", "Moonshot"),
    ("nous", "Nous Portal"),
    ("opencode", "OpenCode Go"),
    ("openrouter", "OpenRouter"),
    ("antigravity", "Antigravity"),
    ("zai", "Z.ai"),
    ("devin", "Devin"),
    ("grok", "Grok"),
    ("ollama", "Ollama Cloud"),
];

/// Environment variable symbrain reads each API-key provider's key from.
const CREDENTIAL_ENV: [(&str, &str); 7] = [
    ("OPENROUTER_API_KEY", "openrouter"),
    ("MOONSHOT_API_KEY", "moonshot"),
    ("KIMI_CODE_API_KEY", "kimi"),
    ("ZAI_API_KEY", "zai"),
    ("DEVIN_API_KEY", "devin"),
    ("GROK_ACCESS_TOKEN", "grok"),
    ("OPENCODE_GO_API_KEY", "opencode"),
];

const SCHEME: &str = "symvault://";

/// The `doctor` credential-source rows. Before any symbrain report every
/// provider's auth source is unknown, which v0.12 prints as `none`.
pub fn credential_sources() -> Value {
    CATALOG
        .iter()
        .map(|(id, _)| json!({"provider": id, "source": "none"}))
        .collect()
}

// --- SymVault references ------------------------------------------------

/// Trims, accepts a pasted `symvault://` reference, drops surrounding slashes;
/// `None` for an empty or unusable path (`SymVaultEntryPaths.normalize`).
pub fn normalize_entry_path(raw: &str) -> Option<String> {
    let mut value = raw.trim();
    if value.len() >= SCHEME.len() && value[..SCHEME.len()].eq_ignore_ascii_case(SCHEME) {
        value = &value[SCHEME.len()..];
    }
    let value = value.trim_matches('/');
    if value.is_empty() || value.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return None;
    }
    if value.split('/').any(|part| part == ".." || part.is_empty()) {
        return None;
    }
    Some(value.to_owned())
}

/// The opaque reference symbrain resolves for one provider, or `None` when the
/// provider uses local discovery or is not an API-key provider.
/// `overrides` maps provider id to the user's chosen vault entry path.
pub fn vault_reference(provider: &str, overrides: &BTreeMap<String, String>) -> Option<String> {
    if !CREDENTIAL_ENV.iter().any(|(_, id)| *id == provider) {
        return None;
    }
    let custom = overrides
        .get(provider)
        .and_then(|raw| normalize_entry_path(raw));
    // Local CLI auth stays discoverable until the user picks a vault entry.
    if matches!(provider, "grok" | "devin" | "opencode") && custom.is_none() {
        return None;
    }
    Some(format!(
        "{SCHEME}{}",
        custom.unwrap_or_else(|| format!("symtune/{provider}"))
    ))
}

// --- Runner port --------------------------------------------------------

pub struct CommandOutput {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub status: i32,
}

/// Runs `symbrain` (bounded, no shell). Implemented by the binary crate.
pub trait UsageRunner {
    /// `BinaryUnavailable` or `CommandFailed(-1)` for a missing binary, timeout or failed start.
    fn run(
        &self,
        args: &[String],
        env: &BTreeMap<String, String>,
    ) -> Result<CommandOutput, UsageError>;
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum UsageError {
    BinaryUnavailable,
    CommandFailed(i32),
    EmptyOutput,
    InvalidJson,
    UnsupportedSchema(i64),
    InvalidValue(String),
    ProviderSelectionUnsupported,
}

impl std::fmt::Display for UsageError {
    /// `SymBrainUsageError.errorDescription`; deliberately generic, subprocess
    /// output is never surfaced.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            UsageError::ProviderSelectionUnsupported => f.write_str("Installed symbrain is too old for provider-specific refresh; update symbrain (needs `symbrain usage --providers` and the SYMBRAIN_USAGE_*_HISTORY consent flags)"),
            UsageError::BinaryUnavailable => f.write_str("symbrain is not installed"),
            UsageError::CommandFailed(_) => f.write_str("symbrain usage failed"),
            UsageError::EmptyOutput => f.write_str("symbrain usage returned no output"),
            UsageError::InvalidJson => f.write_str("symbrain usage returned invalid JSON"),
            UsageError::UnsupportedSchema(_) => f.write_str("symbrain usage returned an unsupported schema version"),
            UsageError::InvalidValue(field) => write!(f, "symbrain usage returned an invalid {field} value"),
        }
    }
}

fn looks_like_unsupported_selection(stderr: &[u8]) -> bool {
    let head = &stderr[..stderr.len().min(4096)];
    let text = String::from_utf8_lossy(head).to_lowercase();
    [
        "unknown flag",
        "unknown option",
        "unrecognized option",
        "unrecognized argument",
        "unexpected argument",
        "flag provided but not defined",
    ]
    .iter()
    .any(|p| text.contains(p))
}

/// The environment handed to `symbrain`: inherited history opt-ins stripped,
/// keys of unselected providers removed, and a `symvault://` reference for
/// every selected API-key provider that has no key in the environment.
pub fn child_environment(
    inherited: &BTreeMap<String, String>,
    selection: Option<&BTreeSet<String>>,
    overrides: &BTreeMap<String, String>,
) -> BTreeMap<String, String> {
    let mut env: BTreeMap<String, String> = inherited
        .iter()
        .filter(|(k, _)| !(k.starts_with("SYMBRAIN_USAGE_") && k.contains("_HISTORY")))
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    for (key, provider) in CREDENTIAL_ENV {
        if selection.is_some_and(|s| !s.contains(provider)) {
            env.remove(key);
            continue;
        }
        if env.get(key).is_some_and(|v| !v.is_empty()) {
            continue;
        }
        if let Some(reference) = vault_reference(provider, overrides) {
            env.insert(key.to_owned(), reference);
        }
    }
    env
}

// --- Report parsing -----------------------------------------------------

pub struct ProviderRow {
    pub id: String,
    pub configured: bool,
    pub error: String,
    pub snapshot: Option<Value>,
    /// Brain's account attribution (`accounts`), raw; sanitised by `accounts_json`.
    pub accounts: Vec<Value>,
}

pub fn fetch_report(
    runner: &dyn UsageRunner,
    inherited: &BTreeMap<String, String>,
    selection: Option<&BTreeSet<String>>,
    overrides: &BTreeMap<String, String>,
) -> Result<Vec<ProviderRow>, UsageError> {
    let mut args = vec!["usage".to_owned(), "--output".into(), "json".into()];
    if let Some(selection) = selection {
        if selection.is_empty() {
            return Ok(Vec::new());
        }
        let valid = |id: &String| {
            !id.is_empty()
                && id
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'_')
        };
        if !selection.iter().all(valid) {
            return Err(UsageError::InvalidValue("provider ID".into()));
        }
        args.push("--providers".into());
        args.push(selection.iter().cloned().collect::<Vec<_>>().join(","));
    }
    let out = runner.run(&args, &child_environment(inherited, selection, overrides))?;
    if out.status != 0 {
        // Brains without `--providers` reject the flag, usually with status 2.
        if selection.is_some() && (out.status == 2 || looks_like_unsupported_selection(&out.stderr))
        {
            return Err(UsageError::ProviderSelectionUnsupported);
        }
        return Err(UsageError::CommandFailed(out.status));
    }
    if out.stdout.is_empty() {
        return Err(UsageError::EmptyOutput);
    }
    let report: Value = serde_json::from_slice(&out.stdout).map_err(|_| UsageError::InvalidJson)?;
    let version = report
        .get("schema_version")
        .and_then(Value::as_i64)
        .ok_or(UsageError::InvalidJson)?;
    if version != 1 {
        return Err(UsageError::UnsupportedSchema(version));
    }
    report
        .get("providers")
        .and_then(Value::as_array)
        .ok_or(UsageError::InvalidJson)?
        .iter()
        .map(|p| {
            let o = p.as_object().ok_or(UsageError::InvalidJson)?;
            let text = |key: &str| o.get(key).and_then(Value::as_str).map(str::to_owned);
            o.get("display_name")
                .and_then(Value::as_str)
                .ok_or(UsageError::InvalidJson)?;
            o.get("auth_status")
                .filter(|a| a.is_object())
                .ok_or(UsageError::InvalidJson)?;
            Ok(ProviderRow {
                id: text("id").ok_or(UsageError::InvalidJson)?,
                configured: o
                    .get("configured")
                    .and_then(Value::as_bool)
                    .ok_or(UsageError::InvalidJson)?,
                error: match o.get("error") {
                    None | Some(Value::Null) => String::new(),
                    Some(Value::String(s)) => s.clone(),
                    Some(_) => return Err(UsageError::InvalidJson),
                },
                snapshot: o.get("snapshot").filter(|s| !s.is_null()).cloned(),
                accounts: o
                    .get("accounts")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default(),
            })
        })
        .collect()
}

// --- Redaction: one redactor, in the store crate (SecretRedactor.swift) ---

pub use symcockpit_store::redact;

// --- Snapshot conversion --------------------------------------------------

/// `Some(f64)` for a valid decimal string, as the Swift `decimal(_:field:)`.
/// shortcut: values travel as f64 (Swift keeps 38 decimal digits); usage
/// figures are far below 2^53, upgrade when a provider reports more digits.
fn decimal(value: Option<&Value>, field: &str) -> Result<Option<f64>, UsageError> {
    static SHAPE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z")
            .expect("static pattern")
    });
    let invalid = || UsageError::InvalidValue(field.to_owned());
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if SHAPE.is_match(s) => s
            .parse::<f64>()
            .ok()
            .filter(|d| d.is_finite())
            .map(Some)
            .ok_or_else(invalid),
        Some(_) => Err(invalid()),
    }
}

fn date_seconds(value: Option<&Value>, field: &str) -> Result<Option<f64>, UsageError> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => parse_iso8601(s)
            .map(|unix| Some(unix - REFERENCE_DATE_OFFSET))
            .ok_or_else(|| UsageError::InvalidValue(field.to_owned())),
        Some(_) => Err(UsageError::InvalidValue(field.to_owned())),
    }
}

fn unit_json(unit: &str) -> Value {
    match unit {
        "tokens" => json!({"tokens": {}}),
        "requests" => json!({"requests": {}}),
        "credits" => json!({"credits": {}}),
        "%" | "percent" => json!({"percent": {}}),
        code => json!({"currency": {"_0": redact(code)}}),
    }
}

fn set_number(map: &mut Map<String, Value>, key: &str, value: Option<f64>) {
    if let Some(n) = value.and_then(serde_json::Number::from_f64) {
        map.insert(key.to_owned(), Value::Number(n));
    }
}

/// The legacy normalised snapshot, with dates as seconds since 2001 (the
/// default `Date` encoding of the Swift CLI).
fn snapshot_json(raw: &Value) -> Result<Value, UsageError> {
    let o = raw.as_object().ok_or(UsageError::InvalidJson)?;
    let text = |key: &str| o.get(key).and_then(Value::as_str).map(str::to_owned);
    let mut meters = Vec::new();
    for m in o
        .get("meters")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let m = m.as_object().ok_or(UsageError::InvalidJson)?;
        let mut meter = Map::new();
        meter.insert(
            "label".into(),
            json!(redact(
                m.get("label")
                    .and_then(Value::as_str)
                    .ok_or(UsageError::InvalidJson)?
            )),
        );
        set_number(&mut meter, "used", decimal(m.get("used"), "used")?);
        set_number(&mut meter, "limit", decimal(m.get("limit"), "limit")?);
        meter.insert(
            "unit".into(),
            unit_json(
                m.get("unit")
                    .and_then(Value::as_str)
                    .ok_or(UsageError::InvalidJson)?,
            ),
        );
        set_number(
            &mut meter,
            "resets_at",
            date_seconds(m.get("resets_at"), "resets_at")?,
        );
        meters.push(Value::Object(meter));
    }
    let mut snapshot = Map::new();
    snapshot.insert(
        "provider_id".into(),
        json!(text("provider_id").ok_or(UsageError::InvalidJson)?),
    );
    snapshot.insert("meters".into(), Value::Array(meters));
    set_number(
        &mut snapshot,
        "balance",
        decimal(o.get("balance"), "balance")?,
    );
    if let Some(currency) = text("currency") {
        snapshot.insert("currency".into(), json!(redact(&currency)));
    }
    set_number(
        &mut snapshot,
        "fetched_at",
        Some(date_seconds(o.get("fetched_at"), "fetched_at")?.ok_or(UsageError::InvalidJson)?),
    );
    snapshot.insert(
        "source".into(),
        json!(redact(&text("source").ok_or(UsageError::InvalidJson)?)),
    );
    snapshot_extras(&mut snapshot, o);
    Ok(Value::Object(snapshot))
}

/// The optional extras of a Brain snapshot (#453, #454): `plan`, `org_billing`
/// (Copilot seats billed to an organization) and `reset_grants` (read-only).
/// Known fields only, every string redacted; a malformed extra is dropped, never
/// failing the snapshot it rides on.
fn snapshot_extras(snapshot: &mut Map<String, Value>, o: &Map<String, Value>) {
    let text = |v: &Value, key: &str| v.get(key).and_then(Value::as_str).map(redact);
    if let Some(plan) = o.get("plan").and_then(Value::as_str) {
        snapshot.insert("plan".into(), json!(redact(plan)));
    }
    if let Some(billing) = o.get("org_billing")
        && let (Some(state), Some(detail)) = (text(billing, "state"), text(billing, "detail"))
    {
        let mut m = Map::new();
        m.insert("state".into(), json!(state));
        m.insert("detail".into(), json!(detail));
        if let Some(org) = text(billing, "organization") {
            m.insert("organization".into(), json!(org));
        }
        snapshot.insert("org_billing".into(), Value::Object(m));
    }
    let Some(status) = o.get("reset_grants") else {
        return;
    };
    let grant = |g: &Value| -> Option<Value> {
        let mut m = Map::new();
        m.insert("id".into(), json!(text(g, "id")?));
        m.insert("resets_left".into(), json!(g.get("resets_left")?.as_u64()?));
        set_number(
            &mut m,
            "ends_at",
            date_seconds(g.get("ends_at"), "ends_at").ok()?,
        );
        let clears: Vec<String> = g
            .get("clears")?
            .as_array()?
            .iter()
            .filter_map(Value::as_str)
            .map(redact)
            .collect();
        m.insert("clears".into(), json!(clears));
        Some(Value::Object(m))
    };
    let grants: Option<Vec<Value>> = status
        .get("grants")
        .and_then(Value::as_array)
        .and_then(|gs| gs.iter().map(grant).collect());
    if let (Some(eligible), Some(grants)) =
        (status.get("eligible").and_then(Value::as_bool), grants)
    {
        let mut m = Map::new();
        m.insert("eligible".into(), json!(eligible));
        m.insert("grants".into(), Value::Array(grants));
        if let Some(next) = text(status, "next_grant_id") {
            m.insert("next_grant_id".into(), json!(next));
        }
        snapshot.insert("reset_grants".into(), Value::Object(m));
    }
}

/// Which local login a row reads when Brain found several (#453): label, source,
/// state and optional detail of each, all non-secret by Brain's contract and
/// redacted again here. Entries missing a required field are dropped.
fn accounts_json(raw: &[Value]) -> Vec<Value> {
    raw.iter()
        .filter_map(|a| {
            let text = |key: &str| a.get(key).and_then(Value::as_str).map(redact);
            let mut m = Map::new();
            for key in ["label", "source", "state"] {
                m.insert(key.into(), json!(text(key)?));
            }
            if let Some(detail) = text("detail") {
                m.insert("detail".into(), json!(detail));
            }
            Some(Value::Object(m))
        })
        .collect()
}

fn with_accounts(mut result: Value, accounts: &[Value]) -> Value {
    let accounts = accounts_json(accounts);
    if !accounts.is_empty()
        && let Some(o) = result.as_object_mut()
    {
        o.insert("accounts".into(), Value::Array(accounts));
    }
    result
}

fn result_json(id: &str, snapshot: Option<Value>, error: Option<String>) -> Value {
    let mut o = Map::new();
    o.insert("provider_id".into(), json!(id));
    if let Some(s) = snapshot {
        o.insert("snapshot".into(), s);
    }
    if let Some(e) = error {
        o.insert("error".into(), json!(e));
    }
    Value::Object(o)
}

/// One result per selected catalog provider, in catalog order
/// (`AIUsageService.usageAll` without cache).
pub fn usage_report(
    runner: &dyn UsageRunner,
    inherited: &BTreeMap<String, String>,
    selection: Option<&BTreeSet<String>>,
    overrides: &BTreeMap<String, String>,
) -> Value {
    let selected: Vec<&str> = CATALOG
        .iter()
        .map(|(id, _)| *id)
        .filter(|id| selection.is_none_or(|s| s.contains(*id)))
        .collect();
    if selected.is_empty() {
        return Value::Array(Vec::new());
    }
    let rows = match fetch_report(runner, inherited, selection, overrides) {
        Ok(rows) => rows,
        Err(error) => {
            let message = error.to_string();
            return selected
                .iter()
                .map(|id| result_json(id, None, Some(message.clone())))
                .collect();
        }
    };
    selected
        .iter()
        .map(|id| {
            let Some(row) = rows.iter().find(|r| r.id == *id) else {
                return result_json(id, None, Some("AI usage unavailable. symbrain did not report this provider; it may need an update.".into()));
            };
            if !row.configured {
                return result_json(id, None, Some(NOT_CONFIGURED.into()));
            }
            if !row.error.is_empty() {
                return with_accounts(result_json(id, None, Some(redact(&row.error))), &row.accounts);
            }
            let converted = row
                .snapshot
                .as_ref()
                .filter(|s| s.get("provider_id").and_then(Value::as_str) == Some(*id))
                .and_then(|s| snapshot_json(s).ok());
            let result = match converted {
                Some(snapshot) => result_json(id, Some(snapshot), None),
                None => result_json(id, None, Some("AI usage unavailable.".into())),
            };
            with_accounts(result, &row.accounts)
        })
        .collect()
}

// --- CLI ----------------------------------------------------------------

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Options {
    pub json: bool,
    pub provider: Option<String>,
}

/// The optional `providers` argument of the agent/MCP read: absent or `null`
/// means every catalog provider, an array of catalog IDs only those (an empty
/// array asks nobody). The app passes its enabled providers, so a provider the
/// user did not select is never discovered or queried through symbrain (#394).
pub fn providers_argument(value: Option<&Value>) -> Result<Option<BTreeSet<String>>, Error> {
    let items = match value {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::Array(items)) => items,
        Some(_) => {
            return Err(Error::Usage(
                "ai-usage: providers must be an array of provider IDs".into(),
            ));
        }
    };
    let mut selection = BTreeSet::new();
    for item in items {
        let id = item.as_str().ok_or_else(|| {
            Error::Usage("ai-usage: providers must be an array of provider IDs".into())
        })?;
        if !CATALOG.iter().any(|(known, _)| *known == id) {
            return Err(Error::Usage(format!("ai-usage: unknown provider '{id}'")));
        }
        selection.insert(id.to_owned());
    }
    Ok(Some(selection))
}

/// `ai-usage [provider] [--json] [--force]`; the caller handles `--help` and
/// `serve` first.
pub fn parse_options(args: &[String]) -> Result<Options, Error> {
    let json = args.iter().any(|a| a == "--json");
    let positional: Vec<&String> = args
        .iter()
        .filter(|a| *a != "--json" && *a != "--force")
        .collect();
    if positional.len() > 1 || positional.iter().any(|a| a.starts_with('-')) {
        return Err(Error::Usage(
            "ai-usage: expected one provider and optional --json/--force".into(),
        ));
    }
    let provider = positional.first().map(|p| (*p).clone());
    if let Some(id) = &provider
        && !CATALOG.iter().any(|(known, _)| known == id)
    {
        return Err(Error::Usage(format!("ai-usage: unknown provider '{id}'")));
    }
    Ok(Options { json, provider })
}

fn money(value: f64) -> String {
    format!("{value:.2}")
}

/// Unix seconds as `ISO8601DateFormatter` / `Date.ISO8601Format` print them.
pub fn format_iso8601_utc(unix: f64) -> String {
    let secs = unix.floor() as i64;
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

/// The plain-text rendering of `usage_report`'s result array.
pub fn usage_text(results: &Value) -> String {
    let mut out = String::new();
    for result in results.as_array().into_iter().flatten() {
        let id = result["provider_id"].as_str().unwrap_or_default();
        let Some(snapshot) = result.get("snapshot") else {
            let error = result["error"].as_str().unwrap_or("unknown");
            out.push_str(&format!("{id}: not set up ({error})\n"));
            continue;
        };
        let fetched = format_iso8601_utc(
            snapshot["fetched_at"].as_f64().unwrap_or(0.0) + REFERENCE_DATE_OFFSET,
        );
        out.push_str(&format!(
            "{} (source: {}, fetched: {fetched}):\n",
            snapshot["provider_id"].as_str().unwrap_or(id),
            snapshot["source"].as_str().unwrap_or("")
        ));
        if let Some(error) = result["error"].as_str() {
            out.push_str(&format!("  Stale cached data: {error}\n"));
        }
        for meter in snapshot["meters"].as_array().into_iter().flatten() {
            let fmt = |key: &str| {
                meter
                    .get(key)
                    .and_then(Value::as_f64)
                    .map_or_else(|| "—".to_owned(), money)
            };
            let reset = meter.get("resets_at").and_then(Value::as_f64).map_or_else(
                || "—".to_owned(),
                |s| format_iso8601_utc(s + REFERENCE_DATE_OFFSET),
            );
            let unit = match meter["unit"].as_object().and_then(|u| u.iter().next()) {
                Some((k, v)) if k == "currency" => v["_0"].as_str().unwrap_or("").to_owned(),
                Some((k, _)) if k == "percent" => "%".to_owned(),
                Some((k, _)) => k.clone(),
                None => String::new(),
            };
            out.push_str(&format!(
                "  {}: {} / {} {unit} (resets {reset})\n",
                meter["label"].as_str().unwrap_or(""),
                fmt("used"),
                fmt("limit")
            ));
        }
        if let Some(balance) = snapshot.get("balance").and_then(Value::as_f64) {
            out.push_str(&format!(
                "  Balance: {} {}\n",
                money(balance),
                snapshot["currency"].as_str().unwrap_or("")
            ));
        }
    }
    out
}

pub const HELP: &str = "Usage: symcockpit ai-usage [provider] [--json] [--force]\n\nAI subscription/token usage via symbrain. Read-only;\nno credentials are ever printed. --json emits the machine-readable\nlegacy per-provider result form shared with MCP get_ai_usage.\nReuses snapshots younger than five minutes; --force refreshes now.\nA provider argument limits credential discovery and requests to that provider.\nWithout a provider argument every catalog provider is queried by symbrain,\nregardless of which providers are enabled in the Cockpit app.\nExample: symcockpit ai-usage claude --json\n";

#[cfg(test)]
mod tests {
    use std::cell::RefCell;

    use super::*;

    /// Fake `symbrain`: records every invocation, answers with canned output.
    type Call = (Vec<String>, BTreeMap<String, String>);

    struct Fake {
        calls: RefCell<Vec<Call>>,
        answer: Result<(i32, String, String), UsageError>,
    }

    impl Fake {
        fn ok(stdout: &str) -> Self {
            Fake {
                calls: RefCell::default(),
                answer: Ok((0, stdout.into(), String::new())),
            }
        }
    }

    impl UsageRunner for Fake {
        fn run(
            &self,
            args: &[String],
            env: &BTreeMap<String, String>,
        ) -> Result<CommandOutput, UsageError> {
            self.calls.borrow_mut().push((args.to_vec(), env.clone()));
            self.answer.clone().map(|(status, out, err)| CommandOutput {
                stdout: out.into_bytes(),
                stderr: err.into_bytes(),
                status,
            })
        }
    }

    const REPORT: &str = r#"{"schema_version":1,"providers":[
      {"id":"claude","display_name":"Claude","configured":true,"auth_status":{"status":"available","detail":"x","source":"oauth"},
       "snapshot":{"provider_id":"claude","meters":[{"label":"Session","used":"12.5","limit":"100","unit":"%","resets_at":"2026-11-20T15:00:00Z"},{"label":"Spend","used":"3","unit":"USD"}],"balance":"7.25","currency":"USD","fetched_at":"2026-11-20T10:00:00Z","source":"oauth"},"error":""},
      {"id":"codex","display_name":"Codex","configured":false,"auth_status":{"status":"missing","detail":"none"},"error":""},
      {"id":"openrouter","display_name":"OpenRouter","configured":true,"auth_status":{"status":"available","detail":"k"},"error":"HTTP 401 token: abcdefghijklmnop1234"},
      {"id":"kimi","display_name":"Kimi","configured":true,"auth_status":{"status":"available","detail":"k"},"snapshot":{"provider_id":"WRONG","fetched_at":"2026-11-20T10:00:00Z","source":"api"},"error":""},
      {"id":"moonshot","display_name":"M","configured":true,"auth_status":{"status":"available","detail":"k"},"snapshot":{"provider_id":"moonshot","meters":[{"label":"x","used":"nan","unit":"tokens"}],"fetched_at":"2026-11-20T10:00:00Z","source":"api"},"error":""}
    ]}"#;

    fn run(fake: &Fake, selection: Option<&[&str]>) -> Value {
        let sel: Option<BTreeSet<String>> =
            selection.map(|s| s.iter().map(|x| (*x).to_owned()).collect());
        usage_report(fake, &BTreeMap::new(), sel.as_ref(), &BTreeMap::new())
    }

    #[test]
    fn normalises_every_provider_state_in_catalog_order() {
        let results = run(&Fake::ok(REPORT), None);
        let r = results.as_array().unwrap();
        assert_eq!(r.len(), 14);
        let ids: Vec<_> = r
            .iter()
            .map(|x| x["provider_id"].as_str().unwrap())
            .collect();
        assert_eq!(ids, CATALOG.map(|(id, _)| id));
        // Snapshot with dates as seconds since 2001 and unit variants.
        let claude = &r[0]["snapshot"];
        assert_eq!(claude["fetched_at"], json!(816_861_600.0));
        assert_eq!(claude["balance"], json!(7.25));
        assert_eq!(claude["meters"][0]["unit"], json!({"percent": {}}));
        assert_eq!(claude["meters"][0]["resets_at"], json!(816_879_600.0));
        assert_eq!(
            claude["meters"][1]["unit"],
            json!({"currency": {"_0": "USD"}})
        );
        assert!(claude["meters"][1].get("limit").is_none());
        assert!(r[0].get("error").is_none());
        assert_eq!(
            r[1],
            json!({"provider_id": "codex", "error": "not configured"})
        );
        // Provider errors are redacted, wrong or invalid snapshots become generic.
        assert_eq!(r[8]["error"], "HTTP 401 <redacted>");
        assert_eq!(r[4]["error"], "AI usage unavailable.");
        assert_eq!(r[5]["error"], "AI usage unavailable.");
        // A provider missing from the report says so.
        assert!(
            r[2]["error"]
                .as_str()
                .unwrap()
                .starts_with("AI usage unavailable. symbrain did not report")
        );
    }

    #[test]
    fn passes_plan_org_billing_reset_grants_and_accounts_through() {
        let report = r#"{"schema_version":1,"providers":[
          {"id":"claude","display_name":"Claude","configured":true,"auth_status":{"status":"available","detail":"x"},
           "accounts":[{"label":"claude-1a2b3c4d","source":"claude_cli","state":"used"},
                       {"label":"claude-9f8e7d6c","source":"claude_desktop","state":"not_read","detail":"token: abcdefghijklmnop1234"},
                       {"label":"broken"}],
           "snapshot":{"provider_id":"claude","meters":[],"fetched_at":"2026-11-20T10:00:00Z","source":"oauth","plan":"Max",
             "reset_grants":{"eligible":true,"next_grant_id":"g1","grants":[{"id":"g1","resets_left":2,"ends_at":"2026-11-20T15:00:00Z","clears":["Weekly"]}]}},
           "error":""},
          {"id":"copilot","display_name":"Copilot","configured":true,"auth_status":{"status":"available","detail":"x"},
           "snapshot":{"provider_id":"copilot","meters":[],"fetched_at":"2026-11-20T10:00:00Z","source":"api",
             "org_billing":{"state":"available","detail":"month to date","organization":"acme"},
             "reset_grants":{"eligible":true,"grants":[{"id":"g","resets_left":-1,"clears":[]}]}},
           "error":""}
        ]}"#;
        let results = run(&Fake::ok(report), Some(&["claude", "copilot"]));
        let claude = &results[0];
        assert_eq!(claude["snapshot"]["plan"], "Max");
        assert_eq!(
            claude["snapshot"]["reset_grants"],
            json!({"eligible": true, "next_grant_id": "g1",
                   "grants": [{"id": "g1", "resets_left": 2, "ends_at": 816_879_600.0, "clears": ["Weekly"]}]})
        );
        assert_eq!(
            claude["accounts"],
            json!([{"label": "claude-1a2b3c4d", "source": "claude_cli", "state": "used"},
                   {"label": "claude-9f8e7d6c", "source": "claude_desktop", "state": "not_read",
                    "detail": "<redacted>"}]),
            "incomplete entries are dropped, strings redacted"
        );
        let copilot = &results[1];
        assert_eq!(
            copilot["snapshot"]["org_billing"],
            json!({"state": "available", "detail": "month to date", "organization": "acme"})
        );
        assert!(
            copilot["snapshot"].get("reset_grants").is_none(),
            "a malformed extra is dropped, the snapshot stays"
        );
        assert!(copilot.get("accounts").is_none());
    }

    #[test]
    fn builds_the_symbrain_command_and_selection() {
        let fake = Fake::ok(r#"{"schema_version":1,"providers":[]}"#);
        run(&fake, None);
        run(&fake, Some(&["openrouter", "claude"]));
        let calls = fake.calls.borrow();
        assert_eq!(calls[0].0, ["usage", "--output", "json"]);
        assert_eq!(
            calls[1].0,
            [
                "usage",
                "--output",
                "json",
                "--providers",
                "claude,openrouter"
            ]
        );
        // An explicit empty selection spawns nothing.
        drop(calls);
        assert_eq!(run(&fake, Some(&[])), json!([]));
        assert_eq!(fake.calls.borrow().len(), 2);
    }

    #[test]
    fn child_environment_carries_references_never_secrets() {
        let inherited: BTreeMap<String, String> = [
            ("PATH", "/usr/bin"),
            ("MOONSHOT_API_KEY", "user-supplied-env-value"),
            ("ZAI_API_KEY", ""),
            ("SYMBRAIN_USAGE_CLAUDE_HISTORY", "1"),
            ("SYMBRAIN_USAGE_GROK_HISTORY_ONLY", "1"),
            ("SYMBRAIN_USAGE_OTHER", "keep"),
        ]
        .map(|(k, v)| (k.to_owned(), v.to_owned()))
        .into();
        let env = child_environment(&inherited, None, &BTreeMap::new());
        assert_eq!(env["OPENROUTER_API_KEY"], "symvault://symtune/openrouter");
        assert_eq!(env["ZAI_API_KEY"], "symvault://symtune/zai");
        assert_eq!(env["KIMI_CODE_API_KEY"], "symvault://symtune/kimi");
        // An existing non-empty value is the user's own and is left alone.
        assert_eq!(env["MOONSHOT_API_KEY"], "user-supplied-env-value");
        // Local-discovery providers get no reference without an override.
        for key in ["GROK_ACCESS_TOKEN", "DEVIN_API_KEY", "OPENCODE_GO_API_KEY"] {
            assert!(!env.contains_key(key), "{key}");
        }
        assert!(!env.keys().any(|k| k.contains("_HISTORY")));
        assert_eq!(env["SYMBRAIN_USAGE_OTHER"], "keep");
        // A selection removes the other providers' keys entirely.
        let sel: BTreeSet<String> = ["openrouter".to_owned()].into();
        let one = child_environment(&inherited, Some(&sel), &BTreeMap::new());
        assert!(
            one.contains_key("OPENROUTER_API_KEY")
                && !one.contains_key("MOONSHOT_API_KEY")
                && !one.contains_key("ZAI_API_KEY")
        );
        // Overrides redirect the reference and enable local-discovery providers.
        let overrides: BTreeMap<String, String> = [
            ("openrouter", " symvault://openrouter/work/ "),
            ("grok", "x/../y"),
            ("devin", "devin/key"),
        ]
        .map(|(k, v)| (k.to_owned(), v.to_owned()))
        .into();
        let env = child_environment(&inherited, None, &overrides);
        assert_eq!(env["OPENROUTER_API_KEY"], "symvault://openrouter/work");
        assert_eq!(env["DEVIN_API_KEY"], "symvault://devin/key");
        assert!(
            !env.contains_key("GROK_ACCESS_TOKEN"),
            "an unusable override falls back to local discovery"
        );
    }

    #[test]
    fn entry_path_normalisation() {
        assert_eq!(
            normalize_entry_path("  SymVault://a/b/  "),
            Some("a/b".into())
        );
        for bad in ["", "   ", "a b", "a//b", "../a", "a/..", "a\tb", "///"] {
            assert_eq!(normalize_entry_path(bad), None, "{bad:?}");
        }
        assert_eq!(vault_reference("claude", &BTreeMap::new()), None);
    }

    #[test]
    fn failures_are_generic_and_never_leak_subprocess_output() {
        let cases = [
            (
                Ok((1, "SECRET-stdout".into(), "SECRET-stderr".into())),
                "symbrain usage failed",
            ),
            (
                Ok((0, String::new(), String::new())),
                "symbrain usage returned no output",
            ),
            (
                Ok((0, "SECRET {".into(), String::new())),
                "symbrain usage returned invalid JSON",
            ),
            (
                Ok((
                    0,
                    r#"{"schema_version":2,"providers":[]}"#.into(),
                    String::new(),
                )),
                "symbrain usage returned an unsupported schema version",
            ),
            (
                Err(UsageError::BinaryUnavailable),
                "symbrain is not installed",
            ),
        ];
        for (answer, message) in cases {
            let fake = Fake {
                calls: RefCell::default(),
                answer,
            };
            let results = run(&fake, None);
            assert_eq!(results.as_array().unwrap().len(), 14);
            assert!(
                results
                    .as_array()
                    .unwrap()
                    .iter()
                    .all(|r| r["error"] == message && r.get("snapshot").is_none()),
                "{message}"
            );
            assert!(!results.to_string().contains("SECRET"));
        }
        // Old Brains reject --providers: status 2 or a recognisable stderr phrase.
        for (status, stderr) in [(2, ""), (1, "Error: unknown flag: --providers")] {
            let fake = Fake {
                calls: RefCell::default(),
                answer: Ok((status, String::new(), stderr.into())),
            };
            let results = run(&fake, Some(&["claude"]));
            assert!(
                results[0]["error"]
                    .as_str()
                    .unwrap()
                    .starts_with("Installed symbrain is too old")
            );
        }
        let fake = Fake {
            calls: RefCell::default(),
            answer: Ok((2, String::new(), String::new())),
        };
        assert_eq!(run(&fake, None)[0]["error"], "symbrain usage failed");
    }

    #[test]
    fn invalid_provider_ids_never_reach_the_subprocess() {
        let fake = Fake::ok("{}");
        let sel: BTreeSet<String> = ["Bad;rm".to_owned()].into();
        assert_eq!(
            fetch_report(&fake, &BTreeMap::new(), Some(&sel), &BTreeMap::new()).err(),
            Some(UsageError::InvalidValue("provider ID".into()))
        );
        assert!(fake.calls.borrow().is_empty());
    }

    #[test]
    fn redactor_covers_the_credential_shapes() {
        for (input, want) in [
            ("key sk-abcdefgh12345678 end", "key <redacted> end"),
            ("ghp_abcdefghijklmnopqrstu1", "<redacted>"),
            (
                "Authorization: Bearer abcdefghijklmnop",
                "Authorization: <redacted>",
            ),
            ("api_key=\"secret value\"", "<redacted>"),
            ("«redacted:x»", "<redacted>"),
            (
                "eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.abcdefghijklm",
                "<redacted>",
            ),
            ("nothing secret", "nothing secret"),
        ] {
            assert_eq!(redact(input), want, "{input}");
        }
    }

    #[test]
    fn option_parsing_matches_swift_messages() {
        let args = |a: &[&str]| a.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
        assert_eq!(
            parse_options(&args(&["claude", "--json", "--force"])).unwrap(),
            Options {
                json: true,
                provider: Some("claude".into())
            }
        );
        assert_eq!(
            parse_options(&args(&[])).unwrap(),
            Options {
                json: false,
                provider: None
            }
        );
        assert_eq!(
            parse_options(&args(&["a", "b"])).unwrap_err().to_string(),
            "ai-usage: expected one provider and optional --json/--force"
        );
        assert_eq!(
            parse_options(&args(&["--bogus"])).unwrap_err().exit_code(),
            2
        );
        assert_eq!(
            parse_options(&args(&["nope"])).unwrap_err().to_string(),
            "ai-usage: unknown provider 'nope'"
        );
    }

    #[test]
    fn text_rendering_matches_the_swift_table() {
        let results = run(&Fake::ok(REPORT), None);
        let text = usage_text(&results);
        assert!(text.starts_with("claude (source: oauth, fetched: 2026-11-20T10:00:00Z):\n  Session: 12.50 / 100.00 % (resets 2026-11-20T15:00:00Z)\n  Spend: 3.00 / — USD (resets —)\n  Balance: 7.25 USD\ncodex: not set up (not configured)\n"), "{text}");
        assert_eq!(format_iso8601_utc(0.0), "1970-01-01T00:00:00Z");
    }

    #[test]
    fn help_text_matches_the_oracle_fixture() {
        let fixture = include_str!("../../../oracle/v0.12/cases/ai-usage-help.stdout");
        assert_eq!(HELP, fixture);
    }
}
