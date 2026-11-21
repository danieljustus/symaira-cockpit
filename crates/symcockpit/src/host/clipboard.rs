//! Clipboard capture and the human's access to the history (R73, D13), hosted by the agent.
//!
//! One thread owns the pasteboard source, the Keychain key and the SQLite store. It polls the
//! pasteboard only while the feature is on and not paused: with the opt-in off, or paused, it
//! sleeps until a request and never touches the pasteboard (Q04). Nothing here is reachable from
//! `serve` or the CLI; the agent methods in `host::mod` are the only door.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{Map, Value, json};
use symcockpit_contract::Error;
use symcockpit_core::clipboard::{
    BackupExclusion, Capture, ClipStore, KeyStore, Outcome, PasteboardSink, PasteboardSource,
    Poller, SettingsStore, clip_copy_back, clip_delete_json, clip_list_json, clip_read_json,
    settings_json, update_settings,
};
use symcockpit_core::plan::{Clock, SystemClock};
use symcockpit_db::clipboard::{JsonSettings, SqliteClipStore};

use super::actor::{Actor, Service};

/// The platform side, built on the clipboard thread.
pub struct ClipboardParts {
    pub source: Box<dyn PasteboardSource>,
    pub sink: Box<dyn PasteboardSink>,
    pub keys: Box<dyn KeyStore>,
    pub exclusion: Box<dyn BackupExclusion>,
}

pub type MakeParts = Arc<dyn Fn() -> Result<ClipboardParts, Error> + Send + Sync>;

/// How often the pasteboard's change counter is looked at while capturing.
pub const POLL: Duration = Duration::from_millis(500);
const ANSWER: Duration = Duration::from_secs(20);

pub enum Req {
    /// Settings may have changed (the CLI writes the same file): start or stop capturing.
    Reconcile,
    Status,
    List {
        limit: usize,
    },
    Read {
        id: String,
    },
    Copy {
        id: String,
    },
    Delete {
        id: String,
    },
    Settings,
    Configure(Map<String, Value>),
}

struct Clipboard {
    dir: PathBuf,
    make: MakeParts,
    parts: Option<Result<ClipboardParts, Error>>,
    settings: JsonSettings,
    store: Option<SqliteClipStore>,
    /// `Some` exactly while capturing.
    poller: Option<Poller>,
    interval: Duration,
    stored: u64,
    skipped: u64,
    last_error: Option<String>,
}

type Resp = Result<Value, Error>;

impl Clipboard {
    fn parts(&mut self) -> Result<&ClipboardParts, Error> {
        let make = Arc::clone(&self.make);
        self.parts
            .get_or_insert_with(|| make())
            .as_ref()
            .map_err(Clone::clone)
    }

    /// The history, opened only if it exists (nothing is created for a read or a delete).
    fn existing_store(&mut self) -> Result<Option<&SqliteClipStore>, Error> {
        if self.store.is_none() {
            self.store = SqliteClipStore::open_existing(&self.dir)?;
        }
        Ok(self.store.as_ref())
    }

    fn reconcile(&mut self) -> Result<(), Error> {
        if !self.settings.load()?.capturing() {
            self.poller = None;
            return Ok(());
        }
        if self.poller.is_some() {
            return Ok(());
        }
        let started = (|| {
            self.parts()?;
            if self.store.is_none() {
                self.ensure_parts()?;
                if let Some(Ok(parts)) = &self.parts {
                    self.store = Some(SqliteClipStore::open(&self.dir, &*parts.exclusion)?);
                }
            }
            Ok::<(), Error>(())
        })();
        match started {
            Ok(()) => {
                self.last_error = None;
                // The baseline is taken by the first poll: what was on the pasteboard before
                // capturing started is never read.
                self.poller = Some(Poller::default());
                Ok(())
            }
            Err(e) => {
                self.last_error = Some(e.to_string());
                Err(e)
            }
        }
    }

