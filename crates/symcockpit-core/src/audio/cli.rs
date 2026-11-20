//! Parsing and dispatch of `symcockpit audio ...` and `symcockpit midi ...`.
//!
//! `parse` turns the words after `audio`/`midi` into a [`Command`]; `run`
//! executes it against the ports in [`Context`]. The dispatcher must obtain the
//! confirmation for commands whose [`Command::risk`] is `Risky` before calling
//! `run` (use [`Command::plan`] to build the plan it shows).

use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};
use symcockpit_contract::{Error, Risk};

use super::commands as c;
use super::hal::Scope;
use super::mixer::{AppMixer, AppSetting, MixerControl, TapHal, run_loop};
use super::service::{AudioPlan, AudioService};
use crate::midi::MidiService;

pub const AUDIO_USAGE: &str = "usage: symcockpit audio <command>
  devices [--json]
  default get | default set <input|output> <uid>
  volume get <uid> | volume set <uid> <0..1> [--direction input|output]
  mute <uid> on|off [--direction input|output]
  format get <uid> | format set <uid> --rate <hz> [--bits <n>]
  aggregate create <name> --member <uid> --member <uid>... [--main <uid>] [--multi-output]
  aggregate delete <uid>
  mixer run --app <pid|bundle-id>=<0..1|mute>... | mixer status
  mixer set <pid|bundle-id> <0..1|mute>   (needs a running mixer)";

pub const MIDI_USAGE: &str = "usage: symcockpit midi devices [--json]";

#[derive(Clone, Debug, PartialEq)]
pub enum Command {
    Devices {
        json: bool,
    },
    Device {
        uid: String,
    },
    DefaultGet,
    DefaultSet {
        scope: Scope,
        uid: String,
    },
    VolumeGet {
        uid: String,
    },
    VolumeSet {
        uid: String,
        scope: Option<Scope>,
        value: f32,
    },
    Mute {
        uid: String,
        scope: Option<Scope>,
        muted: bool,
    },
    FormatGet {
        uid: String,
    },
    FormatSet {
        uid: String,
        rate: f64,
        bits: Option<u32>,
    },
    AggregateCreate {
        name: String,
        members: Vec<String>,
        main: Option<String>,
        multi_output: bool,
    },
    AggregateDelete {
        uid: String,
    },
    /// Each app is `(pid or bundle id, setting)`.
    MixerRun {
        apps: Vec<(String, AppSetting)>,
    },
    /// Needs a mixer that is already running (the app agent's).
    MixerSet {
        app: String,
        setting: AppSetting,
    },
    MixerStatus,
    MidiDevices {
        json: bool,
    },
}

fn usage(text: &str) -> Error {
    Error::Usage(text.to_owned())
}

/// Splits `args` into positionals and `--flag value` pairs (`--json` and
/// `--multi-output` take no value).
struct Args {
    positional: Vec<String>,
    flags: Vec<(String, Option<String>)>,
}

impl Args {
    fn new(args: &[String]) -> Result<Args, Error> {
        let mut a = Args {
            positional: vec![],
            flags: vec![],
        };
        let mut it = args.iter();
        while let Some(arg) = it.next() {
            match arg.strip_prefix("--") {
                Some(name @ ("json" | "multi-output")) => a.flags.push((name.to_owned(), None)),
                Some(name) => {
                    let v = it
                        .next()
                        .ok_or_else(|| usage(&format!("--{name} needs a value")))?;
                    a.flags.push((name.to_owned(), Some(v.clone())));
                }
                None => a.positional.push(arg.clone()),
            }
        }
        Ok(a)
    }

    fn has(&self, name: &str) -> bool {
        self.flags.iter().any(|(n, _)| n == name)
    }

    fn all(&self, name: &str) -> Vec<String> {
        self.flags
            .iter()
            .filter(|(n, _)| n == name)
            .filter_map(|(_, v)| v.clone())
            .collect()
    }

    fn one(&self, name: &str) -> Result<Option<String>, Error> {
        let mut v = self.all(name);
        if v.len() > 1 {
            return Err(usage(&format!("--{name} given twice")));
        }
        Ok(v.pop())
    }

