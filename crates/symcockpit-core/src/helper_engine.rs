//! The privileged helper's engine: what a request does, and the dead-man
//! rules (architecture §6.2, R20). Platform-free: the helper binary only
//! carries requests in (XPC) and drives [`Engine::poll`] on a timer.
//!
//! Rules, all fail-safe toward the firmware:
//! - a governor needs a heartbeat: nothing for more than
//!   [`HEARTBEAT_TIMEOUT_MS`] (three missed pings plus a second of slack)
//!   hands the fans back and ends the governor;
//! - three governor ticks without a die temperature, or three ticks on which
//!   the SMC did not hold the applied state, do the same (the governor's own
//!   policy);
//! - a fixed target lives only for its lease;
//! - the restore record is written before the first change and removed after
//!   a clean restore; a helper that dies leaves it for the next start.
//!
//! The engine never writes an SMC key it was not asked to through a typed
//! request: the write port underneath only knows the fan and charge keys.

use symcockpit_contract::{Error, Outcome};
use symcockpit_helper_proto::{
    Action, ErrorKind, GovernorProfile, HEARTBEAT_TIMEOUT_MS, MAX_LEASE_MS, PROTOCOL_VERSION,
    Reply, Request,
};
use symcockpit_store::Config;
use symcockpit_store::state_perms::Owner;

use crate::battery::BatterySource;
use crate::charge_limit::{self, ChargeEnv, Mechanism};
use crate::clock::Monotonic;
use crate::fan::{FanEnv, has_software_override, restore_auto};
use crate::governor::{DEFAULT_INTERVAL, FixedHold, Governor, Tick};
use crate::restore::RestoreTracker;
use crate::sensors::{FanProfile, FanSelection, SensorHost, SmcPort};
use crate::smc_write::SmcWriter;

/// Chargers: 50..=100 % (`SafetyPolicy`); the helper refuses anything else
/// instead of clamping a value it did not expect (Q02).
const CHARGE_RANGE: std::ops::RangeInclusive<i64> = 50..=100;

/// Everything the engine touches, owned by the helper process.
pub trait HelperPorts: Send {
    fn smc(&self) -> &dyn SmcPort;
    fn writer(&self) -> &dyn SmcWriter;
    fn host(&self) -> &dyn SensorHost;
    fn battery(&self) -> &dyn BatterySource;
    fn clock(&self) -> &dyn Monotonic;
    fn config(&self) -> &Config;
    /// The standalone `fan governor` process (the osascript path) owns the
    /// fans while it runs: the helper must not hand them back under it.
    fn legacy_governor_running(&self) -> bool;
}

/// Why a run ended.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum StopReason {
    Requested,
    HeartbeatTimeout,
    ConnectionInvalidated,
    Terminated,
    ProfileSystem,
    /// The governor returned or failed by itself.
    GovernorFinished,
    LeaseExpired,
}

impl StopReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Requested => "requested",
            Self::HeartbeatTimeout => "heartbeat_timeout",
            Self::ConnectionInvalidated => "connection_invalidated",
            Self::Terminated => "terminated",
            Self::ProfileSystem => "profile_system",
            Self::GovernorFinished => "governor_finished",
            Self::LeaseExpired => "lease_expired",
        }
    }
}

enum Run {
    Idle,
    Governing {
        governor: Governor,
        selection: FanSelection,
        next_tick_ms: u64,
    },
    Fixed {
        hold: FixedHold,
        fraction: f64,
        until_ms: u64,
        next_tick_ms: u64,
    },
}

pub struct Engine {
    ports: Box<dyn HelperPorts>,
    tracker: RestoreTracker,
    run: Run,
    last_beat_ms: u64,
    last_stop: Option<StopReason>,
    failure: Option<String>,
    helper_version: String,
    /// Lines for the helper's stderr (launchd's log).
    pub log: Vec<String>,
}

macro_rules! env {
    ($ports:expr) => {
        FanEnv {
            smc: $ports.smc(),
            writer: $ports.writer(),
            host: $ports.host(),
            config: $ports.config(),
            clock: $ports.clock(),
        }
    };
}

