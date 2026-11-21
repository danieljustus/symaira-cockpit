//! The command line: argument parsing and the decision between answering
//! natively, serving MCP and forwarding to the Swift core. Mirrors
//! `Sources/symcockpit/main.swift` (root dispatch) and
//! `tuning/Sources/SymCockpitCLI/` (per-command parsing) of v0.12, including
//! the error texts. Anything this module does not fully understand is
//! forwarded, so the Swift core stays the authority for it.

use std::path::PathBuf;

use serde_json::Value;
use symcockpit_contract::{CommandSpec, Error, area_commands};
use symcockpit_core::{ai_usage, history, profiles, status};

use crate::app::{App, AreaInput, Context, Output, Params, ProcessSort, ProcessesParams, Request};
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

/// Asks the human whether to run a plan; `None` where nobody can be asked.
pub type Prompt<'a> = Option<&'a dyn Fn(&str) -> bool>;

/// [`plan_with`] with the terminal as the prompt, when there is one.
pub fn plan(app: &App, args: &[String]) -> Action {
    use std::io::IsTerminal;
    let at_terminal = std::io::stdin().is_terminal() && std::io::stderr().is_terminal();
    plan_with(app, args, at_terminal.then_some(&ask_on_terminal))
}

fn ask_on_terminal(summary: &str) -> bool {
    use std::io::Write;
    eprint!("{summary}\nProceed? [y/N] ");
    let _ = std::io::stderr().flush();
    let mut line = String::new();
    std::io::stdin().read_line(&mut line).is_ok()
        && matches!(line.trim().to_lowercase().as_str(), "y" | "yes")
}

pub fn plan_with(app: &App, args: &[String], prompt: Prompt) -> Action {
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
        _ if area_family(args).is_some() => area(app, args, prompt),
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

/// Loads the configuration like Swift does before every command (warnings go
/// to stderr) and runs `run` with the context of this invocation.
fn with_context(
    app: &App,
    data_dir_override: Option<PathBuf>,
    run: impl FnOnce(&Context) -> Action,
) -> Action {
    let env_lookup = |key: &str| app.env.get(key).cloned();
    let loaded = symcockpit_store::Config::load(&app.paths, &env_lookup);
    let warnings: String = loaded
        .warnings
        .iter()
        .map(|w| format!("symcockpit: {w}\n"))
        .collect();
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
    match run(&ctx) {
        Action::Done(outcome) => Action::Done(Outcome {
            stderr: format!("{warnings}{}", outcome.stderr),
            ..outcome
        }),
        other => other,
    }
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
    // Parsing errors and `--help` also carry the configuration warnings.
    with_context(app, data_dir_override, |ctx| {
        let request = match parse(command, &args[1..]) {
            Ok(Step::Run(request)) => request,
            Ok(Step::Text(text)) => return Action::Done(Outcome::out(text)),
            Ok(Step::Forward) => return Action::Forward,
            Err(error) => return Action::Done(Outcome::failure(&error)),
        };
        match native::run_read(app, ctx, &request) {
            Ok(Some(output)) => Action::Done(render(output)),
            Ok(None) => Action::Forward,
            Err(error) => Action::Done(Outcome::failure(&error)),
        }
    })
}

// ------------------------------------------------------------------ the areas

/// First words the areas own. A word v0.12 owns (`processes`) only counts
/// when a longer area path matches.
fn area_family(args: &[String]) -> Option<&'static str> {
    let (_, args) = extract_data_dir(args).ok()?;
    let first = args.first()?;
    area_commands()
        .iter()
        .filter_map(|c| c.cli_path.split(' ').next())
        .find(|family| family == first)
        .filter(|family| !DIRECT.contains(family) || resolve_area(&args).is_some())
}

/// The longest CLI path of an area command that starts the arguments, and
/// what follows it.
fn resolve_area(args: &[String]) -> Option<(&'static CommandSpec, &[String])> {
    area_commands()
        .iter()
        .filter_map(|spec| {
            let words: Vec<&str> = spec.cli_path.split(' ').collect();
            let matches = args.len() >= words.len() && words.iter().zip(args).all(|(w, a)| w == a);
            matches.then(|| (spec, words.len()))
        })
        .max_by_key(|(_, n)| *n)
        .map(|(spec, n)| (spec, &args[n..]))
}

fn family_usage(family: &str) -> String {
    let mut text = format!("Usage: symcockpit {family} <command>\n\nCommands:\n");
    for spec in area_commands()
        .iter()
        .filter(|c| c.cli_path.split(' ').next() == Some(family))
    {
        text.push_str(&format!("  {}\n", spec.cli_path));
    }
    text.push_str(&format!(
        "\n`symcockpit {family} <command> --help` shows the arguments of one command.\n"
    ));
    text
}

fn plan_hint(id: &str) -> String {
    format!("Nothing was changed. To run the plan: symcockpit plan confirm {id}\n")
}

fn plan_summary(plan: &Value) -> String {
    let mut text = format!(
        "Plan {}: {} item(s), {} bytes, valid for {} s",
        plan["id"].as_str().unwrap_or("?"),
        plan["item_count"],
        plan["total_bytes"],
        plan["expires_in_s"]
    );
    let items = plan["items"].as_array().map_or(&[][..], Vec::as_slice);
    for item in items.iter().take(10) {
        text.push_str(&format!(
            "\n  {} {}",
            item["action"].as_str().unwrap_or("?"),
            item["target"].as_str().unwrap_or("?")
        ));
    }
    if items.len() > 10 {
        text.push_str(&format!("\n  ... and {} more", items.len() - 10));
    }
    text
}

