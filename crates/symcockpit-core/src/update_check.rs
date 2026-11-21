//! The update check of `symcockpit version`: `CockpitUpdatePolicy` and
//! `checkForCockpitUpdate` of v0.12 with `SymairaUpdateCheck.UpdateChecker` (corekit
//! 0.23.1). No network and no clock in here: the caller hands in the fetch, the cache
//! bytes and the time, and writes back whatever cache this returns.
//!
//! shortcut: the texts of transport failures are Foundation's `localizedDescription`
//! for the usual `URLError` codes, chosen from curl's exit status; an unusual failure
//! gets the generic one.

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::ai_usage::REFERENCE_DATE_OFFSET;

pub const OWNER: &str = "danieljustus";
pub const REPO: &str = "symaira-cockpit";
pub const CACHE_TTL_SECS: f64 = 24.0 * 60.0 * 60.0;

// ------------------------------------------------------------------ the policy

/// `CockpitUpdatePolicy` plus `UpdateChecker.isUpdateCheckEnabled`: `skip` is what
/// `checkForCockpitUpdateIfEnabled` answers `.skipped` for.
pub fn should_check(
    no_update_check_flag: bool,
    interactive: bool,
    cockpit_env: Option<&str>,
    tune_env: Option<&str>,
    config_toml: Option<&str>,
) -> bool {
    let cockpit = cockpit_env.map(str::to_lowercase);
    if no_update_check_flag
        || cockpit
            .as_deref()
            .is_some_and(|v| ["0", "false", "no", "off"].contains(&v))
    {
        return false;
    }
    let enabled = if let Some(value) = tune_env {
        matches!(value.to_lowercase().as_str(), "1" | "true")
    } else {
        config_toml.is_none_or(config_enabled)
    };
    let explicit = matches!(cockpit.as_deref(), Some("1" | "true" | "yes" | "on"));
    enabled && (interactive || explicit)
}

fn config_enabled(text: &str) -> bool {
    let table = symcockpit_store::parse_toml(text);
    match table.get("general", "check_updates") {
        Some(v) => v
            .as_bool()
            .or_else(|| v.as_int().map(|n| n == 1))
            .or_else(|| {
                v.as_str()
                    .map(|s| s.eq_ignore_ascii_case("true") || s == "1")
            })
            .unwrap_or(true),
        None => true,
    }
}

// ------------------------------------------------------------------ versions

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct StableVersion(u64, u64, u64);

impl StableVersion {
    /// `StableVersion(_:)`: `v1.2.3` or `1.2.3`; no pre-release or build part.
    pub fn parse(raw: &str) -> Option<Self> {
        let text = raw.trim();
        let text = text.strip_prefix(['v', 'V']).unwrap_or(text);
        if text.contains(['-', '+']) {
            return None;
        }
        let number = |s: &str| {
            (!s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
                .then(|| s.parse::<u64>().ok())
                .flatten()
        };
        let mut parts = text.split('.');
        let version = Self(
            number(parts.next()?)?,
            number(parts.next()?)?,
            number(parts.next()?)?,
        );
        parts.next().is_none().then_some(version)
    }
}

// ------------------------------------------------------------------ the answer

#[derive(Clone, Debug, PartialEq)]
pub struct Release {
    pub tag: String,
    pub html_url: String,
    pub assets: Vec<Value>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum UpdateError {
    HttpStatus(u16),
    DecodeFailed,
    Draft,
    Prerelease,
    InvalidTag(String),
    /// A transport failure: curl's exit status.
    Network(i32),
}

impl UpdateError {
    /// `error.localizedDescription`.
    pub fn localized(&self) -> String {
        let code = match self {
            Self::HttpStatus(_) => 0,
            Self::DecodeFailed => 1,
            Self::Draft => 2,
            Self::Prerelease => 3,
            Self::InvalidTag(_) => 4,
            Self::Network(status) => {
                return match status {
                    6 => "A server with the specified hostname could not be found.",
                    7 => "Could not connect to the server.",
                    28 => "The request timed out.",
                    35 | 51 | 58 | 60 | 77 => "A TLS error caused the secure connection to fail.",
                    52 | 56 => "The network connection was lost.",
                    _ => "The Internet connection appears to be offline.",
                }
                .to_owned();
            }
        };
        format!(
            "The operation couldn\u{2019}t be completed. (SymairaUpdateCheck.UpdateCheckError error {code}.)"
        )
    }
}

/// `CockpitUpdateReport`: what `version` prints under `update`.
#[derive(Clone, Debug, PartialEq)]
pub enum Report {
    Skipped,
    UpToDate,
    Available(Release),
    Unavailable(String),
}

impl Report {
    pub fn status(&self) -> &'static str {
        match self {
            Self::Skipped => "skipped",
            Self::UpToDate => "up_to_date",
            Self::Available(_) => "available",
            Self::Unavailable(_) => "unavailable",
        }
    }

