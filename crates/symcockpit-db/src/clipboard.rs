//! The clipboard history store (R73): its own SQLite file `clipboard.sqlite` plus attachment
//! files, in `~/.local/share/symtune/clipboard/`, never in `cockpit.sqlite`.
//!
//! Content is sealed before it gets here (AES-GCM in `symcockpit-core`); this module only
//! stores blobs and clear metadata. Small blobs live in the row, large ones (images) in
//! `attachments/<id>.bin`. Deleting follows the architecture 7 rule: the metadata commit
//! comes first, attachment files are removed only after it succeeded, and files no row points
//! at (a crash in between) are swept at the next open.

use std::{
    collections::HashSet,
    fs, io,
    io::Write,
    os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::Mutex,
};

use rusqlite::{OptionalExtension, params};
use symaira_core_sqlite::{Connection, Entry, MigrationSource};
use symcockpit_contract::Error;
use symcockpit_core::clipboard::{BackupExclusion, ClipStore, ItemMeta, Kind, NewItem};

/// Blobs up to this size stay in the row.
const INLINE_MAX: usize = 64 * 1024;
const DB_FILE: &str = "clipboard.sqlite";
const MIGRATIONS: &[(&str, &str)] = &[(
    "clipboard_0001.sql",
    "CREATE TABLE items (
        id TEXT PRIMARY KEY,
        created_at INTEGER NOT NULL,
        kind TEXT NOT NULL,
        size INTEGER NOT NULL,
        sealed BLOB,
        attachment TEXT
    ) STRICT;
    CREATE INDEX items_created ON items(created_at);",
)];

struct Migrations;

impl MigrationSource for Migrations {
    fn entries(&self) -> io::Result<Vec<Entry>> {
        Ok(MIGRATIONS
            .iter()
            .map(|(name, _)| Entry {
                name: (*name).to_owned(),
                is_dir: false,
            })
            .collect())
    }
    fn read(&self, name: &str) -> io::Result<Vec<u8>> {
        MIGRATIONS
            .iter()
            .find(|(n, _)| *n == name)
            .map(|(_, sql)| sql.as_bytes().to_vec())
            .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))
    }
}

fn failed(e: impl std::fmt::Display) -> Error {
    Error::Failed(format!("clipboard store: {e}"))
}

pub struct SqliteClipStore {
    conn: Mutex<Connection>,
    attachments: PathBuf,
}

impl SqliteClipStore {
    /// Opens or creates the history in `dir` (0700), marks it excluded from backups.
    pub fn open(dir: &Path, exclusion: &dyn BackupExclusion) -> Result<Self, Error> {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)
            .map_err(failed)?;
        exclusion.exclude(dir)?;
        Self::open_in(dir)
    }

    /// Opens the history only when it exists; never creates anything (used by `status` and `clear`).
    pub fn open_existing(dir: &Path) -> Result<Option<Self>, Error> {
        if !dir.join(DB_FILE).is_file() {
            return Ok(None);
        }
        Self::open_in(dir).map(Some)
    }

    fn open_in(dir: &Path) -> Result<Self, Error> {
        let attachments = dir.join("attachments");
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&attachments)
            .map_err(failed)?;
        let mut conn = symaira_core_sqlite::open(dir.join(DB_FILE)).map_err(failed)?;
        symaira_core_sqlite::migrate(&mut conn, &Migrations).map_err(failed)?;
        let store = Self {
            conn: Mutex::new(conn),
            attachments,
        };
        store.sweep_orphans()?;
        Ok(store)
    }

    fn conn(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Removes attachment files no row refers to: leftovers of a crash between commit and cleanup.
    pub fn sweep_orphans(&self) -> Result<u64, Error> {
        let referenced: HashSet<String> = {
            let conn = self.conn();
            let mut stmt = conn
                .prepare("SELECT attachment FROM items WHERE attachment IS NOT NULL")
                .map_err(failed)?;
            stmt.query_map([], |r| r.get::<_, String>(0))
                .map_err(failed)?
                .filter_map(Result::ok)
                .collect()
        };
        let mut removed = 0;
        for entry in fs::read_dir(&self.attachments).map_err(failed)?.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !referenced.contains(&name) && fs::remove_file(entry.path()).is_ok() {
                removed += 1;
            }
        }
        Ok(removed)
    }

    fn remove_files(&self, names: &[String]) {
        // A failure leaves an orphan; the next open sweeps it.
        for n in names {
            let _ = fs::remove_file(self.attachments.join(n));
        }
    }

    /// Writes `name` without ever replacing an existing file (a clash is an error).
    fn write_attachment(&self, name: &str, bytes: &[u8]) -> io::Result<()> {
        let tmp = self.attachments.join(format!(".{name}.tmp"));
        let mut f = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        let linked = fs::hard_link(&tmp, self.attachments.join(name));
        let _ = fs::remove_file(&tmp);
        linked
    }

    /// Deletes `ids` in one transaction and removes their attachment files after the commit.
    fn delete_ids(&self, ids: &[String]) -> Result<u64, Error> {
        let names = {
            let mut conn = self.conn();
            let tx = conn.transaction().map_err(failed)?;
            let mut names = Vec::new();
            for id in ids {
                let name: Option<Option<String>> = tx
                    .query_row("SELECT attachment FROM items WHERE id = ?1", [id], |r| {
                        r.get(0)
                    })
                    .optional()
                    .map_err(failed)?;
                tx.execute("DELETE FROM items WHERE id = ?1", [id])
                    .map_err(failed)?;
                names.extend(name.flatten());
            }
            tx.commit().map_err(failed)?;
            names
        };
        self.remove_files(&names);
        Ok(ids.len() as u64)
    }
}

