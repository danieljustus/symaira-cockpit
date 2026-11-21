//! The helper end to end *without root*: a real XPC round trip (an anonymous
//! listener and a client built from its endpoint, both in this process)
//! through the helper's service into the engine over a fake SMC. Peer
//! signature checking is XPC's job and needs signed binaries; it is not
//! exercised here (anonymous listeners have no peer requirement).

use std::time::{Duration, Instant};

use symcockpit_core::clock::Monotonic;
use symcockpit_core::helper_engine::Engine;
use symcockpit_helper::{Exit, Service, run};
use symcockpit_helper_proto::{Action, ErrorKind, GovernorProfile, Reply, Request};
use symcockpit_macos::xpc::{Client, Server};
use symcockpit_store::smc_restore;
use symcockpit_testkit::smc::FakeSmc;
use symcockpit_testkit::smc_write::{FakeClock, FakePorts, FakeSmcRw};

const WAIT: Duration = Duration::from_secs(5);

struct Rig {
    smc: FakeSmcRw,
    clock: FakeClock,
    service: Service,
    server: Server,
    client: Client,
    dir: tempfile::TempDir,
}

fn rig() -> Rig {
    let smc = FakeSmcRw::new(
        FakeSmc::new(true)
            .with_ui8("FNum", 1)
            .with_ui8("F0Md", 0)
            .with_flt("F0Ac", 2500.0)
            .with_flt("F0Tg", 2500.0)
            .with_flt("F0Mn", 2000.0)
            .with_flt("F0Mx", 8000.0)
            .with_flt("TCMz", 85.0)
            .with_ui8("Ftst", 0),
    );
    let clock = FakeClock::default();
    let dir = tempfile::tempdir().unwrap();
    let ports = FakePorts::new(smc.clone(), clock.clone());
    let engine = Engine::new(Box::new(ports), &dir.path().join("data"), None, "9.9.9");
    let service = Service::new(engine);
    let server = Server::anonymous(service.handler(), service.hooks()).unwrap();
    let client = Client::endpoint(&server.endpoint()).unwrap();
    Rig {
        smc,
        clock,
        service,
        server,
        client,
        dir,
    }
}

impl Rig {
    fn ask(&self, action: Action) -> Reply {
        let text = self
            .client
            .request(&Request::new(action).to_json(), WAIT)
            .unwrap();
        Reply::from_json(&text).unwrap()
    }
}

#[test]
fn hello_over_xpc_and_nothing_unknown_reaches_the_engine() {
    let r = rig();
    assert_eq!(
        r.ask(Action::Hello),
        Reply::Hello {
            version: 1,
            helper_version: "9.9.9".into()
        }
    );
    // Raw texts a hostile or confused peer might send: refused, never executed.
    for text in [
        r#"{"version":1,"action":"write_smc_key","key":"F0Md","value":1}"#,
        r#"{"version":1,"action":"shell","command":"rm -rf /"}"#,
        r#"{"version":2,"action":"hello"}"#,
        r#"{"action":"hello"}"#,
        "not json",
    ] {
        let reply = Reply::from_json(&r.client.request(text, WAIT).unwrap()).unwrap();
        assert!(
            matches!(
                reply,
                Reply::Error {
                    kind: ErrorKind::Usage,
                    ..
                }
            ),
            "{text}: {reply:?}"
        );
    }
    assert!(r.smc.writes().is_empty());
}

#[test]
fn a_governor_started_over_xpc_is_handed_back_when_the_heartbeat_stops() {
    let r = rig();
    assert_eq!(
        r.ask(Action::GovernorStart {
            profile: GovernorProfile::Comfort,
            cool_target_celsius: None
        }),
        Reply::Ok
    );
    r.service.poll();
    assert_eq!(r.smc.get_ui8("F0Md"), Some(1));
    assert_eq!(
        r.ask(Action::Heartbeat),
        Reply::Heartbeat { governing: true }
    );
    assert!(r.dir.path().join("data/smc-restore.json").exists());

    // The agent dies: no more heartbeats. The service's own poll hands the fans back.
    r.clock.advance_ms(7_001);
    r.service.poll();
    assert!(!r.service.is_governing());
    assert_eq!(r.smc.get_ui8("F0Md"), Some(0));
    assert_eq!(r.smc.get_flt("F0Tg"), Some(2500.0));
    assert!(smc_restore::read(&r.dir.path().join("data")).is_none());
    match r.ask(Action::Status) {
        Reply::Status { state, detail } => assert_eq!(
            (state.as_str(), detail.as_deref()),
            ("idle", Some("heartbeat_timeout"))
        ),
        other => panic!("{other:?}"),
    }
}

#[test]
fn the_owning_connection_going_away_ends_the_governor() {
    let r = rig();
    r.ask(Action::GovernorStart {
        profile: GovernorProfile::Performance,
        cool_target_celsius: None,
    });
    r.service.poll();
    assert_eq!(r.smc.get_ui8("F0Md"), Some(1));
    assert!(r.service.has_connection());
    drop(r.client);
    let deadline = Instant::now() + WAIT;
    while r.service.is_governing() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(
        !r.service.is_governing(),
        "the last client is gone: nothing sends heartbeats"
    );
    assert_eq!(r.smc.get_ui8("F0Md"), Some(0));
    drop(r.server);
}

#[test]
fn the_main_loop_restores_on_sigterm_and_exits_idle_without_clients() {
    // SIGTERM while governing: the fans are back before the loop returns.
    let r = rig();
    r.ask(Action::GovernorStart {
        profile: GovernorProfile::Comfort,
        cool_target_celsius: None,
    });
    let polls = std::cell::Cell::new(0);
    let exit = run(
        &r.service,
        &|| {
            polls.set(polls.get() + 1);
            polls.get() > 3
        },
        &r.clock,
        &|_| {},
    );
    assert_eq!(exit, Exit::Terminated);
    assert_eq!(r.smc.get_ui8("F0Md"), Some(0));

    // Nobody connected and nothing governed for the grace period: exit by itself.
    let smc = FakeSmcRw::m4_pro_like();
    let clock = FakeClock::default();
    let engine = Engine::new(
        Box::new(FakePorts::new(smc, clock.clone())),
        &tempfile::tempdir().unwrap().path().join("d"),
        None,
        "9.9.9",
    );
    let service = Service::new(engine);
    let started = clock.now_ms();
    assert_eq!(run(&service, &|| false, &clock, &|_| {}), Exit::Idle);
    assert!(clock.now_ms() - started >= 5_000);
}