    /// The `update` object of `version --json` (nil members are absent).
    pub fn to_json(&self) -> Value {
        match self {
            Self::Available(release) => json!({
                "status": "available", "update_available": true,
                "latest_version": release.tag, "release_url": release.html_url,
            }),
            Self::Unavailable(error) => {
                json!({"status": "unavailable", "update_available": false, "error": error})
            }
            other => json!({"status": other.status(), "update_available": false}),
        }
    }

    /// The suffix of the text form: `symcockpit 0.12.2` plus this.
    pub fn text_suffix(&self) -> String {
        match self {
            Self::Available(release) => format!(" \u{2014} update available: {}", release.tag),
            Self::Unavailable(_) => " \u{2014} update check unavailable".into(),
            Self::Skipped => " \u{2014} update check skipped".into(),
            Self::UpToDate => " \u{2014} up to date".into(),
        }
    }
}

// ------------------------------------------------------------------ the check

/// Where `UpdateChecker` keeps its cache, below the user's Caches directory.
pub fn cache_file_name() -> String {
    let digest = Sha256::digest(format!("{OWNER}\0{REPO}").as_bytes());
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    format!("symaira/updatecheck/{hex}.json")
}

fn decode_cache(bytes: &[u8], now_unix: f64) -> Option<Release> {
    let entry: Value = serde_json::from_slice(bytes).ok()?;
    let fetched = entry.get("fetchedAt")?.as_f64()? + REFERENCE_DATE_OFFSET;
    (now_unix - fetched < CACHE_TTL_SECS).then_some(())?;
    Some(Release {
        tag: entry.get("tagName")?.as_str()?.to_owned(),
        html_url: entry.get("htmlURL")?.as_str()?.to_owned(),
        assets: entry
            .get("assets")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default(),
    })
}

fn encode_cache(release: &Release, now_unix: f64) -> Vec<u8> {
    json!({
        "tagName": release.tag, "htmlURL": release.html_url, "assets": release.assets,
        "fetchedAt": now_unix - REFERENCE_DATE_OFFSET,
    })
    .to_string()
    .into_bytes()
}

/// One GitHub `releases/latest` answer, as `fetchLatest` reads it.
fn parse_release(status: u16, body: &[u8]) -> Result<Release, UpdateError> {
    if !(200..300).contains(&status) {
        return Err(UpdateError::HttpStatus(status));
    }
    let v: Value = serde_json::from_slice(body).map_err(|_| UpdateError::DecodeFailed)?;
    let flag = |key: &str| match v.get(key) {
        None | Some(Value::Null) => Ok(false),
        Some(Value::Bool(b)) => Ok(*b),
        Some(_) => Err(UpdateError::DecodeFailed),
    };
    let (draft, prerelease) = (flag("draft")?, flag("prerelease")?);
    let text = |key: &str| {
        v.get(key)
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or(UpdateError::DecodeFailed)
    };
    let (tag, html_url) = (text("tag_name")?, text("html_url")?);
    let assets = match v.get("assets") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(items)) => items
            .iter()
            .map(|a| {
                Some(json!({
                    "name": a.get("name")?.as_str()?,
                    "browser_download_url": a.get("browser_download_url")?.as_str()?,
                    "size": a.get("size")?.as_i64()?,
                }))
            })
            .collect::<Option<Vec<_>>>()
            .ok_or(UpdateError::DecodeFailed)?,
        Some(_) => return Err(UpdateError::DecodeFailed),
    };
    if draft {
        return Err(UpdateError::Draft);
    }
    if prerelease {
        return Err(UpdateError::Prerelease);
    }
    Ok(Release {
        tag,
        html_url,
        assets,
    })
}

