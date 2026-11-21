//! Production wiring of the migrated read areas: the live SMC, battery,
//! display, metrics and process adapters behind the handler table, plus the
//! `doctor`/`permissions`/`status` ports ([`LiveHardware`], [`LiveOverrides`]).
//!
//! Everything here is read-only. Three rules shape it:
//! - the SMC is opened once per process, on first use, and shared
//!   ([`SharedSmc`]);
//! - the metrics and process services live as long as the process, because
//!   rates and CPU percentages need the previous measurement (in `serve` they
//!   survive across tool calls);
//! - display enumeration needs the main thread. The CLI and `serve` run every
//!   handler on it, and `LiveDisplays::new` refuses (an error, not a crash)
//!   anywhere else.

use std::cell::OnceCell;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use serde_json::{Map, Value, json};
use symcockpit_contract::Error;
use symcockpit_core::audio::AudioService;
use symcockpit_core::battery::{ChargeLimitProbe, battery_json, read_battery};
use symcockpit_core::bluetooth::{Advertisement, BleCentral, BleLink};
use symcockpit_core::display::{any_edr_capable, brightness_get_json, displays_json};
use symcockpit_core::metrics::{self, PowerReading, SystemMetricsService};
use symcockpit_core::midi::MidiService;
use symcockpit_core::plan::SystemClock;
use symcockpit_core::power::{awake_status_json, battery_system_load_milliwatts};
use symcockpit_core::processes::{
    ProcessSortKey, ProcessUsageService, processes_output, sample_twice,
};
use symcockpit_core::sensors::{
    PowerReport, RawKey, SmcPort, detect_charge_limit_key_family, fan_status_json,
    read_fan_max_rpm, read_fan_mode, read_fan_target_rpm, read_key_uint, read_system_power,
    sensors_json,
};
use symcockpit_core::system::{HardwareFacts, HostInfo, PrivilegedExecutable};
use symcockpit_db::{plans::SqlitePlanStore, smart_history::SmartHistoryStore};
use symcockpit_macos::apps::SystemApps;
use symcockpit_macos::battery::{LiveBatterySource, shared_apple_health};
use symcockpit_macos::bluetooth::{CoreBluetoothCentral, SystemProfiler};
use symcockpit_macos::coreaudio::{RealAudioHal, RealTapHal, install_signal_handlers, interrupted};
use symcockpit_macos::coremidi::RealMidiHal;
use symcockpit_macos::display::{DisplayServicesBrightness, LiveDisplays};
use symcockpit_macos::fs_stats::{LiveSpeedHost, StdSpaceFs};
use symcockpit_macos::host::live_metrics_service;
use symcockpit_macos::input::{AfplaySound, JsonFileSettings, LiveProbe, MultitouchHaptics};
use symcockpit_macos::nvme::IoKitNvme;
use symcockpit_macos::power::LiveKeepAwakeStatus;
use symcockpit_macos::process::LiveProcessControl;
use symcockpit_macos::process::live_process_service;
use symcockpit_macos::smc::{FileFanSelection, LiveHost, LiveSmc, PgrepGovernorProbe};
use symcockpit_macos::system;
use symcockpit_macos::trash::SystemRemover;

use crate::app::{App, Output, OverridePort, Params};
use crate::areas::{AudioKit, InputKit, Ports};
use crate::platform::{self, RunFailure};

/// The AppleSMC connection of this process, opened on the first read.
#[derive(Clone, Default)]
pub struct SharedSmc(Arc<OnceLock<LiveSmc>>);

impl SharedSmc {
    fn get(&self) -> &LiveSmc {
        self.0.get_or_init(LiveSmc::open)
    }
}

impl SmcPort for SharedSmc {
    fn is_open(&self) -> bool {
        self.get().is_open()
    }
    fn read_key_raw(&self, key: &str) -> Option<RawKey> {
        self.get().read_key_raw(key)
    }
    fn enumerate_keys(&self) -> Option<Vec<String>> {
        self.get().enumerate_keys()
    }
}

/// `ChargeLimitService.detectKeyFamily() != nil`.
pub struct SmcChargeLimit<S: SmcPort>(pub S);

impl<S: SmcPort> ChargeLimitProbe for SmcChargeLimit<S> {
    fn is_supported(&self) -> bool {
        detect_charge_limit_key_family(&self.0).is_some()
    }
}

