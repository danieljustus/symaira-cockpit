//! What the privileged helper and its clients need from the platform:
//! the connection policy (team identifiers, requirements), a typed client,
//! the live ports of the helper engine, signals and user lookups.
//!
//! `symcockpit-helper` and the CLI only reach the platform through here
//! (ADR 0004).

use std::ffi::CString;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use symcockpit_core::battery::BatterySource;
use symcockpit_core::clock::{Monotonic, SystemMonotonic};
use symcockpit_core::helper_engine::HelperPorts;
use symcockpit_core::sensors::{GovernorProbe, SensorHost, SmcPort};
use symcockpit_core::smc_write::SmcWriter;
use symcockpit_helper_proto::signing::{self, Role};
use symcockpit_helper_proto::{HELPER_IDENTIFIER, Reply, Request, decode_request};
use symcockpit_store::Config;

use crate::battery::LiveBatterySource;
use crate::codesign;
use crate::smc::{LiveHost, LiveSmc, PgrepGovernorProbe};
use crate::xpc::{Client, Handler, Hooks, Server};

/// The team identifier this build is expected to be signed with, baked in at
/// build time from `SYMCOCKPIT_EMBEDDED_TEAM_ID` (release builds only). Without
/// it (every local, CI and debug build) the helper neither serves nor is
/// trusted: the connection policy fails closed.
pub fn embedded_team_identifier() -> Option<&'static str> {
    option_env!("SYMCOCKPIT_EMBEDDED_TEAM_ID").filter(|t| !t.is_empty())
}

/// The peer requirement for this process in `role`, or why it must refuse
/// every connection (`FanHelperConnectionPolicy.decide` plus the check that
/// the own signature satisfies the pinned Developer ID requirement itself, so
/// an ad-hoc or self-signed build cannot claim a team).
pub fn connection_requirement(role: Role) -> Result<String, String> {
    let own = codesign::own_team_identifier();
    let decision =
        signing::decide(role, own.as_deref(), embedded_team_identifier()).map_err(str::to_owned)?;
    if !codesign::self_satisfies(&decision.own) {
        return Err("own signature does not satisfy the Developer ID requirement".into());
    }
    Ok(decision.peer)
}

/// Serve the helper's Mach service. The handler receives the raw request
/// text; use [`reply_to`] to decode, dispatch and encode.
pub fn serve(handler: Handler, hooks: Hooks) -> Result<Server, String> {
    let requirement = connection_requirement(Role::HelperAcceptingClient)?;
    Server::mach_service(HELPER_IDENTIFIER, &requirement, handler, hooks)
}

/// Decode a request, hand it to `engine`, encode the reply; an unknown action
/// or version is answered with an error and never reaches `engine`.
pub fn reply_to(text: &str, engine: impl FnOnce(Request) -> Reply) -> String {
    match decode_request(text) {
        Ok(request) => engine(request).to_json(),
        Err(error) => error.to_json(),
    }
}

/// Typed client of the helper over XPC.
pub struct HelperClient {
    client: Client,
    timeout: Duration,
}

impl HelperClient {
    /// Connect to the installed helper. Fails closed (`Err`) in a build that
    /// is not signed with the team embedded in it.
    pub fn connect() -> Result<Self, String> {
        let requirement = connection_requirement(Role::ClientAcceptingHelper)?;
        Ok(Self {
            client: Client::mach_service(HELPER_IDENTIFIER, &requirement)?,
            timeout: Duration::from_secs(5),
        })
    }

    pub fn request(&self, request: &Request) -> Result<Reply, String> {
        Reply::from_json(&self.client.request(&request.to_json(), self.timeout)?)
    }
}

/// Whether a helper status reply says the governor is actually running.
/// Kept separate from XPC so the interpretation is testable without a helper.
pub fn reports_governor_running(reply: &Reply) -> bool {
    matches!(reply, Reply::Status { state, .. } if state == "governing")
}

/// Ask the helper whether its governor is running. Connection failures are
/// an ordinary "no helper" answer here, not a write falling back silently.
pub fn helper_governor_running() -> bool {
    let Ok(client) = HelperClient::connect() else {
        return false;
    };
    match client.request(&Request::new(symcockpit_helper_proto::Action::Status)) {
        Ok(reply) => reports_governor_running(&reply),
        Err(_) => false,
    }
}

/// Which UID the process runs as is `system::running_as_root`; this is the
/// numeric `(uid, gid)` of a named user (`getpwnam`).
pub fn user_ids(name: &str) -> Option<(u32, u32)> {
    let name = CString::new(name).ok()?;
    // SAFETY: `name` is NUL-terminated; the returned record is static storage
    // owned by libc and read immediately.
    unsafe {
        let entry = libc::getpwnam(name.as_ptr());
        (!entry.is_null()).then(|| ((*entry).pw_uid, (*entry).pw_gid))
    }
}

static TERMINATION: AtomicBool = AtomicBool::new(false);

extern "C" fn on_termination(_: libc::c_int) {
    TERMINATION.store(true, Ordering::SeqCst);
}

/// Route SIGTERM, SIGINT and SIGHUP to a flag instead of killing the process,
/// so the helper and `fan governor` unwind through their restore. The handler
/// only stores to an atomic.
pub fn install_termination_handlers() {
    for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
        // SAFETY: installing an async-signal-safe handler (a single atomic store).
        unsafe { libc::signal(signal, on_termination as *const () as libc::sighandler_t) };
    }
}

pub fn termination_requested() -> bool {
    TERMINATION.load(Ordering::SeqCst)
}

/// The helper's live ports: the real SMC (read and policed write), host
/// facts, the battery and the monotonic clock.
pub struct LiveHelperPorts {
    smc: Arc<LiveSmc>,
    host: LiveHost,
    battery: LiveBatterySource,
    config: Config,
    probe: PgrepGovernorProbe,
}

impl LiveHelperPorts {
    pub fn open(config: Config) -> Self {
        Self {
            smc: Arc::new(LiveSmc::open()),
            host: LiveHost,
            battery: LiveBatterySource,
            config,
            probe: PgrepGovernorProbe,
        }
    }
}

impl HelperPorts for LiveHelperPorts {
    fn smc(&self) -> &dyn SmcPort {
        &*self.smc
    }

    fn writer(&self) -> &dyn SmcWriter {
        // `LiveSmc::write_key_raw` checks the allowlist itself.
        &*self.smc
    }

    fn host(&self) -> &dyn SensorHost {
        &self.host
    }

    fn battery(&self) -> &dyn BatterySource {
        &self.battery
    }

    fn clock(&self) -> &dyn Monotonic {
        &SystemMonotonic
    }

    fn config(&self) -> &Config {
        &self.config
    }

    fn legacy_governor_running(&self) -> bool {
        self.probe.is_running()
    }
}

#[cfg(test)]
mod tests {
    use super::reports_governor_running;
    use symcockpit_helper_proto::Reply;

    #[test]
    fn a_helper_is_reported_running_only_while_governing() {
        assert!(reports_governor_running(&Reply::Status {
            state: "governing".into(),
            detail: None,
        }));
        for state in ["idle", "failed", "governor", ""] {
            assert!(!reports_governor_running(&Reply::Status {
                state: state.into(),
                detail: None,
            }));
        }
        assert!(!reports_governor_running(&Reply::Ok));
    }
}
