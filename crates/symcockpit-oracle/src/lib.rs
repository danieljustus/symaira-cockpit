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

/// Verdict for one case. A case passes when `errors` is empty; `hints` are tolerated drift.
#[derive(Debug)]
pub struct CaseResult {
    pub id: String,
    pub errors: Vec<String>,
    pub hints: Vec<String>,
}

/// Run every case of the manifest against `bin`.
pub fn run_manifest(
    manifest_path: &Path,
    bin: &Path,
    timeout: Duration,
) -> Result<Vec<CaseResult>, String> {
    let text = std::fs::read_to_string(manifest_path)
        .map_err(|e| format!("{}: {e}", manifest_path.display()))?;
    let manifest: Manifest =
        serde_json::from_str(&text).map_err(|e| format!("{}: {e}", manifest_path.display()))?;
    if manifest.schema != 1 {
        return Err(format!("unsupported manifest schema {}", manifest.schema));
    }
    let dir = manifest_path.parent().unwrap_or(Path::new("."));
    let init = initialize_params(dir)?;
    Ok(manifest
        .cases
        .iter()
        .map(|case| {
            let mut result = CaseResult {
                id: case.id.clone(),
                errors: Vec::new(),
                hints: Vec::new(),
            };
            if let Err(error) = run_case(case, dir, bin, &manifest.env, &init, timeout, &mut result)
            {
                result.errors.push(error);
            }
            result
        })
        .collect())
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
            result.errors.extend(compare_tools_list(&expected, &actual));
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

/// Tool-list differences by name first, then any other difference in the full `result`.
pub fn compare_tools_list(expected: &Value, actual: &Value) -> Vec<String> {
    let names = |v: &Value| -> Vec<String> {
        v["tools"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|t| t["name"].as_str().map(str::to_owned))
            .collect()
    };
    let (want, got) = (names(expected), names(actual));
    let mut errors: Vec<String> = want
        .iter()
        .filter(|n| !got.contains(n))
        .map(|n| format!("missing tool '{n}'"))
        .collect();
    errors.extend(
        got.iter()
            .filter(|n| !want.contains(n))
            .map(|n| format!("unexpected tool '{n}'")),
    );
    errors.extend(shape::equal(expected, actual));
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
    fn tools_list_reports_missing_extra_and_changed_tools() {
        let tool = |name: &str, max: Value| json!({"name": name, "inputSchema": {"maximum": max}});
        let expected = json!({"tools": [tool("a", json!(1)), tool("b", json!(1))]});
        assert!(
            compare_tools_list(
                &expected,
                &json!({"tools": [tool("a", json!(1.0)), tool("b", json!(1))]})
            )
            .is_empty()
        );
        let errors = compare_tools_list(
            &expected,
            &json!({"tools": [tool("a", json!(1)), tool("c", json!(1))]}),
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
        );
        assert_eq!(
            changed,
            ["$.tools[0].inputSchema.maximum: expected 1, got 2"]
        );
    }
}