/// The one system-power reading: SMC keys, the battery's `SystemLoad` as the
/// fallback for the total. `metrics`, `doctor` and any later consumer use it.
pub fn live_power(smc: &dyn SmcPort) -> Option<PowerReport> {
    read_system_power(smc, || battery_system_load_milliwatts(&LiveBatterySource))
}

struct SmcPower(SharedSmc);

impl PowerReading for SmcPower {
    fn read_power(&self) -> Option<PowerReport> {
        live_power(&self.0)
    }
}

/// `ActiveOverrides` of a read-only process. Display overrides, the dim
/// level, the warmth and a charge limit are bookkeeping of the process that
/// applied them (`OverrideTracker`, `ChargeLimitState`), so a fresh process
/// has none; only the fan fraction is read from the SMC, as v0.12 does.
pub struct LiveOverrides<S: SmcPort>(pub S);

impl<S: SmcPort> LiveOverrides<S> {
    /// `activeFanFraction`: the uniform target/max ratio while every fan is in manual mode.
    fn fan_fraction(&self) -> Option<f64> {
        let smc = &self.0;
        if !smc.is_open() {
            return None;
        }
        let count = read_key_uint(smc, "FNum").filter(|n| *n > 0)?;
        let mut sum = 0.0;
        for fan in 0..u8::try_from(count).ok()? {
            if read_fan_mode(smc, fan)? != 1 {
                return None;
            }
            let target = read_fan_target_rpm(smc, fan)?;
            let max = read_fan_max_rpm(smc, fan).filter(|m| *m > 0.0)?;
            sum += target / max;
        }
        Some(sum / count as f64)
    }
}

impl<S: SmcPort> OverridePort for LiveOverrides<S> {
    fn active_overrides(&self) -> Value {
        let mut overrides = Map::new();
        if let Some(fraction) = self.fan_fraction() {
            overrides.insert("fan_fraction".into(), json!(fraction));
        }
        Value::Object(overrides)
    }

    /// A read-only process holds no keep-awake session.
    fn keep_awake_active(&self) -> bool {
        false
    }
}

/// Facts for `doctor` and `permissions` (`TuneController.capabilities()`).
pub struct LiveHardware {
    pub smc: SharedSmc,
    pub env: BTreeMap<String, String>,
}

impl HardwareFacts for LiveHardware {
    fn battery_present(&self) -> bool {
        read_battery(&LiveBatterySource, &SmcChargeLimit(self.smc.clone()), None).present
    }
    /// Needs the main thread; off it the answer is "not capable" like Swift's failed lookup.
    fn edr_capable(&self) -> bool {
        LiveDisplays::new().is_ok_and(|displays| any_edr_capable(&displays))
    }
    fn smc_sensors_available(&self) -> bool {
        self.smc.is_open()
    }
    fn smc_connected(&self) -> bool {
        self.smc.is_open()
    }
    fn running_as_root(&self) -> bool {
        system::running_as_root()
    }
    fn charge_limit_key_present(&self) -> bool {
        detect_charge_limit_key_family(&self.smc).is_some()
    }
    fn privileged_executable(&self) -> PrivilegedExecutable {
        inspect_privileged(
            &platform::executable_candidates("symcockpit", &self.env),
            &|path| std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf()),
            &file_attributes,
            &|path| probe_version(path),
            &system::user_name,
            crate::VERSION,
        )
    }
    fn power_draw(&self) -> Option<PowerReport> {
        live_power(&self.smc)
    }
    fn host(&self) -> HostInfo {
        HostInfo {
            macos_version: system::operating_system_version(),
            architecture: system::ARCHITECTURE.to_owned(),
        }
    }
}

// ---------------------------------------------------------------- privileged copy

/// Owner and mode of one path (`BoundedProcessRunner.attributesOfPath`).
fn file_attributes(path: &str) -> Option<(u32, u32)> {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(path).ok().map(|m| (m.uid(), m.mode()))
}

const REFUSAL_TAIL: &str = "Anything that can write it could run as root behind the administrator prompt. Install it in a root-owned location such as /usr/local/bin.";

