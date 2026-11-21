//! The newer areas end to end through the dispatcher and the MCP server, on
//! fakes: no hardware, no real user files (a temporary home), the real
//! `cockpit.sqlite` in that home. Nothing here signals a process the test did
//! not start, and nothing opens the Trash: the remover is a fake.

mod common;

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use common::{app, args};
use serde_json::{Value, json};
use symcockpit::app::{App, Context};
use symcockpit::areas::{AudioKit, InputKit, Ports, register};
use symcockpit::cli::{Action, Outcome, plan_with};
use symcockpit::mcp::Server;
use symcockpit_contract::Error;
use symcockpit_core::audio::{AudioService, Readback};
use symcockpit_core::bluetooth::{Advertisement, BleCentral, BleLink, Characteristic, Service};
use symcockpit_core::input::{Access, HapticLevel};
use symcockpit_core::midi::MidiService;
use symcockpit_core::plan::SystemClock;
use symcockpit_core::storage::health::Location;
use symcockpit_db::{plans::SqlitePlanStore, smart_history::SmartHistoryStore};
use symcockpit_store::Config;
use symcockpit_testkit::audio::{FakeAudioHal, FakeTapHal, input_device, output_device};
use symcockpit_testkit::bluetooth::{FakeCentral, FakeDevice, FakePaired, WriteBehavior};
use symcockpit_testkit::input::{FakeHaptic, FakeProbe, FakeSound, MemorySettings};
use symcockpit_testkit::kill::{FakeProcesses, identity};
use symcockpit_testkit::midi::sample_hal;
use symcockpit_testkit::storage_clean::{FakeApps, FakeRemover};
use symcockpit_testkit::storage_health::{
    FakeNvme, FakeSpeedHost, FakeTree, nvme_device, smart_page,
};

const SVC: &str = "180F";
const CHR: &str = "2A19";

/// Delegates to the shared fake so the test keeps its handle on it.
struct SharedCentral(Rc<FakeCentral>);

impl BleCentral for SharedCentral {
    fn scan(&self, timeout: Duration) -> Result<Vec<Advertisement>, Error> {
        self.0.scan(timeout)
    }

    fn connect(&self, id: &str, timeout: Duration) -> Result<Box<dyn BleLink>, Error> {
        self.0.connect(id, timeout)
    }
}

struct World {
    tmp: tempfile::TempDir,
    app: App,
    processes: Rc<FakeProcesses>,
    remover: Rc<FakeRemover>,
    hal: Arc<FakeAudioHal>,
    central: Rc<FakeCentral>,
    settings: Rc<MemorySettings>,
    sleeps: Rc<RefCell<u32>>,
}

impl World {
    fn home(&self) -> &Path {
        self.tmp.path()
    }

    fn db(&self) -> PathBuf {
        self.app.paths.data_dir.join("cockpit.sqlite")
    }

    fn cli(&self, words: &[&str]) -> Outcome {
        self.cli_with(words, None)
    }

    fn cli_with(&self, words: &[&str], prompt: Option<&dyn Fn(&str) -> bool>) -> Outcome {
        match plan_with(&self.app, &args(words), prompt) {
            Action::Done(outcome) => outcome,
            Action::Forward => panic!("{words:?} was forwarded to the Swift core"),
            Action::Serve { .. } => panic!("{words:?} started the server"),
        }
    }

    fn json(&self, words: &[&str]) -> Value {
        let out = self.cli(words);
        assert_eq!(out.code, 0, "{words:?}: {}", out.stderr);
        serde_json::from_str(&out.stdout)
            .unwrap_or_else(|e| panic!("{words:?}: {e}: {}", out.stdout))
    }

    fn mcp_mode(&self, mode: &str, request: Value) -> Value {
        let config = Config {
            mcp_mode: mode.into(),
            ..Config::default()
        };
        let data = self.app.paths.data_dir.clone();
        let ctx = Context {
            config: &config,
            paths: &self.app.paths,
            data_dir: &data,
            data_dir_override: None,
            env: &self.app.env,
            services: &self.app.services,
        };
        Server::new(&self.app, &ctx)
            .handle_line(&request.to_string())
            .expect("a response")
    }

    fn call(&self, tool: &str, arguments: Value) -> Value {
        self.mcp_mode(
            "full",
            json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": arguments}}),
        )
    }

