//! Production wiring of the privileged write commands (`fan set|auto|governor`,
//! `battery-limit set|clear`, `restore`): the live SMC, PowerUI and helper
//! ports around `symcockpit_core::write_commands`.
//!
//! The ways, as before: root writes itself; without root the SMC work goes
//! to the running helper over XPC when it can be reached, and otherwise is
//! attempted directly and refused (exit 3). No elevation happens here — the
//! GUI elevates through `osascript` and `PrivilegedExecutableResolver`, which
//! this module neither widens nor replaces.

use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::json;
use symcockpit_contract::Error;
use symcockpit_core::clock::SystemMonotonic;
use symcockpit_core::fan::FanEnv;
use symcockpit_core::plan::rfc3339;
use symcockpit_core::write_commands::{
    Command, Route, WriteEnv, execute, helper_action, log_outcome, reply_to_result, route,
    run_governor,
};
use symcockpit_macos::battery::LiveBatterySource;
use symcockpit_macos::helper::{
    HelperClient, install_termination_handlers, termination_requested, user_ids,
};
use symcockpit_macos::powerui::PowerUiClient;
use symcockpit_macos::smc::{FileFanSelection, LiveHost, LiveSmc};
use symcockpit_macos::system::running_as_root;
use symcockpit_store::state_perms::{owner_of_path, ownership_to_restore, sudo_owner};

use crate::app::{App, Context, Output, Params, Request};

fn now() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(0));
    rfc3339(secs)
}

/// `{"applied": true}`, the `ApplyResult` of the Swift CLI.
fn applied() -> Output {
    Output::Json(json!({ "applied": true }))
}

fn run(ctx: &Context, command: &Command) -> Result<Output, Error> {
    let is_root = running_as_root();
    let smc = LiveSmc::open();
    let (host, battery, clock) = (LiveHost, LiveBatterySource, SystemMonotonic);
    // PowerUI is only loaded for the charge limit, which is the only command that uses it.
    let mac = matches!(command, Command::ChargeSet(_) | Command::ChargeClear)
        .then(PowerUiClient::connect)
        .flatten();
    let sudo = sudo_owner(is_root, &|k| ctx.env.get(k).cloned(), &user_ids);
    let env = WriteEnv {
        fan: FanEnv {
            smc: &smc,
            writer: &smc,
            host: &host,
            config: ctx.config,
            clock: &clock,
        },
        mac: mac
            .as_ref()
            .map(|m| m as &dyn symcockpit_core::charge_limit::MacChargeLimit),
        battery: &battery,
        data_dir: ctx.data_dir,
        owner: ownership_to_restore(ctx.data_dir, is_root, &owner_of_path, sudo),
        is_root,
        now: &now,
    };

    if let Command::FanGovernor { state } = command {
        install_termination_handlers();
        let state = state
            .clone()
            .unwrap_or_else(|| ctx.paths.fan_profile_file());
        run_governor(
            &env,
            &state,
            &FileFanSelection::at(&state),
            &|| !termination_requested(),
            &mut |line| eprintln!("{line}"),
        )?;
        return Ok(Output::text(""));
    }

    if route(&env, command) == Route::Helper
        && let (Some(action), Ok(client)) = (helper_action(command), HelperClient::connect())
    {
        match client.request(&symcockpit_helper_proto::Request::new(action)) {
            Ok(reply) => {
                let result = reply_to_result(reply);
                log_outcome(&env, command, &result);
                return result.map(|()| applied());
            }
            // Not reachable (not installed, not approved): the direct write decides.
            Err(_) => {}
        }
    }
    execute(&env, command).map(|()| applied())
}

/// Registers the six write commands on the production app.
pub fn wire(app: &mut App) {
    for name in crate::app::WRITE_COMMANDS {
        app.handlers
            .register_write(name, |ctx: &Context, req: &Request| {
                let Params::Write(command) = &req.params else {
                    return Err(Error::Failed(format!("{}: missing command", req.command)));
                };
                run(ctx, command)
            });
    }
}
