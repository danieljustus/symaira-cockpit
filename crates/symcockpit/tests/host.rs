//! The agent with its long-lived services (wave 2D-S), end to end through the protocol session:
//! the same register handlers, the same dispatch as `call`, on fakes. No hardware, no real
//! pasteboard, Keychain, event tap, process tap or radio; a temporary home, a temporary Finder
//! jobs directory. The binary-level checks (the services stay off without a user, the human
//! clipboard methods exist nowhere else) are in `agent_stdio.rs` and `human_only.rs`.

mod common;

use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use common::app;
use serde_json::{Value, json};
use symcockpit::agent::Session;
use symcockpit::app::{App, Context};
use symcockpit::areas::{AudioKit, InputKit, Ports, register};
use symcockpit::host::clipboard::ClipboardParts;
use symcockpit::host::input::Feedback;
use symcockpit::host::mixer::MixerParts;
use symcockpit::host::{Host, HostConfig, Intervals, Platform};
use symcockpit::mcp::Server;
use symcockpit_contract::agent_proto::HOST_METHODS;
use symcockpit_core::audio::AudioService;
use symcockpit_core::audio::mixer::TapHal;
use symcockpit_core::bluetooth::{
    Advertisement, BleAuthorization, BleCentral, Characteristic, PairedDevice, PairedDevices,
    Service,
};
use symcockpit_core::clipboard::random_key;
use symcockpit_core::clock::SystemMonotonic;
use symcockpit_core::finder::{Action, FinderPlatform, Inbox, Job, new_job_id};
use symcockpit_core::input::{Access, HapticLevel, Synthetic};
use symcockpit_core::midi::MidiService;
use symcockpit_core::plan::{Clock, SystemClock};
use symcockpit_db::{plans::SqlitePlanStore, smart_history::SmartHistoryStore};
use symcockpit_macos::input::JsonFileSettings;
use symcockpit_store::Config;
use symcockpit_testkit::audio::{FakeAudioHal, FakeTapHal, input_device, output_device, process};
use symcockpit_testkit::bluetooth::{FakeCentral, FakeDevice, SyncCentral, WriteBehavior};
use symcockpit_testkit::clipboard::{FakeExclusion, FakeKeys, SharedPasteboard};
use symcockpit_testkit::input::{FakeHaptic, FakeProbe, FakeSound, FakeTapHost, SharedFeedback};
use symcockpit_testkit::kill::{FakeProcesses, identity};
use symcockpit_testkit::midi::sample_hal;
use symcockpit_testkit::snapshot::check;
use symcockpit_testkit::storage_clean::{FakeApps, FakeRemover};
use symcockpit_testkit::storage_health::{FakeNvme, FakeSpeedHost, FakeTree};

const SVC: &str = "180F";
const CHR: &str = "2A19";

struct PassiveBluetooth(Option<BleAuthorization>);

impl PairedDevices for PassiveBluetooth {
    fn paired(&self) -> Result<Vec<PairedDevice>, symcockpit_contract::Error> {
        Ok(vec![])
    }

    fn ble_authorization(&self) -> Option<BleAuthorization> {
        self.0
    }
}

#[derive(Clone, Default)]
struct Recorder(Arc<Mutex<Vec<String>>>);

impl FinderPlatform for Recorder {
    fn copy_text(&self, text: &str) -> Result<(), String> {
        self.0.lock().unwrap().push(format!("copy:{text}"));
        Ok(())
    }
    fn open_in_terminal(&self, dir: &Path) -> Result<(), String> {
        self.0
            .lock()
            .unwrap()
            .push(format!("terminal:{}", dir.display()));
        Ok(())
    }
}

struct World {
    tmp: tempfile::TempDir,
    app: App,
    host: Host,
    tap_hal: Arc<FakeTapHal>,
    audio_hal: Arc<FakeAudioHal>,
    central: SyncCentral,
    pasteboard: SharedPasteboard,
    tap_host: FakeTapHost,
    feedback: SharedFeedback,
    finder: Recorder,
    installed: std::cell::RefCell<Option<symcockpit::host::Installed>>,
}

fn device() -> FakeDevice {
    FakeDevice {
        services: vec![Service {
            uuid: SVC.into(),
            characteristics: vec![Characteristic {
                uuid: CHR.into(),
                properties: vec!["read".into(), "write".into(), "notify".into()],
            }],
        }],
        values: [((SVC.to_owned(), CHR.to_owned()), vec![0x01])].into(),
        write: WriteBehavior::Accept,
        notifications: vec![],
    }
}