/// `validatePrivilegedPath`: the binary and every directory above it must be
/// owned by root and not writable by group or other. `Err` is the refusal text.
fn validate_privileged_path(
    path: &str,
    attributes: &dyn Fn(&str) -> Option<(u32, u32)>,
    owner_name: &dyn Fn(u32) -> String,
) -> Result<(), String> {
    let mut current = PathBuf::from(path);
    loop {
        let candidate = current.to_string_lossy().into_owned();
        let Some((uid, mode)) = attributes(&candidate) else {
            return Err(format!(
                "refusing to run {candidate} as an administrator: it is owned by an unknown user, not root. {REFUSAL_TAIL}"
            ));
        };
        if uid != 0 {
            return Err(format!(
                "refusing to run {candidate} as an administrator: it is owned by {}, not root. {REFUSAL_TAIL}",
                owner_name(uid)
            ));
        }
        if mode & 0o022 != 0 {
            return Err(format!(
                "refusing to run {candidate} as an administrator: it is writable by group or other ({:04o}). {REFUSAL_TAIL}",
                mode & 0o777
            ));
        }
        match current.parent() {
            Some(parent) if candidate != "/" => current = parent.to_path_buf(),
            _ => return Ok(()),
        }
    }
}

/// `PrivilegedElevation.inspectPrivilegedExecutable`: the state of the
/// root-owned `symcockpit` the GUI elevates. Never elevates, never writes.
pub fn inspect_privileged(
    candidates: &[PathBuf],
    canonicalize: &dyn Fn(&Path) -> PathBuf,
    attributes: &dyn Fn(&str) -> Option<(u32, u32)>,
    probe: &dyn Fn(&str) -> Result<String, String>,
    owner_name: &dyn Fn(u32) -> String,
    expected: &str,
) -> PrivilegedExecutable {
    let refresh = |path: &str| {
        format!("sudo install -m 755 -o root -g wheel \"$(brew --prefix)/bin/symcockpit\" {path}")
    };
    let result = |usable: bool, state: &str, detail: String| PrivilegedExecutable {
        usable,
        state: state.to_owned(),
        detail,
    };
    if candidates.is_empty() {
        return result(
            false,
            "not_installed",
            format!(
                "No root-owned symcockpit found; the administrator-prompt fan path is unavailable. Install one with `{}`, or enable the optional fan helper.",
                refresh("/usr/local/bin/symcockpit")
            ),
        );
    }
    let mut first_refusal = None;
    let mut trusted = None;
    for candidate in candidates {
        let canonical = canonicalize(candidate).to_string_lossy().into_owned();
        match validate_privileged_path(&canonical, attributes, owner_name) {
            Ok(()) => {
                trusted = Some(canonical);
                break;
            }
            Err(refusal) => {
                first_refusal.get_or_insert(refusal);
            }
        }
    }
    let Some(path) = trusted else {
        return result(false, "untrusted", first_refusal.unwrap_or_default());
    };
    match probe(&path) {
        Err(reason) => result(
            false,
            "unverifiable",
            format!(
                "Root-owned copy {path}: version could not be verified ({reason}); it will not be elevated."
            ),
        ),
        Ok(found) if found == expected => result(
            true,
            "matching",
            format!("Root-owned copy {path} is {found}, matching this release ({expected})."),
        ),
        Ok(found) => result(
            false,
            "stale",
            format!(
                "Root-owned copy {path} is {found}, but this release is {expected}; GUI fan control refuses it. Refresh it with `{}`, or enable the optional fan helper.",
                refresh(&path)
            ),
        ),
    }
}

const VERSION_PROBE_TIMEOUT: Duration = Duration::from_secs(5);