/// The transport's answer: status and body, or curl's exit status.
pub type Fetched = Result<(u16, Vec<u8>), i32>;

/// `checkForCockpitUpdate`: the report, and the cache bytes to store when a fresh
/// release was fetched.
pub fn check(
    current: &str,
    now_unix: f64,
    cache: Option<&[u8]>,
    fetch: impl FnOnce() -> Fetched,
) -> (Report, Option<Vec<u8>>) {
    let Some(current) = StableVersion::parse(current) else {
        return (Report::UpToDate, None);
    };
    let cached = cache
        .and_then(|bytes| decode_cache(bytes, now_unix))
        .filter(|r| StableVersion::parse(&r.tag).is_some());
    let (release, store) = match cached {
        Some(release) => (release, None),
        None => {
            let fetched = match fetch() {
                Ok((status, body)) => parse_release(status, &body),
                Err(status) => Err(UpdateError::Network(status)),
            };
            let release = match fetched {
                Ok(r) if StableVersion::parse(&r.tag).is_some() => r,
                Ok(r) => {
                    return (
                        Report::Unavailable(UpdateError::InvalidTag(r.tag).localized()),
                        None,
                    );
                }
                Err(e) => return (Report::Unavailable(e.localized()), None),
            };
            let bytes = encode_cache(&release, now_unix);
            (release, Some(bytes))
        }
    };
    let latest = StableVersion::parse(&release.tag).expect("checked above");
    // A pre-1.0 build is not offered 1.0 or later before the ecosystem decided.
    let newer = latest > current && !(current.0 == 0 && latest.0 > 0);
    (
        if newer {
            Report::Available(release)
        } else {
            Report::UpToDate
        },
        store,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: f64 = 1_800_000_000.0;

    fn release(tag: &str) -> Vec<u8> {
        json!({"tag_name": tag, "html_url": format!("https://example.test/{tag}"), "assets": []})
            .to_string()
            .into_bytes()
    }

    #[test]
    fn policy_follows_the_swift_precedence() {
        // Not interactive and not asked: skipped. Interactive: checked.
        assert!(!should_check(false, false, None, None, None));
        assert!(should_check(false, true, None, None, None));
        assert!(should_check(false, false, Some("YES"), None, None));
        // Opt-outs beat everything.
        assert!(!should_check(true, true, Some("1"), None, None));
        assert!(!should_check(false, true, Some("Off"), Some("1"), None));
        // SYMTUNE_CHECK_UPDATES: only 1/true enables; anything else disables.
        assert!(should_check(false, true, None, Some("TRUE"), None));
        assert!(!should_check(false, true, None, Some("yes"), None));
        assert!(!should_check(false, true, None, Some(""), None));
        // config.toml only counts without the environment variable.
        let off = "[general]\ncheck_updates = false\n";
        assert!(!should_check(false, true, None, None, Some(off)));
        assert!(should_check(false, true, None, Some("1"), Some(off)));
        assert!(!should_check(
            false,
            true,
            None,
            None,
            Some("[general]\ncheck_updates = \"false\"\n")
        ));
        assert!(!should_check(
            false,
            true,
            None,
            None,
            Some("[general]\ncheck_updates = 0\n")
        ));
        assert!(should_check(
            false,
            true,
            None,
            None,
            Some("[general]\ncheck_updates = 1\n")
        ));
        assert!(should_check(
            false,
            true,
            None,
            None,
            Some("not toml at all")
        ));
    }

    #[test]
    fn versions_are_stable_three_part_numbers() {
        assert_eq!(
            StableVersion::parse("v0.12.2"),
            StableVersion::parse(" 0.12.2 ")
        );
        assert!(StableVersion::parse("0.13.0") > StableVersion::parse("0.12.9"));
        for bad in [
            "1.2",
            "1.2.3.4",
            "1.2.3-rc1",
            "1.2.3+b",
            "a.b.c",
            "",
            "1..3",
            "-1.2.3",
        ] {
            assert_eq!(StableVersion::parse(bad), None, "{bad}");
        }
    }

    #[test]
    fn a_newer_release_is_available_and_cached_then_the_cache_answers() {
        let (report, store) = check("0.12.2", NOW, None, || Ok((200, release("v0.12.3"))));
        assert_eq!(report.status(), "available");
        assert_eq!(report.text_suffix(), " \u{2014} update available: v0.12.3");
        assert_eq!(
            report.to_json()["release_url"],
            "https://example.test/v0.12.3"
        );
        // The cache it wrote answers the next call without a fetch.
        let (again, none) = check("0.12.2", NOW + 60.0, store.as_deref(), || panic!("fetched"));
        assert_eq!(again, report);
        assert!(none.is_none());
        // A day later it is stale and asks again.
        let (up, _) = check("0.12.3", NOW + 90_000.0, store.as_deref(), || {
            Ok((200, release("v0.12.3")))
        });
        assert_eq!(up, Report::UpToDate);
    }

    #[test]
    fn the_same_or_an_older_release_is_up_to_date_and_zero_major_skips_one_zero() {
        let up = |current: &str, tag: &str| check(current, NOW, None, || Ok((200, release(tag)))).0;
        assert_eq!(up("0.12.2", "v0.12.2"), Report::UpToDate);
        assert_eq!(up("0.12.2", "v0.11.0"), Report::UpToDate);
        assert_eq!(up("0.12.2", "v1.0.0"), Report::UpToDate);
        assert_eq!(up("1.0.0", "v1.0.1").status(), "available");
        // A dev build never sees an update nag and never fetches.
        let (dev, _) = check("0.12.2-dev", NOW, None, || panic!("fetched"));
        assert_eq!(dev, Report::UpToDate);
    }

    #[test]
    fn failures_carry_foundations_message_and_are_never_cached() {
        let unavailable = |fetched: Fetched| {
            let (report, store) = check("0.12.2", NOW, None, || fetched);
            assert!(store.is_none());
            match report {
                Report::Unavailable(message) => message,
                other => panic!("{other:?}"),
            }
        };
        let coded = |n: u8| {
            format!(
                "The operation couldn\u{2019}t be completed. (SymairaUpdateCheck.UpdateCheckError error {n}.)"
            )
        };
        assert_eq!(unavailable(Ok((404, b"{}".to_vec()))), coded(0));
        assert_eq!(unavailable(Ok((200, b"nonsense".to_vec()))), coded(1));
        let flagged = |key: &str| {
            json!({"tag_name": "v9.9.9", "html_url": "u", key: true})
                .to_string()
                .into_bytes()
        };
        assert_eq!(unavailable(Ok((200, flagged("draft")))), coded(2));
        assert_eq!(unavailable(Ok((200, flagged("prerelease")))), coded(3));
        assert_eq!(unavailable(Ok((200, release("nightly")))), coded(4));
        assert_eq!(unavailable(Err(28)), "The request timed out.");
        assert_eq!(
            unavailable(Err(6)),
            "A server with the specified hostname could not be found."
        );
    }

    #[test]
    fn the_reports_print_like_the_swift_version_command() {
        let skipped = Report::Skipped;
        assert_eq!(
            skipped.to_json(),
            json!({"status": "skipped", "update_available": false})
        );
        assert_eq!(Report::UpToDate.text_suffix(), " \u{2014} up to date");
        assert_eq!(
            Report::Unavailable("x".into()).to_json(),
            json!({"status": "unavailable", "update_available": false, "error": "x"})
        );
    }

    #[test]
    fn the_cache_file_is_named_like_corekits() {
        // sha256("danieljustus\0symaira-cockpit"): the digest corekit 0.23.1 derives.
        let name = cache_file_name();
        assert!(name.starts_with("symaira/updatecheck/") && name.ends_with(".json"));
        assert_eq!(name.len(), "symaira/updatecheck/.json".len() + 64);
    }
}