fn error_reply(e: &Error) -> Reply {
    let kind = match e {
        Error::Usage(_) | Error::Config(_) => ErrorKind::Usage,
        Error::Permission(_) => ErrorKind::Permission,
        Error::Unsupported(_) | Error::NotImplemented(_) => ErrorKind::Unsupported,
        Error::Failed(_) => ErrorKind::Failed,
    };
    Reply::error(kind, e.to_string())
}

impl Engine {
    pub fn new(
        ports: Box<dyn HelperPorts>,
        data_dir: &std::path::Path,
        owner: Option<Owner>,
        helper_version: &str,
    ) -> Self {
        let now = ports.clock().now_ms();
        Self {
            ports,
            tracker: RestoreTracker::new(data_dir, owner),
            run: Run::Idle,
            last_beat_ms: now,
            last_stop: None,
            failure: None,
            helper_version: helper_version.into(),
            log: Vec::new(),
        }
    }

    pub fn is_governing(&self) -> bool {
        !matches!(self.run, Run::Idle)
    }

    pub fn last_stop(&self) -> Option<StopReason> {
        self.last_stop
    }

    /// At helper launch, before serving: a fresh helper governs nothing, so a
    /// leftover restore record or a forced fan was left by a predecessor that
    /// died mid-run (#414). Unless the standalone governor still holds them.
    pub fn recover_stale(&mut self) {
        let Self {
            ports,
            tracker,
            log,
            ..
        } = self;
        let env = env!(ports);
        let consumed = tracker.consume_persisted(&env);
        log.extend(consumed.warnings.iter().map(|w| format!("warning: {w}")));
        if consumed.applied {
            log.push("restored the SMC state a previous helper left behind".into());
        }
        Self::recover_forced_fans(&env, ports.legacy_governor_running(), log);
    }

    fn recover_forced_fans(env: &FanEnv, legacy_running: bool, log: &mut Vec<String>) {
        if !has_software_override(env) || legacy_running {
            return;
        }
        match restore_auto(env) {
            Ok(()) => log.push("stale fan override restored".into()),
            Err(e) => log.push(format!("stale fan override: {e:?}")),
        }
    }

    pub fn beat(&mut self) {
        self.last_beat_ms = self.ports.clock().now_ms();
    }

    // -- requests ---------------------------------------------------------

    pub fn handle(&mut self, request: Request) -> Reply {
        match request.action {
            Action::Hello => Reply::Hello {
                version: PROTOCOL_VERSION,
                helper_version: self.helper_version.clone(),
            },
            Action::Heartbeat => {
                self.beat();
                Reply::Heartbeat {
                    governing: self.is_governing(),
                }
            }
            Action::Status => {
                let (state, detail) = self.status();
                Reply::Status { state, detail }
            }
            Action::GovernorStart {
                profile,
                cool_target_celsius,
            } => self.start_governor(profile, cool_target_celsius),
            Action::GovernorStop => {
                self.stop(StopReason::Requested);
                self.recover_if_idle();
                Reply::Ok
            }
            Action::FanSetAuto => {
                self.stop(StopReason::Requested);
                self.recover_if_idle();
                Reply::Ok
            }
            Action::FanSetTarget { fraction, lease_ms } => self.start_fixed(fraction, lease_ms),
            Action::SmcRestore => self.smc_restore(),
            Action::ChargeLimitSmc { percent } => self.charge_limit(percent),
        }
    }

    fn status(&self) -> (String, Option<String>) {
        match &self.run {
            Run::Governing { selection, .. } => {
                ("governing".into(), Some(selection.profile.as_str().into()))
            }
            Run::Fixed { fraction, .. } => {
                ("governing".into(), Some(format!("fixed {fraction:.2}")))
            }
            Run::Idle => match (&self.failure, self.last_stop) {
                (Some(f), _) => ("failed".into(), Some(f.clone())),
                (None, Some(reason)) => ("idle".into(), Some(reason.as_str().into())),
                (None, None) => ("idle".into(), None),
            },
        }
    }