fn ads() -> Vec<Advertisement> {
    ["id-a", "id-b"]
        .iter()
        .map(|id| Advertisement {
            id: (*id).into(),
            name: Some(format!("Sensor {id}")),
            rssi: Some(-60),
            service_uuids: vec![SVC.into()],
            connectable: Some(true),
        })
        .collect()
}

fn world() -> World {
    world_with_ble_authorization(None)
}

fn world_with_ble_authorization(authorization: Option<BleAuthorization>) -> World {
    let tmp = tempfile::tempdir().unwrap();
    let mut app = app(tmp.path());
    let home = tmp.path().to_path_buf();
    // The fakes the handlers (the CLI path) and the host (the agent path) share.
    let tap_hal = Arc::new(FakeTapHal::new());
    tap_hal.set_processes(vec![process(42, 7), process(43, 8)]);
    let audio_hal = Arc::new(FakeAudioHal::new(vec![
        output_device("speakers"),
        output_device("monitor"),
        input_device("mic"),
    ]));
    audio_hal.set_defaults(Some("mic"), Some("speakers"));
    let kit = AudioKit {
        service: Arc::new(AudioService::new(audio_hal.clone())),
        midi: Arc::new(MidiService::new(Arc::new(sample_hal()))),
        tap: Some(tap_hal.clone() as Arc<dyn TapHal>),
        before_foreground: Rc::new(|| {}),
        stop: Rc::new(|| true),
    };
    let one_shot_central = Rc::new(FakeCentral::new(ads(), device()));
    struct Shared(Rc<FakeCentral>);
    impl BleCentral for Shared {
        fn scan(&self, t: Duration) -> Result<Vec<Advertisement>, symcockpit_contract::Error> {
            self.0.scan(t)
        }
        fn connect(
            &self,
            id: &str,
            t: Duration,
        ) -> Result<Box<dyn symcockpit_core::bluetooth::BleLink>, symcockpit_contract::Error>
        {
            self.0.connect(id, t)
        }
    }
    let ports = Ports {
        clock: Rc::new(SystemClock),
        nvme: Rc::new(FakeNvme(Ok(vec![]))),
        history: Box::new(|p| Ok(Box::new(SmartHistoryStore::open(p)?))),
        plans: Box::new(|p| Ok(Box::new(SqlitePlanStore::open(p)?))),
        speed: Rc::new(FakeSpeedHost::new(1 << 30, 1 << 30)),
        space: Rc::new(FakeTree::new()),
        remover: Rc::new(FakeRemover::new(&home, &home.join("trash"))),
        apps: Box::new(|_| Box::new(FakeApps::default())),
        processes: Rc::new(FakeProcesses::new(identity(321, "Hog", 77))),
        sleep: Box::new(|_| {}),
        audio: Box::new(move || Ok(kit.clone())),
        paired: Rc::new(PassiveBluetooth(authorization)),
        central: Box::new(move || Ok(Box::new(Shared(one_shot_central.clone())))),
        input: InputKit {
            settings: Box::new(|path| Box::new(JsonFileSettings::new(path))),
            probe: Rc::new(FakeProbe {
                access: Access::Granted,
                secure: false,
            }),
            haptic: Rc::new(FakeHaptic::new(HapticLevel::Available)),
            sound: Rc::new(FakeSound::default()),
        },
    };
    register(&mut app.handlers, Rc::new(ports));

    let pasteboard = SharedPasteboard::default();
    let central = SyncCentral::new(ads(), device());
    let tap_host = FakeTapHost::default();
    let feedback = SharedFeedback::default();
    let finder = Recorder::default();
    let key = random_key();
    let input_file = app.paths.config_dir.join("input.json");
    let platform = {
        let (board, tap, audio) = (pasteboard.clone(), tap_hal.clone(), audio_hal.clone());
        let (ble, finder, feed) = (central.clone(), finder.clone(), feedback.clone());
        Platform {
            clipboard: Arc::new(move || {
                Ok(ClipboardParts {
                    source: Box::new(board.clone()),
                    sink: Box::new(board.clone()),
                    keys: Box::new(FakeKeys::with_key(key)),
                    exclusion: Box::new(FakeExclusion::default()),
                })
            }),
            mixer: Arc::new(move || {
                Ok(MixerParts {
                    tap: tap.clone() as Arc<dyn TapHal>,
                    audio: audio.clone() as Arc<dyn symcockpit_core::audio::AudioHal>,
                })
            }),
            finder: Arc::new(move || Box::new(finder.clone())),
            central: Arc::new(move || Ok(Box::new(ble.clone()) as Box<dyn BleCentral>)),
            tap: Box::new(tap_host.clone()),
            probe: Box::new(FakeProbe {
                access: Access::Granted,
                secure: false,
            }),
            input_settings: Arc::new(move || Box::new(JsonFileSettings::new(&input_file))),
            feedback: Arc::new(move || {
                Ok(Feedback {
                    haptic: Box::new(feed.clone()),
                    sound: Box::new(feed.clone()),
                })
            }),
            run_loop: None,
        }
    };
    let host = Host::start(
        platform,
        HostConfig {
            data_dir: app.paths.data_dir.clone(),
            finder_jobs_dir: Some(tmp.path().join("jobs")),
            intervals: Intervals {
                clipboard: Duration::from_millis(5),
                jobs: Duration::from_millis(5),
                ble: Duration::from_millis(5),
                reconcile: Duration::from_secs(3600),
            },
        },
    );
    let installed = host.install();
    World {
        tmp,
        app,
        host,
        tap_hal,
        audio_hal,
        central,
        pasteboard,
        tap_host,
        feedback,
        finder,
        installed: std::cell::RefCell::new(Some(installed)),
    }
}

