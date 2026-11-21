//! Handlers of the newer areas: storage, apps, plans, audio and MIDI,
//! Bluetooth, input and ending a process. One handler per command of
//! `symcockpit_contract::area_commands()`, shared by the CLI and MCP.
//!
//! What a handler needs from the machine comes through [`Ports`], built once
//! per process and opened lazily: reading `sensors` never opens the audio
//! HAL, Bluetooth or the database. Production builds the ports in
//! `live::ports`; tests build them from the fakes of `symcockpit-testkit`.
//!
//! Exposure (architecture 5.3): a handler never decides who may call it, the
//! register does. Risky commands only *record a plan* here; the plan runs in
//! `plan.confirm`, which registers every action kind.

use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{Map, Value, json};
use symcockpit_contract::{CommandSpec, Error, area_commands, commands};
use symcockpit_core::audio::cli::{self as audio_cli, Command, parse_audio, parse_midi};
use symcockpit_core::audio::mixer::{AppSetting, TapHal};
use symcockpit_core::audio::{AudioPlanAction, AudioService, Scope};
use symcockpit_core::bluetooth::{
    BLE_WRITE_KIND, BleCentral, BleLog, BlePlanAction, PairedDevices, ScanFilter, WriteRequest,
    ble_read_json, ble_scan_json, ble_services_json, ble_subscribe_json, bt_devices_json,
    plan_ble_write_json,
};
use symcockpit_core::input::{
    HapticBackend, InputProbe, SettingsStore, SoundBackend, input_finder_cut_json,
    input_haptics_status_json, input_haptics_test_json, input_status_json,
};
use symcockpit_core::kill::{GRACE, KillAction, ProcessControl, plan_kill_json};
use symcockpit_core::midi::MidiService;
use symcockpit_core::plan::{
    Action, Clock, Engine, FsAction, PlanStore, Remover, get_plan_json, outcome_exit_code,
};
use symcockpit_core::storage::clean::plan_clean_json;
use symcockpit_core::storage::duplicates::{find_duplicates_json, plan_remove_duplicates_json};
use symcockpit_core::storage::health::{
    HealthParams, HistoryParams, HistoryStore, NvmeSource, health_history_json, health_json,
    render_health,
};
use symcockpit_core::storage::space::{SpaceFs, SpaceParams, render_space, space_json};
use symcockpit_core::storage::speedtest::{
    Limits, SpeedHost, SpeedtestParams, render_speedtest, speedtest_json,
};
use symcockpit_core::storage::uninstall::{Apps, plan_uninstall_app_json};

use crate::app::{AreaInput, Context, Handlers, Output, Params, Request};

/// The audio side of a process: the service, MIDI, process taps and the
/// foreground hooks of `audio mixer run`.
#[derive(Clone)]
pub struct AudioKit {
    pub service: Arc<AudioService>,
    pub midi: Arc<MidiService>,
    /// `None` where process taps do not exist.
    pub tap: Option<Arc<dyn TapHal>>,
    /// Called before a command that runs until it is stopped.
    pub before_foreground: Rc<dyn Fn()>,
    /// True once the process was asked to stop.
    pub stop: Rc<dyn Fn() -> bool>,
}

/// Input preferences and the devices behind them.
pub struct InputKit {
    pub settings: OpenedAt<Box<dyn SettingsStore>>,
    pub probe: Rc<dyn InputProbe>,
    pub haptic: Rc<dyn HapticBackend>,
    pub sound: Rc<dyn SoundBackend>,
}

type Opened<T> = Box<dyn Fn() -> Result<T, Error>>;
/// Opens something that lives in a file, by path.
type OpenedAt<T> = Box<dyn Fn(&Path) -> T>;

/// Everything the area handlers read from or write to the machine. Shared
/// pointers, so a test keeps a handle on its fake.
pub struct Ports {
    pub clock: Rc<dyn Clock>,
    pub nvme: Rc<dyn NvmeSource>,
    /// `cockpit.sqlite` is opened by path, on use.
    pub history: OpenedAt<Result<Box<dyn HistoryStore>, Error>>,
    pub plans: OpenedAt<Result<Box<dyn PlanStore>, Error>>,
    pub speed: Rc<dyn SpeedHost>,
    pub space: Rc<dyn SpaceFs>,
    pub remover: Rc<dyn Remover>,
    /// Built from the home directory.
    pub apps: OpenedAt<Box<dyn Apps>>,
    pub processes: Rc<dyn ProcessControl>,
    pub sleep: Box<dyn Fn(Duration)>,
    pub audio: Opened<AudioKit>,
    pub paired: Rc<dyn PairedDevices>,
    pub central: Opened<Box<dyn BleCentral>>,
    pub input: InputKit,
}

