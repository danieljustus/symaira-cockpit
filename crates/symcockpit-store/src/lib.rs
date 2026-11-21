//! Persisted data formats shared with v0.12. Reading never creates, modifies or
//! locks a file the Swift core owns; the few writers (history append, profiles,
//! the display restore record) keep the Swift file formats and modes.

mod config;
mod display_record;
mod history;
mod paths;
mod profiles;
mod state;
mod toml;

pub use config::{Config, Loaded, safety};
pub use display_record::{DisplayRestoreRecord, clear_record, read_record, write_record};
pub use history::{
    HistoryEvent, HistoryRecord, append_history_event, history_writable, parse_iso8601,
    read_history_records,
};
pub use paths::{Env, Paths};
pub use profiles::{
    Profile, delete_profile, is_valid_profile_name, read_profile, read_profiles, write_profile,
};
pub use state::{ensure_private_dir, secure_file, write_private_atomic};
pub use toml::{Table, Value as TomlValue, parse as parse_toml};
