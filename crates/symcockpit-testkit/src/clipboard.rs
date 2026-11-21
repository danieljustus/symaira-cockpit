//! Fakes for the clipboard ports: no Keychain, no NSPasteboard, no Time Machine.

use std::{
    cell::{Cell, RefCell},
    path::{Path, PathBuf},
};

use symcockpit_contract::Error;
use symcockpit_core::clipboard::{BackupExclusion, Key, KeyStore, PasteboardSource, random_key};

/// A key kept in memory; counts how often it was asked for (it must stay 0 when nothing is stored).
pub struct FakeKeys {
    key: Key,
    pub calls: Cell<u32>,
}

impl Default for FakeKeys {
    fn default() -> Self {
        Self {
            key: random_key(),
            calls: Cell::new(0),
        }
    }
}

impl FakeKeys {
    pub fn with_key(key: Key) -> Self {
        Self {
            key,
            calls: Cell::new(0),
        }
    }
}

impl KeyStore for FakeKeys {
    fn key(&self) -> Result<Key, Error> {
        self.calls.set(self.calls.get() + 1);
        Ok(self.key)
    }
}

#[derive(Default)]
pub struct FakeExclusion {
    pub excluded: RefCell<Vec<PathBuf>>,
}

impl BackupExclusion for FakeExclusion {
    fn exclude(&self, path: &Path) -> Result<(), Error> {
        self.excluded.borrow_mut().push(path.to_path_buf());
        Ok(())
    }
}

/// A pasteboard the test drives. `content_reads` counts reads of the actual content: the
/// privacy rules must decide before it goes up.
#[derive(Default)]
pub struct FakePasteboard {
    change_count: Cell<i64>,
    types: RefCell<Vec<String>>,
    source: RefCell<Option<String>>,
    text: RefCell<Option<String>>,
    png: RefCell<Option<Vec<u8>>>,
    pub content_reads: Cell<u32>,
}

impl FakePasteboard {
    /// Someone copies something: bumps the change count.
    pub fn copy(
        &self,
        types: &[&str],
        source: Option<&str>,
        text: Option<&str>,
        png: Option<Vec<u8>>,
    ) {
        self.change_count.set(self.change_count.get() + 1);
        *self.types.borrow_mut() = types.iter().map(|t| (*t).to_owned()).collect();
        *self.source.borrow_mut() = source.map(str::to_owned);
        *self.text.borrow_mut() = text.map(str::to_owned);
        *self.png.borrow_mut() = png;
    }

    pub fn copy_text(&self, source: &str, text: &str) {
        self.copy(&["public.utf8-plain-text"], Some(source), Some(text), None);
    }
}

impl PasteboardSource for FakePasteboard {
    fn change_count(&self) -> i64 {
        self.change_count.get()
    }
    fn types(&self) -> Vec<String> {
        self.types.borrow().clone()
    }
    fn source_bundle_id(&self) -> Option<String> {
        self.source.borrow().clone()
    }
    fn read_text(&self) -> Option<String> {
        self.content_reads.set(self.content_reads.get() + 1);
        self.text.borrow().clone()
    }
    fn read_png(&self) -> Option<Vec<u8>> {
        self.content_reads.set(self.content_reads.get() + 1);
        self.png.borrow().clone()
    }
}