    /// The JSON a tool answered with.
    fn tool(&self, tool: &str, arguments: Value) -> Value {
        let response = self.call(tool, arguments);
        let text = response["result"]["content"][0]["text"]
            .as_str()
            .unwrap_or_else(|| panic!("{tool}: {response}"));
        serde_json::from_str(text).unwrap()
    }
}

fn world() -> World {
    let tmp = tempfile::tempdir().unwrap();
    let mut app = app(tmp.path());
    let home = tmp.path().to_path_buf();
    std::fs::create_dir_all(home.join("trash")).unwrap();

    let processes = Rc::new(FakeProcesses::new(identity(321, "Hog", 77)));
    let remover = Rc::new(FakeRemover::new(&home, &home.join("trash")));
    let hal = Arc::new(FakeAudioHal::new(vec![
        output_device("speakers"),
        output_device("monitor"),
        input_device("mic"),
    ]));
    hal.set_defaults(Some("mic"), Some("speakers"));
    let service = Arc::new(AudioService::new(hal.clone()).with_readback(Readback {
        attempts: 3,
        delay: Duration::ZERO,
    }));
    let kit = AudioKit {
        service,
        midi: Arc::new(MidiService::new(Arc::new(sample_hal()))),
        tap: Some(Arc::new(FakeTapHal::new())),
        before_foreground: Rc::new(|| {}),
        stop: Rc::new(|| true),
    };
    let device = FakeDevice {
        services: vec![Service {
            uuid: SVC.into(),
            characteristics: vec![Characteristic {
                uuid: CHR.into(),
                properties: vec!["read".into(), "write".into()],
            }],
        }],
        values: [((SVC.to_owned(), CHR.to_owned()), vec![0x01])].into(),
        write: WriteBehavior::Accept,
        notifications: vec![],
    };
    let central = Rc::new(FakeCentral::new(
        vec![Advertisement {
            id: "id-a".into(),
            name: Some("Sensor".into()),
            rssi: Some(-60),
            service_uuids: vec![SVC.into()],
            connectable: Some(true),
        }],
        device,
    ));
    let settings = Rc::new(MemorySettings::default());
    let sleeps = Rc::new(RefCell::new(0));
    let (central_handle, settings_handle, sleep_count) =
        (central.clone(), settings.clone(), sleeps.clone());
    let nvme = FakeNvme(Ok(vec![nvme_device(
        Location::Internal,
        "Fake SSD",
        Ok(smart_page(|_| {})),
    )]));
    let ports = Ports {
        clock: Rc::new(SystemClock),
        nvme: Rc::new(nvme),
        history: Box::new(|p| Ok(Box::new(SmartHistoryStore::open(p)?))),
        plans: Box::new(|p| Ok(Box::new(SqlitePlanStore::open(p)?))),
        speed: Rc::new(FakeSpeedHost::new(10 << 30, 1 << 30)),
        space: Rc::new(FakeTree::new()),
        remover: remover.clone(),
        apps: Box::new(|_| Box::new(FakeApps::default())),
        processes: processes.clone(),
        sleep: Box::new(move |_| *sleep_count.borrow_mut() += 1),
        audio: Box::new(move || Ok(kit.clone())),
        paired: Rc::new(FakePaired(vec![])),
        central: Box::new(move || Ok(Box::new(SharedCentral(central_handle.clone())))),
        input: InputKit {
            settings: Box::new(move |_| {
                struct Shared(Rc<MemorySettings>);
                impl symcockpit_core::input::SettingsStore for Shared {
                    fn load(&self) -> Result<symcockpit_core::input::InputSettings, Error> {
                        self.0.load()
                    }
                    fn save(&self, s: &symcockpit_core::input::InputSettings) -> Result<(), Error> {
                        self.0.save(s)
                    }
                }
                Box::new(Shared(settings_handle.clone()))
            }),
            probe: Rc::new(FakeProbe {
                access: Access::Granted,
                secure: false,
            }),
            haptic: Rc::new(FakeHaptic::new(HapticLevel::Available)),
            sound: Rc::new(FakeSound::default()),
        },
    };
    register(&mut app.handlers, Rc::new(ports));
    World {
        tmp,
        app,
        processes,
        remover,
        hal,
        central,
        settings,
        sleeps,
    }
}

// ----------------------------------------------------------------- storage

