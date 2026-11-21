//! A scripted process table for the kill plan, and the tests of `kill`.
//! One test also ends a child process the test started itself, nothing else.

use std::cell::{Cell, RefCell};
use std::time::Duration;

use symcockpit_contract::Error;
use symcockpit_core::kill::{ProcessControl, ProcessIdentity, SignalError};

pub const OWN_UID: u32 = 501;

pub fn identity(pid: i32, name: &str, started_s: i64) -> ProcessIdentity {
    ProcessIdentity {
        pid,
        name: name.to_owned(),
        path: Some(format!("/Applications/{name}.app/Contents/MacOS/{name}")),
        started_s,
        started_us: 0,
        uid: OWN_UID,
    }
}

/// One process table slot. `leaves_after` is how many identity lookups after
/// SIGTERM still find the process; `None` means it never leaves.
pub struct FakeProcesses {
    pub current: RefCell<Option<ProcessIdentity>>,
    pub deny: Cell<bool>,
    pub leaves_after: Cell<Option<u32>>,
    pub terminated: Cell<u32>,
    sigtermed: Cell<bool>,
    lookups: Cell<u32>,
}

impl FakeProcesses {
    pub fn new(process: ProcessIdentity) -> Self {
        Self {
            current: RefCell::new(Some(process)),
            deny: Cell::new(false),
            leaves_after: Cell::new(Some(0)),
            terminated: Cell::new(0),
            sigtermed: Cell::new(false),
            lookups: Cell::new(0),
        }
    }
}

impl ProcessControl for FakeProcesses {
    fn identity(&self, _pid: i32) -> Result<Option<ProcessIdentity>, Error> {
        if self.sigtermed.get() {
            self.lookups.set(self.lookups.get() + 1);
            if self
                .leaves_after
                .get()
                .is_some_and(|n| self.lookups.get() > n)
            {
                *self.current.borrow_mut() = None;
            }
        }
        Ok(self.current.borrow().clone())
    }

    fn terminate(&self, _pid: i32) -> Result<(), SignalError> {
        self.terminated.set(self.terminated.get() + 1);
        if self.deny.get() {
            return Err(SignalError::Denied("Operation not permitted".into()));
        }
        self.sigtermed.set(true);
        Ok(())
    }

    fn current_pid(&self) -> i32 {
        4242
    }

    fn current_uid(&self) -> u32 {
        OWN_UID
    }
}

/// A sleep that only records, so the grace period costs no time.
pub fn no_sleep() -> impl Fn(Duration) {
    |_| {}
}

#[cfg(test)]
mod tests {
    use serde_json::json;
    use symcockpit_contract::Outcome;
    use symcockpit_core::kill::{GRACE, KillAction, plan_kill_json};
    use symcockpit_core::plan::Engine;

    use super::*;
    use crate::storage_clean::{FixedClock, MemoryStore};

    fn run(fake: &FakeProcesses) -> symcockpit_core::plan::Report {
        let store = MemoryStore::default();
        let clock = FixedClock::new(1_000);
        let sleep = no_sleep();
        let action = KillAction {
            control: fake,
            grace: GRACE,
            sleep: &sleep,
        };
        let engine = Engine::new(&store, &clock).register(&action);
        let planned = plan_kill_json(&engine, fake, 321).unwrap();
        let id = planned["id"].as_str().unwrap().to_owned();
        engine.confirm(&id).unwrap()
    }

    #[test]
    fn planning_records_the_identity_and_touches_nothing() {
        let fake = FakeProcesses::new(identity(321, "Hog", 77));
        let store = MemoryStore::default();
        let clock = FixedClock::new(1_000);
        let engine = Engine::new(&store, &clock);
        let plan = plan_kill_json(&engine, &fake, 321).unwrap();
        assert_eq!(plan["kind"], "kill_process");
        assert_eq!(plan["items"][0]["target"], "Hog (pid 321)");
        assert_eq!(plan["items"][0]["identity"]["started_s"], 77);
        assert_eq!(fake.terminated.get(), 0, "planning must not signal");
    }