type Run = fn(&Ports, &Context, &Request) -> Result<Output, Error>;

fn handler_for(name: &str) -> Option<Run> {
    Some(match name.split('.').next()? {
        "storage" => storage,
        "apps" | "plan" => plans,
        "audio" | "midi" => audio,
        "bt" | "ble" => bluetooth,
        "input" => input,
        "processes" => kill,
        "clipboard" => clipboard,
        _ => return None,
    })
}

/// Registers a handler for every command the areas added.
pub fn register(handlers: &mut Handlers, ports: Rc<Ports>) {
    for spec in area_commands() {
        let Some(run) = handler_for(spec.name) else {
            continue;
        };
        let ports = Rc::clone(&ports);
        handlers.register(spec.name, move |ctx, req| run(&ports, ctx, req));
    }
}

// ------------------------------------------------------------------ arguments

fn spec_of(name: &str) -> &'static CommandSpec {
    commands()
        .iter()
        .find(|c| c.name == name)
        .unwrap_or_else(|| unreachable!("{name} is not in the register"))
}

fn input_of(req: &Request) -> Result<&AreaInput, Error> {
    match &req.params {
        Params::Area(input) => Ok(input),
        _ => Err(Error::Failed(format!("{}: missing arguments", req.command))),
    }
}

/// The usage line of a command, from its schema: `symcockpit ble write <device_id> ... [--no-with-response]`.
pub fn usage_line(spec: &CommandSpec) -> String {
    let schema = &spec.input_schema;
    let required: Vec<&str> = schema["required"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    let mut line = format!("Usage: symcockpit {}", spec.cli_path);
    for key in &required {
        line.push_str(&format!(" <{key}>"));
    }
    for (key, prop) in schema["properties"].as_object().into_iter().flatten() {
        if required.contains(&key.as_str()) {
            continue;
        }
        let flag = key.replace('_', "-");
        line.push_str(&match prop["type"].as_str() {
            Some("boolean") => format!(" [--{flag}]"),
            _ => format!(" [--{flag} <{key}>]"),
        });
    }
    line
}

fn parse_scalar(kind: &str, text: &str, what: &str) -> Result<Value, Error> {
    let bad = |expected: &str| Error::Usage(format!("{what} expects {expected}, got '{text}'"));
    Ok(match kind {
        "integer" => json!(text.parse::<i64>().map_err(|_| bad("a whole number"))?),
        "number" => json!(
            text.parse::<f64>()
                .ok()
                .filter(|n| n.is_finite())
                .ok_or_else(|| bad("a number"))?
        ),
        "boolean" => match text {
            "on" | "true" | "yes" => json!(true),
            "off" | "false" | "no" => json!(false),
            _ => return Err(bad("on or off")),
        },
        _ => json!(text),
    })
}

/// `--device-id x`, `--member a --member b` and `--no-with-response` all name
/// a property of the schema; arrays also accept their singular.
fn property_of<'a>(props: &'a Map<String, Value>, flag: &str) -> Option<&'a str> {
    let snake = flag.replace('-', "_");
    let plural_y = snake.strip_suffix('y').map(|s| format!("{s}ies"));
    props
        .get_key_value(&snake)
        .or_else(|| props.get_key_value(&format!("{snake}s")))
        .or_else(|| plural_y.and_then(|p| props.get_key_value(&p)))
        .map(|(key, _)| key.as_str())
}

