//! `com.symaira.symtune-helper`: started by launchd as root on the first Mach
//! lookup (registered by the app through SMAppService), serves XPC, exits when
//! idle. Diagnostics go to stderr (launchd's log); stdout stays unused.
//!
//! Two read-only introspection modes exist for the release workflow, which
//! must verify the signed bundle against exactly the requirement strings the
//! code enforces (they touch neither XPC nor the SMC):
//!   --print-embedded-team                       the team baked in at build time
//!   --print-requirement <app|helper> <TEAM>     the XPC requirement for TEAM

use std::path::PathBuf;
use std::process::ExitCode;

use symcockpit_core::helper_engine::Engine;
use symcockpit_helper::{Exit, Service, run, system_clock};
use symcockpit_helper_proto::signing::{Role, app_requirement, helper_requirement};
use symcockpit_macos::helper::{
    LiveHelperPorts, connection_requirement, embedded_team_identifier,
    install_termination_handlers, serve, termination_requested,
};
use symcockpit_store::Config;

/// Where the root helper keeps `smc-restore.json` (root-owned, 0700).
const DEFAULT_DATA_DIR: &str = "/var/db/com.symaira.symtune-helper";

fn log(line: &str) {
    eprintln!("symaira cockpit helper: {line}");
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>()
        .as_slice()
    {
        ["--print-embedded-team"] => {
            return match embedded_team_identifier() {
                Some(team) => {
                    println!("{team}");
                    ExitCode::SUCCESS
                }
                None => {
                    println!();
                    ExitCode::FAILURE
                }
            };
        }
        ["--print-requirement", which, team] => {
            let requirement = match *which {
                "app" => app_requirement(team),
                "helper" => helper_requirement(team),
                _ => None,
            };
            return match requirement {
                Some(r) => {
                    println!("{r}");
                    ExitCode::SUCCESS
                }
                None => {
                    eprintln!("usage: --print-requirement <app|helper> <TEAMID>");
                    ExitCode::from(2)
                }
            };
        }
        [] => {}
        ["--data-dir", _] => {}
        _ => {
            eprintln!("usage: symcockpit-helper [--data-dir <path>]");
            return ExitCode::from(2);
        }
    }
    let data_dir = args
        .get(1)
        .map_or_else(|| PathBuf::from(DEFAULT_DATA_DIR), PathBuf::from);

    // Fail closed before touching the SMC: an unsigned or foreign build must
    // neither serve nor recover (a recovery writes the SMC as root).
    if let Err(reason) = connection_requirement(Role::HelperAcceptingClient) {
        log(&format!("refusing to serve: {reason}"));
        return ExitCode::FAILURE;
    }
    install_termination_handlers();
    let ports = LiveHelperPorts::open(Config::default());
    let engine = Engine::new(Box::new(ports), &data_dir, None, env!("CARGO_PKG_VERSION"));
    let service = Service::new(engine);
    service.recover_stale().iter().for_each(|l| log(l));

    // Fails closed: without a team embedded at build time and a matching
    // signature the helper refuses to serve at all.
    let _server = match serve(service.handler(), service.hooks()) {
        Ok(server) => server,
        Err(reason) => {
            log(&format!("refusing to serve: {reason}"));
            return ExitCode::FAILURE;
        }
    };
    match run(&service, &termination_requested, &system_clock(), &log) {
        Exit::Terminated => ExitCode::SUCCESS,
        Exit::Idle => {
            log("idle, exiting (launchd restarts it on demand)");
            ExitCode::SUCCESS
        }
    }
}