/// What the app sends: lines in, frames out. `with_host = false` is a plain session, the
/// way an agent without services (or any older one) would answer.
struct Rpc<'a> {
    session: Session<'a>,
    next: u64,
}

fn data_dir(w: &World) -> PathBuf {
    w.app.paths.data_dir.clone()
}

impl World {
    /// Runs `f` with a session over the register handlers.
    fn session<T>(&self, with_host: bool, f: impl FnOnce(&mut Rpc) -> T) -> T {
        let config = Config::default();
        let data = data_dir(self);
        let ctx = Context {
            config: &config,
            paths: &self.app.paths,
            data_dir: &data,
            data_dir_override: None,
            env: &self.app.env,
            services: &self.app.services,
        };
        // A one-shot command (or an agent without services) runs where no host is installed.
        // Drop first: dropping the old guard after installing would uninstall the new one.
        drop(self.installed.borrow_mut().take());
        *self.installed.borrow_mut() = with_host.then(|| self.host.install());
        let server = Server::new(&self.app, &ctx);
        let (mono, clock) = (SystemMonotonic, SystemClock);
        let mut session = Session::new(&server, &mono, &clock);
        if with_host {
            session = session.with_host(&self.host);
        }
        let mut rpc = Rpc { session, next: 1 };
        let hello = rpc.send("hello", json!({"protocol_version": 1}));
        assert!(hello["result"].is_object(), "{hello}");
        f(&mut rpc)
    }
}

impl Rpc<'_> {
    fn send(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        let mut frames = self.session.handle_line(&line.to_string());
        frames.remove(0)
    }

    /// `call`: the output of a command that must have worked.
    fn call(&mut self, command: &str, params: Value) -> Value {
        let r = self.send("call", json!({"command": command, "params": params}));
        assert_eq!(r["result"]["status"], "ok", "{command}: {r}");
        r["result"]["output"].clone()
    }

    fn call_error(&mut self, command: &str, params: Value) -> Value {
        let r = self.send("call", json!({"command": command, "params": params}));
        assert!(r.get("error").is_some(), "{command}: {r}");
        r["error"].clone()
    }

    fn method(&mut self, method: &str, params: Value) -> Value {
        let r = self.send(method, params);
        assert!(r.get("result").is_some(), "{method}: {r}");
        r["result"].clone()
    }
}