fn area(app: &App, args: &[String], prompt: Prompt) -> Action {
    let (data_dir_override, args) = match extract_data_dir(args) {
        Ok(parsed) => parsed,
        Err(error) => return Action::Done(Outcome::failure(&error)),
    };
    with_context(app, data_dir_override, |ctx| {
        Action::Done(area_outcome(app, ctx, &args, prompt))
    })
}

fn area_outcome(app: &App, ctx: &Context, args: &[String], prompt: Prompt) -> Outcome {
    let help = args.iter().any(|a| a == "--help" || a == "-h");
    let Some((spec, rest)) = resolve_area(args) else {
        let family = args[0].as_str();
        return if help || args.len() == 1 {
            let text = family_usage(family);
            if help {
                Outcome::out(text)
            } else {
                Outcome::err(text, 2)
            }
        } else {
            Outcome::err(
                format!(
                    "symcockpit: unknown command '{}'\n\n{}",
                    args[..2].join(" "),
                    family_usage(family)
                ),
                2,
            )
        };
    };
    if help {
        return Outcome::out(format!("{}\n", crate::areas::usage_line(spec)));
    }
    // `--json`, `--confirm <id>` and the absent `--yes`.
    let (mut json, mut confirm) = (false, None);
    let mut words = Vec::new();
    let mut it = rest.iter();
    while let Some(word) = it.next() {
        match word.as_str() {
            "--json" => json = true,
            "--yes" | "-y" => {
                return Outcome::failure(&Error::Usage(
                    "there is no --yes: a risky command records a plan, then `--confirm <plan_id>` or `plan confirm <plan_id>` runs it".into(),
                ));
            }
            "--confirm" => match it.next() {
                Some(id) => confirm = Some(id.clone()),
                None => return Outcome::failure(&Error::Usage("--confirm needs a plan id".into())),
            },
            _ => words.push(word.clone()),
        }
    }
    let run = |name: &'static str, json: bool, params: Params| {
        native::run_read(
            app,
            ctx,
            &Request {
                command: name,
                json,
                params,
            },
        )
    };
    let confirm_run = |id: &str, kind: Option<&str>| {
        let mut input = serde_json::Map::new();
        input.insert("plan_id".into(), Value::String(id.to_owned()));
        if let Some(kind) = kind {
            input.insert("expect_kind".into(), Value::String(kind.to_owned()));
        }
        run("plan.confirm", true, Params::Area(AreaInput::Args(input)))
    };
    let finish = |result: Result<Option<Output>, Error>| match result {
        Ok(Some(output)) => render(output),
        Ok(None) => Outcome::failure(&Error::Unsupported(format!(
            "{} is not available in this build",
            spec.cli_path
        ))),
        Err(error) => Outcome::failure(&error),
    };
    let makes_plans = spec.mcp_name.is_some_and(|m| m.starts_with("plan_"));
    if let Some(id) = confirm {
        if !makes_plans {
            return Outcome::failure(&Error::Usage(format!(
                "{} does not take --confirm",
                spec.cli_path
            )));
        }
        return finish(confirm_run(&id, crate::areas::plan_kind(spec.name)));
    }
    let output = match run(spec.name, json, Params::Area(AreaInput::Words(words))) {
        Ok(Some(Output::Json(plan))) if makes_plans && plan["id"].is_string() => plan,
        other => return finish(other),
    };
    let id = output["id"].as_str().unwrap_or_default().to_owned();
    let empty = output["item_count"].as_u64() == Some(0);
    if !empty && let Some(ask) = prompt {
        if ask(&plan_summary(&output)) {
            return finish(confirm_run(&id, None));
        }
        return Outcome {
            stdout: format!("{}\n", json::pretty(&output)),
            stderr: plan_hint(&id),
            code: 1,
        };
    }
    Outcome {
        stdout: format!("{}\n", json::pretty(&output)),
        stderr: if empty { String::new() } else { plan_hint(&id) },
        code: 0,
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
        Output::Report { value, code } => Outcome {
            stdout: format!("{}\n", json::pretty(&value)),
            code,
            ..Outcome::default()
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
        "dim" | "warmth" | "battery-limit" => match is_help(rest) {
            true => Ok(Step::Text(
                help::write_family(command).unwrap_or_default().to_owned(),
            )),
            false => Ok(Step::Forward),
        },
        "fan" => {
            if is_help(rest) {
                return Ok(Step::Text(
                    help::write_family("fan").unwrap_or_default().to_owned(),
                ));
            }
            match rest {
                // Bare `fan profile` / `fan target` only read the selection; an argument sets it.
                [sub] if sub == "profile" || sub == "target" => {
                    run("fan.status", true, Params::None)
                }
                [sub, extra, ..] if sub == "status" => Err(unexpected("fan status", extra)),
                [sub] if sub == "status" => run("fan.status", true, Params::None),
                _ => Ok(Step::Forward),
            }
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
        Output::Json(value) | Output::Report { value, .. } => Ok(value),
        Output::Text { .. } => Err(Error::Failed(
            "handler returned text for a JSON request".into(),
        )),
    }
}
