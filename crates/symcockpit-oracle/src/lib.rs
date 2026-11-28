//! Oracle harness: replays the frozen v0.12 manifest (`oracle/v0.12/manifest.json`)
//! against a candidate `symcockpit` binary and reports every divergence.
//!
//! Case kinds: `exact` (normalised stdout), `exit_code`, `json_shape`,
//! `mcp_tools_list` and `mcp_call_shape`. Fixture paths are relative to the
//! manifest's directory. `mcp_*` cases start `<bin> serve` and initialise with the
//! `params` found in `mcp-initialize.json` next to the manifest (either
//! `{"params": {...}}` or the bare params object), else with a default.

pub mod process;
pub mod shape;

use std::path::Path;
use std::time::Duration;

use process::{EnvSpec, McpSession, run_cli};
use regex::Regex;
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Debug, Deserialize)]
pub struct Manifest {
    pub schema: u32,
    #[serde(default)]
    pub env: EnvSpec,
    pub cases: Vec<Case>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Exact,
    ExitCode,
    JsonShape,
    McpToolsList,
    McpCallShape,
}

#[derive(Debug, Deserialize)]
pub struct Rewrite {
    pub pattern: String,
    pub replacement: String,
}

#[derive(Debug, Deserialize)]
pub struct Case {
    pub id: String,
    pub kind: Kind,
    #[serde(default)]
    pub argv: Vec<String>,
    pub expect_exit: Option<i32>,
    pub fixture: Option<String>,
    #[serde(default)]
    pub normalize: Vec<Rewrite>,
    pub tool: Option<String>,
    pub arguments: Option<Value>,
}

/// Verdict for one case. A case passes when `errors` is empty and it was not
/// `skipped`; `hints` are tolerated drift. Only native mode skips: a skipped
/// case verified nothing and must never be counted as passed.
#[derive(Debug)]
pub struct CaseResult {
    pub id: String,
    pub errors: Vec<String>,
    pub hints: Vec<String>,
    pub skipped: Option<String>,
}

/// Run every case of the manifest against `bin`.
pub fn run_manifest(
    manifest_path: &Path,
    bin: &Path,
    timeout: Duration,
) -> Result<Vec<CaseResult>, String> {
    run_manifest_in(manifest_path, bin, timeout, None)
}

/// Native mode (`SYMCOCKPIT_ORACLE_NATIVE=1`): the candidate gets a tripwire
/// instead of a Swift binary. Only cases whose command is `Read` in the
/// register run; a case that makes the candidate forward to Swift is reported
/// as skipped ("forwarded"), never as passed.
pub fn run_manifest_native(
    manifest_path: &Path,
    bin: &Path,
    timeout: Duration,
) -> Result<Vec<CaseResult>, String> {
    let dir = tempfile::tempdir().map_err(|e| format!("tempdir: {e}"))?;
    let tripwire = Tripwire::create(dir.path())?;
    run_manifest_in(manifest_path, bin, timeout, Some(&tripwire))
}

/// A stand-in for the legacy binary that records being called and fails.
struct Tripwire {
    script: std::path::PathBuf,
    marker: std::path::PathBuf,
}

impl Tripwire {
    fn create(dir: &Path) -> Result<Self, String> {
        use std::os::unix::fs::PermissionsExt;
        let (script, marker) = (dir.join("tripwire"), dir.join("forwarded"));
        std::fs::write(
            &script,
            format!(
                "#!/bin/sh\nprintf 'forwarded\\n' > '{}'\nexit 97\n",
                marker.display()
            ),
        )
        .and_then(|()| std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)))
        .map_err(|e| format!("tripwire: {e}"))?;
        Ok(Self { script, marker })
    }

    fn reset(&self) {
        let _ = std::fs::remove_file(&self.marker);
    }

    fn fired(&self) -> bool {
        self.marker.exists()
    }
}

