//! What a native command runs against: the handler table the migrated areas
//! register into, the ports for platform facts, and the request/response
//! types shared by the CLI dispatcher and the MCP server.
//!
//! Wiring a command is one call, for any command of the register:
//!
//! ```ignore
//! app.handlers.register("sensors", |ctx, _req| {
//!     Ok(Output::Json(symcockpit_core::sensors::sensors_json(ctx.config)?))
//! });
//! ```
//!
//! A command without a handler answers `unsupported` (exit 4): nothing in this
//! binary hands work to the Swift core any more.

use std::collections::{BTreeMap, HashMap};
use std::path::Path;

use serde_json::{Map, Value};
use symcockpit_contract::Error;
use symcockpit_core::ai_usage::UsageRunner;
use symcockpit_core::system::HardwareFacts;
use symcockpit_store::{Config, Paths};

/// `processes` / `top` options, parsed like `ProcessListingPresentation`.
/// The handler samples twice, `interval` seconds apart, and clamps `limit`
/// to `1..=MAX_PROCESS_LIMIT` (`ProcessUsageService`).
#[derive(Clone, Debug, PartialEq)]
pub struct ProcessesParams {
    pub sort: ProcessSort,
    pub limit: i64,
    pub interval: f64,
}

pub const DEFAULT_PROCESS_LIMIT: i64 = 6;
pub const MAX_PROCESS_LIMIT: i64 = 50;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProcessSort {
    Cpu,
    Memory,
    Gpu,
}

impl ProcessSort {
    pub fn parse(text: &str) -> Option<Self> {
        match text.to_lowercase().as_str() {
            "cpu" => Some(Self::Cpu),
            "memory" => Some(Self::Memory),
            "gpu" => Some(Self::Gpu),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Cpu => "cpu",
            Self::Memory => "memory",
            Self::Gpu => "gpu",
        }
    }
}

impl Default for ProcessesParams {
    fn default() -> Self {
        Self {
            sort: ProcessSort::Cpu,
            limit: DEFAULT_PROCESS_LIMIT,
            interval: 1.0,
        }
    }
}

/// Where the arguments of an area command come from: the words after its CLI
/// path, or the JSON object of an MCP `tools/call`.
#[derive(Clone, Debug, PartialEq)]
pub enum AreaInput {
    Words(Vec<String>),
    Args(Map<String, Value>),
}

/// Command-specific parsed arguments.
#[derive(Clone, Debug, PartialEq)]
pub enum Params {
    None,
    Processes(ProcessesParams),
    History {
        limit: i64,
    },
    AiUsage {
        provider: Option<String>,
    },
    /// A command of one of the newer areas (`areas.rs`).
    Area(AreaInput),
    /// A privileged write (`fan set`, `battery-limit`, `restore`, ...).
    Write(symcockpit_core::write_commands::Command),
}

/// One read request, from the CLI or from an MCP `tools/call`.
#[derive(Clone, Debug, PartialEq)]
pub struct Request {
    /// Register name (`sensors`, `fan.status`, `awake.status`, ...).
    pub command: &'static str,
    /// `--json` was given. Always `true` for MCP and for the always-JSON
    /// commands; a handler returns `Output::Json` whenever it is set.
    pub json: bool,
    pub params: Params,
}

/// What a handler produces. `Json` is rendered like the Swift CLI (pretty) or
/// the Swift MCP server (compact); keys use snake_case.
pub enum Output {
    Json(Value),
    Text {
        stdout: String,
        stderr: String,
    },
    /// JSON with an exit code of its own: an action that ended `unconfirmed`,
    /// `failed` or `skipped_changed` still prints its report.
    Report {
        value: Value,
        code: u8,
    },
}

impl Output {
    pub fn text(stdout: impl Into<String>) -> Self {
        Output::Text {
            stdout: stdout.into(),
            stderr: String::new(),
        }
    }
}

/// Everything a handler may read. Owned by the dispatcher for one invocation.
pub struct Context<'a> {
    pub config: &'a Config,
    pub paths: &'a Paths,
    /// `--data-dir` or the XDG data directory.
    pub data_dir: &'a Path,
    /// The `--data-dir` value as typed.
    pub data_dir_override: Option<&'a Path>,
    pub env: &'a BTreeMap<String, String>,
    pub services: &'a Services,
}