impl ClipStore for SqliteClipStore {
    fn insert(&self, item: &NewItem) -> Result<(), Error> {
        let m = &item.meta;
        let (inline, attachment) = if item.sealed.len() <= INLINE_MAX {
            (Some(item.sealed.as_slice()), None)
        } else {
            let name = format!("{}.bin", m.id);
            self.write_attachment(&name, &item.sealed).map_err(failed)?;
            (None, Some(name))
        };
        let inserted = self.conn().execute(
            "INSERT INTO items (id, created_at, kind, size, sealed, attachment) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![m.id, m.created_at, m.kind.name(), m.size as i64, inline, attachment],
        );
        if let Err(e) = inserted {
            self.remove_files(attachment.as_slice());
            return Err(failed(e));
        }
        Ok(())
    }

    fn list(&self, limit: usize) -> Result<Vec<ItemMeta>, Error> {
        let conn = self.conn();
        let mut stmt = conn
            .prepare("SELECT id, created_at, kind, size FROM items ORDER BY created_at DESC, rowid DESC LIMIT ?1")
            .map_err(failed)?;
        let rows = stmt
            .query_map([limit as i64], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, i64>(3)?,
                ))
            })
            .map_err(failed)?;
        Ok(rows
            .filter_map(Result::ok)
            .filter_map(|(id, created_at, kind, size)| {
                Some(ItemMeta {
                    id,
                    created_at,
                    kind: Kind::parse(&kind)?,
                    size: size as u64,
                })
            })
            .collect())
    }

    fn count(&self) -> Result<u64, Error> {
        self.conn()
            .query_row("SELECT COUNT(*) FROM items", [], |r| r.get::<_, i64>(0))
            .map(|n| n as u64)
            .map_err(failed)
    }

    fn read_sealed(&self, id: &str) -> Result<Option<Vec<u8>>, Error> {
        let row: Option<(Option<Vec<u8>>, Option<String>)> = self
            .conn()
            .query_row(
                "SELECT sealed, attachment FROM items WHERE id = ?1",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()
            .map_err(failed)?;
        match row {
            None => Ok(None),
            Some((Some(blob), _)) => Ok(Some(blob)),
            // The name comes from our own row; keep it a plain file name anyway.
            Some((None, Some(name))) if !name.contains('/') => {
                fs::read(self.attachments.join(name))
                    .map(Some)
                    .map_err(failed)
            }
            Some(_) => Ok(None),
        }
    }

    fn delete_all(&self) -> Result<u64, Error> {
        let ids: Vec<String> = {
            let conn = self.conn();
            let mut stmt = conn.prepare("SELECT id FROM items").map_err(failed)?;
            stmt.query_map([], |r| r.get(0))
                .map_err(failed)?
                .filter_map(Result::ok)
                .collect()
        };
        let n = self.delete_ids(&ids)?;
        self.sweep_orphans()?;
        Ok(n)
    }

    fn prune(&self, now: i64, max_items: usize, max_age_secs: i64) -> Result<u64, Error> {
        let ids: Vec<String> = {
            let conn = self.conn();
            let mut stmt = conn
                .prepare(
                    "SELECT id FROM items WHERE created_at < ?1 OR id NOT IN
                     (SELECT id FROM items ORDER BY created_at DESC, rowid DESC LIMIT ?2)",
                )
                .map_err(failed)?;
            stmt.query_map(params![now - max_age_secs, max_items as i64], |r| r.get(0))
                .map_err(failed)?
                .filter_map(Result::ok)
                .collect()
        };
        self.delete_ids(&ids)
    }
}

/// `settings.json` in the clipboard directory (0600, replaced atomically).
pub struct JsonSettings {
    path: PathBuf,
}

impl JsonSettings {
    pub fn new(dir: &Path) -> Self {
        Self {
            path: dir.join("settings.json"),
        }
    }
}

impl symcockpit_core::clipboard::SettingsStore for JsonSettings {
    fn load(&self) -> Result<symcockpit_core::clipboard::ClipboardSettings, Error> {
        use symcockpit_core::clipboard::ClipboardSettings;
        match fs::read(&self.path) {
            Ok(bytes) => Ok(serde_json::from_slice(&bytes)
                .map(|v| ClipboardSettings::from_json(&v))
                // A damaged file means "off": never guess a feature into being.
                .unwrap_or_default()),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(ClipboardSettings::default()),
            Err(e) => Err(failed(e)),
        }
    }

