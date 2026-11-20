//! SMART measurements in `~/.local/share/symtune/cockpit.sqlite` (R30, R31).
//!
//! `rusqlite` with the bundled SQLite directly, same pin and features as
//! CoreKit's `symaira-core-sqlite`, which is not used because (a) its
//! migrations are SQL files in a `schema_migrations` table, while the
//! architecture (section 7) wants `user_version` migrations compiled in, and
//! (b) it pulls `symaira-core-fs` (nix, rustix, fs2, a git fetch of the
//! CoreKit workspace) to do what is 15 lines here: a 0700 parent directory,
//! WAL and a busy timeout. Revisit when CoreKit offers an embedded source.
//!
//! The raw 512-byte log page is stored next to the grade and `rules_version`,
//! so a later rule table can re-judge old measurements.

use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use rusqlite::{Connection, Transaction, TransactionBehavior, params};
use symcockpit_contract::Error;
use symcockpit_core::storage::health::{Grade, HistoryStore, Location, SmartSample};

/// Schema steps; step *n* takes `user_version` from *n* to *n + 1*. Each step
/// must be idempotent (`IF NOT EXISTS`): two processes may race, and other
/// areas of the same file keep their own steps in the same list.
pub const MIGRATIONS: &[&str] = &["
    CREATE TABLE IF NOT EXISTS smart_samples (
        id            INTEGER PRIMARY KEY,
        measured_at   INTEGER NOT NULL,
        device_key    TEXT    NOT NULL,
        model         TEXT    NOT NULL,
        firmware      TEXT    NOT NULL,
        location      TEXT    NOT NULL,
        rules_version INTEGER NOT NULL,
        grade         TEXT    NOT NULL CHECK (grade IN ('good', 'warning', 'critical')),
        page          BLOB    NOT NULL CHECK (length(page) = 512)
    );
    CREATE INDEX IF NOT EXISTS smart_samples_device_time ON smart_samples (device_key, measured_at DESC, id DESC);
"];

fn db_err(e: rusqlite::Error) -> Error {
    Error::Failed(format!("smart history: {e}"))
}

/// Bring `conn` to the latest of `steps`. A database written by a newer
/// version (`user_version` above `steps.len()`) is refused, not touched.
pub fn migrate(conn: &Connection, steps: &[&str]) -> Result<(), Error> {
    let version: i64 = conn
        .pragma_query_value(None, "user_version", |r| r.get(0))
        .map_err(db_err)?;
    if version > steps.len() as i64 {
        return Err(Error::Config(format!(
            "cockpit.sqlite is schema version {version}, this build knows {}",
            steps.len()
        )));
    }
    for (i, sql) in steps.iter().enumerate().skip(version as usize) {
        let tx =
            Transaction::new_unchecked(conn, TransactionBehavior::Immediate).map_err(db_err)?;
        tx.execute_batch(sql).map_err(db_err)?;
        tx.pragma_update(None, "user_version", i as i64 + 1)
            .map_err(db_err)?;
        tx.commit().map_err(db_err)?;
    }
    Ok(())
}

/// `$XDG_DATA_HOME/symtune/cockpit.sqlite`, else `$HOME/.local/share/symtune/cockpit.sqlite`.
pub fn default_path(xdg_data_home: Option<&str>, home: Option<&str>) -> Option<PathBuf> {
    let base = match xdg_data_home.filter(|p| Path::new(p).is_absolute()) {
        Some(x) => PathBuf::from(x),
        None => Path::new(home.filter(|h| !h.is_empty())?).join(".local/share"),
    };
    Some(base.join("symtune/cockpit.sqlite"))
}

pub struct SmartHistoryStore {
    conn: Connection,
}

impl SmartHistoryStore {
    /// Open (creating the 0700 parent directory and the file), enable WAL, migrate.
    pub fn open(path: &Path) -> Result<Self, Error> {
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            std::fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(parent)
                .map_err(|e| Error::Failed(format!("smart history: {}: {e}", parent.display())))?;
        }
        Self::init(Connection::open(path).map_err(db_err)?)
    }

    /// The default location from the process environment.
    pub fn open_default() -> Result<Self, Error> {
        let path = default_path(
            std::env::var("XDG_DATA_HOME").ok().as_deref(),
            std::env::var("HOME").ok().as_deref(),
        )
        .ok_or_else(|| Error::Config("HOME is not set".into()))?;
        Self::open(&path)
    }

    fn init(conn: Connection) -> Result<Self, Error> {
        conn.busy_timeout(Duration::from_secs(5)).map_err(db_err)?;
        conn.pragma_update(None, "journal_mode", "WAL")
            .map_err(db_err)?;
        migrate(&conn, MIGRATIONS)?;
        Ok(SmartHistoryStore { conn })
    }

    fn sample(r: &rusqlite::Row<'_>) -> rusqlite::Result<(SmartSample, String)> {
        let page: Vec<u8> = r.get(7)?;
        let location: String = r.get(4)?;
        let grade: String = r.get(6)?;
        let sample = SmartSample {
            measured_at: r.get(0)?,
            device_key: r.get(1)?,
            model: r.get(2)?,
            firmware: r.get(3)?,
            location: match location.as_str() {
                "internal" => Location::Internal,
                "external" => Location::External,
                _ => Location::Unknown,
            },
            rules_version: r.get(5)?,
            grade: Grade::Good,
            page: page.try_into().map_err(|_| rusqlite::Error::InvalidQuery)?,
        };
        Ok((sample, grade))
    }

    fn query(&self, sql: &str, args: &[&dyn rusqlite::ToSql]) -> Result<Vec<SmartSample>, Error> {
        let mut stmt = self.conn.prepare(sql).map_err(db_err)?;
        let rows = stmt.query_map(args, Self::sample).map_err(db_err)?;
        rows.map(|r| {
            let (mut s, grade) = r.map_err(db_err)?;
            s.grade = Grade::parse(&grade)
                .ok_or_else(|| Error::Failed(format!("smart history: unknown grade '{grade}'")))?;
            Ok(s)
        })
        .collect()
    }
}

