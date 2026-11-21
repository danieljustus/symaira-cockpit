//! `cockpit.sqlite`: the one SQLite file of Cockpit 2 (architecture section 7).
//!
//! Opened through CoreKit's `symaira-core-sqlite` (0700 parent, WAL, busy
//! timeout, name-keyed `schema_migrations`), so each module owns its own
//! migration names instead of sharing one `user_version`. Separate from
//! `symcockpit-store` because core depends on store (read side) and these
//! adapters implement core traits.

use std::{io, path::Path};

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

/// The file lives at `<data dir>/cockpit.sqlite`; the data directory is the
/// one `symcockpit-store::Paths` resolves (or `--data-dir`), so there is one
/// place that knows where Cockpit keeps its data.
pub const FILE_NAME: &str = "cockpit.sqlite";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_file_holds_history_and_plans_in_wal_mode_and_reopens_cleanly() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("data").join(FILE_NAME);
        let tables = |conn: &Connection| -> Vec<String> {
            let mut stmt = conn
                .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
                .unwrap();
            stmt.query_map([], |r| r.get(0))
                .unwrap()
                .map(Result::unwrap)
                .collect()
        };
        let conn = open(&path).unwrap();
        let mode: String = conn
            .query_row("PRAGMA journal_mode", [], |r| r.get(0))
            .unwrap();
        assert_eq!(mode, "wal");
        let first = tables(&conn);
        assert!(first.contains(&"plans".to_owned()), "{first:?}");
        assert!(first.contains(&"smart_samples".to_owned()), "{first:?}");
        drop(conn);
        // A second open applies nothing twice.
        assert_eq!(tables(&open(&path).unwrap()), first);
    }
}