#[test]
fn health_is_recorded_by_the_cli_and_never_by_mcp() {
    let w = world();
    let history = |w: &World| {
        w.json(&["storage", "health", "history", "--json"])["samples"]
            .as_array()
            .unwrap()
            .len()
    };
    assert_eq!(history(&w), 0);
    let out = w.cli(&["storage", "health", "--json"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(history(&w), 1, "the CLI records by default");
    let health = w.tool("get_storage_health", json!({}));
    assert_eq!(health["devices"][0]["model"], "Fake SSD");
    assert_eq!(history(&w), 1, "MCP stays read-only");
    assert!(w.db().is_file(), "one SQLite file holds the history");
    // The same file serves the plans below.
    let tools = w.tool("get_storage_health_history", json!({"limit": 5}));
    assert_eq!(tools["samples"].as_array().unwrap().len(), 1);
}

#[test]
fn text_and_json_forms_of_space_and_speedtest() {
    let w = world();
    let text = w.cli(&["storage", "space", "/root"]);
    assert_eq!(text.code, 0, "{}", text.stderr);
    assert!(text.stdout.contains("/root"), "{}", text.stdout);
    assert_eq!(
        w.json(&["storage", "space", "/root", "--json"])["schema"],
        1
    );
    let speed = w.json(&["storage", "speedtest", "--size", "8", "--json"]);
    assert_eq!(speed["size_mib"], 8);
    // Agents may not escape the home directory or /Volumes (limits of the MCP form).
    let refused = w.call("run_speedtest", json!({"path": "/etc", "size_mib": 1}));
    assert_eq!(refused["error"]["code"], -32603, "{refused}");
}

#[test]
fn bad_arguments_are_usage_errors_with_exit_2_and_mcp_validates_the_schema() {
    let w = world();
    for words in [
        &["storage", "health", "--nope"][..],
        &["storage", "space"],
        &["audio", "volume", "set", "u"],
        &["ble", "write", "id-a"],
        &["processes", "kill", "abc"],
    ] {
        let out = w.cli(words);
        assert_eq!(out.code, 2, "{words:?}: {}", out.stderr);
        assert!(out.stdout.is_empty(), "{words:?}");
    }
    let bad = w.call("plan_kill_process", json!({"pid": "x"}));
    assert_eq!(bad["error"]["code"], -32603);
    let missing = w.call("get_audio_device", json!({}));
    assert!(
        missing["error"]["message"]
            .as_str()
            .unwrap()
            .contains("uid")
    );
    let range = w.call("set_audio_volume", json!({"uid": "speakers", "value": 7}));
    assert!(
        range["error"]["message"]
            .as_str()
            .unwrap()
            .contains("range")
    );
}

#[test]
fn cleanup_goes_through_a_plan_and_the_fake_trash() {
    let w = world();
    let cache = w.home().join("Library/Caches/com.example.app");
    std::fs::create_dir_all(&cache).unwrap();
    std::fs::write(cache.join("blob"), vec![7u8; 4096]).unwrap();
    let planned = w.cli(&["storage", "clean", "--json"]);
    assert_eq!(planned.code, 0, "{}", planned.stderr);
    let plan: Value = serde_json::from_str(&planned.stdout).unwrap();
    let id = plan["id"].as_str().unwrap().to_owned();
    assert_eq!(plan["item_count"], 1, "{plan}");
    assert!(
        planned.stderr.contains(&format!("plan confirm {id}")),
        "{}",
        planned.stderr
    );
    assert!(cache.exists(), "planning deletes nothing");
    assert!(w.remover.calls().is_empty());

    let shown = w.json(&["plan", "show", &id]);
    assert_eq!(shown["state"], "pending");
    // A plan of another kind cannot be confirmed through this command.
    let wrong = w.cli(&["processes", "kill", "--confirm", &id]);
    assert_eq!(wrong.code, 2, "{}", wrong.stderr);
    assert!(
        wrong.stderr.contains("not 'kill_process'"),
        "{}",
        wrong.stderr
    );
    assert!(cache.exists());

    let done = w.cli(&["plan", "confirm", &id]);
    assert_eq!(done.code, 0, "{}", done.stderr);
    let report: Value = serde_json::from_str(&done.stdout).unwrap();
    assert_eq!(report["status"], "confirmed", "{report}");
    assert!(!cache.exists(), "the fake Trash took it");
    assert_eq!(w.remover.calls().len(), 1);
    // Once only.
    let again = w.cli(&["plan", "confirm", &id]);
    assert_eq!(again.code, 2);
    assert!(again.stderr.contains("already confirmed"));
    assert_eq!(w.json(&["plan", "show", &id])["state"], "confirmed");
}

// ----------------------------------------------------------------- the plan flow

#[test]
fn a_risky_command_prints_a_plan_and_runs_only_on_its_id_never_on_yes() {
    let w = world();
    let planned = w.cli(&["processes", "kill", "321", "--json"]);
    assert_eq!(planned.code, 0, "{}", planned.stderr);
    let plan: Value = serde_json::from_str(&planned.stdout).unwrap();
    assert_eq!(plan["kind"], "kill_process");
    assert_eq!(plan["items"][0]["target"], "Hog (pid 321)");
    assert_eq!(w.processes.terminated.get(), 0);

    for flag in ["--yes", "-y"] {
        let out = w.cli(&["processes", "kill", "321", flag]);
        assert_eq!(out.code, 2, "{flag}");
        assert!(out.stderr.contains("no --yes"), "{}", out.stderr);
    }
    assert_eq!(w.processes.terminated.get(), 0);

    let id = plan["id"].as_str().unwrap();
    let ran = w.cli(&["processes", "kill", "--confirm", id]);
    assert_eq!(ran.code, 0, "{}", ran.stderr);
    let report: Value = serde_json::from_str(&ran.stdout).unwrap();
    assert_eq!(report["status"], "confirmed");
    assert_eq!(report["results"][0]["outcome"], "confirmed");
    assert_eq!(w.processes.terminated.get(), 1);
}

#[test]
fn at_a_terminal_the_human_is_asked_and_a_no_changes_nothing() {
    let w = world();
    let asked = RefCell::new(Vec::new());
    let no = |summary: &str| {
        asked.borrow_mut().push(summary.to_owned());
        false
    };
    let declined = w.cli_with(&["processes", "kill", "321"], Some(&no));
    assert_eq!(declined.code, 1, "{}", declined.stderr);
    assert!(
        declined.stderr.contains("plan confirm"),
        "{}",
        declined.stderr
    );
    assert_eq!(w.processes.terminated.get(), 0);
    assert!(asked.borrow()[0].contains("Hog (pid 321)"), "{:?}", asked);

    let yes = |_: &str| true;
    let accepted = w.cli_with(&["processes", "kill", "321"], Some(&yes));
    assert_eq!(accepted.code, 0, "{}", accepted.stderr);
    assert_eq!(w.processes.terminated.get(), 1);
}

#[test]
fn a_process_that_does_not_leave_exits_1_with_the_report() {
    let w = world();
    w.processes.leaves_after.set(None);
    let plan = w.json(&["processes", "kill", "321", "--json"]);
    let out = w.cli(&["plan", "confirm", plan["id"].as_str().unwrap()]);
    assert_eq!(out.code, 1, "{}", out.stderr);
    let report: Value = serde_json::from_str(&out.stdout).unwrap();
    assert_eq!(report["status"], "unconfirmed");
    assert!(*w.sleeps.borrow() > 0, "the post-check waited");
}

#[test]
fn mcp_gets_plans_and_confirm_plan_but_no_direct_kill() {
    let w = world();
    let plan = w.tool("plan_kill_process", json!({"pid": 321}));
    assert_eq!(w.processes.terminated.get(), 0);
    let id = plan["id"].as_str().unwrap().to_owned();
    assert_eq!(
        w.tool("get_plan", json!({"plan_id": id}))["state"],
        "pending"
    );
    let report = w.tool("confirm_plan", json!({"plan_id": id}));
    assert_eq!(report["status"], "confirmed", "{report}");
    assert_eq!(w.processes.terminated.get(), 1);
    for direct in [
        "kill_process",
        "kill",
        "set_audio_format",
        "delete_duplicates",
    ] {
        assert_eq!(
            w.call(direct, json!({}))["error"]["code"],
            -32603,
            "{direct}"
        );
    }
    // Planning refuses what must not be ended, with the usual exit class.
    let own = w.call("plan_kill_process", json!({"pid": 4242}));
    assert!(own["error"]["message"].as_str().unwrap().contains("itself"));
}

#[test]
fn read_only_mode_hides_plans_and_actions() {
    let w = world();
    let list = w.mcp_mode(
        "read-only",
        json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}),
    );
    let names: Vec<&str> = list["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    for hidden in [
        "plan_kill_process",
        "confirm_plan",
        "set_audio_volume",
        "run_speedtest",
    ] {
        assert!(!names.contains(&hidden), "{hidden}");
    }
    assert!(names.contains(&"get_plan") && names.contains(&"scan_ble"));
}

