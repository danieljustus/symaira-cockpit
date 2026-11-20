//! `cockpit.sqlite`: the one SQLite file of Cockpit 2 (architecture section 7).
//!
//! Opened through CoreKit's `symaira-core-sqlite` (0700 parent, WAL, busy
//! timeout, name-keyed `schema_migrations`), so each module owns its own
//! migration names instead of sharing one `user_version`. Separate from
//! `symcockpit-store` because core depends on store (read side) and these
//! adapters implement core traits.

use std::{
    io,
    path::{Path, PathBuf},
};

use symaira_core_sqlite::{Connection, Entry, MigrationSource};
use symcockpit_contract::Error;

pub mod plans;
pub mod smart_history;

fn all_migrations() -> Vec<(&'static str, &'static str)> {
    [smart_history::MIGRATIONS, plans::MIGRATIONS].concat()
}

struct Migrations;

impl MigrationSource for Migrations {
    fn entries(&self) -> io::Result<Vec<Entry>> {
        Ok(all_migrations()
            .iter()
            .map(|(name, _)| Entry {
                name: (*name).to_owned(),
                is_dir: false,
            })
            .collect())
    }

    fn read(&self, name: &str) -> io::Result<Vec<u8>> {
        all_migrations()
            .iter()
            .find(|(n, _)| *n == name)
            .map(|(_, sql)| sql.as_bytes().to_vec())
            .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))
    }
}

/// Open `path` and apply every module's missing migrations.
pub fn open(path: &Path) -> Result<Connection, Error> {
    let fail = |e: symaira_core_sqlite::Error| Error::Failed(format!("cockpit.sqlite: {e}"));
    let mut conn = symaira_core_sqlite::open(path).map_err(fail)?;
    symaira_core_sqlite::migrate(&mut conn, &Migrations).map_err(fail)?;
    Ok(conn)
}

/// `$XDG_DATA_HOME/symtune/cockpit.sqlite`, else `$HOME/.local/share/symtune/cockpit.sqlite`.
pub fn default_path(xdg_data_home: Option<&str>, home: Option<&str>) -> Result<PathBuf, Error> {
    let base = match xdg_data_home.filter(|p| Path::new(p).is_absolute()) {
        Some(x) => PathBuf::from(x),
        None => Path::new(
            home.filter(|h| !h.is_empty())
                .ok_or_else(|| Error::Config("HOME is not set".into()))?,
        )
        .join(".local/share"),
    };
    Ok(base.join("symtune/cockpit.sqlite"))
}
