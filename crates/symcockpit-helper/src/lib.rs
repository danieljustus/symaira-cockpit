//! The privileged helper (root, launchd Mach service `com.symaira.symtune-helper`).
//!
//! This crate is glue: [`Service`] puts the platform-free engine
//! (`symcockpit_core::helper_engine`) behind the XPC transport and a polling
//! loop. It reaches the platform only through `symcockpit-macos` and contains
//! no `unsafe` (ADR 0004).

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use symcockpit_core::clock::{Monotonic, SystemMonotonic};
use symcockpit_core::helper_engine::{Engine, idle_should_exit};
use symcockpit_macos::helper::reply_to;
use symcockpit_macos::xpc::{Handler, Hooks};

/// How often the engine is polled (watchdog, lease, governor tick). Finer than
/// the watchdog's one-second cadence, so a stop is never a second late.
pub const POLL_INTERVAL: Duration = Duration::from_millis(200);
/// How long an idle helper (no client, no governor, fans restored) lingers
/// before it exits; launchd starts the current binary on the next lookup.
pub const IDLE_EXIT_GRACE: Duration = Duration::from_secs(5);

pub struct Service {
    engine: Arc<Mutex<Engine>>,
    connections: Arc<AtomicUsize>,
}

fn lock(engine: &Mutex<Engine>) -> MutexGuard<'_, Engine> {
    // A poisoned engine is still the only thing that knows how to hand the fans back.
    engine.lock().unwrap_or_else(|e| e.into_inner())
}

impl Service {
    pub fn new(engine: Engine) -> Self {
        Self {
            engine: Arc::new(Mutex::new(engine)),
            connections: Arc::new(AtomicUsize::new(0)),
        }
    }

    /// Request text in, reply text out. Unknown actions and versions are
    /// answered with an error and never reach the engine.
    pub fn handler(&self) -> Handler {
        let engine = self.engine.clone();
        Arc::new(move |text| reply_to(text, |request| lock(&engine).handle(request)))
    }

    /// Connection bookkeeping: when the last client goes away nothing is left
    /// to send heartbeats, so a running governor ends (its owner is gone).
    pub fn hooks(&self) -> Hooks {
        let (up, down) = (self.connections.clone(), self.connections.clone());
        let engine = self.engine.clone();
        Hooks {
            on_connect: Some(Arc::new(move || {
                up.fetch_add(1, Ordering::SeqCst);
            })),
            on_disconnect: Some(Arc::new(move || {
                if down.fetch_sub(1, Ordering::SeqCst) == 1 {
                    lock(&engine).connection_invalidated();
                }
            })),
        }
    }

    /// At launch, before serving: recover what a dead predecessor left behind.
    pub fn recover_stale(&self) -> Vec<String> {
        let mut engine = lock(&self.engine);
        engine.recover_stale();
        std::mem::take(&mut engine.log)
    }

    /// One scheduling step; returns the log lines it produced.
    pub fn poll(&self) -> Vec<String> {
        let mut engine = lock(&self.engine);
        engine.poll();
        std::mem::take(&mut engine.log)
    }

    /// SIGTERM: the fans are back before this returns.
    pub fn terminate(&self) -> Vec<String> {
        let mut engine = lock(&self.engine);
        engine.terminate();
        std::mem::take(&mut engine.log)
    }

    pub fn is_governing(&self) -> bool {
        lock(&self.engine).is_governing()
    }

    pub fn has_connection(&self) -> bool {
        self.connections.load(Ordering::SeqCst) > 0
    }
}

/// Why [`run`] returned.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Exit {
    Terminated,
    Idle,
}

/// The helper's main loop. `log` gets every line for launchd's log (stderr).
pub fn run(
    service: &Service,
    terminated: &dyn Fn() -> bool,
    clock: &dyn Monotonic,
    log: &dyn Fn(&str),
) -> Exit {
    let mut idle_since = Some(clock.now_ms());
    loop {
        if terminated() {
            service.terminate().iter().for_each(|l| log(l));
            return Exit::Terminated;
        }
        service.poll().iter().for_each(|l| log(l));
        let now = clock.now_ms();
        if service.is_governing() || service.has_connection() {
            idle_since = None;
        } else {
            let since = *idle_since.get_or_insert(now);
            if idle_should_exit(
                false,
                false,
                now - since,
                IDLE_EXIT_GRACE.as_millis() as u64,
            ) {
                return Exit::Idle;
            }
        }
        clock.sleep(POLL_INTERVAL);
    }
}

/// The monotonic clock of the real helper.
pub fn system_clock() -> SystemMonotonic {
    SystemMonotonic
}