const COLUMNS: &str =
    "measured_at, device_key, model, firmware, location, rules_version, grade, page";

impl HistoryStore for SmartHistoryStore {
    fn latest(&self, device_key: &str) -> Result<Option<SmartSample>, Error> {
        let sql = format!(
            "SELECT {COLUMNS} FROM smart_samples WHERE device_key = ?1 ORDER BY measured_at DESC, id DESC LIMIT 1"
        );
        Ok(self.query(&sql, &[&device_key])?.pop())
    }

    fn record(&self, s: &SmartSample) -> Result<(), Error> {
        self.conn
            .execute(
                &format!(
                    "INSERT INTO smart_samples ({COLUMNS}) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)"
                ),
                params![
                    s.measured_at,
                    s.device_key,
                    s.model,
                    s.firmware,
                    s.location.as_str(),
                    s.rules_version,
                    s.grade.as_str(),
                    &s.page[..]
                ],
            )
            .map(drop)
            .map_err(db_err)
    }

    fn list(&self, device_key: Option<&str>, limit: usize) -> Result<Vec<SmartSample>, Error> {
        let sql = format!(
            "SELECT {COLUMNS} FROM smart_samples WHERE (?1 IS NULL OR device_key = ?1) ORDER BY measured_at DESC, id DESC LIMIT ?2"
        );
        self.query(&sql, &[&device_key, &(limit as i64)])
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    fn sample(at: i64, key: &str, grade: Grade, tag: u8) -> SmartSample {
        let mut page = [0u8; 512];
        page[0] = tag;
        SmartSample {
            measured_at: at,
            device_key: key.into(),
            model: "TEST SSD".into(),
            firmware: "1.0".into(),
            location: Location::Internal,
            rules_version: 1,
            grade,
            page,
        }
    }

    fn store() -> (tempfile::TempDir, SmartHistoryStore) {
        let dir = tempfile::tempdir().unwrap();
        let s = SmartHistoryStore::open(&dir.path().join("sub/cockpit.sqlite")).unwrap();
        (dir, s)
    }

    #[test]
    fn open_creates_private_wal_database_at_user_version_1() {
        let (dir, s) = store();
        let mode = std::fs::metadata(dir.path().join("sub"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o700);
        let v: i64 = s
            .conn
            .pragma_query_value(None, "user_version", |r| r.get(0))
            .unwrap();
        assert_eq!(v, MIGRATIONS.len() as i64);
        let j: String = s
            .conn
            .pragma_query_value(None, "journal_mode", |r| r.get(0))
            .unwrap();
        assert_eq!(j, "wal");
    }

    #[test]
    fn record_latest_and_list_round_trip_raw_pages_newest_first() {
        let (_d, s) = store();
        for (at, key, tag) in [
            (10, "internal:A", 1),
            (20, "internal:A", 2),
            (15, "external:B", 3),
            (30, "internal:A", 4),
        ] {
            s.record(&sample(at, key, Grade::Warning, tag)).unwrap();
        }
        let latest = s.latest("internal:A").unwrap().unwrap();
        assert_eq!(
            (latest.measured_at, latest.page[0], latest.grade),
            (30, 4, Grade::Warning)
        );
        assert!(s.latest("nope").unwrap().is_none());
        let all: Vec<_> = s
            .list(None, 10)
            .unwrap()
            .iter()
            .map(|x| x.measured_at)
            .collect();
        assert_eq!(all, [30, 20, 15, 10]);
        let a: Vec<_> = s
            .list(Some("internal:A"), 2)
            .unwrap()
            .iter()
            .map(|x| x.measured_at)
            .collect();
        assert_eq!(a, [30, 20]);
    }

    #[test]
    fn rules_version_is_stored_with_each_measurement() {
        let (_d, s) = store();
        let mut x = sample(1, "internal:A", Grade::Good, 0);
        x.rules_version = 7;
        s.record(&x).unwrap();
        assert_eq!(s.latest("internal:A").unwrap().unwrap().rules_version, 7);
    }

    #[test]
    fn reopening_keeps_data_and_a_newer_database_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.sqlite");
        SmartHistoryStore::open(&path)
            .unwrap()
            .record(&sample(1, "internal:A", Grade::Good, 9))
            .unwrap();
        assert_eq!(
            SmartHistoryStore::open(&path)
                .unwrap()
                .latest("internal:A")
                .unwrap()
                .unwrap()
                .page[0],
            9
        );
        Connection::open(&path)
            .unwrap()
            .pragma_update(None, "user_version", 99)
            .unwrap();
        assert!(matches!(
            SmartHistoryStore::open(&path),
            Err(Error::Config(_))
        ));
    }

    #[test]
    fn migrate_applies_only_missing_steps_and_rolls_back_a_failing_one() {
        let conn = Connection::open_in_memory().unwrap();
        migrate(&conn, &["CREATE TABLE t (a)"]).unwrap();
        migrate(&conn, &["CREATE TABLE t (a)", "CREATE TABLE u (b)"]).unwrap();
        let bad = [
            "CREATE TABLE t (a)",
            "CREATE TABLE u (b)",
            "CREATE TABLE v (c); THIS IS NOT SQL",
        ];
        assert!(migrate(&conn, &bad).is_err());
        let v: i64 = conn
            .pragma_query_value(None, "user_version", |r| r.get(0))
            .unwrap();
        assert_eq!(v, 2);
        let v_exists: i64 = conn
            .query_row(
                "SELECT count(*) FROM sqlite_master WHERE name = 'v'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(v_exists, 0);
    }

    #[test]
    fn default_path_follows_xdg_then_home() {
        assert_eq!(
            default_path(Some("/x"), Some("/h")),
            Some("/x/symtune/cockpit.sqlite".into())
        );
        assert_eq!(
            default_path(Some("rel"), Some("/h")),
            Some("/h/.local/share/symtune/cockpit.sqlite".into())
        );
        assert_eq!(
            default_path(None, Some("/h")),
            Some("/h/.local/share/symtune/cockpit.sqlite".into())
        );
        assert_eq!(default_path(None, None), None);
    }
}