/// The words after the CLI path as the JSON object the MCP tool would get:
/// `--name value` for any property, the rest fills the required properties in
/// their order (an array swallows what is left).
pub fn words_to_args(spec: &CommandSpec, words: &[String]) -> Result<Map<String, Value>, Error> {
    let none = Map::new();
    let props = spec.input_schema["properties"].as_object().unwrap_or(&none);
    let kind_of = |key: &str| props[key]["type"].as_str().unwrap_or("string").to_owned();
    let mut out = Map::new();
    let mut positional = Vec::new();
    let mut it = words.iter();
    while let Some(word) = it.next() {
        let Some(flag) = word.strip_prefix("--") else {
            positional.push(word);
            continue;
        };
        let (key, negated) = match property_of(props, flag) {
            Some(key) => (key, false),
            None => match flag
                .strip_prefix("no-")
                .and_then(|f| property_of(props, f))
                .filter(|k| kind_of(k) == "boolean")
            {
                Some(key) => (key, true),
                None => {
                    return Err(Error::Usage(format!(
                        "{}: unknown option --{flag}\n{}",
                        spec.cli_path,
                        usage_line(spec)
                    )));
                }
            },
        };
        match kind_of(key).as_str() {
            "boolean" => {
                out.insert(key.to_owned(), json!(!negated));
            }
            kind => {
                let value = it.next().ok_or_else(|| {
                    Error::Usage(format!("{}: --{flag} needs a value", spec.cli_path))
                })?;
                if kind == "array" {
                    let list = out.entry(key).or_insert_with(|| json!([]));
                    if let Some(items) = list.as_array_mut() {
                        items.push(json!(value));
                    }
                } else {
                    out.insert(
                        key.to_owned(),
                        parse_scalar(kind, value, &format!("--{flag}"))?,
                    );
                }
            }
        }
    }
    let mut rest = positional.into_iter();
    for key in spec.input_schema["required"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
    {
        if out.contains_key(key) {
            continue;
        }
        let kind = kind_of(key);
        if kind == "array" {
            out.insert(key.to_owned(), json!(rest.by_ref().collect::<Vec<_>>()));
        } else {
            let word = rest.next().ok_or_else(|| Error::Usage(usage_line(spec)))?;
            out.insert(key.to_owned(), parse_scalar(&kind, word, key)?);
        }
    }
    if let Some(extra) = rest.next() {
        return Err(Error::Usage(format!(
            "{}: unexpected argument '{extra}'\n{}",
            spec.cli_path,
            usage_line(spec)
        )));
    }
    Ok(out)
}

/// Checks MCP (and parsed CLI) arguments against the schema of the command.
pub fn validate(spec: &CommandSpec, args: &Map<String, Value>) -> Result<(), Error> {
    let usage = |m: String| Err(Error::Usage(m));
    for key in spec.input_schema["required"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
    {
        if args.get(key).is_none_or(Value::is_null) {
            return usage(format!("missing argument '{key}'"));
        }
    }
    let none = Map::new();
    for (key, schema) in spec.input_schema["properties"].as_object().unwrap_or(&none) {
        let Some(value) = args.get(key).filter(|v| !v.is_null()) else {
            continue;
        };
        let fits = match schema["type"].as_str() {
            Some("string") => value.is_string(),
            Some("integer") => value.as_i64().is_some() || value.as_u64().is_some(),
            Some("number") => value.is_number(),
            Some("boolean") => value.is_boolean(),
            Some("array") => value
                .as_array()
                .is_some_and(|items| items.iter().all(Value::is_string)),
            _ => true,
        };
        if !fits {
            return usage(format!("'{key}' must be of type {}", schema["type"]));
        }
        if let Some(allowed) = schema["enum"].as_array()
            && !allowed.contains(value)
        {
            return usage(format!("'{key}' must be one of {allowed:?}"));
        }
        if let Some(n) = value.as_f64() {
            let below = schema["minimum"].as_f64().is_some_and(|m| n < m);
            let above = schema["maximum"].as_f64().is_some_and(|m| n > m);
            if below || above {
                return usage(format!("'{key}' is out of range"));
            }
        }
        if let (Some(items), Some(min)) = (value.as_array(), schema["minItems"].as_u64())
            && (items.len() as u64) < min
        {
            return usage(format!("'{key}' needs at least {min} entries"));
        }
    }
    Ok(())
}

/// The validated arguments of a request, whichever way they arrived.
fn args_of(req: &Request) -> Result<Map<String, Value>, Error> {
    let spec = spec_of(req.command);
    let args = match input_of(req)? {
        AreaInput::Words(words) => words_to_args(spec, words)?,
        AreaInput::Args(args) => args.clone(),
    };
    validate(spec, &args)?;
    Ok(args)
}

fn text<'a>(args: &'a Map<String, Value>, key: &str) -> Result<&'a str, Error> {
    args.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| Error::Usage(format!("missing argument '{key}'")))
}