pub type Handler = Box<dyn Fn(&Context, &Request) -> Result<Output, Error>>;

/// The nine read commands wave 1 wired through handlers (`doctor`,
/// `permissions`, `status`, `history`, `profile.list` and `ai-usage` are native
/// in this crate). Not a gate: any command of the register can get a handler.
pub const AREA_COMMANDS: [&str; 9] = [
    "sensors",
    "fan.status",
    "battery",
    "awake.status",
    "displays",
    "brightness.get",
    "metrics",
    "processes",
    "top",
];

/// The privileged write commands, wired in [`crate::write`] and absent from
/// test apps (which therefore answer `unsupported`).
pub const WRITE_COMMANDS: [&str; 6] = [
    "fan.set",
    "fan.auto",
    "fan.governor",
    "battery-limit.set",
    "battery-limit.clear",
    "restore",
];

#[derive(Default)]
pub struct Handlers(HashMap<&'static str, Handler>);

impl Handlers {
    /// Registers the native implementation of a command.
    ///
    /// # Panics
    /// On a name that is not in the register: a typo here is a programming
    /// error, not a runtime condition.
    pub fn register(
        &mut self,
        command: &'static str,
        handler: impl Fn(&Context, &Request) -> Result<Output, Error> + 'static,
    ) {
        assert!(
            symcockpit_contract::commands()
                .iter()
                .any(|c| c.name == command),
            "no handler slot for '{command}'"
        );
        self.0.insert(command, Box::new(handler));
    }

    pub fn get(&self, command: &str) -> Option<&Handler> {
        self.0.get(command)
    }

    pub fn contains(&self, command: &str) -> bool {
        self.0.contains_key(command)
    }
}

/// Live state `status` folds in beyond the sensor, battery and display reports.
pub trait OverridePort {
    /// `ActiveOverrides` as JSON; absent keys mean "not active".
    fn active_overrides(&self) -> Value;
    fn keep_awake_active(&self) -> bool;
}

/// The newest release of the shipped repository, for the update check of `version`.
pub trait ReleaseSource {
    fn latest(&self) -> symcockpit_core::update_check::Fetched;
}

/// The elevation-dependent half of fan control, absent from test apps. The
/// profile command writes the selection itself but asks this port whether the
/// chosen position can actually be enforced, and uses it to hand fans back
/// when `system` is selected over a stale override.
pub trait FanControl {
    /// The raw SMC state, read only: `Ftst` or any fan in manual mode.
    fn has_software_override(&self) -> bool;
    /// Return the fans to macOS through the available elevated path. The
    /// outcome is recorded in history by the implementation.
    fn restore_auto(&self, ctx: &Context) -> Result<(), Error>;
    /// `Err` with the reason when neither a helper nor a usable root-owned
    /// copy can change the fans on this Mac.
    fn check_elevation(&self, ctx: &Context) -> Result<(), Error>;
}

/// Ports to the platform. `hardware` and `overrides` stay `None` until the
/// areas that own them are wired; `doctor`, `permissions` and `status` answer
/// `unsupported` while they are missing.
pub struct Services {
    pub hardware: Option<Box<dyn HardwareFacts>>,
    pub overrides: Option<Box<dyn OverridePort>>,
    pub fan_control: Option<Box<dyn FanControl>>,
    pub usage_runner: Box<dyn UsageRunner>,
    /// Custom SymVault entry path per provider. shortcut: Swift reads these
    /// from `UserDefaults.standard`, which for the CLI is a domain named after
    /// the process that nothing writes, so the default is empty.
    pub vault_entry_paths: BTreeMap<String, String>,
    /// Unix seconds to `yyyy-MM-dd HH:mm:ss` in the user's time zone.
    pub local_time: Box<dyn Fn(f64) -> String>,
    /// `AIUsageEnabledProviders.loadPersisted()`: the providers the app has switched on.
    pub enabled_ai_providers: Box<dyn Fn() -> std::collections::BTreeSet<String>>,
    pub release_source: Box<dyn ReleaseSource>,
    /// Whether stdout is a terminal (`version` checks for updates only there, or on request).
    pub stdout_is_terminal: bool,
}

pub struct App {
    pub env: BTreeMap<String, String>,
    pub paths: Paths,
    pub handlers: Handlers,
    pub services: Services,
}