    /// Reject flags the command does not know, and surplus positionals.
    fn check(&self, known: &[&str], positionals: usize) -> Result<(), Error> {
        if let Some((n, _)) = self
            .flags
            .iter()
            .find(|(n, _)| !known.contains(&n.as_str()))
        {
            return Err(usage(&format!("unknown option --{n}\n{AUDIO_USAGE}")));
        }
        if self.positional.len() != positionals {
            return Err(usage(AUDIO_USAGE));
        }
        Ok(())
    }
}

fn number<T: std::str::FromStr>(text: &str, what: &str) -> Result<T, Error> {
    text.parse()
        .map_err(|_| usage(&format!("{what} must be a number, got '{text}'")))
}

fn finite_f32(text: &str, what: &str) -> Result<f32, Error> {
    let v: f32 = number(text, what)?;
    if v.is_finite() {
        Ok(v)
    } else {
        Err(usage(&format!("{what} must be finite")))
    }
}

fn direction(a: &Args) -> Result<Option<Scope>, Error> {
    a.one("direction")?.map(|d| Scope::parse(&d)).transpose()
}

/// `args` are the words after `audio`.
pub fn parse_audio(args: &[String]) -> Result<Command, Error> {
    let (head, rest) = args.split_first().ok_or_else(|| usage(AUDIO_USAGE))?;
    let sub = |rest: &[String]| -> Result<(String, Args), Error> {
        let (s, r) = rest.split_first().ok_or_else(|| usage(AUDIO_USAGE))?;
        Ok((s.clone(), Args::new(r)?))
    };
    match head.as_str() {
        "devices" => {
            let a = Args::new(rest)?;
            a.check(&["json"], 0)?;
            Ok(Command::Devices {
                json: a.has("json"),
            })
        }
        "device" => {
            let a = Args::new(rest)?;
            a.check(&[], 1)?;
            Ok(Command::Device {
                uid: a.positional[0].clone(),
            })
        }
        "default" => match sub(rest)? {
            (s, a) if s == "get" => {
                a.check(&[], 0)?;
                Ok(Command::DefaultGet)
            }
            (s, a) if s == "set" => {
                a.check(&[], 2)?;
                Ok(Command::DefaultSet {
                    scope: Scope::parse(&a.positional[0])?,
                    uid: a.positional[1].clone(),
                })
            }
            _ => Err(usage(AUDIO_USAGE)),
        },
        "volume" => match sub(rest)? {
            (s, a) if s == "get" => {
                a.check(&[], 1)?;
                Ok(Command::VolumeGet {
                    uid: a.positional[0].clone(),
                })
            }
            (s, a) if s == "set" => {
                a.check(&["direction"], 2)?;
                Ok(Command::VolumeSet {
                    uid: a.positional[0].clone(),
                    scope: direction(&a)?,
                    value: finite_f32(&a.positional[1], "volume")?,
                })
            }
            _ => Err(usage(AUDIO_USAGE)),
        },
        "mute" => {
            let a = Args::new(rest)?;
            a.check(&["direction"], 2)?;
            let muted = match a.positional[1].as_str() {
                "on" => true,
                "off" => false,
                _ => return Err(usage("mute takes on or off")),
            };
            Ok(Command::Mute {
                uid: a.positional[0].clone(),
                scope: direction(&a)?,
                muted,
            })
        }
        "format" => match sub(rest)? {
            (s, a) if s == "get" => {
                a.check(&[], 1)?;
                Ok(Command::FormatGet {
                    uid: a.positional[0].clone(),
                })
            }
            (s, a) if s == "set" => {
                a.check(&["rate", "bits"], 1)?;
                let rate = a
                    .one("rate")?
                    .ok_or_else(|| usage("format set needs --rate <hz>"))?;
                Ok(Command::FormatSet {
                    uid: a.positional[0].clone(),
                    rate: number(&rate, "--rate")?,
                    bits: a.one("bits")?.map(|b| number(&b, "--bits")).transpose()?,
                })
            }
            _ => Err(usage(AUDIO_USAGE)),
        },
        "aggregate" => match sub(rest)? {
            (s, a) if s == "create" => {
                a.check(&["member", "main", "multi-output"], 1)?;
                Ok(Command::AggregateCreate {
                    name: a.positional[0].clone(),
                    members: a.all("member"),
                    main: a.one("main")?,
                    multi_output: a.has("multi-output"),
                })
            }
            (s, a) if s == "delete" => {
                a.check(&[], 1)?;
                Ok(Command::AggregateDelete {
                    uid: a.positional[0].clone(),
                })
            }
            _ => Err(usage(AUDIO_USAGE)),
        },
        "mixer" => match sub(rest)? {
            (s, a) if s == "status" => {
                a.check(&[], 0)?;
                Ok(Command::MixerStatus)
            }
            (s, a) if s == "set" => {
                a.check(&[], 2)?;
                let (app, setting) =
                    parse_app(&format!("{}={}", a.positional[0], a.positional[1]))?;
                Ok(Command::MixerSet { app, setting })
            }
            (s, a) if s == "run" => {
                a.check(&["app"], 0)?;
                let apps = a
                    .all("app")
                    .iter()
                    .map(|spec| parse_app(spec))
                    .collect::<Result<Vec<_>, _>>()?;
                if apps.is_empty() {
                    return Err(usage(
                        "mixer run needs at least one --app <pid|bundle-id>=<0..1|mute>",
                    ));
                }
                Ok(Command::MixerRun { apps })
            }
            _ => Err(usage(AUDIO_USAGE)),
        },
        _ => Err(usage(AUDIO_USAGE)),
    }
}