fn strings(args: &Map<String, Value>, key: &str) -> Vec<String> {
    args.get(key)
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|v| v.as_str().map(str::to_owned))
        .collect()
}

/// JSON for `--json` and for MCP, else the command's text form.
fn render(req: &Request, value: Value, text: impl FnOnce(&Value) -> String) -> Output {
    if req.json {
        Output::Json(value)
    } else {
        Output::text(text(&value))
    }
}

fn db_path(ctx: &Context) -> PathBuf {
    ctx.data_dir.join(symcockpit_db::FILE_NAME)
}

// --------------------------------------------------------------------- plans

/// An engine over `cockpit.sqlite` with every action kind registered. The
/// actions open their ports on first use.
fn with_engine<T>(
    ports: &Ports,
    ctx: &Context,
    run: impl FnOnce(&Engine) -> Result<T, Error>,
) -> Result<T, Error> {
    let store = (ports.plans)(&db_path(ctx))?;
    let apps = (ports.apps)(&ctx.paths.home);
    let trash = FsAction::trash(&*ports.remover).with_running(&*apps);
    let delete = FsAction::delete(&*ports.remover);
    let kill = KillAction {
        control: &*ports.processes,
        grace: GRACE,
        sleep: &*ports.sleep,
    };
    let service = || Ok((ports.audio)()?.service);
    let audio = [
        "audio.format.set",
        "audio.aggregate.create",
        "audio.aggregate.delete",
    ]
    .map(|kind| AudioPlanAction {
        kind,
        service: &service,
    });
    let ble = BlePlanAction {
        central: &*ports.central,
        connect_timeout: Duration::from_secs(10),
    };
    let mut engine = Engine::new(&*store, &*ports.clock)
        .register(&trash)
        .register(&delete)
        .register(&kill)
        .register(&ble);
    for action in &audio {
        engine = engine.register(action as &dyn Action);
    }
    run(&engine)
}

/// The plan kind a risky command records, so `--confirm <id>` can refuse the
/// id of a plan some other command made.
pub fn plan_kind(command: &str) -> Option<&'static str> {
    Some(match command {
        "storage.clean" => "clean",
        "storage.duplicates.remove" => "remove_duplicates",
        "apps.uninstall" => "uninstall_app",
        "processes.kill" => symcockpit_core::kill::KIND,
        "ble.write" => BLE_WRITE_KIND,
        "audio.format.set" => "audio.format.set",
        "audio.aggregate.create" => "audio.aggregate.create",
        "audio.aggregate.delete" => "audio.aggregate.delete",
        _ => return None,
    })
}

fn plans(ports: &Ports, ctx: &Context, req: &Request) -> Result<Output, Error> {
    let args = args_of(req)?;
    let home = &ctx.paths.home;
    let json = |value| Ok(Output::Json(value));
    match req.command {
        "plan.show" => json(with_engine(ports, ctx, |e| {
            get_plan_json(e, text(&args, "plan_id")?)
        })?),
        "plan.confirm" => with_engine(ports, ctx, |e| {
            let id = text(&args, "plan_id")?;
            if let Some(kind) = args.get("expect_kind").and_then(Value::as_str) {
                let plan = e.get(id)?;
                if plan.kind != kind {
                    return Err(Error::Usage(format!(
                        "plan {id} is a '{}' plan, not '{kind}'",
                        plan.kind
                    )));
                }
            }
            let report = e.confirm(id)?;
            Ok(Output::Report {
                code: outcome_exit_code(report.status),
                value: report.to_json(),
            })
        }),
        "storage.clean" => json(with_engine(ports, ctx, |e| {
            plan_clean_json(e, home, &strings(&args, "categories"))
        })?),
        "storage.duplicates.remove" => json(with_engine(ports, ctx, |e| {
            let select: Vec<PathBuf> = strings(&args, "select")
                .into_iter()
                .map(PathBuf::from)
                .collect();
            plan_remove_duplicates_json(
                e,
                home,
                Path::new(text(&args, "path")?),
                &select,
                min_size(&args),
            )
        })?),
        "apps.uninstall" => json(with_engine(ports, ctx, |e| {
            let apps = (ports.apps)(home);
            plan_uninstall_app_json(e, &*apps, home, Path::new("/"), text(&args, "app")?)
        })?),
        other => Err(Error::Failed(format!("{other}: no handler"))),
    }
}

