//! Audio devices, default devices, volume, formats, aggregates and per-app
//! volume (R40 to R44). Ports in `hal` and `mixer`; the live adapters are in
//! `symcockpit-macos::coreaudio`, the fakes in `symcockpit-testkit::audio`.

pub mod cli;
pub mod commands;
mod hal;
pub mod mixer;
mod registry;
mod service;

pub use hal::*;
pub use registry::{Changes, DeviceHandle, DeviceRecord, DeviceRegistry};
pub use service::{
    ActionReport, AudioAction, AudioPlan, AudioPlanAction, AudioService, Readback, VOLUME_TOLERANCE,
};
