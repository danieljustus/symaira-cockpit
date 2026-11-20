//! SQLite storage of plans in `cockpit.sqlite` (architecture §7).
//!
//! The file is shared with other modules (SMART measurements, ...); see
//! `crate::open`. This module only touches the `plans` table.

use std::{path::Path, sync::Mutex};

use serde_json::Value;
use symaira_core_sqlite::Connection;
use symcockpit_contract::Error;
use symcockpit_core::plan::{PlanStore, StoredPlan};

/// Confirmed and expired plans stay readable this long (`plan show`).
const KEEP_SECS: i64 = 24 * 3600;

pub(crate) const MIGRATIONS: &[(&str, &str)] = &[(
    "plans_0001.sql",
    "CREATE TABLE plans (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        digest TEXT NOT NULL,
        items TEXT NOT NULL,
        confirmed_at INTEGER,
        results TEXT
    ) STRICT;",
)];

fn failed(e: impl std::fmt::Display) -> Error {
    Error::Failed(format!("plan store: {e}"))
}

pub struct SqlitePlanStore {
    conn: Mutex<Connection>,
}

impl SqlitePlanStore {
    /// Opens (creating the 0700 parent and the table when needed).
    pub fn open(path: &Path) -> Result<Self, Error> {
        let conn = crate::open(path)?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    fn conn(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|p| p.into_inner())
    }
}

impl PlanStore for SqlitePlanStore {
    fn insert(&self, p: &StoredPlan) -> Result<(), Error> {
        let conn = self.conn();
        conn.execute(
            "DELETE FROM plans WHERE expires_at < ?1",
            [p.created_at - KEEP_SECS],
        )
        .map_err(failed)?;
        conn.execute(
            "INSERT INTO plans (id, kind, created_at, expires_at, digest, items) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            (
                &p.id,
                &p.kind,
                p.created_at,
                p.expires_at,
                &p.digest,
                Value::Array(p.items.clone()).to_string(),
            ),
        )
        .map_err(failed)?;
        Ok(())
    }

    fn load(&self, id: &str) -> Result<Option<StoredPlan>, Error> {
        type Row = (
            String,
            String,
            i64,
            i64,
            String,
            String,
            Option<i64>,
            Option<String>,
        );
        let conn = self.conn();
        let mut stmt = conn
            .prepare("SELECT id, kind, created_at, expires_at, digest, items, confirmed_at, results FROM plans WHERE id = ?1")
            .map_err(failed)?;
        let row: Option<Row> = stmt
            .query_map([id], |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get(5)?,
                    r.get(6)?,
                    r.get(7)?,
                ))
            })
            .map_err(failed)?
            .next()
            .transpose()
            .map_err(failed)?;
        let Some((id, kind, created_at, expires_at, digest, items, confirmed_at, results)) = row
        else {
            return Ok(None);
        };
        let items: Vec<Value> = serde_json::from_str(&items).map_err(failed)?;
        let results = results
            .map(|r| serde_json::from_str(&r))
            .transpose()
            .map_err(failed)?;
        Ok(Some(StoredPlan {
            id,
            kind,
            created_at,
            expires_at,
            digest,
            items,
            confirmed_at,
            results,
        }))
    }

    fn claim(&self, id: &str, at: i64) -> Result<bool, Error> {
        let n = self
            .conn()
            .execute(
                "UPDATE plans SET confirmed_at = ?2 WHERE id = ?1 AND confirmed_at IS NULL",
                (id, at),
            )
            .map_err(failed)?;
        Ok(n == 1)
    }

    fn finish(&self, id: &str, results: &Value) -> Result<(), Error> {
        self.conn()
            .execute(
                "UPDATE plans SET results = ?2 WHERE id = ?1",
                (id, results.to_string()),
            )
            .map_err(failed)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn plan(id: &str, created: i64) -> StoredPlan {
        StoredPlan {
            id: id.into(),
            kind: "clean".into(),
            created_at: created,
            expires_at: created + 300,
            digest: "d".into(),
            items: vec![json!({"action": "trash", "target": "/x"})],
            confirmed_at: None,
            results: None,
        }
    }

    #[test]
    fn round_trip_claim_once_and_purge() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("data/cockpit.sqlite");
        let store = SqlitePlanStore::open(&db).unwrap();
        let p = plan("a", 1_000);
        store.insert(&p).unwrap();
        assert_eq!(store.load("a").unwrap().unwrap(), p);
        assert!(store.load("nope").unwrap().is_none());
        assert!(store.claim("a", 1_010).unwrap());
        assert!(!store.claim("a", 1_011).unwrap());
        store.finish("a", &json!({"status": "confirmed"})).unwrap();
        let got = store.load("a").unwrap().unwrap();
        assert_eq!(got.confirmed_at, Some(1_010));
        assert_eq!(got.results, Some(json!({"status": "confirmed"})));
        // Reopening keeps the data and the migration is not applied twice.
        drop(store);
        let again = SqlitePlanStore::open(&db).unwrap();
        assert!(again.load("a").unwrap().is_some());
        // A plan older than the retention window is purged on the next insert.
        again.insert(&plan("b", 1_000 + KEEP_SECS + 301)).unwrap();
        assert!(again.load("a").unwrap().is_none());
        assert!(again.load("b").unwrap().is_some());
    }
}
