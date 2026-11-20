//! SIGINT, SIGTERM and SIGHUP only raise a flag; the foreground loop polls it
//! and does the cleanup on its own thread (nothing async-signal-unsafe runs in
//! the handler).

use std::sync::atomic::{AtomicBool, Ordering};

static STOP: AtomicBool = AtomicBool::new(false);

extern "C" fn on_signal(_signal: i32) {
    STOP.store(true, Ordering::SeqCst);
}

unsafe extern "C" {
    fn signal(signum: i32, handler: usize) -> usize;
}

pub fn install_signal_handlers() {
    for sig in [1, 2, 15] {
        // SAFETY: `on_signal` only performs an atomic store, which is async-signal-safe.
        unsafe { signal(sig, on_signal as *const () as usize) };
    }
}

/// True once the process was asked to stop.
pub fn interrupted() -> bool {
    STOP.load(Ordering::SeqCst)
}
