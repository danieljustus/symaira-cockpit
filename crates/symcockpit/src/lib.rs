//! `symcockpit` during the strangler migration (ADR 0003). Read commands run
//! natively as soon as their area is wired in (`app::Handlers`), `version`,
//! `help`, `history`, `profile list`, `ai-usage` and the MCP server `serve`
//! always do; everything else is `exec`ed into the legacy Swift binary so
//! stdin, stdout, stderr and the exit code stay untouched.

pub mod agent;
pub mod app;
pub mod areas;
pub mod cli;
pub mod help;
pub mod json;
pub mod legacy;
pub mod live;
pub mod mcp;
pub mod native;
pub mod platform;

use std::ffi::OsString;

use symcockpit_contract::exit;

pub use legacy::{LEGACY_ENV, forward, resolve_legacy};

/// Release version; must equal `CockpitVersion.current` in Swift.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

const UPDATE_ENV: &str = "SYMCOCKPIT_CHECK_UPDATES";

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

/// Entry point shared by `main` and tests: handles the invocation with the
/// production wiring of [`platform::app`].
pub fn run(args: Vec<OsString>) -> u8 {
    run_with(&platform::app(), args)
}

/// [`run`] with an explicit app, for wiring areas and for tests.
pub fn run_with(app: &app::App, args: Vec<OsString>) -> u8 {
    use std::io::IsTerminal;

    let update_env = app.env.get(UPDATE_ENV).map(String::as_str);
    if let Some(text) = version_output(&args, update_env, std::io::stdout().is_terminal()) {
        return write_all(text.as_bytes(), b"", exit::OK);
    }
    // Arguments that are not UTF-8 cannot be parsed here; Swift decides.
    let Some(strings) = args
        .iter()
        .map(|a| a.to_str().map(str::to_owned))
        .collect::<Option<Vec<String>>>()
    else {
        return forward(args);
    };
    // Internal command of the app bundle: not in the help text or the oracle.
    if strings.first().map(String::as_str) == Some("agent") {
        return agent::main(app, &strings[1..]);
    }
    match cli::plan(app, &strings) {
        cli::Action::Done(outcome) => write_all(
            outcome.stdout.as_bytes(),
            outcome.stderr.as_bytes(),
            outcome.code,
        ),
        cli::Action::Forward => forward(args),
        cli::Action::Serve { data_dir_override } => serve(app, data_dir_override),
    }
}

fn write_all(stdout: &[u8], stderr: &[u8], code: u8) -> u8 {
    use std::io::Write;
    if !stderr.is_empty() {
        let _ = std::io::stderr().lock().write_all(stderr);
    }
    if !stdout.is_empty() && std::io::stdout().lock().write_all(stdout).is_err() {
        return exit::ERROR;
    }
    code
}

fn serve(app: &app::App, data_dir_override: Option<std::path::PathBuf>) -> u8 {
    let env_lookup = |key: &str| app.env.get(key).cloned();
    let loaded = symcockpit_store::Config::load(&app.paths, &env_lookup);
    for warning in &loaded.warnings {
        eprintln!("symcockpit: {warning}");
    }
    let data_dir = data_dir_override
        .clone()
        .unwrap_or_else(|| app.paths.data_dir.clone());
    let ctx = app::Context {
        config: &loaded.config,
        paths: &app.paths,
        data_dir: &data_dir,
        data_dir_override: data_dir_override.as_deref(),
        env: &app.env,
        services: &app.services,
    };
    let server = mcp::Server::new(app, &ctx);
    match mcp::serve(&server, std::io::stdin().lock(), std::io::stdout().lock()) {
        Ok(()) => exit::OK,
        Err(error) => {
            eprintln!("symcockpit: serve: {error}");
            exit::ERROR
        }
    }
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
}