fn parse_app(spec: &str) -> Result<(String, AppSetting), Error> {
    let (app, level) = spec.rsplit_once('=').ok_or_else(|| {
        usage(&format!(
            "--app '{spec}': expected <pid|bundle-id>=<0..1|mute>"
        ))
    })?;
    let setting = if level == "mute" {
        AppSetting {
            volume: 1.0,
            muted: true,
        }
    } else {
        let v = finite_f32(level, "app volume")?;
        if !(0.0..=1.0).contains(&v) {
            return Err(usage("app volume must be between 0 and 1"));
        }
        AppSetting {
            volume: v,
            muted: false,
        }
    };
    Ok((app.to_owned(), setting))
}

/// `args` are the words after `midi`.
pub fn parse_midi(args: &[String]) -> Result<Command, Error> {
    match args.split_first() {
        Some((h, rest)) if h == "devices" => {
            let a = Args::new(rest)?;
            if a.flags.iter().any(|(n, _)| n != "json") || !a.positional.is_empty() {
                return Err(usage(MIDI_USAGE));
            }
            Ok(Command::MidiDevices {
                json: a.has("json"),
            })
        }
        _ => Err(usage(MIDI_USAGE)),
    }
}

impl Command {
    /// Risky commands need a plan and a confirmation before `run`.
    pub fn risk(&self) -> Risk {
        match self {
            Command::FormatSet { .. }
            | Command::AggregateCreate { .. }
            | Command::AggregateDelete { .. } => Risk::Risky,
            Command::DefaultSet { .. }
            | Command::VolumeSet { .. }
            | Command::Mute { .. }
            | Command::MixerRun { .. }
            | Command::MixerSet { .. } => Risk::Reversible,
            _ => Risk::Read,
        }
    }

    /// The plan for a risky command, `None` for the others.
    pub fn plan(&self, svc: &AudioService) -> Option<Result<AudioPlan, Error>> {
        match self {
            Command::FormatSet { uid, rate, bits } => {
                Some(c::plan_format_set(svc, uid, *rate, *bits))
            }
            Command::AggregateCreate {
                name,
                members,
                main,
                multi_output,
            } => Some(c::plan_aggregate_create(
                svc,
                name,
                members,
                main.as_deref(),
                *multi_output,
            )),
            Command::AggregateDelete { uid } => Some(c::plan_aggregate_delete(svc, uid)),
            _ => None,
        }
    }
}

pub struct Context<'a> {
    pub audio: &'a AudioService,
    pub midi: &'a MidiService,
    /// `None` where process taps do not exist; mixer commands then exit 4.
    pub tap: Option<Arc<dyn TapHal>>,
    /// The running mixer of this process, if any (the app agent's); `mixer set` needs it.
    pub mixer: Option<&'a dyn MixerControl>,
    /// True once the process was asked to stop (SIGINT, SIGTERM).
    pub stop: &'a dyn Fn() -> bool,
}