    fn state(&self) -> &'static str {
        match (&self.poller, &self.last_error) {
            (Some(_), _) => "capturing",
            (None, Some(_)) => "failed",
            (None, None) => "idle",
        }
    }

    fn status(&mut self) -> Resp {
        let s = self.settings.load()?;
        let items = match self.existing_store()? {
            Some(store) => store.count()?,
            None => 0,
        };
        Ok(json!({
            "state": self.state(), "enabled": s.enabled, "paused": s.paused,
            "items": items, "stored_this_session": self.stored,
            "skipped_this_session": self.skipped, "last_error": self.last_error,
        }))
    }

    fn ensure_parts(&mut self) -> Result<(), Error> {
        self.parts().map(|_| ())
    }

    /// The platform side and the existing history, or an error when there is no such item.
    fn ready(&mut self, id: &str) -> Result<(&ClipboardParts, &SqliteClipStore), Error> {
        if self.existing_store()?.is_none() {
            return Err(gone(id));
        }
        self.ensure_parts()?;
        match (&self.parts, &self.store) {
            (Some(Ok(parts)), Some(store)) => Ok((parts, store)),
            _ => Err(gone(id)),
        }
    }
}

impl Service for Clipboard {
    type Req = Req;
    type Resp = Resp;

    fn handle(&mut self, req: Req) -> Resp {
        match req {
            Req::Reconcile => {
                // A failure to start is reported in the status, not as a failed request.
                let _ = self.reconcile();
                Ok(json!({}))
            }
            Req::Status => self.status(),
            Req::List { limit } => match self.existing_store()? {
                Some(store) => clip_list_json(store, limit),
                None => Ok(json!({"count": 0, "items": []})),
            },
            Req::Read { id } => {
                let (parts, store) = self.ready(&id)?;
                clip_read_json(&*parts.keys, store, &id)
            }
            Req::Copy { id } => {
                let count = {
                    let (parts, store) = self.ready(&id)?;
                    clip_copy_back(&*parts.keys, store, &*parts.sink, &id)?
                };
                // Our own write is not a new copy.
                if let Some(poller) = &mut self.poller {
                    poller.ignore_change(count);
                }
                Ok(json!({"id": id, "copied": true}))
            }
            Req::Delete { id } => match self.existing_store()? {
                Some(store) => clip_delete_json(store, &id),
                None => Ok(json!({"id": id, "deleted": false})),
            },
            Req::Settings => settings_json(&self.settings),
            Req::Configure(patch) => {
                let updated = update_settings(&self.settings, &patch)?;
                let _ = self.reconcile();
                let mut out = updated.to_json();
                out["state"] = json!(self.state());
                out["last_error"] = json!(self.last_error);
                Ok(out)
            }
        }
    }

    fn wake_in(&self) -> Option<Duration> {
        self.poller.is_some().then_some(self.interval)
    }

    fn tick(&mut self) {
        let Some(mut poller) = self.poller.take() else {
            return;
        };
        let (Some(Ok(parts)), Some(store)) = (&self.parts, &self.store) else {
            return;
        };
        let capture = Capture {
            settings: &self.settings,
            keys: &*parts.keys,
            store,
        };
        match poller.poll(&*parts.source, &capture, SystemClock.now()) {
            None => {}
            Some(Ok(Outcome::Stored(_))) => self.stored += 1,
            Some(Ok(Outcome::Skipped(_))) => self.skipped += 1,
            Some(Err(e)) => self.last_error = Some(e.to_string()),
        }
        self.poller = Some(poller);
        // The settings file may have been changed behind our back (`clipboard pause`).
        if !self.settings.load().is_ok_and(|s| s.capturing()) {
            self.poller = None;
        }
    }
}

fn gone(id: &str) -> Error {
    Error::Failed(format!("clipboard item {id} is gone"))
}

pub struct ClipboardHandle {
    actor: Actor<Clipboard>,
}

impl ClipboardHandle {
    pub fn spawn(dir: PathBuf, make: MakeParts, interval: Duration) -> Self {
        let settings = JsonSettings::new(&dir);
        Self {
            actor: Actor::spawn("symcockpit-clipboard", move || Clipboard {
                dir,
                make,
                parts: None,
                settings,
                store: None,
                poller: None,
                interval,
                stored: 0,
                skipped: 0,
                last_error: None,
            }),
        }
    }

    pub fn call(&self, req: Req) -> Result<Value, Error> {
        self.actor.request(req, ANSWER)?
    }

    pub fn stop(&self) {
        self.actor.stop();
    }
}

#[cfg(test)]
mod tests {
    use std::time::Instant;

    use symcockpit_testkit::clipboard::{FakeExclusion, FakeKeys, SharedPasteboard};

    use super::*;

    struct Rig {
        tmp: tempfile::TempDir,
        pasteboard: SharedPasteboard,
        handle: ClipboardHandle,
    }

