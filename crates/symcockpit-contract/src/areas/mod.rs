//! Command specifications per functional area. Every area exposes
//! `specs()`; [`all`] chains them in a fixed order and the register appends
//! the result to the v0.12 commands. A new area is one module, one line here.

pub mod audio;
pub mod bluetooth;
pub mod clipboard;
pub mod finder;
pub mod input;
pub mod processes;
pub mod storage_clean;
pub mod storage_health;

use crate::CommandSpec;

/// The commands of every area, in a stable order.
pub fn all() -> Vec<CommandSpec> {
    [
        storage_health::specs(),
        storage_clean::specs(),
        audio::specs(),
        bluetooth::specs(),
        input::specs(),
        processes::specs(),
    ]
    .concat()
}
