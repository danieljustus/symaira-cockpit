//! After a system wake the process puts back its display overrides, once, and writes nothing
//! when it holds none. A fake wake source and the fake display of `symcockpit-testkit`: no
//! display, gamma table or SMC key is touched, and the live source is never registered.

mod common;

use std::sync::mpsc;

use common::{app, done};
use symcockpit::app::{App, Context};
use symcockpit::{wake, writes};
use symcockpit_store::Config;
use symcockpit_testkit::tune_write::{Observers, rig};
use symcockpit_testkit::wake::FakeWake;

struct Env {
    tmp: tempfile::TempDir,
    app: App,
    rig: Observers,
}

fn env() -> Env {
    let tmp = tempfile::tempdir().unwrap();
    let app = app(tmp.path());
    let (writer, observers) = rig(&app.paths.data_dir).split();
    writes::install(writer);
    Env {
        tmp,
        app,
        rig: observers,
    }
}

/// What `agent` and `serve` do: the source's thread queues, the main thread handles.
fn wake_once(e: &Env, source: &FakeWake) {
    let (tx, rx) = mpsc::channel();
    let _guard = wake::watch(source, move || {
        let _ = tx.send(());
    })
    .expect("the fake registers");
    source.fire();
    let config = Config::default();
    let ctx = Context {
        config: &config,
        paths: &e.app.paths,
        data_dir: &e.app.paths.data_dir,
        data_dir_override: None,
        env: &e.app.env,
        services: &e.app.services,
    };
    assert_eq!(rx.try_iter().count(), 1, "one wake event for one wake");
    wake::after_wake(&ctx);
    assert!(rx.try_recv().is_err());
    let _ = &e.tmp;
}

fn gamma_writes(e: &Env) -> usize {
    e.rig
        .hw
        .calls()
        .iter()
        .filter(|c| c.starts_with("gamma.write"))
        .count()
}

#[test]
fn a_wake_rewrites_the_held_warmth_table_exactly_once() {
    let e = env();
    done(&e.app, &["warmth", "set", "0.25"]);
    let before = gamma_writes(&e);
    assert!(before >= 1, "the warmth write reached the fake gamma port");
    wake_once(&e, &FakeWake::default());
    assert_eq!(gamma_writes(&e), before + 1);
}

#[test]
fn a_wake_without_overrides_writes_nothing() {
    let e = env();
    wake_once(&e, &FakeWake::default());
    assert_eq!(e.rig.hw.calls(), Vec::<String>::new());
    assert!(e.rig.history.borrow().is_empty());
    assert!(e.rig.power.created.lock().unwrap().is_empty());
}

#[test]
fn a_wake_with_the_overrides_put_back_writes_nothing_either() {
    let e = env();
    done(&e.app, &["warmth", "set", "0.25"]);
    done(&e.app, &["warmth", "reset"]);
    let before = e.rig.hw.calls();
    wake_once(&e, &FakeWake::default());
    assert_eq!(e.rig.hw.calls(), before);
}

#[test]
fn dropping_the_guard_stops_the_watch() {
    let source = FakeWake::default();
    let guard = wake::watch(&source, || {}).unwrap();
    assert!(source.watching());
    drop(guard);
    assert!(!source.watching());
}
