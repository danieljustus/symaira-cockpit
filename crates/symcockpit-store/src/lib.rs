//! Persisted data formats shared with v0.12. Read-only, with one exception:
//! `smc_restore` writes `smc-restore.json` (the privileged write path's
//! restore record, same format and modes as Swift). Nothing here locks or
//! modifies any other file the Swift core owns.

mod config;
mod history;
pub mod history_log;
mod paths;
mod profiles;
pub mod smc_restore;
pub mod state_perms;
mod toml;

pub use config::{Config, Loaded, safety};
pub use history::{HistoryRecord, history_writable, parse_iso8601, read_history_records};
pub use paths::{Env, Paths};
pub use profiles::{Profile, read_profiles};
pub use toml::{Table, Value as TomlValue, parse as parse_toml};