fn min_size(args: &Map<String, Value>) -> u64 {
    args.get("min_size").and_then(Value::as_u64).unwrap_or(1)
}

// ------------------------------------------------------------------- storage

fn storage(ports: &Ports, ctx: &Context, req: &Request) -> Result<Output, Error> {
    let input = input_of(req)?;
    let home = &ctx.paths.home;
    let words = match input {
        AreaInput::Words(w) => Some(w.as_slice()),
        AreaInput::Args(_) => None,
    };
    match req.command {
        "storage.health" => {
            // MCP never records: the tool stays read-only.
            let params = match words {
                Some(w) => HealthParams::parse_cli(w)?,
                None => HealthParams { record: false },
            };
            let history = (ports.history)(&db_path(ctx))?;
            let value = health_json(&*ports.nvme, &*ports.clock, Some(&*history), &params)?;
            Ok(render(req, value, render_health))
        }
        "storage.health.history" => {
            let params = match (words, input) {
                (Some(w), _) => HistoryParams::parse_cli(w)?,
                (None, AreaInput::Args(a)) => {
                    validate(spec_of(req.command), a)?;
                    HistoryParams::from_json(&Value::Object(a.clone()))?
                }
                (None, _) => HistoryParams::default(),
            };
            let history = (ports.history)(&db_path(ctx))?;
            Ok(Output::Json(health_history_json(&*history, &params)?))
        }
        "storage.speedtest" => {
            let params = match input {
                AreaInput::Words(w) => SpeedtestParams::parse_cli(w, Limits::cli())?,
                AreaInput::Args(a) => {
                    validate(spec_of(req.command), a)?;
                    SpeedtestParams::from_json(&Value::Object(a.clone()), Limits::mcp(home))?
                }
            };
            let value = speedtest_json(&*ports.speed, &*ports.clock, &params)?;
            Ok(render(req, value, render_speedtest))
        }
        "storage.space" => {
            let params = match input {
                AreaInput::Words(w) => SpaceParams::parse_cli(w)?,
                AreaInput::Args(a) => {
                    validate(spec_of(req.command), a)?;
                    SpaceParams::from_json(&Value::Object(a.clone()))?
                }
            };
            let value = space_json(&*ports.space, &*ports.clock, &params)?;
            Ok(render(req, value, render_space))
        }
        "storage.duplicates" => {
            let args = args_of(req)?;
            Ok(Output::Json(find_duplicates_json(
                Path::new(text(&args, "path")?),
                min_size(&args),
            )?))
        }
        _ => plans(ports, ctx, req),
    }
}

// --------------------------------------------------------------------- kill

fn kill(ports: &Ports, ctx: &Context, req: &Request) -> Result<Output, Error> {
    let args = args_of(req)?;
    let pid = args.get("pid").and_then(Value::as_i64).unwrap_or(0);
    let plan = with_engine(ports, ctx, |e| plan_kill_json(e, &*ports.processes, pid))?;
    Ok(Output::Json(plan))
}

// --------------------------------------------------------------------- audio

fn scope_of(args: &Map<String, Value>) -> Result<Option<Scope>, Error> {
    args.get("direction")
        .and_then(Value::as_str)
        .map(Scope::parse)
        .transpose()
}

fn volume(args: &Map<String, Value>, key: &str) -> Result<f32, Error> {
    args.get(key)
        .and_then(Value::as_f64)
        .map(|v| v as f32)
        .ok_or_else(|| Error::Usage(format!("missing argument '{key}'")))
}