// ----------------------------------------------------------------- audio, MIDI

#[test]
fn audio_reads_and_reversible_writes_act_directly_in_the_cli_and_over_mcp() {
    let w = world();
    let devices = w.json(&["audio", "devices", "--json"]);
    assert_eq!(devices["devices"].as_array().unwrap().len(), 3);
    assert!(w.cli(&["audio", "devices"]).stdout.contains("speakers"));
    assert_eq!(
        w.json(&["midi", "devices", "--json"])["devices"][0]["present"],
        true
    );

    let set = w.json(&["audio", "volume", "set", "speakers", "0.4", "--json"]);
    assert_eq!(set["outcome"], "confirmed", "{set}");
    let via_mcp = w.tool("set_audio_volume", json!({"uid": "speakers", "value": 0.6}));
    assert_eq!(via_mcp["outcome"], "confirmed");
    assert_eq!(
        w.tool("get_audio_device", json!({"uid": "speakers"}))["output"]["volume"]
            .as_f64()
            .map(|v| (v * 10.0).round()),
        Some(6.0)
    );
    let unknown = w.cli(&["audio", "device", "nope"]);
    assert_eq!(unknown.code, 2, "{}", unknown.stderr);
    // No mixer runs in a one-shot process.
    let app = w.cli(&["audio", "mixer", "set", "123", "0.5"]);
    assert_eq!(app.code, 4, "{}", app.stderr);
    assert_eq!(
        w.call("set_audio_app_volume", json!({"app": "123", "volume": 0.5}))["error"]["code"],
        -32603
    );
}

