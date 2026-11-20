//! `symcockpit` during the strangler migration (ADR 0003): `version` is answered
//! here, every other invocation is `exec`ed into the legacy Swift binary so
//! stdin, stdout, stderr and the exit code stay untouched.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use symcockpit_contract::exit;

/// Release version; must equal `CockpitVersion.current` in Swift.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Environment variable naming the legacy binary explicitly.
pub const LEGACY_ENV: &str = "SYMCOCKPIT_LEGACY_BIN";

const UPDATE_ENV: &str = "SYMCOCKPIT_CHECK_UPDATES";

/// Where the legacy Swift binary lives: the environment override, then next to
/// this executable, then in the Homebrew-style `libexec` layout.
pub fn resolve_legacy(override_path: Option<OsString>, exe: &Path) -> Option<PathBuf> {
    if let Some(path) = override_path.filter(|p| !p.is_empty()) {
        // An explicit override is never second-guessed by falling through.
        return Some(PathBuf::from(path)).filter(|p| p.is_file());
    }
    let dir = exe.parent()?;
    [
        dir.join("symcockpit-legacy"),
        dir.join("../libexec/symcockpit/symcockpit-legacy"),
    ]
    .into_iter()
    .find(|p| p.is_file())
}

/// The text of `symcockpit version` when the Swift binary would skip its
/// update check (the only case reproducible without network access); `None`
/// means "forward, the real check may run".
pub fn version_output(
    args: &[OsString],
    update_env: Option<&str>,
    stdout_is_terminal: bool,
) -> Option<String> {
    if !matches!(args.first()?.to_str()?, "version" | "--version" | "-V") {
        return None;
    }
    let has = |flag: &str| args.iter().any(|a| a == flag);
    let env = update_env.map(str::to_lowercase);
    let opted_out =
        has("--no-update-check") || matches!(env.as_deref(), Some("0" | "false" | "no" | "off"));
    let opted_in = matches!(env.as_deref(), Some("1" | "true" | "yes" | "on"));
    if !(opted_out || (!stdout_is_terminal && !opted_in)) {
        return None;
    }
    Some(if has("--json") {
        // Byte-for-byte what Swift's pretty-printed, key-sorted JSONEncoder emits.
        format!(
            "{{\n  \"families\" : [\n\n  ],\n  \"schema_version\" : 1,\n  \"tool\" : \"symcockpit\",\n  \"update\" : {{\n    \"status\" : \"skipped\",\n    \"update_available\" : false\n  }},\n  \"version\" : \"{VERSION}\"\n}}\n"
        )
    } else {
        format!("symcockpit {VERSION} — update check skipped\n")
    })
}

/// Replace this process with the legacy binary. Returns only on failure.
pub fn forward(args: Vec<OsString>) -> u8 {
    use std::os::unix::process::CommandExt;

    let exe = std::env::current_exe()
        .map(|p| p.canonicalize().unwrap_or(p))
        .unwrap_or_default();
    let Some(legacy) = resolve_legacy(std::env::var_os(LEGACY_ENV), &exe) else {
        eprintln!(
            "symcockpit: legacy binary not found; set {LEGACY_ENV} or install symcockpit-legacy next to symcockpit"
        );
        return exit::UNSUPPORTED;
    };
    let error = std::process::Command::new(&legacy).args(args).exec();
    eprintln!("symcockpit: cannot start {}: {error}", legacy.display());
    exit::ERROR
}

/// Entry point shared by `main` and tests.
pub fn run(args: Vec<OsString>) -> u8 {
    use std::io::{IsTerminal, Write};

    let update_env = std::env::var(UPDATE_ENV).ok();
    if let Some(text) = version_output(
        &args,
        update_env.as_deref(),
        std::io::stdout().is_terminal(),
    ) {
        return match std::io::stdout().lock().write_all(text.as_bytes()) {
            Ok(()) => exit::OK,
            Err(_) => exit::ERROR,
        };
    }
    forward(args)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<OsString> {
        list.iter().map(OsString::from).collect()
    }

    #[test]
    fn version_constant_matches_swift_cockpit_version() {
        let swift = include_str!("../../../Sources/SymCockpitVersion/CockpitVersion.swift");
        assert!(
            swift.contains(&format!("current = \"{VERSION}\"")),
            "bump Cargo.toml with CockpitVersion"
        );
    }

    #[test]
    fn version_text_and_json_match_swift_output() {
        let text = version_output(&args(&["version"]), None, false).unwrap();
        assert_eq!(
            text,
            format!("symcockpit {VERSION} — update check skipped\n")
        );
        assert_eq!(
            version_output(&args(&["-V"]), None, false),
            Some(text.clone())
        );
        assert_eq!(
            version_output(&args(&["--version", "extra"]), None, false),
            Some(text)
        );
        let json = version_output(&args(&["version", "--json"]), None, false).unwrap();
        let swift = [
            "{",
            "  \"families\" : [",
            "",
            "  ],",
            "  \"schema_version\" : 1,",
            "  \"tool\" : \"symcockpit\",",
            "  \"update\" : {",
            "    \"status\" : \"skipped\",",
            "    \"update_available\" : false",
            "  },",
            &format!("  \"version\" : \"{VERSION}\""),
            "}",
            "",
        ];
        assert_eq!(json, swift.join("\n"));
    }

    #[test]
    fn real_update_check_is_forwarded() {
        // Interactive terminal, or an explicit opt-in: only Swift can check.
        assert_eq!(version_output(&args(&["version"]), None, true), None);
        assert_eq!(version_output(&args(&["version"]), Some("1"), false), None);
        // Opt-outs always skip, even on a terminal.
        assert!(
            version_output(&args(&["version", "--no-update-check"]), Some("1"), true).is_some()
        );
        assert!(version_output(&args(&["version"]), Some("OFF"), true).is_some());
    }

    #[test]
    fn other_commands_are_never_answered_locally() {
        for a in [&["sensors"][..], &["serve"], &[], &["help"], &["nope"]] {
            assert_eq!(version_output(&args(a), None, false), None, "{a:?}");
        }
    }

    #[test]
    fn resolution_order_is_override_then_sibling_then_libexec() {
        let tmp = tempfile::tempdir().unwrap();
        let bin = tmp.path().join("bin");
        let libexec = tmp.path().join("libexec/symcockpit");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::create_dir_all(&libexec).unwrap();
        let exe = bin.join("symcockpit");
        let sibling = bin.join("symcockpit-legacy");
        let far = libexec.join("symcockpit-legacy");
        let custom = tmp.path().join("custom");
        assert_eq!(resolve_legacy(None, &exe), None);
        std::fs::write(&far, "").unwrap();
        assert_eq!(
            resolve_legacy(None, &exe).unwrap().canonicalize().unwrap(),
            far.canonicalize().unwrap()
        );
        std::fs::write(&sibling, "").unwrap();
        assert_eq!(resolve_legacy(None, &exe), Some(sibling.clone()));
        std::fs::write(&custom, "").unwrap();
        assert_eq!(
            resolve_legacy(Some(custom.clone().into()), &exe),
            Some(custom)
        );
        // A missing override does not fall back to the sibling.
        assert_eq!(
            resolve_legacy(Some(tmp.path().join("gone").into()), &exe),
            None
        );
        // An empty override counts as unset.
        assert_eq!(resolve_legacy(Some(OsString::new()), &exe), Some(sibling));
    }
}
