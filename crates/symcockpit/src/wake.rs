//! What a process that holds overrides does when the system wakes from sleep: the agent and
//! `serve` (one-shot commands end before there is a wake to hear). macOS resets the gamma
//! table on wake and, on Apple Silicon, the SMC charge-inhibit bit, which silently cancels a
//! brightness boost, a warmth shift or a charge limit. v0.12's `serve` and the old app did the
//! same, through `reassertDisplayOverrides` and `reconcileChargeLimit`.
//!
//! The source reports on a thread of its own; the writers live on the main thread
//! (AppKit, thread-local `TuneWriter`). So the callback only queues an event and the main loop
//! calls [`after_wake`].

use symcockpit_core::wake::WakeSource;
use symcockpit_macos::wake::LiveWake;

use crate::app::Context;

/// Puts back what the system dropped. Main thread. Without a writer (no override held) the
/// display half has nothing to write, and without a tracked limit neither has the charge half.
pub fn after_wake(ctx: &Context) {
    crate::writes::reassert();
    crate::write::reassert_charge(ctx);
}

/// The live source, except in a debug binary a test started with the no-hardware switch.
pub fn live_source() -> Option<LiveWake> {
    crate::service_blocked("wake").ok().map(|()| LiveWake)
}

/// Starts watching; a source that cannot register is reported once and the process goes on
/// without wake handling, as v0.12 did.
pub fn watch(
    source: &dyn WakeSource,
    on_wake: impl Fn() + Send + Sync + 'static,
) -> Option<Box<dyn Send>> {
    match source.watch(Box::new(on_wake)) {
        Ok(guard) => Some(guard),
        Err(e) => {
            eprintln!("symcockpit: wake: {e}");
            None
        }
    }
}
