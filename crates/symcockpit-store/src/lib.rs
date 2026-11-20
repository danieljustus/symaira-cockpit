//! Persisted data formats shared with v0.12. Read-only: nothing in this crate
//! creates, modifies or locks a file the Swift core owns.

mod config;
mod history;
mod paths;
mod profiles;
mod toml;

pub use config::{Config, Loaded, safety};
pub use history::{HistoryRecord, history_writable, parse_iso8601, read_history_records};
pub use paths::{Env, Paths};
pub use profiles::{Profile, read_profiles};
pub use toml::{Table, Value as TomlValue, parse as parse_toml};
