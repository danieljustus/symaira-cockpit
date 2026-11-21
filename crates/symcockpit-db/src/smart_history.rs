//! SMART measurements in `cockpit.sqlite` (R30, R31).
//!
//! The raw 512-byte log page is stored next to the grade and `rules_version`,
//! so a later rule table can re-judge old measurements.

use std::path::Path;

use rusqlite::params;
use symaira_core_sqlite::Connection;
use symcockpit_contract::Error;
use symcockpit_core::storage::health::{Grade, HistoryStore, Location, SmartSample};

pub(crate) const MIGRATIONS: &[(&str, &str)] = &[(
    "smart_0001.sql",
    "CREATE TABLE smart_samples (
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
    CREATE INDEX smart_samples_device_time ON smart_samples (device_key, measured_at DESC, id DESC);",
)];

fn db_err(e: rusqlite::Error) -> Error {
    Error::Failed(format!("smart history: {e}"))
}

pub struct SmartHistoryStore {
    conn: Connection,
}

impl SmartHistoryStore {
    /// Open (creating the 0700 parent directory and the file), enable WAL, migrate.
    pub fn open(path: &Path) -> Result<Self, Error> {
        Ok(SmartHistoryStore {
            conn: crate::open(path)?,
        })
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
    fn open_creates_private_wal_database_with_named_migrations() {
        let (dir, s) = store();
        let mode = std::fs::metadata(dir.path().join("sub"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o700);
        let j: String = s
            .conn
            .pragma_query_value(None, "journal_mode", |r| r.get(0))
            .unwrap();
        assert_eq!(j, "wal");
        let applied: i64 = s
            .conn
            .query_row(
                "SELECT count(*) FROM schema_migrations WHERE version = 'smart_0001'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(applied, 1);
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
    fn reopening_keeps_data_and_does_not_reapply_migrations() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.sqlite");
        SmartHistoryStore::open(&path)
            .unwrap()
            .record(&sample(1, "internal:A", Grade::Good, 9))
            .unwrap();
        let again = SmartHistoryStore::open(&path).unwrap();
        assert_eq!(again.latest("internal:A").unwrap().unwrap().page[0], 9);
        let n: i64 = again
            .conn
            .query_row("SELECT count(*) FROM schema_migrations", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, crate::all_migrations().len() as i64);
    }
}
