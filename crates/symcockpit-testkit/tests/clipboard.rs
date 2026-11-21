//! Clipboard history end to end: engine, poller, encryption at rest, retention and deletion,
//! with the real SQLite store in a temp directory and fakes for Keychain, pasteboard and backup.

use std::{cell::Cell, fs, os::unix::fs::PermissionsExt, path::Path};

use serde_json::Value;
use symcockpit_core::clipboard::{
    Capture, Clip, ClipStore, ClipboardSettings, Outcome, Payload, Poller, SECURE_TYPES,
    SettingsStore, SkipReason, clipboard_clear_json, clipboard_pause_json, clipboard_resume_json,
    clipboard_status_json, open_item,
};
use symcockpit_db::clipboard::{JsonSettings, SqliteClipStore};
use symcockpit_testkit::clipboard::{FakeExclusion, FakeKeys, FakePasteboard};
use tempfile::TempDir;

const NOW: i64 = 1_800_000_000;
const SECRET: &str = "correct horse battery staple 7f3a9c";

struct Rig {
    _tmp: TempDir,
    dir: std::path::PathBuf,
    store: SqliteClipStore,
    settings: JsonSettings,
    keys: FakeKeys,
    exclusion: FakeExclusion,
    pb: FakePasteboard,
    poller: Poller,
    clock: Cell<i64>,
}

impl Rig {
    fn new() -> Rig {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path().join("clipboard");
        let exclusion = FakeExclusion::default();
        let store = SqliteClipStore::open(&dir, &exclusion).unwrap();
        let mut rig = Rig {
            settings: JsonSettings::new(&dir),
            dir,
            store,
            keys: FakeKeys::default(),
            exclusion,
            pb: FakePasteboard::default(),
            poller: Poller::default(),
            clock: Cell::new(NOW),
            _tmp: tmp,
        };
        // The first poll only takes the baseline.
        assert!(rig.poll().is_none());
        rig.keys.calls.set(0);
        rig
    }

    fn enable(&self) {
        let mut s = self.settings.load().unwrap();
        s.enabled = true;
        self.settings.save(&s).unwrap();
    }

    fn update(&self, f: impl FnOnce(&mut ClipboardSettings)) {
        let mut s = self.settings.load().unwrap();
        f(&mut s);
        self.settings.save(&s).unwrap();
    }

    fn poll(&mut self) -> Option<Outcome> {
        let capture = Capture {
            settings: &self.settings,
            keys: &self.keys,
            store: &self.store,
        };
        self.clock.set(self.clock.get() + 1);
        self.poller
            .poll(&self.pb, &capture, self.clock.get())
            .map(Result::unwrap)
    }

    /// Everything on disk, concatenated: the database, its WAL and the attachments.
    fn bytes_at_rest(&self) -> Vec<u8> {
        let mut all = Vec::new();
        for dir in [self.dir.clone(), self.dir.join("attachments")] {
            for e in fs::read_dir(dir).unwrap().flatten() {
                if e.path().is_file() && e.file_name() != "settings.json" {
                    all.extend(fs::read(e.path()).unwrap());
                }
            }
        }
        all
    }
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}

#[test]
fn off_by_default_nothing_is_read_keyed_or_stored() {
    let mut r = Rig::new();
    r.pb.copy_text("com.apple.TextEdit", SECRET);
    assert_eq!(r.poll(), Some(Outcome::Skipped(SkipReason::Disabled)));
    assert_eq!(r.store.count().unwrap(), 0);
    assert_eq!(r.pb.content_reads.get(), 0, "content was not even read");
    assert_eq!(r.keys.calls.get(), 0, "no key was fetched or created");
}

#[test]
fn an_enabled_copy_is_stored_sealed_and_readable_by_the_human() {
    let mut r = Rig::new();
    r.enable();
    r.pb.copy_text("com.apple.TextEdit", SECRET);
    let Some(Outcome::Stored(id)) = r.poll() else {
        panic!("not stored")
    };
    let items = r.store.list(10).unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(
        (items[0].id.as_str(), items[0].size),
        (id.as_str(), SECRET.len() as u64)
    );
    let clip = open_item(&r.keys, &r.store, &items[0]).unwrap().unwrap();
    assert_eq!(
        clip,
        Clip {
            source: Some("com.apple.TextEdit".into()),
            payload: Payload::Text(SECRET.into())
        }
    );
    let at_rest = r.bytes_at_rest();
    assert!(
        !contains(&at_rest, SECRET.as_bytes()),
        "the content is on disk in the clear"
    );
    assert!(
        !contains(&at_rest, b"com.apple.TextEdit"),
        "the source app is on disk in the clear"
    );
}

