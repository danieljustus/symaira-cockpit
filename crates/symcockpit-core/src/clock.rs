//! Monotonic time and sleeping as a port, so the fan loops, the heartbeat
//! watchdog and the backoff are tested without waiting.

use std::sync::OnceLock;
use std::time::{Duration, Instant};

pub trait Monotonic {
    /// Milliseconds on a clock that never goes backwards (the Swift helper
    /// uses `systemUptime`).
    fn now_ms(&self) -> u64;
    fn sleep(&self, duration: Duration);
}

pub struct SystemMonotonic;

impl Monotonic for SystemMonotonic {
    fn now_ms(&self) -> u64 {
        static START: OnceLock<Instant> = OnceLock::new();
        START.get_or_init(Instant::now).elapsed().as_millis() as u64
    }

    fn sleep(&self, duration: Duration) {
        std::thread::sleep(duration);
    }
}

/// Never sleeps (the denied path of an unprivileged process has nothing to wait for).
pub struct NoSleep;

impl Monotonic for NoSleep {
    fn now_ms(&self) -> u64 {
        SystemMonotonic.now_ms()
    }

    fn sleep(&self, _: Duration) {}
}
