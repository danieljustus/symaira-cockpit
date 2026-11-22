//! `symcockpit`: every command of the register runs in this binary (ADR 0003, wave 2D). The
//! Swift core is not started for any CLI command or MCP tool; it only remains as the frozen
//! reference of the oracle (`make oracle`).

pub mod agent;
pub mod app;
pub mod areas;
pub mod cli;
pub mod fan_select;
pub mod help;
pub mod host;
pub mod json;
pub mod live;
pub mod loops;
pub mod mcp;
pub mod native;
pub mod platform;
pub mod version;
pub mod wake;
pub mod write;
pub mod writes;

use std::ffi::OsString;

use symcockpit_contract::exit;

/// Debug builds only: tests that spawn this binary set it, and then no command
/// reaches a display, gamma, overlay, keep-awake, SMC or charge-limit write;
/// the write fails as unsupported instead (tuning/AGENTS.md hardware
/// isolation). Release builds never read it.
pub const NO_HARDWARE_ENV: &str = "SYMCOCKPIT_TEST_NO_HARDWARE";

pub(crate) fn hardware_writes_blocked() -> Result<(), symcockpit_contract::Error> {
    if cfg!(debug_assertions) && std::env::var_os(NO_HARDWARE_ENV).is_some() {
        return Err(symcockpit_contract::Error::Unsupported(format!(
            "hardware writes are disabled ({NO_HARDWARE_ENV})"
        )));
    }
    Ok(())
}

/// The same switch for the agent's long-lived services (clipboard, mixer, Finder jobs, event
/// tap, BLE, click feedback): a debug binary a test started must never start one on the real
/// machine. They answer `unsupported` instead. Release builds never read it.
pub(crate) fn service_blocked(service: &str) -> Result<(), symcockpit_contract::Error> {
    if cfg!(debug_assertions) && std::env::var_os(NO_HARDWARE_ENV).is_some() {
        return Err(symcockpit_contract::Error::Unsupported(format!(
            "{service} is disabled ({NO_HARDWARE_ENV})"
        )));
    }
    Ok(())
}

/// Release version; must equal `CockpitVersion.current` in Swift.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Entry point shared by `main` and tests: handles the invocation with the
/// production wiring of [`platform::app`].
pub fn run(args: Vec<OsString>) -> u8 {
    run_with(&platform::app(), args)
}

/// [`run`] with an explicit app, for wiring areas and for tests.
pub fn run_with(app: &app::App, args: Vec<OsString>) -> u8 {
    // Like Swift's `CommandLine.arguments`: bytes that are not UTF-8 become U+FFFD.
    let strings: Vec<String> = args
        .iter()
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    // Internal command of the app bundle: not in the help text or the oracle.
    if strings.first().map(String::as_str) == Some("agent") {
        // The agent ends on EOF or SIGTERM (its own signal pipe); the
        // overrides it held for the app are put back afterwards.
        let code = agent::main(app, &strings[1..]);
        writes::shutdown();
        return code;
    }
    // Restore-on-interrupt for the commands that can hold an override. Armed
    // here, in production only: it installs signal handlers and starts a thread.
    if matches!(
        strings.first().map(String::as_str),
        Some(
            "serve"
                | "awake"
                | "brightness"
                | "extbright"
                | "dim"
                | "warmth"
                | "profile"
                | "restore"
        )
    ) {
        writes::arm_interrupt_restore();
    }
    let code = match cli::plan(app, &strings) {
        cli::Action::Done(outcome) => write_all(
            outcome.stdout.as_bytes(),
            outcome.stderr.as_bytes(),
            outcome.code,
        ),
        cli::Action::Serve { data_dir_override } => serve(app, data_dir_override),
        cli::Action::StatusWatch {
            data_dir_override,
            interval,
        } => long_running(app, data_dir_override, |ctx| {
            let mut signals = loops::Signals::install()?;
            Ok(loops::status_watch(
                app,
                ctx,
                interval,
                &mut std::io::stdout().lock(),
                &mut signals,
            ))
        }),
        cli::Action::AiUsageServe {
            data_dir_override,
            port,
        } => long_running(app, data_dir_override, |ctx| {
            let mut signals = loops::Signals::install()?;
            let dir = ctx.paths.cache_dir.join("ai-usage");
            let refresh = || {
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_or(0.0, |d| d.as_secs_f64());
                symcockpit_core::ai_usage_api::cached_rows(
                    &dir,
                    &(app.services.enabled_ai_providers)(),
                    now,
                )
            };
            Ok(loops::ai_usage_serve(
                port,
                &refresh,
                &mut std::io::stdout().lock(),
                &mut signals,
            ))
        }),
    };
    // Restore-on-exit for the display and keep-awake overrides.
    writes::shutdown();
    code
}

/// The configuration like Swift loads it before every command (warnings to stderr), then
/// `run` with the context of this invocation.
fn long_running(
    app: &app::App,
    data_dir_override: Option<std::path::PathBuf>,
    run: impl FnOnce(&app::Context) -> Result<u8, symcockpit_contract::Error>,
) -> u8 {
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
    run(&ctx).unwrap_or_else(|error| {
        eprintln!("symcockpit: {error}");
        error.exit_code()
    })
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
    // Held overrides survive a sleep: the display half and the charge limit are put back.
    let mut input = writes::PumpedStdin::spawn();
    if let Some(source) = wake::live_source() {
        input.watch_wake(&source, || wake::after_wake(&ctx));
    }
    match mcp::serve(&server, input, std::io::stdout().lock()) {
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

    #[test]
    fn version_constant_matches_swift_cockpit_version() {
        let swift = include_str!("../../../Sources/SymCockpitVersion/CockpitVersion.swift");
        assert!(
            swift.contains(&format!("current = \"{VERSION}\"")),
            "bump Cargo.toml with CockpitVersion"
        );
    }
}
