//! `fan profile <name>` and `fan target <°C>|off` as v0.12 runs them: only the
//! user's own file (`~/.symtune/fan-profile.json`) is written, never an SMC key
//! and never with a password prompt; a governor that is running picks the change
//! up on its next tick. The answer is the `fan status` document.

use serde_json::{Map, Value};
use symcockpit_contract::Error;
use symcockpit_core::fan_select::{Change, apply, encode};
use symcockpit_core::sensors::{FanProfile, FanSelection};
use symcockpit_macos::system::running_as_root;
use symcockpit_store::state_perms::{owner_of_path, ownership_to_restore};
use symcockpit_store::{HistoryEvent, append_history_event, write_private_atomic};

use crate::app::{App, Context, Output, Params, Request};
use crate::json;

/// The register commands `fan.profile` (`profile`) and `fan.target` (`celsius`,
/// a number or `off`) of the app agent, which has no argv.
pub fn change_from_arguments(
    name: &str,
    arguments: &Map<String, Value>,
) -> Result<Option<Change>, Error> {
    let (sub, key) = match name {
        "fan.profile" => ("profile", "profile"),
        "fan.target" => ("target", "celsius"),
        _ => return Ok(None),
    };
    let word = match arguments.get(key) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        // The app clears the target with `null` (it sends `off` only where the schema says text).
        Some(Value::Null) if sub == "target" => "off".to_owned(),
        _ => return Err(Error::Usage(format!("fan {sub} requires '{key}'."))),
    };
    symcockpit_core::fan_select::parse(sub, &[word]).map(Some)
}

/// Writes the selection and answers with the `fan status` document.
/// `Ok(None)`: no `fan.status` handler (test apps), the command is `unsupported`.
pub fn run_json(
    app: &App,
    ctx: &Context,
    change: &Change,
) -> Result<Option<(FanSelection, Value)>, Error> {
    let Some(status) = app.handlers.get("fan.status") else {
        return Ok(None);
    };
    let file = ctx.paths.fan_profile_file();
    let is_root = running_as_root();
    let current =
        std::fs::read(&file).map_or(FanSelection::SYSTEM, |b| FanSelection::from_json(&b));
    let selection = apply(current, *change);
    write_private_atomic(&file, encode(&selection).as_bytes(), is_root)
        .map_err(|e| Error::Failed(e.to_string()))?;
    let (action, requested, clamped) = match change {
        Change::Profile(p) => (format!("fan.profile.{}", p.as_str()), None, None),
        Change::Target(t) => (
            "fan.cooltarget".to_owned(),
            *t,
            selection.cool_target_celsius,
        ),
    };
    let event = HistoryEvent {
        timestamp: jiff::Timestamp::now()
            .strftime("%Y-%m-%dT%H:%M:%SZ")
            .to_string(),
        action,
        requested_value: requested,
        clamped_value: clamped,
        applied_value: None,
        result: "success".into(),
        error_reason: None,
    };
    let owner = ownership_to_restore(ctx.data_dir, is_root, &owner_of_path, None);
    if let Err(e) = append_history_event(&ctx.data_dir.join("history.ndjson"), &event, owner) {
        eprintln!("symtune: warning: failed to write history event: {e}");
    }
    let request = Request {
        command: "fan.status",
        json: true,
        params: Params::None,
    };
    let document = crate::cli::json_value(status(ctx, &request)?)?;
    Ok(Some((selection, document)))
}

/// The CLI's answer: the hint lines v0.12 prints, then the document.
pub fn run(app: &App, ctx: &Context, change: &Change) -> Result<Option<Output>, Error> {
    let Some((selection, document)) = run_json(app, ctx, change)? else {
        return Ok(None);
    };
    let (mut stdout, mut stderr) = (String::new(), String::new());
    match change {
        Change::Profile(profile) => {
            if *profile != FanProfile::System && document["governor_running"] != true {
                stdout.push_str(&format!(
                    "Selected {}. No fan governor is running \u{2014} start one with `sudo symcockpit fan governor`.\n",
                    profile.as_str()
                ));
            }
        }
        Change::Target(_) if selection.profile != FanProfile::Comfort => stderr.push_str(
            "Stored. The target applies while the fan control is on Cool (`symcockpit fan profile comfort`).\n",
        ),
        Change::Target(_) => {}
    }
    stdout.push_str(&format!("{}\n", json::pretty(&document)));
    Ok(Some(Output::Text { stdout, stderr }))
}
