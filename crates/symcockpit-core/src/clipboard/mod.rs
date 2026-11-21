//! Clipboard history (R73, D13): for the human only, opt-in, encrypted.
//!
//! Nothing here is reachable from `symcockpit serve` or any agent profile: every command is
//! `human_only` and the CLI has no command that prints a clip. Capture runs later in the app
//! agent (the poller below plus the NSPasteboard adapter); reading clips back is for the app.
//!
//! Privacy order, checked before any content is read or any key or file is touched: feature
//! off, paused, secure pasteboard types, excluded source app. Only then is content read,
//! sealed with AES-256-GCM (key in the Keychain through a port) and stored.

mod commands;
mod crypto;
mod engine;
mod human;
mod settings;

pub use commands::{
    OpenStore, clipboard_clear_json, clipboard_pause_json, clipboard_resume_json,
    clipboard_status_json,
};
pub use crypto::{KEY_LEN, Key, open, random_key, seal};
pub use engine::{
    Capture, Clip, Outcome, Payload, Poller, SECURE_TYPES, SkipReason, decide, open_item,
};
pub use human::{
    base64, clip_copy_back, clip_delete_json, clip_list_json, clip_read_json, settings_json,
    update_settings,
};
pub use settings::{ClipboardSettings, DEFAULT_EXCLUDED_APPS};

use symcockpit_contract::Error;

/// Port: the data key, kept in the Keychain "this device only" by the live adapter.
pub trait KeyStore {
    /// The existing key, or a new one stored on first use.
    fn key(&self) -> Result<Key, Error>;
}

/// Port: persisted settings (a small JSON file in the clipboard directory).
pub trait SettingsStore {
    fn load(&self) -> Result<ClipboardSettings, Error>;
    fn save(&self, settings: &ClipboardSettings) -> Result<(), Error>;
}

/// What the store keeps per item in the clear: no content, no source app (those are sealed).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ItemMeta {
    pub id: String,
    pub created_at: i64,
    pub kind: Kind,
    /// Size of the plain payload in bytes.
    pub size: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Kind {
    Text,
    Image,
}

impl Kind {
    pub fn name(self) -> &'static str {
        match self {
            Kind::Text => "text",
            Kind::Image => "image",
        }
    }
    pub fn parse(s: &str) -> Option<Kind> {
        match s {
            "text" => Some(Kind::Text),
            "image" => Some(Kind::Image),
            _ => None,
        }
    }
}

/// An item ready to store: sealed payload, clear metadata.
#[derive(Clone, Debug)]
pub struct NewItem {
    pub meta: ItemMeta,
    pub sealed: Vec<u8>,
}

/// Port: the history store (SQLite plus attachment files in `symcockpit-db`).
pub trait ClipStore {
    fn insert(&self, item: &NewItem) -> Result<(), Error>;
    fn list(&self, limit: usize) -> Result<Vec<ItemMeta>, Error>;
    fn count(&self) -> Result<u64, Error>;
    fn read_sealed(&self, id: &str) -> Result<Option<Vec<u8>>, Error>;
    /// The clear metadata of one item; `None` when it is gone.
    fn meta(&self, id: &str) -> Result<Option<ItemMeta>, Error>;
    /// Removes one item (metadata first, then its attachment); `false` when it was not there.
    fn delete(&self, id: &str) -> Result<bool, Error>;
    /// Removes every item. Metadata first; attachment files only after that commit succeeded.
    fn delete_all(&self) -> Result<u64, Error>;
    /// Applies the retention rules; returns how many items went.
    fn prune(&self, now: i64, max_items: usize, max_age_secs: i64) -> Result<u64, Error>;
}

/// Port: what the platform shows about the pasteboard. Content is read only after the privacy
/// checks passed, so the fake in tests can prove nothing was read for a skipped copy.
pub trait PasteboardSource {
    /// `NSPasteboard.general.changeCount`.
    fn change_count(&self) -> i64;
    /// Type identifiers of the current item.
    fn types(&self) -> Vec<String>;
    /// Bundle id of the frontmost app: the best available stand-in for the copy's source.
    fn source_bundle_id(&self) -> Option<String>;
    fn read_text(&self) -> Option<String>;
    fn read_png(&self) -> Option<Vec<u8>>;
}

/// Port: keeps the clipboard directory out of Time Machine backups.
pub trait BackupExclusion {
    fn exclude(&self, path: &std::path::Path) -> Result<(), Error>;
}

/// Port: puts a clip back on the pasteboard (the human's "copy again"). Returns the new
/// change count so the poller can skip its own write instead of storing it a second time.
pub trait PasteboardSink {
    fn write_text(&self, text: &str) -> Result<i64, Error>;
    fn write_png(&self, png: &[u8]) -> Result<i64, Error>;
}