fn eventually(what: &str, mut check: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !check() {
        assert!(Instant::now() < deadline, "timed out waiting for: {what}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn gatt(id: &str) -> Value {
    json!({"device_id": id, "service": SVC, "characteristic": CHR})
}

// ---------------------------------------------------------------- the protocol

#[test]
fn hello_lists_the_host_methods_and_the_new_topics_only_for_an_agent_with_services() {
    let w = world();
    let with = w.session(true, |rpc| {
        rpc.send("hello", json!({"protocol_version": 1}))["result"].clone()
    });
    let methods: Vec<&str> = with["capabilities"]["methods"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m.as_str().unwrap())
        .collect();
    for m in HOST_METHODS {
        assert!(methods.contains(&m), "{m}");
    }
    let topics: Vec<&str> = with["capabilities"]["topics"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m.as_str().unwrap())
        .collect();
    for t in [
        "audio.devices",
        "audio.default.get",
        "audio.mixer.status",
        "midi.devices",
        "clipboard.status",
        "input.status",
        "input.haptics.status",
        "ble.session",
        "metrics",
    ] {
        assert!(topics.contains(&t), "{t}");
    }
    for t in [
        "storage.health",
        "storage.space",
        "storage.speedtest",
        "bt.devices",
        "ble.scan",
    ] {
        assert!(!topics.contains(&t), "{t} is too expensive to sample");
    }
    // A session without services does not know the methods at all.
    w.session(false, |rpc| {
        let r = rpc.send("clipboard.list", json!({}));
        assert_eq!(r["error"]["code"], -32601, "{r}");
        let hello = rpc.send("hello", json!({"protocol_version": 1}));
        let methods = hello["result"]["capabilities"]["methods"]
            .as_array()
            .unwrap()
            .len();
        assert_eq!(methods, 7);
    });
}

#[test]
fn a_host_method_is_not_a_command_and_a_command_is_not_a_method() {
    let w = world();
    w.session(true, |rpc| {
        for name in [
            "clipboard.list",
            "clipboard.read",
            "clipboard.copy",
            "clipboard.delete",
            "clipboard.settings",
            "clipboard.configure",
            "services",
        ] {
            let e = rpc.call_error(name, json!({}));
            assert_eq!(e["code"], -32602, "call {name} is an unknown command: {e}");
        }
        let r = rpc.send("audio.devices", json!({}));
        assert_eq!(r["error"]["code"], -32601, "{r}");
        // Before `hello` nothing is served, host methods included.
    });
    let config = Config::default();
    let data = data_dir(&w);
    let ctx = Context {
        config: &config,
        paths: &w.app.paths,
        data_dir: &data,
        data_dir_override: None,
        env: &w.app.env,
        services: &w.app.services,
    };
    let server = Server::new(&w.app, &ctx);
    let (mono, clock) = (SystemMonotonic, SystemClock);
    let mut session = Session::new(&server, &mono, &clock).with_host(&w.host);
    let r = session.handle_line(r#"{"jsonrpc":"2.0","id":1,"method":"clipboard.list"}"#);
    assert_eq!(r[0]["error"]["code"], -32002);
}

#[test]
fn services_reports_every_service_and_a_fresh_agent_runs_none_of_them() {
    let w = world();
    w.session(true, |rpc| {
        let s = rpc.method("services", json!({}));
        assert_eq!(s["clipboard"]["state"], "off");
        assert_eq!(s["mixer"], json!({"running": false, "apps": 0}));
        assert_eq!(s["input_tap"]["finder_cut"], "off");
        assert_eq!(s["finder_jobs"]["succeeded"], 0);
        assert_eq!(s["ble"]["connections"], json!([]));
    });
    assert_eq!(w.pasteboard.reads(), 0, "nothing looked at the pasteboard");
    assert_eq!(w.tap_host.starts(), 0);
    assert_eq!(
        (w.central.counters(), w.tap_hal.live_taps()),
        ((0, 0, 0), 0)
    );
}

// ----------------------------------------------------------------------- mixer

#[test]
fn audio_mixer_set_works_through_the_hosted_mixer_and_fails_open_without_one() {
    let w = world();
    // The agent without services: the command exists and says why it cannot work.
    w.session(false, |rpc| {
        let hello_less =
            rpc.call_error("audio.app-volume.set", json!({"app": "42", "volume": 0.5}));
        assert_eq!(hello_less["data"]["class"], "unsupported", "{hello_less}");
    });
    assert_eq!(w.tap_hal.live_taps(), 0);
    w.session(true, |rpc| {
        let out = rpc.call("audio.app-volume.set", json!({"app": "42", "volume": 0.5}));
        assert_eq!(out["apps"][0]["state"], "active", "{out}");
        assert_eq!(w.tap_hal.live_taps(), 1);
        let status = rpc.call("audio.mixer.status", json!({}));
        assert_eq!(status["mixer_running"], true);
        assert_eq!(status["managed"][0]["pid"], 42);
        // Muting a second app, then both back to normal: no tap stays.
        rpc.call(
            "audio.app-volume.set",
            json!({"app": "43", "volume": 1.0, "muted": true}),
        );
        assert_eq!(w.tap_hal.live_taps(), 2);
        rpc.call("audio.app-volume.set", json!({"app": "42", "volume": 1.0}));
        rpc.call("audio.app-volume.set", json!({"app": "43", "volume": 1.0}));
        assert_eq!(w.tap_hal.live(), Vec::<String>::new());
    });
}

#[test]
fn ending_the_agent_releases_every_app_even_when_the_output_changed_meanwhile() {
    let w = world();
    w.session(true, |rpc| {
        rpc.call("audio.app-volume.set", json!({"app": "42", "volume": 0.3}));
        w.audio_hal.set_defaults(Some("mic"), Some("monitor"));
        w.audio_hal.bump_epoch();
        eventually("the mixer followed the new output", || {
            w.tap_hal
                .log()
                .iter()
                .filter(|l| l.starts_with("create_aggregate"))
                .count()
                == 2
        });
    });
    w.host.end();
    assert_eq!(w.tap_hal.live(), Vec::<String>::new());
    // A late request after the end is an error, never a pipeline nobody releases.
    w.session(true, |rpc| {
        let e = rpc.call_error("audio.app-volume.set", json!({"app": "42", "volume": 0.3}));
        assert!(e["message"].as_str().unwrap().contains("ended"), "{e}");
    });
    assert_eq!(w.tap_hal.live(), Vec::<String>::new());
}

// ------------------------------------------------------------------------- BLE

#[test]
fn ble_session_reports_authorization_without_starting_a_scan_or_connection() {
    let w = world_with_ble_authorization(Some(BleAuthorization::NotDetermined));
    w.session(true, |rpc| {
        let session = rpc.call("ble.session", json!({}));
        assert_eq!(session["authorization"], "not_determined");
        assert_eq!(session["connections"], json!([]));
        assert_eq!(w.central.counters(), (0, 0, 0));
    });
}

#[test]
fn the_ble_session_lives_in_the_agent_and_exports_its_log() {
    let w = world();
    // Without the agent a one-shot command has no session.
    w.session(false, |rpc| {
        // `ble.session` outside the host: the handler falls back to the one-shot path.
        let e = rpc.call_error("ble.session", json!({}));
        assert_eq!(e["data"]["class"], "unsupported", "{e}");
    });
    w.session(true, |rpc| {
        let scan = rpc.call("ble.scan", json!({"timeout_seconds": 1}));
        assert_eq!(scan["total_seen"], 2);
        let connect = rpc.call("ble.connect", json!({"device_id": "id-a"}));
        check("bluetooth", "ble.connect", &connect);
        assert_eq!(connect["new"], true);
        // A filter changes what the scan shows and nothing else.
        let filtered = rpc.call("ble.scan", json!({"timeout_seconds": 1, "filter": "id-b"}));
        assert_eq!(
            (filtered["total_seen"].as_u64(), filtered["shown"].as_u64()),
            (Some(2), Some(1))
        );
        assert_eq!(w.central.open_links(), 1);
        let services = rpc.call("ble.services", json!({"device_id": "id-a"}));
        check("bluetooth", "ble.services", &services);
        let read = rpc.call("ble.read", gatt("id-a"));
        assert_eq!(read["value_hex"], "01");
        assert_eq!(
            w.central.counters().1,
            1,
            "one connection served everything"
        );
        // Live subscription and its notifications.
        let sub = rpc.call("ble.subscribe", gatt("id-a"));
        check("bluetooth", "ble.subscribe.live", &sub);
        w.central.notify(SVC, CHR, &[0xde, 0xad]);
        eventually("the notification is in the log", || {
            rpc.call("ble.session", json!({}))["log_entries"]
                .as_u64()
                .unwrap()
                >= 4
        });
        let session = rpc.call("ble.session", json!({}));
        check("bluetooth", "ble.session", &session);
        assert_eq!(session["subscriptions"][0]["characteristic"], CHR);
        let log = rpc.call("ble.log", json!({}));
        check("bluetooth", "ble.log", &log);
        let unsub = rpc.call("ble.unsubscribe", gatt("id-a"));
        check("bluetooth", "ble.unsubscribe", &unsub);
        // Export: CSV after RFC 4180 and JSON with the raw bytes, same shapes as ever.
        let csv = rpc.call("ble.export", json!({"format": "csv"}));
        check("bluetooth", "ble.export.csv", &csv);
        let text = csv["content"].as_str().unwrap();
        assert!(
            text.contains("\r\n") && text.contains(",notify,id-a,180F,2A19,dead,2,"),
            "{text}"
        );
        let doc = rpc.call("ble.export", json!({"format": "json"}));
        check("bluetooth", "ble.export", &doc);
        let notify = doc["entries"]
            .as_array()
            .unwrap()
            .iter()
            .find(|e| e["kind"] == "notify")
            .unwrap();
        assert_eq!(notify["bytes"], json!([0xde, 0xad]));
        let off = rpc.call("ble.disconnect", json!({"device_id": "id-a"}));
        check("bluetooth", "ble.disconnect", &off);
        assert_eq!(w.central.open_links(), 0);
    });
}

#[test]
fn a_confirmed_ble_write_goes_over_the_open_connection_and_stays_visible_stage_by_stage() {
    let w = world();
    w.session(true, |rpc| {
        rpc.call("ble.connect", json!({"device_id": "id-a"}));
        // Area commands plan themselves; `plan.confirm` is the second step.
        let plan = rpc.call(
            "ble.write",
            json!({"device_id": "id-a", "service": SVC, "characteristic": CHR, "value_hex": "ff00"}),
        );
        assert_eq!(plan["state"], "pending", "{plan}");
        assert_eq!(w.central.stored_value(SVC, CHR), Some(vec![0x01]), "planning writes nothing");
        let id = plan["id"].as_str().unwrap().to_owned();
        let done = rpc.call("plan.confirm", json!({"plan_id": id}));
        assert_eq!(done["status"], "confirmed", "{done}");
        assert_eq!(w.central.stored_value(SVC, CHR), Some(vec![0xff, 0x00]));
        assert_eq!(w.central.counters().1, 1, "the write reused the session's connection");
        let log = rpc.call("ble.log", json!({}));
        let kinds: Vec<&str> =
            log["entries"].as_array().unwrap().iter().map(|e| e["kind"].as_str().unwrap()).collect();
        assert_eq!(kinds, ["connect", "write_requested", "write_acknowledged", "write_readback"]);
    });
}

// ------------------------------------------------------------------- clipboard

#[test]
fn the_human_reads_the_history_through_agent_methods_and_the_cli_commands_stay_content_free() {
    let w = world();
    w.session(true, |rpc| {
        assert_eq!(rpc.method("clipboard.list", json!({}))["count"], 0);
        // The register commands the CLI has (status, pause, resume, clear) share the settings.
        let status = rpc.call("clipboard.status", json!({}));
        assert_eq!(status["capturing"], false);
        let configured = rpc.method("clipboard.configure", json!({"enabled": true}));
        assert_eq!(configured["state"], "capturing", "{configured}");
        assert_eq!(rpc.call("clipboard.status", json!({}))["capturing"], true);
        let before = w.pasteboard.reads();
        eventually("the poller took its baseline", || {
            w.pasteboard.reads() > before
        });
        w.pasteboard
            .copy_text("com.example.editor", "hello clipboard");
        eventually("one item", || {
            rpc.method("clipboard.list", json!({}))["count"] == 1
        });
        let list = rpc.method("clipboard.list", json!({}));
        let id = list["items"][0]["id"].as_str().unwrap().to_owned();
        assert!(
            !list.to_string().contains("hello clipboard"),
            "a list never carries content"
        );
        let read = rpc.method("clipboard.read", json!({"id": id}));
        assert_eq!(read["text"], "hello clipboard");
        // `clipboard pause` (a register command, CLI and app) stops the capture at once.
        rpc.call("clipboard.pause", json!({}));
        let reads = w.pasteboard.reads();
        w.pasteboard.copy_text("com.example.editor", "while paused");
        std::thread::sleep(Duration::from_millis(60));
        assert_eq!(
            w.pasteboard.reads(),
            reads,
            "paused: the pasteboard is not looked at"
        );
        rpc.call("clipboard.resume", json!({}));
        let copy = rpc.method("clipboard.copy", json!({"id": id}));
        assert_eq!(copy["copied"], true);
        assert_eq!(w.pasteboard.writes(), ["text:hello clipboard"]);
        let deleted = rpc.method("clipboard.delete", json!({"id": id}));
        assert_eq!(deleted["deleted"], true);
        let missing = rpc.send("clipboard.read", json!({"id": id}));
        assert_eq!(missing["error"]["code"], -32000);
        let bad = rpc.send("clipboard.configure", json!({"enabled": "yes"}));
        assert_eq!(bad["error"]["data"]["class"], "usage");
        let no_id = rpc.send("clipboard.read", json!({}));
        assert_eq!(no_id["error"]["data"]["class"], "usage");
        // `clipboard clear` (register command) removes everything.
        w.pasteboard.copy_text("a.b", "x");
        rpc.method("clipboard.configure", json!({"paused": false}));
        assert!(rpc.call("clipboard.clear", json!({}))["cleared"].is_number());
        assert_eq!(rpc.method("clipboard.list", json!({}))["count"], 0);
    });
}

#[test]
fn nothing_is_captured_without_the_users_opt_in_even_when_the_agent_runs() {
    let w = world();
    w.pasteboard.copy_text("com.example.editor", "before");
    w.session(true, |rpc| {
        rpc.call("input.status", json!({}));
        rpc.method("services", json!({}));
    });
    w.pasteboard.copy_text("com.example.editor", "during");
    std::thread::sleep(Duration::from_millis(60));
    assert_eq!(w.pasteboard.reads(), 0);
    assert!(!data_dir(&w).join("clipboard").exists());
}

// ----------------------------------------------------------------------- input

#[test]
fn the_finder_tap_follows_the_setting_the_cli_and_the_app_write_and_clicks_on_a_replaced_key() {
    let w = world();
    let settings = JsonFileSettings::new(w.app.paths.config_dir.join("input.json"));
    w.session(true, |rpc| {
        assert_eq!(
            rpc.call("input.status", json!({}))["finder_cut"]["enabled"],
            false
        );
        assert_eq!(w.tap_host.starts(), 0, "no setting, no tap");
        rpc.call("input.finder-cut", json!({"state": "on"}));
        assert_eq!(
            w.tap_host.starts(),
            1,
            "the command's own effect, not the next periodic check"
        );
        let s = rpc.method("services", json!({}));
        assert_eq!(s["input_tap"]["finder_cut"], "running", "{s}");
        // Haptics and the material sound answer a replaced key through the existing backends.
        let mut now = symcockpit_core::input::SettingsStore::load(&settings).unwrap();
        now.haptics = true;
        now.sound = true;
        symcockpit_core::input::SettingsStore::save(&settings, &now).unwrap();
        assert!(w.tap_host.fire(Synthetic::Copy));
        eventually("the click", || {
            w.feedback
                .actuations
                .load(std::sync::atomic::Ordering::SeqCst)
                == 1
                && w.feedback.sounds.load(std::sync::atomic::Ordering::SeqCst) == 1
        });
        rpc.call("input.finder-cut", json!({"state": "off"}));
        assert_eq!(w.tap_host.stops(), 1);
        assert!(!w.tap_host.running());
        assert_eq!(
            rpc.method("services", json!({}))["input_tap"]["finder_cut"],
            "off"
        );
    });
    // Ending the agent with the tap on removes it too.
    w.session(true, |rpc| {
        rpc.call("input.finder-cut", json!({"state": "on"}));
    });
    assert!(w.tap_host.running());
    w.host.end();
    assert!(!w.tap_host.running());
}

// ----------------------------------------------------------------- Finder jobs

#[test]
fn a_finder_job_in_the_group_container_runs_once_and_is_reported() {
    let w = world();
    let inbox = Inbox::new(w.tmp.path().join("jobs"));
    let job = Job {
        id: new_job_id(),
        action: Action::CopyPath,
        paths: vec!["/Users/x/a file; rm -rf ~".into()],
        created_at: SystemClock.now(),
        expires_at: SystemClock.now() + 60,
    };
    inbox.submit(&job).unwrap();
    eventually("the result file", || inbox.result(&job.id).is_some());
    assert_eq!(inbox.result(&job.id).unwrap()["state"], "succeeded");
    assert_eq!(
        *w.finder.0.lock().unwrap(),
        ["copy:/Users/x/a file; rm -rf ~"]
    );
    w.session(true, |rpc| {
        assert_eq!(
            rpc.method("services", json!({}))["finder_jobs"]["succeeded"],
            1
        );
    });
}