    impl Rig {
        fn dir(&self) -> PathBuf {
            self.tmp.path().join("clipboard")
        }
        fn call(&self, req: Req) -> Value {
            self.handle.call(req).unwrap()
        }
        fn configure(&self, patch: Value) -> Value {
            self.call(Req::Configure(patch.as_object().unwrap().clone()))
        }
        fn status(&self) -> Value {
            self.call(Req::Status)
        }
        /// Applies a setting that starts capturing and waits for the poller's baseline: a copy
        /// made before that is, by design, part of the baseline and never stored.
        fn start_capturing(&self, patch: Value) -> Value {
            let before = self.pasteboard.reads();
            let out = self.configure(patch);
            eventually("the poller took its baseline", || {
                self.pasteboard.reads() > before
            });
            out
        }
        fn items(&self) -> Vec<Value> {
            self.call(Req::List { limit: 50 })["items"]
                .as_array()
                .unwrap()
                .clone()
        }
    }

    fn rig() -> Rig {
        let tmp = tempfile::tempdir().unwrap();
        let pasteboard = SharedPasteboard::default();
        let board = pasteboard.clone();
        let key = symcockpit_core::clipboard::random_key();
        let make: MakeParts = Arc::new(move || {
            Ok(ClipboardParts {
                source: Box::new(board.clone()),
                sink: Box::new(board.clone()),
                keys: Box::new(FakeKeys::with_key(key)),
                exclusion: Box::new(FakeExclusion::default()),
            })
        });
        let handle =
            ClipboardHandle::spawn(tmp.path().join("clipboard"), make, Duration::from_millis(5));
        Rig {
            tmp,
            pasteboard,
            handle,
        }
    }

