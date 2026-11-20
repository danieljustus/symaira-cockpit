//! One `*_json` function per command: the single implementation behind the
//! CLI and the MCP tool of the same name. Each returns the JSON the command
//! prints, or the [`Error`] that sets the exit code.
//!
//! Writes return `Ok` with the report for `confirmed`, `unconfirmed` and
//! `skipped_changed` (the report says which; see [`exit_code_of`]) and `Err`
//! when the HAL refused or the capability is absent.
//!
//! Risky commands (`format_set`, `aggregate_*`) also have a `plan_*` function;
//! the plan engine confirms a plan and then calls the `*_json` function or
//! [`AudioService::execute`] with it.

use serde_json::{Value, json};
use symcockpit_contract::{Error, exit};

use super::hal::{Scope, ScopeState};
use super::mixer::{AudioProcess, MixerControl, TapHal};
use super::registry::DeviceRecord;
use super::service::{AudioPlan, AudioService};

/// Exit code for a successful command's JSON: `0` unless it carries an
/// `outcome` other than `confirmed` (then `1`).
pub fn exit_code_of(value: &Value) -> u8 {
    match value.get("outcome").and_then(Value::as_str) {
        None | Some("confirmed") => exit::OK,
        Some(_) => exit::ERROR,
    }
}

fn scope_json(s: &ScopeState) -> Value {
    json!({
        "channels": s.channels,
        "volume": s.volume,
        "volume_settable": s.volume_settable,
        "muted": s.muted,
        "mute_settable": s.mute_settable,
        "format": s.format.map(|f| f.to_json()),
    })
}

fn device_value(svc: &AudioService, rec: &DeviceRecord) -> Value {
    let d = &rec.last;
    let reg = svc.registry();
    json!({
        "uid": d.uid,
        "name": d.name,
        "manufacturer": d.manufacturer,
        "transport": d.transport,
        "kind": d.kind.name(),
        "online": rec.online(),
        "object_id": rec.object.map(|o| o.0),
        "epoch": rec.epoch,
        "default_input": reg.default_uid(Scope::Input) == Some(d.uid.as_str()),
        "default_output": reg.default_uid(Scope::Output) == Some(d.uid.as_str()),
        "input": scope_json(&d.input),
        "output": scope_json(&d.output),
        "sample_rate": d.sample_rate,
        "sample_rates": d.sample_rates.iter().map(|r| json!({"min": r.min, "max": r.max})).collect::<Vec<_>>(),
        "members": d.members,
    })
}

pub fn devices_json(svc: &AudioService) -> Result<Value, Error> {
    svc.refresh()?;
    let records: Vec<DeviceRecord> = svc.registry().records().cloned().collect();
    let devices: Vec<Value> = records.iter().map(|r| device_value(svc, r)).collect();
    let reg = svc.registry();
    Ok(json!({
        "generation": reg.generation(),
        "default_input_uid": reg.default_uid(Scope::Input),
        "default_output_uid": reg.default_uid(Scope::Output),
        "devices": devices,
    }))
}

pub fn device_json(svc: &AudioService, uid: &str) -> Result<Value, Error> {
    svc.refresh()?;
    let rec = svc
        .registry()
        .record(uid)
        .cloned()
        .ok_or_else(|| Error::Usage(format!("no audio device with uid '{uid}'")))?;
    Ok(device_value(svc, &rec))
}

pub fn default_get_json(svc: &AudioService) -> Result<Value, Error> {
    svc.refresh()?;
    let reg = svc.registry();
    Ok(json!({
        "input": reg.default_uid(Scope::Input),
        "output": reg.default_uid(Scope::Output),
    }))
}

pub fn default_set_json(svc: &AudioService, scope: Scope, uid: &str) -> Result<Value, Error> {
    svc.set_default(scope, uid)?.into_json()
}

pub fn volume_get_json(svc: &AudioService, uid: &str) -> Result<Value, Error> {
    let (_, d) = svc.resolve(uid)?;
    Ok(json!({"uid": uid, "input": d.input.volume, "output": d.output.volume}))
}

pub fn volume_set_json(
    svc: &AudioService,
    uid: &str,
    scope: Option<Scope>,
    value: f32,
) -> Result<Value, Error> {
    svc.set_volume(uid, scope, value)?.into_json()
}

pub fn mute_json(
    svc: &AudioService,
    uid: &str,
    scope: Option<Scope>,
    muted: bool,
) -> Result<Value, Error> {
    svc.set_mute(uid, scope, muted)?.into_json()
}