#[test]
fn audio_format_changes_are_plans_in_the_cli_and_over_mcp() {
    let w = world();
    let before = w.hal.device("speakers").unwrap().sample_rate;
    let plan = w.json(&[
        "audio", "format", "set", "speakers", "--rate", "48000", "--json",
    ]);
    assert_eq!(plan["kind"], "audio.format.set");
    assert_eq!(w.hal.device("speakers").unwrap().sample_rate, before);
    let out = w.cli(&[
        "audio",
        "format",
        "set",
        "--confirm",
        plan["id"].as_str().unwrap(),
    ]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(w.hal.device("speakers").unwrap().sample_rate, Some(48000.0));

    let plan = w.tool(
        "plan_audio_format",
        json!({"uid": "monitor", "rate": 48000}),
    );
    let report = w.tool("confirm_plan", json!({"plan_id": plan["id"]}));
    assert_eq!(report["status"], "confirmed", "{report}");

    // A device that changed after planning is skipped, not written.
    let plan = w.tool(
        "plan_audio_format",
        json!({"uid": "monitor", "rate": 96000}),
    );
    w.hal.unplug("monitor");
    let report = w.tool("confirm_plan", json!({"plan_id": plan["id"]}));
    assert_eq!(report["status"], "skipped_changed", "{report}");
}

#[test]
fn aggregates_are_planned_and_deleting_one_is_cli_only() {
    let w = world();
    let plan = w.tool(
        "plan_audio_aggregate",
        json!({"name": "Mix", "members": ["speakers", "monitor"], "multi_output": true}),
    );
    let report = w.tool("confirm_plan", json!({"plan_id": plan["id"]}));
    assert_eq!(report["status"], "confirmed", "{report}");
    let devices = w.json(&["audio", "devices", "--json"]);
    let aggregate = devices["devices"]
        .as_array()
        .unwrap()
        .iter()
        .find(|d| d["kind"] == "aggregate")
        .expect("the aggregate exists")["uid"]
        .as_str()
        .unwrap()
        .to_owned();
    let removal = w.json(&["audio", "aggregate", "delete", &aggregate, "--json"]);
    assert_eq!(removal["kind"], "audio.aggregate.delete");
    let done = w.cli(&["plan", "confirm", removal["id"].as_str().unwrap()]);
    assert_eq!(done.code, 0, "{}", done.stderr);
    assert!(w.hal.device(&aggregate).is_none());
}

// ----------------------------------------------------------------- Bluetooth

#[test]
fn ble_reads_directly_and_writes_only_through_a_plan() {
    let w = world();
    assert_eq!(w.json(&["bt", "devices", "--json"])["count"], 0);
    assert_eq!(
        w.json(&["ble", "scan", "--timeout-seconds", "2"])["total_seen"],
        1
    );
    assert_eq!(w.tool("scan_ble", json!({"filter": "sensor"}))["shown"], 1);
    assert_eq!(w.json(&["ble", "read", "id-a"])["services"][0]["uuid"], SVC);
    let read = w.json(&["ble", "read", "id-a", SVC, CHR]);
    assert_eq!(read["value_hex"], "01");

    let plan = w.json(&["ble", "write", "id-a", SVC, CHR, "0a0b", "--json"]);
    assert_eq!(plan["kind"], "ble_write");
    assert_eq!(
        w.json(&["ble", "read", "id-a", SVC, CHR])["value_hex"],
        "01",
        "planning writes nothing"
    );
    let done = w.cli(&["ble", "write", "--confirm", plan["id"].as_str().unwrap()]);
    assert_eq!(done.code, 0, "{}", done.stderr);
    let report: Value = serde_json::from_str(&done.stdout).unwrap();
    assert_eq!(report["status"], "confirmed", "{report}");
    assert_eq!(
        w.json(&["ble", "read", "id-a", SVC, CHR])["value_hex"],
        "0a0b"
    );

    // A rejected write is `failed` with the reason, and exit 1.
    w.central.device.borrow_mut().write = WriteBehavior::Reject("ATT error 3".into());
    let plan = w.tool(
        "plan_ble_write",
        json!({"device_id": "id-a", "service": SVC, "characteristic": CHR, "value_hex": "ff"}),
    );
    let out = w.cli(&["plan", "confirm", plan["id"].as_str().unwrap()]);
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert!(out.stdout.contains("failed"));
    // The log is kept in memory only: nothing to export from a one-shot command.
    assert_eq!(w.cli(&["ble", "export"]).code, 4);
}

// ----------------------------------------------------------------- input

#[test]
fn input_is_cli_only_and_never_an_mcp_tool() {
    let w = world();
    let status = w.json(&["input", "status", "--json"]);
    assert_eq!(status["finder_cut"]["enabled"], false);
    assert_eq!(
        w.json(&["input", "finder-cut", "on"])["finder_cut"]["enabled"],
        true
    );
    assert!(w.settings.value.borrow().finder_cut);
    assert_eq!(w.cli(&["input", "finder-cut", "maybe"]).code, 2);
    assert_eq!(
        w.json(&["input", "haptics", "status"])["state"]["level"],
        "available"
    );
    let list = w.mcp_mode(
        "full",
        json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}),
    );
    for tool in list["result"]["tools"].as_array().unwrap() {
        let name = tool["name"].as_str().unwrap();
        for word in ["input", "haptic", "finder", "clipboard"] {
            assert!(!name.contains(word), "{name}");
        }
    }
    assert_eq!(w.call("input_status", json!({}))["error"]["code"], -32603);
}