    #[test]
    fn planning_refuses_what_must_not_be_ended() {
        let fake = FakeProcesses::new(identity(321, "Hog", 77));
        let store = MemoryStore::default();
        let clock = FixedClock::new(1_000);
        let engine = Engine::new(&store, &clock);
        for pid in [0, 1, -5, 4242, 99_999_999_999] {
            let e = plan_kill_json(&engine, &fake, pid).unwrap_err();
            assert!(matches!(e, Error::Usage(_)), "{pid}: {e:?}");
        }
        // No such process (the fake only knows 321 but answers for any pid, so empty it).
        *fake.current.borrow_mut() = None;
        assert!(matches!(
            plan_kill_json(&engine, &fake, 321),
            Err(Error::Usage(_))
        ));
        // Another user's process: exit 3, no plan.
        let mut other = identity(321, "Root thing", 1);
        other.uid = 0;
        let fake = FakeProcesses::new(other);
        let e = plan_kill_json(&engine, &fake, 321).unwrap_err();
        assert_eq!(e.exit_code(), 3);
        assert!(store.is_empty());
    }

    #[test]
    fn a_process_that_leaves_is_confirmed() {
        let fake = FakeProcesses::new(identity(321, "Hog", 77));
        fake.leaves_after.set(Some(3));
        let report = run(&fake);
        assert_eq!(report.status, Outcome::Confirmed);
        assert_eq!(fake.terminated.get(), 1);
    }

    #[test]
    fn a_process_that_keeps_running_is_unconfirmed_never_killed_harder() {
        let fake = FakeProcesses::new(identity(321, "Hog", 77));
        fake.leaves_after.set(None);
        let report = run(&fake);
        assert_eq!(report.status, Outcome::Unconfirmed);
        assert!(
            report.results[0]
                .detail
                .as_deref()
                .unwrap()
                .contains("still running")
        );
        assert_eq!(
            fake.terminated.get(),
            1,
            "exactly one SIGTERM, no escalation"
        );
    }

    #[test]
    fn a_refusal_is_failed_with_the_reason() {
        let fake = FakeProcesses::new(identity(321, "Hog", 77));
        fake.deny.set(true);
        let report = run(&fake);
        assert_eq!(report.status, Outcome::Failed);
        assert!(
            report.results[0]
                .detail
                .as_deref()
                .unwrap()
                .contains("not permitted")
        );
    }

    #[test]
    fn a_reused_pid_is_skipped_without_a_signal() {
        let fake = FakeProcesses::new(identity(321, "Hog", 77));
        let store = MemoryStore::default();
        let clock = FixedClock::new(1_000);
        let sleep = no_sleep();
        let action = KillAction {
            control: &fake,
            grace: GRACE,
            sleep: &sleep,
        };
        let engine = Engine::new(&store, &clock).register(&action);
        let id = plan_kill_json(&engine, &fake, 321).unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        // Same id, different process (later start time).
        *fake.current.borrow_mut() = Some(identity(321, "Newcomer", 5_000));
        let report = engine.confirm(&id).unwrap();
        assert_eq!(report.status, Outcome::SkippedChanged);
        assert_eq!(fake.terminated.get(), 0);
        // And a process that exited in between.
        let again = plan_kill_json(&engine, &fake, 321).unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        *fake.current.borrow_mut() = None;
        let report = engine.confirm(&again).unwrap();
        assert_eq!(report.status, Outcome::SkippedChanged);
        assert_eq!(
            report.to_json()["results"][0]["detail"],
            json!("no longer running")
        );
    }

    /// The live table against a child this test starts and ends itself.
    #[test]
    fn live_control_ends_only_the_child_the_test_started() {
        use symcockpit_core::kill::GRACE;
        use symcockpit_macos::process::LiveProcessControl;

        let mut child = std::process::Command::new("/bin/sleep")
            .arg("60")
            .spawn()
            .unwrap();
        let pid = child.id() as i32;
        let control = LiveProcessControl;
        let store = MemoryStore::default();
        let clock = FixedClock::new(1_000);
        let sleep = |d: Duration| std::thread::sleep(d);
        let action = KillAction {
            control: &control,
            grace: GRACE,
            sleep: &sleep,
        };
        let engine = Engine::new(&store, &clock).register(&action);
        let plan = plan_kill_json(&engine, &control, i64::from(pid)).unwrap();
        let identity = &plan["items"][0]["identity"];
        assert_eq!(identity["path"], "/bin/sleep");
        assert!(identity["started_s"].as_i64().unwrap() > 0);
        // The child is a zombie after SIGTERM until it is reaped: the control
        // must already call that "gone".
        let report = engine.confirm(plan["id"].as_str().unwrap()).unwrap();
        let _ = child.wait();
        assert_eq!(report.status, Outcome::Confirmed, "{:?}", report.results);
        assert!(control.identity(pid).unwrap().is_none());
    }
}