/// `probeVersion`: asks the trusted copy for its version without elevation,
/// with the update check off and a scrubbed environment.
fn probe_version(path: &str) -> Result<String, String> {
    let env = BTreeMap::from([
        ("PATH".to_owned(), "/usr/bin:/bin".to_owned()),
        ("HOME".to_owned(), std::env::var("HOME").unwrap_or_default()),
        ("SYMCOCKPIT_CHECK_UPDATES".to_owned(), "0".to_owned()),
    ]);
    let args = ["version", "--json", "--no-update-check"].map(str::to_owned);
    let output = platform::run_bounded(path.as_ref(), &args, &env, VERSION_PROBE_TIMEOUT).map_err(
        |failure| match failure {
            RunFailure::Launch(message) => format!("could not run `version --json`: {message}"),
            RunFailure::TimedOut => format!(
                "`version --json` did not answer within {} s",
                VERSION_PROBE_TIMEOUT.as_secs()
            ),
        },
    )?;
    if output.status != 0 {
        return Err(format!(
            "`version --json` exited with status {}",
            output.status
        ));
    }
    serde_json::from_slice::<Value>(&output.stdout)
        .ok()
        .and_then(|v| v.get("version")?.as_str().map(|s| s.trim().to_owned()))
        .filter(|v| !v.is_empty())
        .ok_or_else(|| "`version --json` did not print a version".to_owned())
}

// ---------------------------------------------------------------- wiring

fn json_output(value: Result<Value, Error>) -> Result<Output, Error> {
    value.map(Output::Json)
}

/// A core text result as the dispatcher's: one newline-terminated line per entry.
fn dispatcher_output(output: metrics::Output) -> Output {
    let lines = |lines: Vec<String>| lines.into_iter().map(|l| l + "\n").collect::<String>();
    match output {
        metrics::Output::Json(value) => Output::Json(value),
        metrics::Output::Text { stdout, stderr } => Output::Text {
            stdout: lines(stdout),
            stderr: lines(stderr),
        },
    }
}

/// A BLE central one process shares: CoreBluetooth is started on first use
/// and kept, so a long-lived `serve` does not start one per tool call.
struct SharedCentral(Rc<dyn BleCentral>);

impl BleCentral for SharedCentral {
    fn scan(&self, timeout: Duration) -> Result<Vec<Advertisement>, Error> {
        self.0.scan(timeout)
    }

    fn connect(&self, id: &str, timeout: Duration) -> Result<Box<dyn BleLink>, Error> {
        self.0.connect(id, timeout)
    }
}

fn audio_kit() -> Result<AudioKit, Error> {
    let service = Arc::new(AudioService::new(Arc::new(RealAudioHal::new())));
    let midi = Arc::new(MidiService::new(Arc::new(RealMidiHal::new()?)));
    Ok(AudioKit {
        service,
        midi,
        tap: Some(Arc::new(RealTapHal::new())),
        // Only a foreground mixer takes over SIGINT/SIGTERM; `serve` must keep
        // dying on them.
        before_foreground: Rc::new(install_signal_handlers),
        stop: Rc::new(interrupted),
    })
}

/// The ports of the newer areas on this Mac. Nothing is opened here.
pub fn ports() -> Ports {
    let audio: Rc<OnceCell<Result<AudioKit, Error>>> = Rc::default();
    let central: Rc<OnceCell<Result<Rc<dyn BleCentral>, Error>>> = Rc::default();
    Ports {
        clock: Rc::new(SystemClock),
        nvme: Rc::new(IoKitNvme),
        history: Box::new(|path| Ok(Box::new(SmartHistoryStore::open(path)?))),
        plans: Box::new(|path| Ok(Box::new(SqlitePlanStore::open(path)?))),
        speed: Rc::new(LiveSpeedHost::default()),
        space: Rc::new(StdSpaceFs),
        remover: Rc::new(SystemRemover),
        apps: Box::new(|home| Box::new(SystemApps::new(home))),
        processes: Rc::new(LiveProcessControl),
        sleep: Box::new(std::thread::sleep),
        audio: Box::new(move || audio.get_or_init(audio_kit).clone()),
        paired: Rc::new(SystemProfiler),
        central: Box::new(move || {
            central
                .get_or_init(|| {
                    CoreBluetoothCentral::new().map(|c| Rc::new(c) as Rc<dyn BleCentral>)
                })
                .clone()
                .map(|c| Box::new(SharedCentral(c)) as Box<dyn BleCentral>)
        }),
        input: InputKit {
            settings: Box::new(|path| Box::new(JsonFileSettings::new(path))),
            probe: Rc::new(LiveProbe),
            haptic: Rc::new(MultitouchHaptics),
            sound: Rc::new(AfplaySound::default()),
        },
    }
}