/// Why a case must not run in native mode, `None` when it may.
fn not_a_read_case(case: &Case) -> Option<String> {
    use symcockpit_contract::{Risk, commands};
    let skip = || Some("not a read command".to_owned());
    match case.kind {
        Kind::McpToolsList => None,
        Kind::McpCallShape => {
            let tool = case.tool.as_deref()?;
            match commands().iter().find(|c| c.mcp_name == Some(tool)) {
                Some(spec) if spec.risk == Risk::Read => None,
                Some(_) => skip(),
                None => None,
            }
        }
        _ => {
            let words: Vec<&str> = case.argv.iter().map(String::as_str).collect();
            let matched = commands()
                .iter()
                .filter(|c| {
                    let path: Vec<&str> = c.cli_path.split(' ').collect();
                    words.starts_with(&path)
                })
                .max_by_key(|c| c.cli_path.len());
            if let Some(spec) = matched {
                // Bare `fan profile` / `fan target` read the selection; an argument sets it.
                let read_form = matches!(words.as_slice(), ["fan", "profile" | "target"]);
                return if spec.risk == Risk::Read || read_form {
                    None
                } else {
                    skip()
                };
            }
            let family = words.first().copied();
            let in_register = commands()
                .iter()
                .any(|c| c.cli_path.split(' ').next() == family);
            // `fan --help` and friends are usage text, and a bare family that
            // the oracle recorded as a usage error (exit 2) never reached a
            // write; anything else in a register family without a Read match
            // is a write.
            let usage_error = words.len() == 1 && case.expect_exit == Some(2);
            if in_register && !usage_error && !words.iter().any(|w| matches!(*w, "--help" | "-h")) {
                skip()
            } else {
                None
            }
        }
    }
}

fn run_manifest_in(
    manifest_path: &Path,
    bin: &Path,
    timeout: Duration,
    tripwire: Option<&Tripwire>,
) -> Result<Vec<CaseResult>, String> {
    let text = std::fs::read_to_string(manifest_path)
        .map_err(|e| format!("{}: {e}", manifest_path.display()))?;
    let mut manifest: Manifest =
        serde_json::from_str(&text).map_err(|e| format!("{}: {e}", manifest_path.display()))?;
    if let Some(tripwire) = tripwire {
        manifest.env.legacy_override = Some(tripwire.script.clone().into_os_string());
    }
    if manifest.schema != 1 {
        return Err(format!("unsupported manifest schema {}", manifest.schema));
    }
    let dir = manifest_path.parent().unwrap_or(Path::new("."));
    let init = initialize_params(dir)?;
    let allowed = allowed_drift(dir)?;
    Ok(manifest
        .cases
        .iter()
        .map(|case| {
            let mut result = CaseResult {
                id: case.id.clone(),
                errors: Vec::new(),
                hints: Vec::new(),
                skipped: None,
            };
            if tripwire.is_some() {
                result.skipped = not_a_read_case(case);
                if result.skipped.is_some() {
                    return result;
                }
            }
            if let Some(t) = tripwire {
                t.reset();
            }
            if let Err(error) = run_case(case, dir, bin, &manifest.env, &init, timeout, &mut result)
            {
                result.errors.push(error);
            }
            if let Some(keys) = allowed.get(&case.id) {
                apply_allowed_drift(keys, &mut result);
            }
            if tripwire.is_some_and(Tripwire::fired) {
                result.errors.clear();
                result.hints.clear();
                result.skipped =
                    Some("forwarded to the Swift core (no native implementation yet)".to_owned());
            }
            result
        })
        .collect())
}

/// Documented drift from the frozen fixtures, per case: `{"<case id>": {"<$.json.path.key>":
/// "<reason>"}}` in `allowed-drift.json` one directory above the manifest, outside the
/// frozen fixture directory. Missing file: nothing is allowed.
type AllowedDrift = std::collections::BTreeMap<String, std::collections::BTreeMap<String, String>>;

fn allowed_drift(dir: &Path) -> Result<AllowedDrift, String> {
    let path = dir.join("../allowed-drift.json");
    if !path.is_file() {
        return Ok(AllowedDrift::new());
    }
    let mut value = read_json(&path)?;
    let cases = value
        .get_mut("cases")
        .map(Value::take)
        .ok_or_else(|| format!("{}: expected {{\"cases\": {{...}}}}", path.display()))?;
    serde_json::from_value(cases).map_err(|e| format!("{}: {e}", path.display()))
}

