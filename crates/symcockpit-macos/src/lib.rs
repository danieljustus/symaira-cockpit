//! macOS platform adapters.
//!
//! `unsafe` is permitted in this crate only (ADR 0004); every other workspace
//! crate forbids it. Keep each use behind a safe wrapper with its invariants
//! documented. This crate therefore opts out of the workspace `unsafe_code` lint.

pub mod battery;
pub mod display;
pub mod fs_stats;
pub mod gpu;
pub mod host;
pub mod network;
pub mod nvme;
pub mod power;
pub mod process;
pub mod smc;
pub mod system;
pub mod volumes;