/// The audio command an MCP tool call stands for.
fn command_from_args(name: &str, args: &Map<String, Value>) -> Result<Command, Error> {
    let uid = || text(args, "uid").map(str::to_owned);
    Ok(match name {
        "audio.devices" => Command::Devices { json: true },
        "audio.device" => Command::Device { uid: uid()? },
        "audio.default.get" => Command::DefaultGet,
        "audio.volume.get" => Command::VolumeGet { uid: uid()? },
        "audio.format.get" => Command::FormatGet { uid: uid()? },
        "audio.mixer.status" => Command::MixerStatus,
        "midi.devices" => Command::MidiDevices { json: true },
        "audio.default.set" => Command::DefaultSet {
            scope: Scope::parse(text(args, "direction")?)?,
            uid: uid()?,
        },
        "audio.volume.set" => Command::VolumeSet {
            uid: uid()?,
            scope: scope_of(args)?,
            value: volume(args, "value")?,
        },
        "audio.mute.set" => Command::Mute {
            uid: uid()?,
            scope: scope_of(args)?,
            muted: args.get("muted").and_then(Value::as_bool).unwrap_or(false),
        },
        "audio.app-volume.set" => Command::MixerSet {
            app: text(args, "app")?.to_owned(),
            setting: AppSetting {
                volume: volume(args, "volume")?,
                muted: args.get("muted").and_then(Value::as_bool).unwrap_or(false),
            },
        },
        "audio.format.set" => Command::FormatSet {
            uid: uid()?,
            rate: args.get("rate").and_then(Value::as_f64).unwrap_or_default(),
            bits: args
                .get("bits")
                .and_then(Value::as_u64)
                .and_then(|b| u32::try_from(b).ok()),
        },
        "audio.aggregate.create" => Command::AggregateCreate {
            name: text(args, "name")?.to_owned(),
            members: strings(args, "members"),
            main: args.get("main").and_then(Value::as_str).map(str::to_owned),
            multi_output: args
                .get("multi_output")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        },
        other => {
            return Err(Error::Unsupported(format!("{other} is not available here")));
        }
    })
}

fn audio(ports: &Ports, ctx: &Context, req: &Request) -> Result<Output, Error> {
    let spec = spec_of(req.command);
    let command = match input_of(req)? {
        AreaInput::Words(words) => {
            // The audio parser wants everything after the family word.
            let mut all: Vec<String> = spec
                .cli_path
                .split(' ')
                .skip(1)
                .map(str::to_owned)
                .collect();
            all.extend(words.iter().cloned());
            if spec.name.starts_with("midi") {
                parse_midi(&all)?
            } else {
                parse_audio(&all)?
            }
        }
        AreaInput::Args(args) => {
            validate(spec, args)?;
            command_from_args(spec.name, args)?
        }
    };
    let kit = (ports.audio)()?;
    if let Some(plan) = command.plan(&kit.service) {
        let plan = plan?;
        let stored = with_engine(ports, ctx, |e| {
            let stored = e.create(plan.action_id(), vec![plan.engine_item()])?;
            Ok(e.plan_json(&stored))
        })?;
        return Ok(Output::Json(stored));
    }
    if matches!(command, Command::MixerRun { .. }) {
        (kit.before_foreground)();
    }
    let audio_ctx = audio_cli::Context {
        audio: &kit.service,
        midi: &kit.midi,
        tap: kit.tap.clone(),
        mixer: None,
        stop: &*kit.stop,
    };
    let value = audio_cli::run(&command, &audio_ctx)?;
    let code = symcockpit_core::audio::commands::exit_code_of(&value);
    Ok(
        if req.json
            || !matches!(
                command,
                Command::Devices { .. } | Command::MidiDevices { .. }
            )
        {
            Output::Report { value, code }
        } else {
            Output::Text {
                stdout: audio_cli::render(&command, &value),
                stderr: String::new(),
            }
        },
    )
}

// ----------------------------------------------------------------- bluetooth