/// Turns a missing or extra key listed for this case into a hint carrying its
/// reason. Every other error stays an error, so unlisted drift still fails.
fn apply_allowed_drift(keys: &std::collections::BTreeMap<String, String>, result: &mut CaseResult) {
    let pattern = Regex::new(r"^(\S+): (?:missing|unexpected) key '(.+)'$").expect("static regex");
    let (allowed, kept): (Vec<String>, Vec<String>) = std::mem::take(&mut result.errors)
        .into_iter()
        .partition(|error| {
            pattern
                .captures(error)
                .is_some_and(|c| keys.contains_key(&format!("{}.{}", &c[1], &c[2])))
        });
    result.errors = kept;
    for error in allowed {
        let c = pattern.captures(&error).expect("matched above");
        let reason = &keys[&format!("{}.{}", &c[1], &c[2])];
        result.hints.push(format!("{error} (allowed: {reason})"));
    }
}

fn initialize_params(dir: &Path) -> Result<Value, String> {
    let default = json!({
        "protocolVersion": "2025-06-18",
        "capabilities": {},
        "clientInfo": {"name": "symcockpit-oracle", "version": "1"}
    });
    let path = dir.join("mcp-initialize.json");
    if !path.exists() {
        return Ok(default);
    }
    let value = read_json(&path)?;
    match (value.get("params"), value.get("protocolVersion")) {
        (Some(params), _) => Ok(params.clone()),
        (None, Some(_)) => Ok(value),
        _ => Err(format!(
            "{}: expected a params object or {{\"params\": ...}}",
            path.display()
        )),
    }
}

fn read_json(path: &Path) -> Result<Value, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))
}

fn fixture(case: &Case) -> Result<&str, String> {
    case.fixture
        .as_deref()
        .ok_or_else(|| format!("case '{}' needs a fixture", case.id))
}

fn run_case(
    case: &Case,
    dir: &Path,
    bin: &Path,
    env: &EnvSpec,
    init: &Value,
    timeout: Duration,
    result: &mut CaseResult,
) -> Result<(), String> {
    match case.kind {
        Kind::ExitCode => {
            check_exit(&run_cli(bin, &case.argv, env, timeout)?, case, result);
        }
        Kind::Exact => {
            let out = run_cli(bin, &case.argv, env, timeout)?;
            check_exit(&out, case, result);
            let expected = std::fs::read(dir.join(fixture(case)?)).map_err(|e| e.to_string())?;
            let actual = normalize(&out.stdout, &case.normalize)?;
            let expected = normalize(&expected, &case.normalize)?;
            if actual != expected {
                result.errors.push(first_difference(&expected, &actual));
            }
        }
        Kind::JsonShape => {
            let out = run_cli(bin, &case.argv, env, timeout)?;
            check_exit(&out, case, result);
            let actual: Value = serde_json::from_slice(&out.stdout)
                .map_err(|e| format!("stdout is not JSON: {e}"))?;
            compare_shape(&read_json(&dir.join(fixture(case)?))?, &actual, result)?;
        }
        Kind::McpToolsList => {
            let mut session = McpSession::start(bin, env, init, timeout)?;
            let actual = session.request("tools/list", json!({}))?;
            let expected = read_json(&dir.join(fixture(case)?))?;
            // Fixtures live in oracle/<version>/; the snapshots of the newer tools in snapshots/.
            let snapshot_file = dir.join("../../snapshots/mcp/tools_list.json");
            let snapshot = if snapshot_file.is_file() {
                read_json(&snapshot_file)?
            } else {
                Value::Null
            };
            result
                .errors
                .extend(compare_tools_list(&expected, &actual, &snapshot));
        }
        Kind::McpCallShape => {
            let tool = case.tool.as_deref().ok_or("mcp_call_shape needs a tool")?;
            let arguments = case.arguments.clone().unwrap_or_else(|| json!({}));
            let mut session = McpSession::start(bin, env, init, timeout)?;
            let actual =
                session.request("tools/call", json!({"name": tool, "arguments": arguments}))?;
            // Tool payloads travel as JSON text in the first content block.
            let payload = actual["content"][0]["text"]
                .as_str()
                .and_then(|text| serde_json::from_str::<Value>(text).ok())
                .unwrap_or(actual);
            compare_shape(&read_json(&dir.join(fixture(case)?))?, &payload, result)?;
        }
    }
    Ok(())
}

fn check_exit(out: &process::Output, case: &Case, result: &mut CaseResult) {
    let want = case.expect_exit.unwrap_or(0);
    if out.code != Some(want) {
        result
            .errors
            .push(format!("exit code: expected {want}, got {:?}", out.code));
    }
}

