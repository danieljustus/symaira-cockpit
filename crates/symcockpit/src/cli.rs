//! The command line: argument parsing and the decision between answering
//! natively, serving MCP and forwarding to the Swift core. Mirrors
//! `Sources/symcockpit/main.swift` (root dispatch) and
//! `tuning/Sources/SymCockpitCLI/` (per-command parsing) of v0.12, including
//! the error texts. Anything this module does not fully understand is
//! forwarded, so the Swift core stays the authority for it.

use std::path::PathBuf;

use serde_json::Value;
use symcockpit_contract::Error;
use symcockpit_core::{ai_usage, history, profiles, status};

use crate::app::{App, Context, Output, Params, ProcessSort, ProcessesParams, Request};
use crate::{help, json, native};

/// What to do with the invocation.
pub enum Action {
    /// Answered here.
    Done(Outcome),
    /// Hand the original arguments to the Swift core.
    Forward,
    /// Run the MCP server on stdio.
    Serve { data_dir_override: Option<PathBuf> },
}

#[derive(Debug, Default, Eq, PartialEq)]
pub struct Outcome {
    pub stdout: String,
    pub stderr: String,
    pub code: u8,
}

impl Outcome {
    fn out(stdout: impl Into<String>) -> Self {
        Self {
            stdout: stdout.into(),
            ..Self::default()
        }
    }

    fn err(stderr: impl Into<String>, code: u8) -> Self {
        Self {
            stderr: stderr.into(),
            code,
            ..Self::default()
        }
    }

    fn failure(error: &Error) -> Self {
        Self::err(format!("symcockpit: {error}\n"), error.exit_code())
    }
}

/// The commands `CockpitCommandMap.directTuneCommands` routes to the tune core.
const DIRECT: [&str; 21] = [
    "sensors",
    "battery",
    "displays",
    "metrics",
    "ai-usage",
    "processes",
    "top",
    "status",
    "awake",
    "brightness",
    "extbright",
    "dim",
    "warmth",
    "restore",
    "profile",
    "fan",
    "battery-limit",
    "doctor",
    "permissions",
    "serve",
    "history",
];

fn is_help(args: &[String]) -> bool {
    args.iter().any(|a| a == "--help" || a == "-h")
}

pub fn plan(app: &App, args: &[String]) -> Action {
    let Some(first) = args.first() else {
        return Action::Done(Outcome::err(help::ROOT_USAGE, 2));
    };
    match first.as_str() {
        "tune" => {
            let direct = format!("symcockpit {}", args[1..].join(" "));
            let suggestion = if args.len() > 1 {
                direct
            } else {
                "symcockpit <command>".into()
            };
            Action::Done(Outcome::err(
                format!("symcockpit: the 'tune' prefix was removed; run '{suggestion}' instead.\n"),
                2,
            ))
        }
        "version" | "--version" | "-V" => Action::Forward,
        "help" | "--help" | "-h" => Action::Done(Outcome::out(help::ROOT_USAGE)),
        "operate" | "scope" => Action::Done(Outcome::err(
            format!(
                "\nsymcockpit: '{first}' moved to Symaira Brain as an optional module.\nInstall it from a Brain checkout:\n  symbrain setup --from-source <brain-checkout> --modules {first}\n\nsymcockpit now ships hardware and system tuning only (thermals, power,\ndisplay, brightness). See docs/product-boundaries.md (PB-2026-09-09).\n"
            ),
            4,
        )),
        command if DIRECT.contains(&command) => tune(app, args),
        other => Action::Done(Outcome::err(
            format!(
                "symcockpit: unknown family '{other}'\n\n{}",
                help::ROOT_USAGE
            ),
            2,
        )),
    }
}

/// `extractDataDir`: a global `--data-dir <path>` anywhere in the arguments.
fn extract_data_dir(args: &[String]) -> Result<(Option<PathBuf>, Vec<String>), Error> {
    let Some(index) = args.iter().position(|a| a == "--data-dir") else {
        return Ok((None, args.to_vec()));
    };
    let value = args
        .get(index + 1)
        .ok_or_else(|| Error::Usage("--data-dir: expected a path".into()))?;
    let mut rest = args.to_vec();
    rest.drain(index..=index + 1);
    Ok((Some(PathBuf::from(value)), rest))
}