    fn start_governor(&mut self, profile: GovernorProfile, cool: Option<f64>) -> Reply {
        // Not trusted: a non-finite number is refused, a finite one clamped
        // to 50..=85 °C, and it only ever adds cooling.
        if cool.is_some_and(|c| !c.is_finite()) {
            return Reply::error(ErrorKind::Usage, "cool_target_celsius must be finite");
        }
        let profile = match profile {
            GovernorProfile::Comfort => FanProfile::Comfort,
            GovernorProfile::Performance => FanProfile::Performance,
        };
        let selection = FanSelection::new(profile, cool);
        if let Run::Governing {
            selection: current, ..
        } = &mut self.run
        {
            *current = selection;
            self.beat();
            return Reply::Ok;
        }
        // A fixed hold, or anything still unwinding, ends before the governor
        // captures "original" state (it would capture the half-restored one).
        self.stop(StopReason::Requested);
        {
            let Self { ports, tracker, .. } = self;
            let env = env!(ports);
            let fans = crate::sensors::read_key_uint(env.smc, "FNum").unwrap_or(0) as usize;
            for i in 0..fans {
                tracker.save_fan_original(&env, i);
            }
        }
        self.failure = None;
        self.last_stop = None;
        self.beat();
        let now = self.ports.clock().now_ms();
        self.run = Run::Governing {
            governor: Governor::default(),
            selection,
            next_tick_ms: now,
        };
        Reply::Ok
    }

    fn start_fixed(&mut self, fraction: f64, lease_ms: u64) -> Reply {
        if !fraction.is_finite() {
            return Reply::error(ErrorKind::Usage, "fraction must be finite");
        }
        if lease_ms == 0 || lease_ms > MAX_LEASE_MS {
            return Reply::error(
                ErrorKind::Usage,
                format!("lease_ms must be 1..={MAX_LEASE_MS}"),
            );
        }
        self.stop(StopReason::Requested);
        let started = {
            let Self { ports, tracker, .. } = self;
            let env = env!(ports);
            let fans = crate::sensors::read_key_uint(env.smc, "FNum").unwrap_or(0) as usize;
            for i in 0..fans {
                tracker.save_fan_original(&env, i);
            }
            FixedHold::start(&env, fraction)
        };
        match started {
            Ok(hold) => {
                let now = self.ports.clock().now_ms();
                self.failure = None;
                self.last_stop = None;
                self.run = Run::Fixed {
                    hold,
                    fraction,
                    until_ms: now + lease_ms,
                    next_tick_ms: now + DEFAULT_INTERVAL.as_millis() as u64,
                };
                Reply::Ok
            }
            Err(e) => {
                self.tracker.forget_fans();
                error_reply(&e.into_error(true))
            }
        }
    }

    fn smc_restore(&mut self) -> Reply {
        self.stop(StopReason::Requested);
        let Self {
            ports,
            tracker,
            log,
            ..
        } = self;
        let env = env!(ports);
        let consumed = tracker.consume_persisted(&env);
        log.extend(consumed.warnings.iter().map(|w| format!("warning: {w}")));
        tracker.restore_all(&env);
        Self::recover_forced_fans(&env, ports.legacy_governor_running(), log);
        if has_software_override(&env) && !ports.legacy_governor_running() {
            Reply::error(
                ErrorKind::Failed,
                "the SMC still reports a forced fan after the restore",
            )
        } else {
            Reply::Ok
        }
    }

    fn charge_limit(&mut self, percent: Option<i64>) -> Reply {
        if let Some(p) = percent
            && !CHARGE_RANGE.contains(&p)
        {
            return Reply::error(
                ErrorKind::Usage,
                format!(
                    "percent must be {}..={}",
                    CHARGE_RANGE.start(),
                    CHARGE_RANGE.end()
                ),
            );
        }
        let Self { ports, tracker, .. } = self;
        let fan_env = env!(ports);
        // Only the SMC mechanism is the helper's; the macOS limit runs in the user's agent.
        if !matches!(charge_limit::select(&fan_env, None), Mechanism::Smc(_)) {
            return Reply::error(
                ErrorKind::Unsupported,
                crate::sensors::MISSING_CHARGE_LIMIT_KEY_DETAIL,
            );
        }
        let env = ChargeEnv {
            fan: &fan_env,
            mac: None,
            battery: ports.battery(),
            config: ports.config(),
        };
        let result = match percent {
            Some(p) => charge_limit::set(&env, tracker, p),
            None => charge_limit::clear(&env),
        };
        match result {
            Err(e) => error_reply(&e),
            Ok(r) => match r.outcome {
                Outcome::Confirmed => Reply::Ok,
                Outcome::Unconfirmed => Reply::error(
                    ErrorKind::Unconfirmed,
                    r.detail.unwrap_or_else(|| "state not confirmed".into()),
                ),
                Outcome::Unsupported => {
                    Reply::error(ErrorKind::Unsupported, r.detail.unwrap_or_default())
                }
                _ => Reply::error(ErrorKind::Failed, r.detail.unwrap_or_default()),
            },
        }
    }