fn compare_shape(
    expected_shape: &Value,
    actual: &Value,
    result: &mut CaseResult,
) -> Result<(), String> {
    let diff = shape::compare(expected_shape, &shape::derive(actual)?);
    result.errors.extend(diff.errors);
    result.hints.extend(diff.hints);
    Ok(())
}

/// `tools/list` against the frozen v0.12 result: the v0.12 tools must match it
/// value for value; any other tool is allowed only when the register declares
/// it (`mcp_name`) and `snapshot` (the schema snapshot of the newer tools,
/// `{"tools": [...]}` or `null`) holds exactly the tool the server lists.
/// Differences by name come first, then any other difference.
pub fn compare_tools_list(expected: &Value, actual: &Value, snapshot: &Value) -> Vec<String> {
    let list = |v: &Value| v["tools"].as_array().cloned().unwrap_or_default();
    let name = |t: &Value| t["name"].as_str().unwrap_or_default().to_owned();
    let (want, got, snap) = (list(expected), list(actual), list(snapshot));
    let want_names: Vec<String> = want.iter().map(name).collect();
    let got_names: Vec<String> = got.iter().map(name).collect();
    let mut errors: Vec<String> = want_names
        .iter()
        .filter(|n| !got_names.contains(n))
        .map(|n| format!("missing tool '{n}'"))
        .collect();
    let v012: Vec<Value> = got
        .iter()
        .filter(|t| want_names.contains(&name(t)))
        .cloned()
        .collect();
    errors.extend(shape::equal(expected, &json!({"tools": v012})));
    for tool in got.iter().filter(|t| !want_names.contains(&name(t))) {
        let n = name(tool);
        if !symcockpit_contract::commands()
            .iter()
            .any(|c| c.mcp_name == Some(n.as_str()))
        {
            errors.push(format!("unexpected tool '{n}'"));
        } else if let Some(declared) = snap.iter().find(|s| name(s) == n) {
            errors.extend(
                shape::equal(declared, tool)
                    .into_iter()
                    .map(|e| format!("tool '{n}' differs from its snapshot: {e}")),
            );
        } else {
            errors.push(format!("tool '{n}' has no schema snapshot"));
        }
    }
    errors.extend(
        snap.iter()
            .map(name)
            .filter(|n| !got_names.contains(n))
            .map(|n| format!("snapshot tool '{n}' is not listed")),
    );
    errors
}

/// Apply the manifest's regex rewrites to UTF-8 output; non-UTF-8 passes through untouched.
fn normalize(bytes: &[u8], rewrites: &[Rewrite]) -> Result<Vec<u8>, String> {
    if rewrites.is_empty() {
        return Ok(bytes.to_vec());
    }
    let mut text = String::from_utf8(bytes.to_vec()).map_err(|_| "normalize needs UTF-8 output")?;
    for rewrite in rewrites {
        let re = Regex::new(&rewrite.pattern)
            .map_err(|e| format!("bad pattern '{}': {e}", rewrite.pattern))?;
        text = re
            .replace_all(&text, rewrite.replacement.as_str())
            .into_owned();
    }
    Ok(text.into_bytes())
}