fn bluetooth(ports: &Ports, ctx: &Context, req: &Request) -> Result<Output, Error> {
    // `ble read <device>` lists the GATT tree; with a service and a
    // characteristic it reads one value.
    let services_only = req.command == "ble.read"
        && matches!(input_of(req)?, AreaInput::Words(w) if w.len() == 1 && !w[0].starts_with("--"));
    let args = if services_only {
        Map::new()
    } else {
        args_of(req)?
    };
    let mut log = BleLog::new(1000);
    let seconds =
        |key: &str, default: f64| args.get(key).and_then(Value::as_f64).unwrap_or(default);
    let value = match req.command {
        "bt.devices" => bt_devices_json(&*ports.paired)?,
        "ble.scan" => {
            let central = (ports.central)()?;
            let filter = ScanFilter::new(args.get("filter").and_then(Value::as_str).unwrap_or(""));
            ble_scan_json(
                &*central,
                &mut log,
                Duration::from_secs_f64(seconds("timeout_seconds", 5.0)),
                &filter,
            )?
        }
        "ble.read" if services_only => {
            let AreaInput::Words(w) = input_of(req)? else {
                unreachable!("services_only implies words");
            };
            ble_services_json(&*(ports.central)()?, &mut log, &w[0])?
        }
        "ble.read" => ble_read_json(
            &*(ports.central)()?,
            &mut log,
            text(&args, "device_id")?,
            text(&args, "service")?,
            text(&args, "characteristic")?,
            Duration::from_secs(10),
        )?,
        "ble.subscribe" => ble_subscribe_json(
            &*(ports.central)()?,
            &mut log,
            text(&args, "device_id")?,
            text(&args, "service")?,
            text(&args, "characteristic")?,
            Duration::from_secs_f64(seconds("seconds", 10.0)),
        )?,
        "ble.write" => {
            let request = WriteRequest::new(
                text(&args, "device_id")?,
                text(&args, "service")?,
                text(&args, "characteristic")?,
                text(&args, "value_hex")?,
                args.get("with_response")
                    .and_then(Value::as_bool)
                    .unwrap_or(true),
            )?;
            with_engine(ports, ctx, |e| plan_ble_write_json(e, &request))?
        }
        // shortcut: the log lives in the memory of one process, and a one-shot
        // command ends with it; exporting needs the long-lived app agent.
        "ble.export" => {
            return Err(Error::Unsupported(
                "the BLE log lives in the running app agent; a one-shot command has none to export"
                    .into(),
            ));
        }
        other => return Err(Error::Failed(format!("{other}: no handler"))),
    };
    Ok(Output::Json(value))
}

// --------------------------------------------------------------------- input

fn input(ports: &Ports, ctx: &Context, req: &Request) -> Result<Output, Error> {
    let args = args_of(req)?;
    let kit = &ports.input;
    let store = (kit.settings)(&ctx.paths.config_dir.join("input.json"));
    let value = match req.command {
        "input.status" => input_status_json(&*store, &*kit.probe, &*kit.haptic)?,
        "input.finder-cut" => input_finder_cut_json(&*store, text(&args, "state")? == "on")?,
        "input.haptics.status" => input_haptics_status_json(&*store, &*kit.haptic)?,
        "input.haptics.test" => input_haptics_test_json(&*store, &*kit.haptic, &*kit.sound)?,
        other => return Err(Error::Failed(format!("{other}: no handler"))),
    };
    Ok(Output::Json(value))
}

/// Clipboard history management (R73, D13). No command returns clip content;
/// only the app reads the history. Creating the store is the app's job, so a
/// command here only opens an existing one.
fn clipboard(_ports: &Ports, ctx: &Context, req: &Request) -> Result<Output, Error> {
    use symcockpit_core::clipboard::{
        ClipStore, clipboard_clear_json, clipboard_pause_json, clipboard_resume_json,
        clipboard_status_json,
    };
    use symcockpit_db::clipboard::{JsonSettings, SqliteClipStore, dir_in};

    let dir = dir_in(ctx.data_dir);
    let settings = JsonSettings::new(&dir);
    let open = || -> Result<Option<Box<dyn ClipStore>>, Error> {
        Ok(SqliteClipStore::open_existing(&dir)?.map(|s| Box::new(s) as Box<dyn ClipStore>))
    };
    let value = match req.command {
        "clipboard.status" => clipboard_status_json(&settings, &open)?,
        "clipboard.pause" => clipboard_pause_json(&settings)?,
        "clipboard.resume" => clipboard_resume_json(&settings)?,
        "clipboard.clear" => clipboard_clear_json(&open)?,
        other => return Err(Error::Failed(format!("{other}: no handler"))),
    };
    Ok(Output::Json(value))
}