/// Registers the area handlers and fills `hardware` and `overrides`.
pub fn wire(app: &mut App) {
    crate::areas::register(&mut app.handlers, Rc::new(ports()));
    let smc = SharedSmc::default();
    let metrics_service: Rc<OnceCell<SystemMetricsService>> = Rc::default();
    let process_service: Rc<OnceCell<ProcessUsageService>> = Rc::default();

    let handlers = &mut app.handlers;
    let s = smc.clone();
    handlers.register("sensors", move |_, _| {
        json_output(sensors_json(&s, &LiveHost))
    });
    let s = smc.clone();
    handlers.register("fan.status", move |_, _| {
        json_output(fan_status_json(
            &FileFanSelection::default_location(),
            &PgrepGovernorProbe,
            &s,
            &LiveHost,
        ))
    });
    let s = smc.clone();
    handlers.register("battery", move |_, _| {
        json_output(battery_json(
            &LiveBatterySource,
            &SmcChargeLimit(s.clone()),
            Some(shared_apple_health()),
        ))
    });
    handlers.register("awake.status", |_, _| {
        json_output(awake_status_json(&LiveKeepAwakeStatus))
    });
    handlers.register("displays", |_, _| {
        json_output(displays_json(&LiveDisplays::new()?))
    });
    handlers.register("brightness.get", |_, _| {
        json_output(brightness_get_json(
            &LiveDisplays::new()?,
            &DisplayServicesBrightness::new(),
        ))
    });
    let (s, service) = (smc.clone(), Rc::clone(&metrics_service));
    handlers.register("metrics", move |_, _| {
        let service = service.get_or_init(|| live_metrics_service(Box::new(SmcPower(s.clone()))));
        json_output(metrics::metrics_json(service))
    });
    for command in ["processes", "top"] {
        let service = Rc::clone(&process_service);
        handlers.register(command, move |_, req| {
            let Params::Processes(p) = &req.params else {
                return Err(Error::Failed(format!("{}: missing options", req.command)));
            };
            let service = service.get_or_init(live_process_service);
            let sort = ProcessSortKey::parse(p.sort.as_str()).unwrap_or(ProcessSortKey::Cpu);
            let report = sample_twice(
                service,
                sort,
                p.limit,
                Duration::from_secs_f64(p.interval),
                &std::thread::sleep,
            );
            processes_output(&report, req.json).map(dispatcher_output)
        });
    }

    app.services.hardware = Some(Box::new(LiveHardware {
        smc: smc.clone(),
        env: app.env.clone(),
    }));
    app.services.overrides = Some(Box::new(LiveOverrides(smc)));
}

#[cfg(test)]
mod tests {
    use symcockpit_testkit::smc::FakeSmc;

    use super::*;

    fn fan_smc(modes: &[(u8, f32, f32)]) -> FakeSmc {
        let smc = FakeSmc::new(true).with_ui8("FNum", modes.len() as u8);
        modes
            .iter()
            .enumerate()
            .fold(smc, |smc, (i, (mode, target, max))| {
                smc.with_ui8(&format!("F{i}Md"), *mode)
                    .with_flt(&format!("F{i}Tg"), *target)
                    .with_flt(&format!("F{i}Mx"), *max)
            })
    }

    #[test]
    fn display_enumeration_refuses_off_the_main_thread_instead_of_crashing() {
        // The test harness never runs on the main thread.
        assert!(LiveDisplays::new().is_err());
        let hardware = LiveHardware {
            smc: SharedSmc::default(),
            env: BTreeMap::new(),
        };
        assert!(!hardware.edr_capable());
    }

    #[test]
    fn fan_fraction_needs_every_fan_in_manual_mode() {
        let manual = LiveOverrides(fan_smc(&[(1, 2000.0, 4000.0), (1, 3000.0, 4000.0)]));
        assert_eq!(
            manual.active_overrides(),
            json!({"fan_fraction": 0.625}),
            "mean of 0.5 and 0.75"
        );
        let mixed = LiveOverrides(fan_smc(&[(1, 2000.0, 4000.0), (3, 0.0, 4000.0)]));
        assert_eq!(mixed.active_overrides(), json!({}));
        assert_eq!(
            LiveOverrides(FakeSmc::closed()).active_overrides(),
            json!({})
        );
        assert_eq!(LiveOverrides(fan_smc(&[])).active_overrides(), json!({}));
        assert!(!manual.keep_awake_active());
    }