#[test]
fn a_blob_opens_only_with_the_key_it_was_sealed_with() {
    let mut r = Rig::new();
    r.enable();
    r.pb.copy_text("a.b", "one");
    r.poll();
    r.pb.copy_text("a.b", "two");
    r.poll();
    let items = r.store.list(10).unwrap();
    assert_eq!(items.len(), 2);
    // Another device's key cannot open anything.
    let other = FakeKeys::default();
    assert!(open_item(&other, &r.store, &items[0]).unwrap().is_none());
}

#[test]
fn pause_stops_capture_and_resume_restarts_it_without_enabling() {
    let mut r = Rig::new();
    r.enable();
    clipboard_pause_json(&r.settings).unwrap();
    r.pb.copy_text("a.b", "while paused");
    assert_eq!(r.poll(), Some(Outcome::Skipped(SkipReason::Paused)));
    assert_eq!((r.store.count().unwrap(), r.pb.content_reads.get()), (0, 0));
    let v = clipboard_resume_json(&r.settings).unwrap();
    assert_eq!(v["paused"], false);
    r.pb.copy_text("a.b", "after resume");
    assert!(matches!(r.poll(), Some(Outcome::Stored(_))));
    // `resume` on a disabled feature does not switch it on.
    let off = Rig::new();
    clipboard_resume_json(&off.settings).unwrap();
    assert!(!off.settings.load().unwrap().enabled);
}

#[test]
fn excluded_source_apps_are_never_stored_or_read() {
    let mut r = Rig::new();
    r.enable();
    r.pb.copy_text("com.1password.1password", SECRET);
    assert_eq!(r.poll(), Some(Outcome::Skipped(SkipReason::ExcludedApp)));
    r.update(|s| s.excluded_apps = vec!["org.example.Vault".into()]);
    r.pb.copy_text("org.example.Vault", SECRET);
    assert_eq!(r.poll(), Some(Outcome::Skipped(SkipReason::ExcludedApp)));
    assert_eq!(
        (
            r.store.count().unwrap(),
            r.pb.content_reads.get(),
            r.keys.calls.get()
        ),
        (0, 0, 0)
    );
}

#[test]
fn concealed_transient_and_autogenerated_content_is_never_stored() {
    for secure in SECURE_TYPES {
        let mut r = Rig::new();
        r.enable();
        r.pb.copy(
            &["public.utf8-plain-text", secure],
            Some("com.apple.TextEdit"),
            Some(SECRET),
            None,
        );
        assert_eq!(
            r.poll(),
            Some(Outcome::Skipped(SkipReason::SecureType)),
            "{secure}"
        );
        assert_eq!(
            (
                r.store.count().unwrap(),
                r.pb.content_reads.get(),
                r.keys.calls.get()
            ),
            (0, 0, 0),
            "{secure}"
        );
        assert!(!contains(&r.bytes_at_rest(), SECRET.as_bytes()));
    }
}

#[test]
fn what_was_on_the_clipboard_before_the_first_poll_is_never_read() {
    let mut r = Rig::new();
    r.enable();
    // The Rig polled once at start; a fresh poller on a pasteboard that already has content.
    r.poller = Poller::default();
    r.pb.copy_text("a.b", "was already there");
    assert!(r.poll().is_none());
    assert_eq!(r.pb.content_reads.get(), 0);
    assert_eq!(r.store.count().unwrap(), 0);
}

#[test]
fn unsupported_empty_and_oversized_content_is_skipped() {
    let mut r = Rig::new();
    r.enable();
    r.update(|s| s.max_item_bytes = 10);
    r.pb.copy(&["public.tiff"], Some("a.b"), None, None);
    assert_eq!(
        r.poll(),
        Some(Outcome::Skipped(SkipReason::NoSupportedType))
    );
    r.pb.copy(&["public.utf8-plain-text"], Some("a.b"), Some(""), None);
    assert_eq!(r.poll(), Some(Outcome::Skipped(SkipReason::Empty)));
    r.pb.copy_text("a.b", "this text is longer than ten bytes");
    assert_eq!(r.poll(), Some(Outcome::Skipped(SkipReason::Oversized)));
    assert_eq!(r.store.count().unwrap(), 0);
}

#[test]
fn images_go_to_sealed_attachment_files_and_clear_removes_them_and_the_metadata() {
    let mut r = Rig::new();
    r.enable();
    let png: Vec<u8> = (0..200_000u32).map(|i| (i % 251) as u8).collect();
    r.pb.copy(
        &["public.png"],
        Some("com.apple.Preview"),
        None,
        Some(png.clone()),
    );
    assert!(matches!(r.poll(), Some(Outcome::Stored(_))));
    let attachments: Vec<_> = fs::read_dir(r.dir.join("attachments"))
        .unwrap()
        .flatten()
        .collect();
    assert_eq!(attachments.len(), 1);
    assert!(
        !contains(&fs::read(attachments[0].path()).unwrap(), &png[1000..1064]),
        "sealed on disk"
    );
    let item = r.store.list(1).unwrap().remove(0);
    let clip = open_item(&r.keys, &r.store, &item).unwrap().unwrap();
    assert_eq!(clip.payload, Payload::Png(png));
    let open = || {
        Ok(Some(
            Box::new(SqliteClipStore::open_existing(&r.dir).unwrap().unwrap())
                as Box<dyn ClipStore>,
        ))
    };
    assert_eq!(clipboard_clear_json(&open).unwrap()["cleared"], 1);
    assert_eq!(r.store.count().unwrap(), 0);
    assert_eq!(fs::read_dir(r.dir.join("attachments")).unwrap().count(), 0);
}