fn first_difference(expected: &[u8], actual: &[u8]) -> String {
    let at = expected
        .iter()
        .zip(actual)
        .position(|(a, b)| a != b)
        .unwrap_or(expected.len().min(actual.len()));
    let excerpt = |b: &[u8]| {
        String::from_utf8_lossy(&b[at.min(b.len())..(at + 40).min(b.len())]).into_owned()
    };
    format!(
        "stdout differs at byte {at} ({} vs {} bytes): expected {:?}, got {:?}",
        expected.len(),
        actual.len(),
        excerpt(expected),
        excerpt(actual)
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_listed_drift_becomes_a_hint() {
        let keys = std::collections::BTreeMap::from([
            ("$.fans".to_owned(), "added in v0.13.1".to_owned()),
            ("$.a.gone".to_owned(), "machine state".to_owned()),
        ]);
        let mut result = CaseResult {
            id: "fan-status".into(),
            errors: vec![
                "$: unexpected key 'fans'".into(),
                "$.a: missing key 'gone'".into(),
                "$: unexpected key 'other'".into(),
                "$.fans: expected type array, got object".into(),
            ],
            hints: Vec::new(),
            skipped: None,
        };
        apply_allowed_drift(&keys, &mut result);
        assert_eq!(
            result.errors,
            [
                "$: unexpected key 'other'",
                "$.fans: expected type array, got object"
            ]
        );
        assert_eq!(
            result.hints,
            [
                "$: unexpected key 'fans' (allowed: added in v0.13.1)",
                "$.a: missing key 'gone' (allowed: machine state)"
            ]
        );
    }

    #[test]
    fn the_shipped_allow_list_parses() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../oracle/v0.12");
        let allowed = allowed_drift(&dir).expect("allowed-drift.json parses");
        assert!(allowed["fan-status"].contains_key("$.software_override"));
    }

    #[test]
    fn normalize_rewrites_both_sides_and_exact_compare_is_byte_exact() {
        let rewrite = [Rewrite {
            pattern: r"\d+\.\d+°C".into(),
            replacement: "<T>".into(),
        }];
        assert_eq!(
            normalize(b"cpu 45.5\xc2\xb0C\n", &rewrite).unwrap(),
            b"cpu <T>\n"
        );
        assert!(normalize(b"\xff", &rewrite).is_err());
        assert_eq!(normalize(b"\xff", &[]).unwrap(), b"\xff");
        assert!(first_difference(b"abc\n", b"abd\n").contains("byte 2"));
    }

    #[test]
    fn tools_list_reports_missing_undeclared_and_changed_tools() {
        let tool = |name: &str, max: Value| json!({"name": name, "inputSchema": {"maximum": max}});
        let expected = json!({"tools": [tool("a", json!(1)), tool("b", json!(1))]});
        assert!(
            compare_tools_list(
                &expected,
                &json!({"tools": [tool("a", json!(1.0)), tool("b", json!(1))]}),
                &Value::Null
            )
            .is_empty()
        );
        let errors = compare_tools_list(
            &expected,
            &json!({"tools": [tool("a", json!(1)), tool("c", json!(1))]}),
            &Value::Null,
        );
        assert!(
            errors.contains(&"missing tool 'b'".to_owned()),
            "{errors:?}"
        );
        assert!(
            errors.contains(&"unexpected tool 'c'".to_owned()),
            "{errors:?}"
        );
        let changed = compare_tools_list(
            &expected,
            &json!({"tools": [tool("a", json!(2)), tool("b", json!(1))]}),
            &Value::Null,
        );
        assert_eq!(
            changed,
            ["$.tools[0].inputSchema.maximum: expected 1, got 2"]
        );
    }

    #[test]
    fn a_new_tool_needs_a_register_entry_and_an_equal_snapshot() {
        let tool = |name: &str, max: i64| json!({"name": name, "inputSchema": {"maximum": max}});
        let expected = json!({"tools": [tool("get_sensors", 1)]});
        // `get_storage_health` is declared in the register.
        let listed = json!({"tools": [tool("get_sensors", 1), tool("get_storage_health", 5)]});
        let snapshot = json!({"tools": [tool("get_storage_health", 5)]});
        assert!(compare_tools_list(&expected, &listed, &snapshot).is_empty());
        // Declared but no snapshot, or a snapshot that differs.
        assert_eq!(
            compare_tools_list(&expected, &listed, &Value::Null),
            ["tool 'get_storage_health' has no schema snapshot"]
        );
        let stale = json!({"tools": [tool("get_storage_health", 6)]});
        let errors = compare_tools_list(&expected, &listed, &stale);
        assert_eq!(errors.len(), 1, "{errors:?}");
        assert!(
            errors[0].contains("differs from its snapshot"),
            "{errors:?}"
        );
        // A tool the register does not declare is refused even with a snapshot.
        let rogue = json!({"tools": [tool("get_sensors", 1), tool("rogue_tool", 1)]});
        let errors = compare_tools_list(
            &expected,
            &rogue,
            &json!({"tools": [tool("rogue_tool", 1)]}),
        );
        assert_eq!(errors, ["unexpected tool 'rogue_tool'"]);
        // A snapshot tool the server stopped listing.
        let errors = compare_tools_list(&expected, &expected, &snapshot);
        assert_eq!(errors, ["snapshot tool 'get_storage_health' is not listed"]);
    }
}