    fn attributes<'a>(
        table: &'a [(&'a str, u32, u32)],
    ) -> impl Fn(&str) -> Option<(u32, u32)> + 'a {
        move |path| {
            table
                .iter()
                .find(|(p, ..)| *p == path)
                .map(|(_, uid, mode)| (*uid, *mode))
        }
    }

    const ROOT_TREE: [(&str, u32, u32); 3] = [
        ("/usr/local/bin/symcockpit", 0, 0o100755),
        ("/usr/local/bin", 0, 0o040755),
        ("/usr/local", 0, 0o040755),
    ];

    fn inspect(
        candidates: &[&str],
        table: &[(&str, u32, u32)],
        probe: Result<&str, &str>,
    ) -> PrivilegedExecutable {
        let candidates: Vec<PathBuf> = candidates.iter().map(PathBuf::from).collect();
        inspect_privileged(
            &candidates,
            &|path| path.to_path_buf(),
            &attributes(table),
            &|_| probe.map(str::to_owned).map_err(str::to_owned),
            &|uid| format!("user{uid}"),
            "0.12.2",
        )
    }

    #[test]
    fn privileged_copy_states_follow_the_swift_inspection() {
        let none = inspect(&[], &[], Ok("0.12.2"));
        assert_eq!((none.usable, none.state.as_str()), (false, "not_installed"));
        assert!(none.detail.starts_with("No root-owned symcockpit found;"));

        let tree = [
            ("/usr/local/bin/symcockpit", 0, 0o100755),
            ("/usr/local/bin", 0, 0o040755),
            ("/usr/local", 0, 0o040755),
            ("/usr", 0, 0o040755),
            ("/", 0, 0o040755),
        ];
        let ok = inspect(&["/usr/local/bin/symcockpit"], &tree, Ok("0.12.2"));
        assert_eq!((ok.usable, ok.state.as_str()), (true, "matching"));
        assert_eq!(
            ok.detail,
            "Root-owned copy /usr/local/bin/symcockpit is 0.12.2, matching this release (0.12.2)."
        );

        let stale = inspect(&["/usr/local/bin/symcockpit"], &tree, Ok("0.11.0"));
        assert_eq!((stale.usable, stale.state.as_str()), (false, "stale"));
        assert!(
            stale
                .detail
                .contains("but this release is 0.12.2; GUI fan control refuses it.")
        );

        let unverifiable = inspect(
            &["/usr/local/bin/symcockpit"],
            &tree,
            Err("`version --json` exited with status 1"),
        );
        assert_eq!(unverifiable.state, "unverifiable");
        assert_eq!(
            unverifiable.detail,
            "Root-owned copy /usr/local/bin/symcockpit: version could not be verified (`version --json` exited with status 1); it will not be elevated."
        );
    }

    #[test]
    fn a_user_writable_or_user_owned_path_is_untrusted() {
        let mut tree = ROOT_TREE.to_vec();
        tree.push(("/usr", 0, 0o040755));
        tree.push(("/", 0, 0o040755));
        tree[1].2 = 0o040775;
        let writable = inspect(&["/usr/local/bin/symcockpit"], &tree, Ok("0.12.2"));
        assert_eq!(
            (writable.usable, writable.state.as_str()),
            (false, "untrusted")
        );
        assert!(writable.detail.contains(
            "/usr/local/bin as an administrator: it is writable by group or other (0775)."
        ));

        let owned = inspect(
            &["/opt/homebrew/bin/symcockpit", "/usr/local/bin/symcockpit"],
            &[("/opt/homebrew/bin/symcockpit", 501, 0o100755)],
            Ok("0.12.2"),
        );
        assert_eq!(owned.state, "untrusted");
        assert!(
            owned.detail.contains("it is owned by user501, not root."),
            "{}",
            owned.detail
        );

        // The first refusal is reported, but a later trustworthy candidate wins.
        let mut both = tree.clone();
        both[1].2 = 0o040755;
        both.extend([("/opt/homebrew/bin/symcockpit", 501, 0o100755)]);
        let won = inspect(
            &["/opt/homebrew/bin/symcockpit", "/usr/local/bin/symcockpit"],
            &both,
            Ok("0.12.2"),
        );
        assert_eq!(won.state, "matching");
    }
}