    fn recover_if_idle(&mut self) {
        // Nothing of ours is running: an explicit Standard still has to
        // recover fans a dead predecessor left forced.
        if matches!(self.run, Run::Idle) {
            let Self { ports, log, .. } = self;
            let env = env!(ports);
            Self::recover_forced_fans(&env, ports.legacy_governor_running(), log);
        }
    }

    // -- runs --------------------------------------------------------------

    /// Ends the current run and hands the fans back to what was found.
    pub fn stop(&mut self, reason: StopReason) {
        let run = std::mem::replace(&mut self.run, Run::Idle);
        let Self { ports, tracker, .. } = self;
        let env = env!(ports);
        match run {
            Run::Idle => return,
            Run::Governing { mut governor, .. } => governor.finish(&env),
            Run::Fixed { mut hold, .. } => hold.finish(&env),
        }
        tracker.forget_fans();
        self.last_stop = Some(reason);
        self.log.push(format!("run ended: {}", reason.as_str()));
    }

    /// The connection that owned the run went away: nothing is left to send heartbeats.
    pub fn connection_invalidated(&mut self) {
        if matches!(self.run, Run::Governing { .. }) {
            self.stop(StopReason::ConnectionInvalidated);
        }
    }

    /// SIGTERM: stop the run, the fans are back before the process exits.
    pub fn terminate(&mut self) {
        self.stop(StopReason::Terminated);
    }

    /// One scheduling step: the watchdog, the lease and the due governor tick.
    /// Call it every few hundred milliseconds.
    pub fn poll(&mut self) {
        let now = self.ports.clock().now_ms();
        let next = DEFAULT_INTERVAL.as_millis() as u64;
        let mut stop = None;
        {
            let Self {
                ports,
                run,
                last_beat_ms,
                failure,
                log,
                ..
            } = self;
            let env = env!(ports);
            match run {
                Run::Idle => {}
                Run::Governing {
                    governor,
                    selection,
                    next_tick_ms,
                } => {
                    if now.saturating_sub(*last_beat_ms) > HEARTBEAT_TIMEOUT_MS {
                        stop = Some(StopReason::HeartbeatTimeout);
                    } else if now >= *next_tick_ms {
                        *next_tick_ms = now + next;
                        match governor.tick(&env, selection) {
                            Ok(Tick::Stop) => stop = Some(StopReason::ProfileSystem),
                            Ok(Tick::Ran { .. }) => {}
                            Err(e) => {
                                log.push(format!("governor stopped: {e:?}"));
                                *failure = Some(e.into_error(true).to_string());
                                stop = Some(StopReason::GovernorFinished);
                            }
                        }
                    }
                }
                Run::Fixed {
                    hold,
                    until_ms,
                    next_tick_ms,
                    ..
                } => {
                    if now >= *until_ms {
                        stop = Some(StopReason::LeaseExpired);
                    } else if now >= *next_tick_ms {
                        *next_tick_ms = now + next;
                        if let Err(e) = hold.tick(&env) {
                            log.push(format!("fixed target stopped: {e:?}"));
                            *failure = Some(e.into_error(true).to_string());
                            stop = Some(StopReason::GovernorFinished);
                        }
                    }
                }
            }
        }
        if let Some(reason) = stop {
            self.stop(reason);
        }
    }
}

/// When an idle helper may exit (`FanHelperIdleMonitor.shouldExit`): no
/// governor, no client, continuously for the grace period. launchd starts the
/// current binary on the next Mach lookup, which is what lets an app upgrade
/// swap the helper.
pub fn idle_should_exit(governing: bool, connected: bool, idle_for_ms: u64, grace_ms: u64) -> bool {
    !governing && !connected && idle_for_ms >= grace_ms
}