    fn save(&self, settings: &symcockpit_core::clipboard::ClipboardSettings) -> Result<(), Error> {
        let dir = self.path.parent().ok_or_else(|| failed("no parent"))?;
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)
            .map_err(failed)?;
        let tmp = dir.join(".settings.json.tmp");
        let mut f = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)
            .map_err(failed)?;
        f.write_all(settings.to_json().to_string().as_bytes())
            .map_err(failed)?;
        f.sync_all().map_err(failed)?;
        fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600)).map_err(failed)?;
        fs::rename(&tmp, &self.path).map_err(failed)
    }
}

/// Where the history lives: `<data dir>/clipboard`, next to `cockpit.sqlite`
/// in the data directory `symcockpit-store::Paths` resolves (or `--data-dir`).
pub fn dir_in(data_dir: &Path) -> PathBuf {
    data_dir.join("clipboard")
}

#[cfg(test)]
mod tests {
    use symcockpit_core::clipboard::{ClipStore, ItemMeta, Kind, NewItem};
    use tempfile::TempDir;

    use super::*;

    struct NoExclusion;
    impl BackupExclusion for NoExclusion {
        fn exclude(&self, _: &Path) -> Result<(), Error> {
            Ok(())
        }
    }

    fn item(id: &str, size: usize) -> NewItem {
        NewItem {
            meta: ItemMeta {
                id: id.into(),
                created_at: 1,
                kind: Kind::Image,
                size: size as u64,
            },
            sealed: vec![7; size],
        }
    }

    fn files(dir: &Path) -> usize {
        fs::read_dir(dir.join("attachments")).unwrap().count()
    }

    #[test]
    fn attachments_are_removed_only_after_the_metadata_commit_succeeded() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path().join("clip");
        let store = SqliteClipStore::open(&dir, &NoExclusion).unwrap();
        store.insert(&item("a", INLINE_MAX + 1)).unwrap();
        store.insert(&item("b", 10)).unwrap();
        assert_eq!((store.count().unwrap(), files(&dir)), (2, 1));
        // A trigger makes every DELETE fail, so the transaction cannot commit.
        let blocker = Connection::open(dir.join(DB_FILE)).unwrap();
        blocker
            .execute_batch("CREATE TRIGGER no_delete BEFORE DELETE ON items BEGIN SELECT RAISE(ABORT, 'blocked'); END;")
            .unwrap();
        assert!(store.delete_all().is_err());
        assert_eq!(
            (store.count().unwrap(), files(&dir)),
            (2, 1),
            "nothing was cleaned up"
        );
        assert!(
            store.read_sealed("a").unwrap().is_some(),
            "the item is still readable"
        );
        // Once the commit can succeed, rows and files go, in that order.
        blocker.execute_batch("DROP TRIGGER no_delete").unwrap();
        assert_eq!(store.delete_all().unwrap(), 2);
        assert_eq!((store.count().unwrap(), files(&dir)), (0, 0));
    }

    #[test]
    fn orphaned_attachments_are_swept_at_open_and_referenced_ones_stay() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path().join("clip");
        let store = SqliteClipStore::open(&dir, &NoExclusion).unwrap();
        store.insert(&item("kept", INLINE_MAX + 1)).unwrap();
        fs::write(dir.join("attachments/orphan.bin"), b"left by a crash").unwrap();
        drop(store);
        let store = SqliteClipStore::open(&dir, &NoExclusion).unwrap();
        assert_eq!(files(&dir), 1);
        assert_eq!(
            store.read_sealed("kept").unwrap().unwrap().len(),
            INLINE_MAX + 1
        );
    }

    #[test]
    fn a_failed_insert_leaves_no_attachment_behind() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path().join("clip");
        let store = SqliteClipStore::open(&dir, &NoExclusion).unwrap();
        store.insert(&item("dup", INLINE_MAX + 1)).unwrap();
        let again = NewItem {
            sealed: vec![1; INLINE_MAX + 5],
            ..item("dup", INLINE_MAX + 5)
        };
        assert!(store.insert(&again).is_err(), "primary key");
        assert_eq!(files(&dir), 1);
        assert_eq!(
            store.read_sealed("dup").unwrap().unwrap().len(),
            INLINE_MAX + 1
        );
    }

    #[test]
    fn open_existing_never_creates_and_the_dir_is_not_cockpit_sqlite() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path().join("clip");
        assert!(SqliteClipStore::open_existing(&dir).unwrap().is_none());
        assert!(!dir.exists());
        SqliteClipStore::open(&dir, &NoExclusion).unwrap();
        assert!(SqliteClipStore::open_existing(&dir).unwrap().is_some());
        assert!(dir.join("clipboard.sqlite").is_file() && !dir.join("cockpit.sqlite").exists());
        assert_eq!(
            dir_in(Path::new("/data/symtune")),
            Path::new("/data/symtune/clipboard")
        );
    }
}
