//! macOS platform adapters.
//!
//! `unsafe` is permitted in this crate only (ADR 0004); every other workspace
//! crate forbids it. Keep each use behind a safe wrapper with its invariants
//! documented. This crate therefore opts out of the workspace `unsafe_code` lint.

pub mod apps;
pub mod battery;
pub mod bluetooth;
pub mod clipboard;
pub mod codesign;
pub mod coreaudio;
pub mod coremidi;
pub mod display;
pub mod display_write;
pub mod finder;
pub mod fs_stats;
pub mod gpu;
pub mod helper;
pub mod host;
pub mod input;
pub mod network;
pub mod nvme;
pub mod parent_check;
pub mod power;
pub mod powerui;
pub mod prefs;
pub mod process;
pub mod runloop;
pub mod signal;
pub mod smc;
pub mod system;
pub mod trash;
pub mod volumes;
pub mod xpc;