    fn eventually(what: &str, check: impl Fn() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !check() {
            assert!(Instant::now() < deadline, "timed out waiting for: {what}");
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    /// Lets the thread poll a few times, so "nothing happened" means something.
    fn settle() {
        std::thread::sleep(Duration::from_millis(80));
    }

    #[test]
    fn off_by_default_nothing_is_read_and_nothing_is_created() {
        let r = rig();
        r.pasteboard.copy_text("com.example.editor", "before");
        r.call(Req::Reconcile);
        r.pasteboard.copy_text("com.example.editor", "during");
        settle();
        assert_eq!(
            r.pasteboard.reads(),
            0,
            "the pasteboard was not even looked at"
        );
        assert_eq!(r.pasteboard.content_reads(), 0);
        assert!(!r.dir().exists(), "no directory, no database");
        assert_eq!(r.status()["state"], "idle");
        assert_eq!(r.items().len(), 0);
    }

    #[test]
    fn switching_it_on_captures_new_copies_and_never_what_was_there_before() {
        let r = rig();
        r.pasteboard
            .copy_text("com.example.editor", "old secret from before");
        let out = r.start_capturing(json!({"enabled": true}));
        assert_eq!(out["state"], "capturing");
        r.pasteboard.copy_text("com.example.editor", "first");
        eventually("the copy is stored", || r.items().len() == 1);
        assert_eq!(
            r.pasteboard.content_reads(),
            1,
            "only the new copy's content was read, never the old one"
        );
        let id = r.items()[0]["id"].as_str().unwrap().to_owned();
        // The list is metadata: no text, no source app.
        let meta = &r.items()[0];
        assert_eq!(meta["kind"], "text");
        assert!(meta.get("text").is_none() && meta.get("source").is_none());
        // Only reading names the content.
        let read = r.call(Req::Read { id: id.clone() });
        assert_eq!(read["text"], "first");
        assert_eq!(read["source"], "com.example.editor");
        // The text is sealed on disk.
        let db = std::fs::read(r.dir().join("clipboard.sqlite")).unwrap();
        assert!(!db.windows(5).any(|w| w == b"first"));
        assert_eq!(r.status()["stored_this_session"], 1);
    }

    #[test]
    fn paused_or_switched_off_it_stops_looking_at_the_pasteboard() {
        let r = rig();
        r.start_capturing(json!({"enabled": true}));
        r.pasteboard.copy_text("a.b", "one");
        eventually("one is stored", || r.items().len() == 1);
        let out = r.configure(json!({"paused": true}));
        assert_eq!(out["state"], "idle");
        let reads = r.pasteboard.reads();
        r.pasteboard.copy_text("a.b", "while paused");
        settle();
        assert_eq!(r.pasteboard.reads(), reads, "paused: not a single read");
        assert_eq!(r.items().len(), 1);
        // Resuming starts a new baseline: what was copied while paused is never captured.
        r.start_capturing(json!({"paused": false}));
        r.pasteboard.copy_text("a.b", "two");
        eventually("two is stored", || r.items().len() == 2);
        assert_eq!(
            r.pasteboard.content_reads(),
            2,
            "'while paused' was never read"
        );
        let out = r.configure(json!({"enabled": false}));
        assert_eq!(out["state"], "idle");
        let reads = r.pasteboard.reads();
        settle();
        assert_eq!(r.pasteboard.reads(), reads);
    }

    #[test]
    fn secret_types_and_excluded_apps_are_never_stored_or_read() {
        let r = rig();
        r.start_capturing(json!({"enabled": true}));
        r.pasteboard.copy_secret("com.example.editor", "hunter2");
        r.pasteboard
            .copy_text("com.1password.1password", "vault entry");
        settle();
        r.pasteboard.copy_text("com.example.editor", "fine");
        eventually("the ordinary copy is stored", || r.items().len() == 1);
        assert_eq!(
            r.pasteboard.content_reads(),
            1,
            "the other two were decided before reading"
        );
        assert_eq!(
            r.call(Req::Read {
                id: r.items()[0]["id"].as_str().unwrap().into()
            })["text"],
            "fine"
        );
    }

    #[test]
    fn copying_back_does_not_store_it_again_and_delete_removes_one_item() {
        let r = rig();
        r.start_capturing(json!({"enabled": true}));
        r.pasteboard.copy_text("a.b", "keep");
        r.pasteboard.copy_text("a.b", "drop me");
        eventually("something is stored", || !r.items().is_empty());
        r.pasteboard.copy_text("a.b", "third");
        eventually("three states seen or fewer", || r.items().len() >= 2);
        let items = r.items();
        let newest = items[0]["id"].as_str().unwrap().to_owned();
        let before = items.len();
        let copied = r.call(Req::Copy { id: newest.clone() });
        assert_eq!(copied["copied"], true);
        assert_eq!(r.pasteboard.writes().len(), 1);
        settle();
        assert_eq!(r.items().len(), before, "our own write is not a new copy");
        let deleted = r.call(Req::Delete { id: newest.clone() });
        assert_eq!(deleted["deleted"], true);
        assert_eq!(r.items().len(), before - 1);
        assert_eq!(r.call(Req::Delete { id: newest.clone() })["deleted"], false);
        assert!(r.handle.call(Req::Read { id: newest }).is_err());
    }

    #[test]
    fn settings_are_validated_and_survive_in_the_file() {
        let r = rig();
        let bad = r.handle.call(Req::Configure(
            json!({"enabled": "yes"}).as_object().unwrap().clone(),
        ));
        assert!(matches!(bad, Err(Error::Usage(_))));
        r.configure(json!({"max_items": 3, "excluded_apps": ["x.y"]}));
        let s = r.call(Req::Settings);
        assert_eq!(
            (s["max_items"].as_u64(), s["enabled"].as_bool()),
            (Some(3), Some(false))
        );
        assert_eq!(s["excluded_apps"], json!(["x.y"]));
        let on_disk: Value =
            serde_json::from_slice(&std::fs::read(r.dir().join("settings.json")).unwrap()).unwrap();
        assert_eq!(on_disk["max_items"], 3);
    }

    #[test]
    fn an_unavailable_platform_is_reported_as_the_state_not_swallowed() {
        let tmp = tempfile::tempdir().unwrap();
        let handle = ClipboardHandle::spawn(
            tmp.path().join("clipboard"),
            Arc::new(|| {
                Err(Error::Unsupported(
                    "the clipboard history is disabled here".into(),
                ))
            }),
            Duration::from_millis(5),
        );
        let out = handle
            .call(Req::Configure(
                json!({"enabled": true}).as_object().unwrap().clone(),
            ))
            .unwrap();
        assert_eq!(out["state"], "failed");
        assert!(
            out["last_error"]
                .as_str()
                .unwrap()
                .contains("disabled here")
        );
        assert!(
            !tmp.path()
                .join("clipboard")
                .join("clipboard.sqlite")
                .exists()
        );
        assert!(handle.call(Req::Read { id: "x".into() }).is_err());
    }
}
