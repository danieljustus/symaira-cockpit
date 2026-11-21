//! `SecretRedactor` of `history/`: credential-shaped substrings become
//! `<redacted>`. The one redactor of the workspace (history lines and usage rows).

use std::sync::LazyLock;

use regex::Regex;

static REDACTIONS: LazyLock<Vec<Regex>> = LazyLock::new(|| {
    [
        r"«redacted:[^»]*»",
        r"(sk-[A-Za-z0-9_-]{8,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{8,}|xox[baprs]-[A-Za-z0-9-]{8,}|AIza[0-9A-Za-z_-]{20,})",
        r#"(?i)(authorization|bearer|api[_-]?key|token)\s*[:=]\s*("[^"]+"|'[^']+'|[A-Za-z0-9._-]{12,})"#,
        r"(?i)\bbearer\s+[A-Za-z0-9._-]{12,}",
        r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}",
    ]
    .iter()
    .filter_map(|p| Regex::new(p).ok())
    .collect()
});

/// Replaces every credential-shaped substring with `<redacted>`.
pub fn redact(text: &str) -> String {
    REDACTIONS.iter().fold(text.to_owned(), |t, re| {
        re.replace_all(&t, "<redacted>").into_owned()
    })
}