pub fn run(cmd: &Command, ctx: &Context<'_>) -> Result<Value, Error> {
    let svc = ctx.audio;
    match cmd {
        Command::Devices { .. } => c::devices_json(svc),
        Command::Device { uid } => c::device_json(svc, uid),
        Command::DefaultGet => c::default_get_json(svc),
        Command::DefaultSet { scope, uid } => c::default_set_json(svc, *scope, uid),
        Command::VolumeGet { uid } => c::volume_get_json(svc, uid),
        Command::VolumeSet { uid, scope, value } => c::volume_set_json(svc, uid, *scope, *value),
        Command::Mute { uid, scope, muted } => c::mute_json(svc, uid, *scope, *muted),
        Command::FormatGet { uid } => c::format_get_json(svc, uid),
        Command::FormatSet { uid, rate, bits } => c::format_set_json(svc, uid, *rate, *bits),
        Command::AggregateCreate {
            name,
            members,
            main,
            multi_output,
        } => c::aggregate_create_json(svc, name, members, main.as_deref(), *multi_output),
        Command::AggregateDelete { uid } => c::aggregate_delete_json(svc, uid),
        Command::MidiDevices { .. } => ctx.midi.devices_json(),
        Command::MixerStatus => c::mixer_status_json(tap(ctx)?.as_ref(), ctx.mixer),
        Command::MixerSet { app, setting } => {
            let mixer = ctx.mixer.ok_or_else(|| {
                Error::Unsupported(
                    "no mixer is running in this process; use `audio mixer run` or the app".into(),
                )
            })?;
            c::app_volume_set_json(
                mixer,
                tap(ctx)?.as_ref(),
                app,
                setting.volume,
                setting.muted,
            )
        }
        Command::MixerRun { apps } => mixer_run(ctx, apps),
    }
}

fn tap(ctx: &Context<'_>) -> Result<Arc<dyn TapHal>, Error> {
    ctx.tap
        .clone()
        .ok_or_else(|| Error::Unsupported("per-app volume is not available on this system".into()))
}

/// Foreground mixer: holds the taps until `ctx.stop`, then releases every app.
fn mixer_run(ctx: &Context<'_>, apps: &[(String, AppSetting)]) -> Result<Value, Error> {
    let tap = tap(ctx)?;
    if !tap.supported() {
        return Err(Error::Unsupported(
            "per-app volume needs process taps (macOS 14.2 or later)".into(),
        ));
    }
    let mixer = Mutex::new(AppMixer::new(tap.clone()));
    let out = ctx.audio.hal().default_device(Scope::Output)?;
    let out_uid = out.map(|o| ctx.audio.hal().device_uid(o)).transpose()?;
    mixer
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .on_default_output(out_uid.as_deref());
    let processes = tap.processes()?;
    for (app, setting) in apps {
        // An app that is not playing yet is attached once it opens a stream.
        let pids: Vec<i32> = c::resolve_app(&processes, app)
            .map(|v| v.iter().map(|p| p.pid).collect())
            .or_else(|_| {
                app.parse::<i32>().map(|p| vec![p]).map_err(|_| {
                    Error::Failed(format!(
                        "'{app}' has no audio process; start it first or pass its pid"
                    ))
                })
            })?;
        for pid in pids {
            mixer.set_app_volume(pid, setting.volume, setting.muted)?;
        }
    }
    eprintln!(
        "{}",
        json!({"event": "mixer_started", "apps": MixerControl::status(&mixer).iter().map(|s| s.to_json()).collect::<Vec<_>>()})
    );
    let summary = run_loop(
        &mixer,
        ctx.audio.hal().as_ref(),
        ctx.stop,
        &std::thread::sleep as &dyn Fn(Duration),
    );
    let leaked = !summary.teardown_errors.is_empty();
    let result = json!({
        "stopped": true,
        "output_changes": summary.output_changes,
        "events": summary.events,
        "teardown_errors": summary.teardown_errors,
    });
    if leaked {
        return Err(Error::Failed(format!(
            "mixer stopped but cleanup failed: {result}"
        )));
    }
    Ok(result)
}