pub fn format_get_json(svc: &AudioService, uid: &str) -> Result<Value, Error> {
    let (_, d) = svc.resolve(uid)?;
    let formats = |s: &ScopeState| s.formats.iter().map(|f| f.to_json()).collect::<Vec<_>>();
    Ok(json!({
        "uid": uid,
        "sample_rate": d.sample_rate,
        "sample_rates": d.sample_rates.iter().map(|r| json!({"min": r.min, "max": r.max})).collect::<Vec<_>>(),
        "input": {"format": d.input.format.map(|f| f.to_json()), "formats": formats(&d.input)},
        "output": {"format": d.output.format.map(|f| f.to_json()), "formats": formats(&d.output)},
    }))
}

pub fn plan_format_set(
    svc: &AudioService,
    uid: &str,
    rate: f64,
    bits: Option<u32>,
) -> Result<AudioPlan, Error> {
    svc.plan_format(uid, rate, bits)
}

/// Plan and run in one go; the caller has already obtained the confirmation.
pub fn format_set_json(
    svc: &AudioService,
    uid: &str,
    rate: f64,
    bits: Option<u32>,
) -> Result<Value, Error> {
    let plan = plan_format_set(svc, uid, rate, bits)?;
    svc.execute(&plan).into_json()
}

pub fn plan_aggregate_create(
    svc: &AudioService,
    name: &str,
    members: &[String],
    main: Option<&str>,
    multi_output: bool,
) -> Result<AudioPlan, Error> {
    svc.plan_aggregate_create(name, members, main, multi_output)
}

pub fn aggregate_create_json(
    svc: &AudioService,
    name: &str,
    members: &[String],
    main: Option<&str>,
    multi_output: bool,
) -> Result<Value, Error> {
    let plan = plan_aggregate_create(svc, name, members, main, multi_output)?;
    svc.execute(&plan).into_json()
}

pub fn plan_aggregate_delete(svc: &AudioService, uid: &str) -> Result<AudioPlan, Error> {
    svc.plan_aggregate_delete(uid)
}

pub fn aggregate_delete_json(svc: &AudioService, uid: &str) -> Result<Value, Error> {
    let plan = plan_aggregate_delete(svc, uid)?;
    svc.execute(&plan).into_json()
}

/// Resolve `app` (a pid or a bundle id) to the audio processes it names.
pub fn resolve_app(processes: &[AudioProcess], app: &str) -> Result<Vec<AudioProcess>, Error> {
    let found: Vec<AudioProcess> = match app.parse::<i32>() {
        Ok(pid) => processes.iter().filter(|p| p.pid == pid).cloned().collect(),
        Err(_) => processes
            .iter()
            .filter(|p| p.bundle_id.as_deref() == Some(app))
            .cloned()
            .collect(),
    };
    if found.is_empty() {
        return Err(Error::Failed(format!(
            "'{app}' has no audio process; it must have opened an audio stream"
        )));
    }
    Ok(found)
}

/// `set_audio_app_volume`: needs a running mixer (the app agent's, or
/// `audio mixer run`'s). Reversible: volume 1 without mute removes the tap.
pub fn app_volume_set_json(
    mixer: &dyn MixerControl,
    tap: &dyn TapHal,
    app: &str,
    volume: f32,
    muted: bool,
) -> Result<Value, Error> {
    let processes = resolve_app(&tap.processes()?, app)?;
    let mut apps = Vec::new();
    for p in processes {
        apps.push(mixer.set_app_volume(p.pid, volume, muted)?.to_json());
    }
    Ok(json!({"app": app, "apps": apps}))
}

pub fn mixer_status_json(
    tap: &dyn TapHal,
    mixer: Option<&dyn MixerControl>,
) -> Result<Value, Error> {
    let supported = tap.supported();
    let processes = if supported { tap.processes()? } else { vec![] };
    Ok(json!({
        "supported": supported,
        "mixer_running": mixer.is_some(),
        "managed": mixer.map(|m| m.status().iter().map(|s| s.to_json()).collect::<Vec<_>>()),
        "audio_processes": processes.iter().map(|p| json!({
            "pid": p.pid, "bundle_id": p.bundle_id, "running_output": p.running_output,
        })).collect::<Vec<_>>(),
    }))
}

/// Short human summary of `devices_json` output.
pub fn render_devices(value: &Value) -> String {
    let mut out = String::new();
    for d in value["devices"].as_array().into_iter().flatten() {
        let mark = |k: &str, c: &'static str| if d[k] == json!(true) { c } else { " " };
        out.push_str(&format!(
            "{}{} {:<9} {:<12} {} [{}]\n",
            mark("default_input", "i"),
            mark("default_output", "o"),
            if d["online"] == json!(true) {
                "online"
            } else {
                "offline"
            },
            d["transport"].as_str().unwrap_or("?"),
            d["name"].as_str().unwrap_or("?"),
            d["uid"].as_str().unwrap_or("?"),
        ));
    }
    out
}