fn tune(app: &App, args: &[String]) -> Action {
    let (data_dir_override, args) = match extract_data_dir(args) {
        Ok(parsed) => parsed,
        Err(error) => return Action::Done(Outcome::failure(&error)),
    };
    let command = args[0].as_str();
    if command == "serve" {
        return Action::Serve { data_dir_override };
    }
    // Swift loads the configuration before every tune command and warns on stderr.
    let env_lookup = |key: &str| app.env.get(key).cloned();
    let loaded = symcockpit_store::Config::load(&app.paths, &env_lookup);
    let warnings: String = loaded
        .warnings
        .iter()
        .map(|w| format!("symcockpit: {w}\n"))
        .collect();
    let done = |outcome: Outcome| {
        Action::Done(Outcome {
            stderr: format!("{warnings}{}", outcome.stderr),
            ..outcome
        })
    };

    let request = match parse(command, &args[1..]) {
        Ok(Step::Run(request)) => request,
        Ok(Step::Text(text)) => return done(Outcome::out(text)),
        Ok(Step::Forward) => return Action::Forward,
        Err(error) => return done(Outcome::failure(&error)),
    };
    let data_dir = data_dir_override
        .clone()
        .unwrap_or_else(|| app.paths.data_dir.clone());
    let ctx = Context {
        config: &loaded.config,
        paths: &app.paths,
        data_dir: &data_dir,
        data_dir_override: data_dir_override.as_deref(),
        env: &app.env,
        services: &app.services,
    };
    match native::run_read(app, &ctx, &request) {
        Ok(Some(output)) => done(render(output)),
        Ok(None) => Action::Forward,
        Err(error) => done(Outcome::failure(&error)),
    }
}

fn render(output: Output) -> Outcome {
    match output {
        Output::Json(value) => Outcome::out(format!("{}\n", json::pretty(&value))),
        Output::Text { stdout, stderr } => Outcome {
            stdout,
            stderr,
            code: 0,
        },
    }
}

/// The result of parsing one tune command line.
enum Step {
    /// Run this read request natively (or forward when nothing implements it).
    Run(Request),
    /// Print this text and exit 0 (`--help`).
    Text(String),
    /// Not a read the Swift core cannot do better: hand it over.
    Forward,
}

fn run(command: &'static str, json: bool, params: Params) -> Result<Step, Error> {
    Ok(Step::Run(Request {
        command,
        json,
        params,
    }))
}

fn unexpected(command: &str, arg: &str) -> Error {
    Error::Usage(format!("{command}: unexpected argument '{arg}'"))
}

/// The always-JSON read commands: `--help`, `--json` as a no-op, nothing else.
fn always_json(command: &'static str, name: &'static str, rest: &[String]) -> Result<Step, Error> {
    if is_help(rest) {
        let text = if command == "metrics" {
            help::METRICS.to_owned()
        } else {
            help::always_json(command).unwrap_or_default()
        };
        return Ok(Step::Text(text));
    }
    if let Some(arg) = rest.iter().find(|a| *a != "--json") {
        return Err(unexpected(command, arg));
    }
    run(name, true, Params::None)
}