/// Text for a human, or pretty JSON when `--json` was given or the command has
/// no text form.
pub fn render(cmd: &Command, value: &Value) -> String {
    match cmd {
        Command::Devices { json: false } => c::render_devices(value),
        Command::MidiDevices { json: false } => render_midi(value),
        _ => serde_json::to_string_pretty(value).unwrap_or_default() + "\n",
    }
}

fn render_midi(value: &Value) -> String {
    let mut out = String::new();
    for d in value["devices"].as_array().into_iter().flatten() {
        let count = |k: &str| -> usize {
            d["entities"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|e| e[k].as_array().map_or(0, Vec::len))
                .sum()
        };
        out.push_str(&format!(
            "{:<8} {} ({} in, {} out)\n",
            if d["present"] == json!(true) {
                "present"
            } else {
                "gone"
            },
            d["name"].as_str().unwrap_or("?"),
            count("sources"),
            count("destinations"),
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(s: &str) -> Result<Command, Error> {
        let words: Vec<String> = s.split_whitespace().map(str::to_owned).collect();
        parse_audio(&words)
    }

    #[test]
    fn parses_the_documented_surface() {
        assert_eq!(
            p("devices --json").unwrap(),
            Command::Devices { json: true }
        );
        assert_eq!(
            p("default set output u1").unwrap(),
            Command::DefaultSet {
                scope: Scope::Output,
                uid: "u1".into()
            }
        );
        assert_eq!(
            p("volume set u1 0.5").unwrap(),
            Command::VolumeSet {
                uid: "u1".into(),
                scope: None,
                value: 0.5
            }
        );
        assert_eq!(
            p("mute u1 on").unwrap(),
            Command::Mute {
                uid: "u1".into(),
                scope: None,
                muted: true
            }
        );
        assert_eq!(
            p("format set u1 --rate 48000 --bits 24").unwrap(),
            Command::FormatSet {
                uid: "u1".into(),
                rate: 48000.0,
                bits: Some(24)
            }
        );
        assert_eq!(
            p("aggregate create Mix --member a --member b --multi-output").unwrap(),
            Command::AggregateCreate {
                name: "Mix".into(),
                members: vec!["a".into(), "b".into()],
                main: None,
                multi_output: true
            }
        );
        assert!(
            matches!(p("mixer run --app 123=0.5 --app com.x.y=mute").unwrap(), Command::MixerRun { apps } if apps.len() == 2)
        );
        assert_eq!(
            p("mixer set 123 0.25").unwrap(),
            Command::MixerSet {
                app: "123".into(),
                setting: AppSetting {
                    volume: 0.25,
                    muted: false
                }
            }
        );
    }

    #[test]
    fn rejects_bad_input_with_usage_errors() {
        for bad in [
            "",
            "volume set u1",
            "volume set u1 loud",
            "volume set u1 nan",
            "mute u1 maybe",
            "default set sideways u1",
            "format set u1",
            "format set u1 --rate fast",
            "devices extra",
            "devices --nope",
            "mixer run",
            "mixer run --app 1=2",
            "aggregate create",
            "unknown",
        ] {
            let err = p(bad).unwrap_err();
            assert!(matches!(err, Error::Usage(_)), "{bad}: {err:?}");
            assert_eq!(err.exit_code(), 2);
        }
    }

    #[test]
    fn risk_classes_follow_decision_d10() {
        assert_eq!(p("format set u --rate 44100").unwrap().risk(), Risk::Risky);
        assert_eq!(p("aggregate delete u").unwrap().risk(), Risk::Risky);
        assert_eq!(p("volume set u 1").unwrap().risk(), Risk::Reversible);
        assert_eq!(p("devices").unwrap().risk(), Risk::Read);
    }

    #[test]
    fn midi_parses() {
        let w = |s: &str| s.split_whitespace().map(str::to_owned).collect::<Vec<_>>();
        assert_eq!(
            parse_midi(&w("devices --json")).unwrap(),
            Command::MidiDevices { json: true }
        );
        assert!(parse_midi(&w("nope")).is_err());
    }
}