#[test]
fn retention_keeps_the_newest_items_and_drops_old_ones() {
    let mut r = Rig::new();
    r.enable();
    r.update(|s| s.max_items = 3);
    for i in 0..5 {
        r.pb.copy_text("a.b", &format!("item {i}"));
        assert!(matches!(r.poll(), Some(Outcome::Stored(_))));
    }
    let items = r.store.list(10).unwrap();
    assert_eq!(items.len(), 3);
    let texts: Vec<_> = items
        .iter()
        .map(
            |m| match open_item(&r.keys, &r.store, m).unwrap().unwrap().payload {
                Payload::Text(t) => t,
                Payload::Png(_) => unreachable!(),
            },
        )
        .collect();
    assert_eq!(texts, ["item 4", "item 3", "item 2"]);
    // Age: a day-old limit drops everything older than that on the next capture.
    r.update(|s| {
        s.max_items = 100;
        s.max_age_secs = 3600;
    });
    r.clock.set(NOW + 7200);
    r.pb.copy_text("a.b", "fresh");
    assert!(matches!(r.poll(), Some(Outcome::Stored(_))));
    assert_eq!(r.store.count().unwrap(), 1);
}

#[test]
fn status_reports_counts_never_content_and_creates_nothing() {
    let mut r = Rig::new();
    r.enable();
    r.pb.copy_text("a.b", SECRET);
    r.poll();
    let open = || {
        SqliteClipStore::open_existing(&r.dir).map(|s| s.map(|s| Box::new(s) as Box<dyn ClipStore>))
    };
    let status = clipboard_status_json(&r.settings, &open).unwrap();
    assert_eq!(
        (
            status["items"].as_u64(),
            status["enabled"].as_bool(),
            status["capturing"].as_bool()
        ),
        (Some(1), Some(true), Some(true))
    );
    assert!(!status.to_string().contains(SECRET));
    // No history yet: status says zero and must not create the directory.
    let empty = TempDir::new().unwrap();
    let nothing = empty.path().join("clipboard");
    let open_none = || {
        SqliteClipStore::open_existing(&nothing)
            .map(|s| s.map(|s| Box::new(s) as Box<dyn ClipStore>))
    };
    let status = clipboard_status_json(&JsonSettings::new(&nothing), &open_none).unwrap();
    assert_eq!(
        (status["items"].as_u64(), status["enabled"].as_bool()),
        (Some(0), Some(false))
    );
    assert!(!nothing.exists());
    assert_eq!(clipboard_clear_json(&open_none).unwrap()["cleared"], 0);
    assert!(!nothing.exists());
}

#[test]
fn storage_is_private_excluded_from_backups_and_a_damaged_settings_file_means_off() {
    let r = Rig::new();
    let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(&r.dir), 0o700);
    assert_eq!(mode(&r.dir.join("attachments")), 0o700);
    assert_eq!(*r.exclusion.excluded.borrow(), std::slice::from_ref(&r.dir));
    r.enable();
    assert_eq!(mode(&r.dir.join("settings.json")), 0o600);
    fs::write(r.dir.join("settings.json"), b"{ not json").unwrap();
    assert!(!r.settings.load().unwrap().enabled);
    fs::write(r.dir.join("settings.json"), br#"{"enabled": "true"}"#).unwrap();
    assert!(!r.settings.load().unwrap().enabled);
    let v: Value =
        serde_json::from_str(&clipboard_pause_json(&r.settings).unwrap().to_string()).unwrap();
    assert_eq!(v["paused"], true);
}

#[test]
fn the_four_commands_match_their_shape_snapshots() {
    use symcockpit_testkit::snapshot::check;
    let mut r = Rig::new();
    r.enable();
    r.pb.copy_text("a.b", SECRET);
    r.poll();
    let open = || {
        SqliteClipStore::open_existing(&r.dir).map(|s| s.map(|s| Box::new(s) as Box<dyn ClipStore>))
    };
    check(
        "clipboard",
        "clipboard.status",
        &clipboard_status_json(&r.settings, &open).unwrap(),
    );
    check(
        "clipboard",
        "clipboard.pause",
        &clipboard_pause_json(&r.settings).unwrap(),
    );
    check(
        "clipboard",
        "clipboard.resume",
        &clipboard_resume_json(&r.settings).unwrap(),
    );
    check(
        "clipboard",
        "clipboard.clear",
        &clipboard_clear_json(&open).unwrap(),
    );
}