/// `ProcessListingPresentation.parseOptions`.
fn processes(name: &'static str, rest: &[String]) -> Result<Step, Error> {
    if is_help(rest) {
        return Ok(Step::Text(help::PROCESSES.to_owned()));
    }
    let mut params = ProcessesParams::default();
    let mut json = false;
    let mut i = 0;
    while i < rest.len() {
        match rest[i].as_str() {
            "--json" => json = true,
            "--sort" => {
                i += 1;
                params.sort = rest
                    .get(i)
                    .and_then(|v| ProcessSort::parse(v))
                    .ok_or_else(|| {
                        Error::Usage("processes: --sort expects 'cpu', 'memory', or 'gpu'".into())
                    })?;
            }
            "--limit" => {
                i += 1;
                params.limit = rest
                    .get(i)
                    .and_then(|v| v.parse::<i64>().ok())
                    .filter(|n| *n > 0)
                    .ok_or_else(|| {
                        Error::Usage("processes: --limit expects a positive integer".into())
                    })?;
            }
            "--interval" => {
                i += 1;
                params.interval = rest
                    .get(i)
                    .and_then(|v| v.parse::<f64>().ok())
                    .filter(|n| *n > 0.0)
                    .ok_or_else(|| {
                        Error::Usage(
                            "processes: --interval expects a positive number of seconds".into(),
                        )
                    })?;
            }
            other => return Err(unexpected("processes", other)),
        }
        i += 1;
    }
    run(name, json, Params::Processes(params))
}

fn parse(command: &str, rest: &[String]) -> Result<Step, Error> {
    match command {
        "doctor" => always_json("doctor", "doctor", rest),
        "sensors" => always_json("sensors", "sensors", rest),
        "battery" => always_json("battery", "battery", rest),
        "displays" => always_json("displays", "displays", rest),
        "permissions" => always_json("permissions", "permissions", rest),
        "metrics" => always_json("metrics", "metrics", rest),
        "processes" => processes("processes", rest),
        "top" => processes("top", rest),
        "ai-usage" => {
            if rest.first().is_some_and(|a| a == "serve") {
                return Ok(Step::Forward);
            }
            if is_help(rest) {
                return Ok(Step::Text(ai_usage::HELP.to_owned()));
            }
            let options = ai_usage::parse_options(rest)?;
            run(
                "ai-usage",
                options.json,
                Params::AiUsage {
                    provider: options.provider,
                },
            )
        }
        "status" => {
            let options = status::parse_options(rest)?;
            // The endless NDJSON loop stays with Swift until it has a native home.
            if options.watch {
                Ok(Step::Forward)
            } else {
                run("status", options.json, Params::None)
            }
        }
        "history" => {
            if is_help(rest) {
                return Ok(Step::Text(history::HELP.to_owned()));
            }
            let options = history::parse_options(rest)?;
            run(
                "history",
                options.json,
                Params::History {
                    limit: options.limit,
                },
            )
        }
        "awake" => match rest.first().map(String::as_str) {
            Some("status") => run("awake.status", true, Params::None),
            _ => Ok(Step::Forward),
        },
        "brightness" => {
            if rest.is_empty() || rest[0] == "get" {
                if let Some(extra) = rest.get(1) {
                    return Err(unexpected("brightness get", extra));
                }
                run("brightness.get", true, Params::None)
            } else {
                Ok(Step::Forward)
            }
        }
        "fan" => {
            if is_help(rest) || rest.first().map(String::as_str) != Some("status") {
                return Ok(Step::Forward);
            }
            if let Some(extra) = rest.get(1) {
                return Err(unexpected("fan status", extra));
            }
            run("fan.status", true, Params::None)
        }
        "profile" => {
            if is_help(rest) {
                return Ok(Step::Text(profiles::HELP.to_owned()));
            }
            let Some(subcommand) = rest.first() else {
                return Err(Error::Usage(
                    "profile: expected subcommand (save, load, list, delete).".into(),
                ));
            };
            // `rejectTrailingArguments`: `list` takes nothing, the others one name.
            let tail = &rest[1..];
            let allowed = usize::from(subcommand != "list");
            if let Some(extra) = tail.get(allowed) {
                return Err(unexpected(&format!("profile {subcommand}"), extra));
            }
            if subcommand == "list" {
                run("profile.list", true, Params::None)
            } else {
                Ok(Step::Forward)
            }
        }
        _ => Ok(Step::Forward),
    }
}

/// Used by tests and the MCP layer: the value of an `Output::Json`.
pub fn json_value(output: Output) -> Result<Value, Error> {
    match output {
        Output::Json(value) => Ok(value),
        Output::Text { .. } => Err(Error::Failed(
            "handler returned text for a JSON request".into(),
        )),
    }
}