// ----------------------------------------------------------------- routing

#[test]
fn every_area_command_has_a_cli_route_and_help_and_a_family_usage() {
    let w = world();
    for spec in symcockpit_contract::area_commands() {
        let mut words: Vec<&str> = spec.cli_path.split(' ').collect();
        words.push("--help");
        let out = w.cli(&words);
        assert_eq!(out.code, 0, "{}: {}", spec.cli_path, out.stderr);
        assert!(
            out.stdout
                .starts_with(&format!("Usage: symcockpit {}", spec.cli_path)),
            "{}: {}",
            spec.cli_path,
            out.stdout
        );
    }
    let family = w.cli(&["audio", "--help"]);
    assert_eq!(family.code, 0);
    assert!(family.stdout.contains("audio volume set"));
    assert_eq!(w.cli(&["audio"]).code, 2);
    assert_eq!(w.cli(&["audio", "frobnicate"]).code, 2);
    // `processes` without `kill` is still the v0.12 listing, not an area command.
    assert!(matches!(
        plan_with(&w.app, &args(&["processes", "--help"]), None),
        Action::Done(Outcome { code: 0, .. })
    ));
}

#[test]
fn an_unwired_area_answers_unsupported_instead_of_reaching_the_swift_core() {
    let tmp = tempfile::tempdir().unwrap();
    let bare = app(tmp.path());
    match plan_with(&bare, &args(&["audio", "devices"]), None) {
        Action::Done(out) => {
            assert_eq!(out.code, 4, "{}", out.stderr);
            assert!(out.stderr.contains("not available"));
        }
        _ => panic!("an area command must never be forwarded"),
    }
}

#[test]
fn the_data_dir_override_moves_the_database() {
    let w = world();
    let other = w.home().join("elsewhere");
    let out = w.cli(&[
        "--data-dir",
        other.to_str().unwrap(),
        "storage",
        "health",
        "--json",
    ]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(other.join("cockpit.sqlite").is_file());
    assert!(!w.db().exists());
}
