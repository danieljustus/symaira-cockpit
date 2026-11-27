//! Production wiring of the privileged write commands (`fan set|auto|governor`,
//! `battery-limit set|clear`, `restore`): the live SMC, PowerUI and helper
//! ports around `symcockpit_core::write_commands`.
//!
//! The ways, as before: root writes itself; without root the SMC work goes
//! to the running helper over XPC when it can be reached, and otherwise is
//! attempted directly and refused (exit 3). No elevation happens here — the
//! GUI elevates through `osascript` and `PrivilegedExecutableResolver`, which
//! this module neither widens nor replaces.

use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::json;
use symcockpit_contract::Error;
use symcockpit_core::battery::{BatterySource, BatterySourceResult, charge_percent};
use symcockpit_core::charge_limit::{BandStep, band_step};
use symcockpit_core::clock::SystemMonotonic;
use symcockpit_core::fan::FanEnv;
use symcockpit_core::plan::rfc3339;
use symcockpit_core::sensors::{
    SmcPort, detect_charge_limit_key_family, read_charge_inhibit_state,
};
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

/// Runs one privileged command against the live SMC/helper and records its
/// outcome. Public so the fan-profile port can use exactly this write path
/// when a `system` selection has to clear a stale override.
pub fn run(ctx: &Context, command: &Command) -> Result<Output, Error> {
    crate::hardware_writes_blocked()?;
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
        // A transport error (not installed, not approved) falls through: the direct write decides.
        if let Ok(reply) = client.request(&symcockpit_helper_proto::Request::new(action)) {
            let result = reply_to_result(reply);
            log_outcome(&env, command, &result);
            return result.map(|()| applied());
        }
    }
    execute(&env, command).map(|()| applied())
}

/// The charge limit this process applied (`ChargeLimitState`): what a wake puts back. In
/// memory only, as in v0.12; a one-shot command ends before there is a wake to hear.
static CHARGE_TARGET: Mutex<Option<i64>> = Mutex::new(None);

fn track_charge_target(config: &symcockpit_store::Config, command: &Command) {
    let mut target = CHARGE_TARGET.lock().unwrap_or_else(|e| e.into_inner());
    match command {
        Command::ChargeSet(percent) => {
            *target = Some(
                (*percent)
                    .max(config.charge_limit_min)
                    .min(config.charge_limit_max),
            );
        }
        Command::ChargeClear | Command::Restore => *target = None,
        _ => {}
    }
}

/// After a wake: on Apple Silicon the SMC inhibit bit is volatile, so a limit this process
/// applied is put back (`reconcileChargeLimit`): inhibit again at or above the target, release
/// only once the battery is `charge_limit_hysteresis_percent` below it. Goes through the same
/// route as the command itself (root, or the helper). Intel `CHLC` persists: nothing to do.
pub fn reassert_charge(ctx: &Context) {
    let target = *CHARGE_TARGET.lock().unwrap_or_else(|e| e.into_inner());
    let Some(target) = target else { return };
    if !cfg!(target_arch = "aarch64") || crate::hardware_writes_blocked().is_err() {
        return;
    }
    let smc = LiveSmc::open();
    let BatterySourceResult::Success(props) = LiveBatterySource.read_properties() else {
        return;
    };
    if !smc.is_open() || detect_charge_limit_key_family(&smc).is_none() {
        return;
    }
    let Some(percent) = charge_percent(&props) else {
        return;
    };
    let inhibited = read_charge_inhibit_state(&smc).unwrap_or(false);
    let command = match band_step(
        inhibited,
        percent,
        target,
        ctx.config.charge_limit_hysteresis_percent,
    ) {
        BandStep::Inhibit => Command::ChargeSet(target),
        BandStep::Release => Command::ChargeClear,
        BandStep::Keep => return,
    };
    // Not tracked: a release inside the band keeps the target, as Swift's does.
    if let Err(e) = run(ctx, &command) {
        eprintln!("symcockpit: wake: charge limit not restored: {e}");
    }
}

/// Registers the six write commands on the production app.
pub fn wire(app: &mut App) {
    for name in crate::app::WRITE_COMMANDS {
        app.handlers.register(name, |ctx: &Context, req: &Request| {
            let Params::Write(command) = &req.params else {
                return Err(Error::Failed(format!("{}: missing command", req.command)));
            };
            let output = run(ctx, command)?;
            track_charge_target(ctx.config, command);
            Ok(output)
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn target() -> Option<i64> {
        *CHARGE_TARGET.lock().unwrap()
    }

    #[test]
    fn the_limit_this_process_applied_is_what_a_wake_restores() {
        let config = symcockpit_store::Config::default();
        track_charge_target(&config, &Command::ChargeSet(85));
        assert_eq!(target(), Some(85));
        // Clamped to the configured range, as the write is.
        track_charge_target(&config, &Command::ChargeSet(1));
        assert_eq!(target(), Some(config.charge_limit_min));
        // Other commands leave it; a clear or a restore forgets it.
        track_charge_target(&config, &Command::FanAuto);
        assert_eq!(target(), Some(config.charge_limit_min));
        track_charge_target(&config, &Command::ChargeClear);
        assert_eq!(target(), None);
        track_charge_target(&config, &Command::ChargeSet(80));
        track_charge_target(&config, &Command::Restore);
        assert_eq!(target(), None);
    }
}
