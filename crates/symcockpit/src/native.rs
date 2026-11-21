//! Execution of one read request: a registered area handler, or one of the
//! commands implemented in this crate. `Ok(None)` means "no native
//! implementation (yet)": the caller answers `unsupported`.

use std::collections::BTreeSet;

use serde_json::Value;
use symcockpit_contract::Error;
use symcockpit_core::{ai_usage, history, profiles, status, system};
use symcockpit_store::history_writable;

use crate::VERSION;
use crate::app::{App, Context, Output, Params, Request};

fn json_of(app: &App, ctx: &Context, command: &'static str) -> Result<Value, Error> {
    let request = Request {
        command,
        json: true,
        params: Params::None,
    };
    match app
        .handlers
        .get(command)
        .ok_or_else(|| Error::Failed(format!("{command}: no handler")))?(ctx, &request)?
    {
        Output::Json(value) => Ok(value),
        Output::Report { value, .. } => Ok(value),
        Output::Text { .. } => Err(Error::Failed(format!(
            "{command}: handler returned text for a JSON request"
        ))),
    }
}

/// Whether `status` can run natively: it needs the three area reports and the
/// live overrides.
pub fn status_ready(app: &App) -> bool {
    ["sensors", "battery", "displays"]
        .iter()
        .all(|c| app.handlers.contains(c))
        && app.services.overrides.is_some()
}

pub fn run_read(app: &App, ctx: &Context, req: &Request) -> Result<Option<Output>, Error> {
    let history_file = ctx.data_dir.join("history.ndjson");
    match req.command {
        "doctor" => Ok(app.services.hardware.as_deref().map(|hw| {
            Output::Json(system::capabilities_json(
                hw,
                ctx.config,
                history_writable(&history_file),
                VERSION,
            ))
        })),
        "permissions" => Ok(app.services.hardware.as_deref().map(|hw| {
            Output::Json(system::permissions_json(
                hw,
                ctx.config,
                history_writable(&history_file),
            ))
        })),
        "status" => {
            let Some(overrides) = app
                .services
                .overrides
                .as_deref()
                .filter(|_| status_ready(app))
            else {
                return Ok(None);
            };
            let report = status::status_json(
                json_of(app, ctx, "sensors")?,
                json_of(app, ctx, "battery")?,
                json_of(app, ctx, "displays")?,
                overrides.active_overrides(),
                overrides.keep_awake_active(),
            )?;
            Ok(Some(if req.json {
                Output::Json(report)
            } else {
                Output::text(status::status_text(&report))
            }))
        }
        "history" => {
            let Params::History { limit } = req.params else {
                return Err(Error::Failed("history: missing limit".into()));
            };
            let events = history::read_events(&history_file, limit);
            Ok(Some(if req.json {
                Output::Json(history::events_json(&events))
            } else {
                Output::text(history::events_text(&events, &*app.services.local_time))
            }))
        }
        "profile.list" => Ok(Some(Output::Json(profiles::list_json(ctx.data_dir)))),
        "ai-usage" => {
            let Params::AiUsage { provider } = &req.params else {
                return Err(Error::Failed("ai-usage: missing provider".into()));
            };
            let selection: Option<BTreeSet<String>> =
                provider.as_ref().map(|p| BTreeSet::from([p.clone()]));
            let results = ai_usage::usage_report(
                &*app.services.usage_runner,
                ctx.env,
                selection.as_ref(),
                &app.services.vault_entry_paths,
            );
            Ok(Some(if req.json {
                Output::Json(results)
            } else {
                Output::text(ai_usage::usage_text(&results))
            }))
        }
        name => app
            .handlers
            .get(name)
            .map(|handler| handler(ctx, req))
            .transpose(),
    }
}
