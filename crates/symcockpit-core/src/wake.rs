//! The system waking from sleep, as a port. macOS drops volatile state on the way (the gamma
//! table, and on Apple Silicon the SMC charge-inhibit bit), so a process that holds display
//! overrides or a charge limit puts them back when it hears this.
//!
//! The source calls `on_wake` on a thread of its own: the callback may only hand the event to
//! the owner of the writers (a channel send), never write itself.

use symcockpit_contract::Error;

pub trait WakeSource {
    /// Starts watching. Dropping the returned guard stops it.
    fn watch(&self, on_wake: Box<dyn Fn() + Send + Sync>) -> Result<Box<dyn Send>, Error>;
}
