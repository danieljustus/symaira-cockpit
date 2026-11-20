//! macOS platform adapters.
//!
//! `unsafe` is permitted in this crate only (ADR 0004); every other workspace
//! crate forbids it. Keep each use behind a safe wrapper with its invariants
//! documented. This crate therefore opts out of the workspace `unsafe_code` lint.

pub mod smc;
pub mod battery;
pub mod power;
pub mod display;
