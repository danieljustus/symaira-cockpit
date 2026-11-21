//! Clipboard adapters (R73): the NSPasteboard poller source, the Keychain key and the Time
//! Machine exclusion. None of them runs in the CLI's `serve`; the app agent owns them.

use std::{ffi::CString, path::Path};

use objc2_app_kit::{NSPasteboard, NSWorkspace};
use objc2_foundation::{NSData, NSString};
use security_framework::passwords::delete_generic_password;
use security_framework::passwords_options::PasswordOptions;
use symcockpit_contract::Error;
use symcockpit_core::clipboard::{
    BackupExclusion, KEY_LEN, Key, KeyStore, PasteboardSink, PasteboardSource, random_key,
};

/// `NSPasteboard.general`, read through the port the privacy rules sit in front of.
pub struct SystemPasteboard;

impl SystemPasteboard {
    fn general() -> objc2::rc::Retained<NSPasteboard> {
        NSPasteboard::generalPasteboard()
    }
}

impl PasteboardSource for SystemPasteboard {
    fn change_count(&self) -> i64 {
        Self::general().changeCount() as i64
    }

    fn types(&self) -> Vec<String> {
        Self::general()
            .types()
            .map(|t| t.iter().map(|s| s.to_string()).collect())
            .unwrap_or_default()
    }

    /// The frontmost app at the time of polling: pasteboards carry no source app, so this is a
    /// best effort and can name the wrong app when focus moves between copy and poll.
    fn source_bundle_id(&self) -> Option<String> {
        NSWorkspace::sharedWorkspace()
            .frontmostApplication()
            .and_then(|app| app.bundleIdentifier())
            .map(|id| id.to_string())
    }

    fn read_text(&self) -> Option<String> {
        Self::general()
            .stringForType(&NSString::from_str("public.utf8-plain-text"))
            .map(|s| s.to_string())
    }

    fn read_png(&self) -> Option<Vec<u8>> {
        Self::general()
            .dataForType(&NSString::from_str("public.png"))
            .map(|d| d.to_vec())
    }
}

impl SystemPasteboard {
    fn write(
        &self,
        kind: &str,
        put: impl FnOnce(&NSPasteboard, &NSString) -> bool,
    ) -> Result<i64, Error> {
        let pasteboard = Self::general();
        pasteboard.clearContents();
        if put(&pasteboard, &NSString::from_str(kind)) {
            Ok(pasteboard.changeCount() as i64)
        } else {
            Err(Error::Failed("the pasteboard refused the clip".into()))
        }
    }
}

impl PasteboardSink for SystemPasteboard {
    fn write_text(&self, text: &str) -> Result<i64, Error> {
        self.write("public.utf8-plain-text", |pb, kind| {
            pb.setString_forType(&NSString::from_str(text), kind)
        })
    }

    fn write_png(&self, png: &[u8]) -> Result<i64, Error> {
        self.write("public.png", |pb, kind| {
            pb.setData_forType(Some(&NSData::with_bytes(png)), kind)
        })
    }
}

/// Keychain item `com.symaira.symtune` / `clipboard-key` (the grandfathered service name, so
/// the existing namespace is reused). Not synchronised: the key never leaves this Mac.
/// shortcut: legacy file keychain without `kSecAttrAccessible...ThisDeviceOnly` (that needs the
/// data-protection keychain and a keychain-access-groups entitlement); revisit with the signed app.
pub struct KeychainKey;

const SERVICE: &str = "com.symaira.symtune";
const ACCOUNT: &str = "clipboard-key";

impl KeyStore for KeychainKey {
    fn key(&self) -> Result<Key, Error> {
        let fail = |e: security_framework::base::Error| Error::Failed(format!("keychain: {e}"));
        let mut options = PasswordOptions::new_generic_password(SERVICE, ACCOUNT);
        options.set_access_synchronized(Some(false));
        match security_framework::passwords::generic_password(options) {
            Ok(bytes) => <Key>::try_from(bytes.as_slice()).map_err(|_| {
                Error::Failed(format!(
                    "keychain: stored key has {} bytes, expected {KEY_LEN}",
                    bytes.len()
                ))
            }),
            // errSecItemNotFound: first use. Any other error must not create a second key.
            Err(e) if e.code() == -25300 => {
                let key = random_key();
                let mut options = PasswordOptions::new_generic_password(SERVICE, ACCOUNT);
                options.set_access_synchronized(Some(false));
                options.set_label("Symaira Cockpit clipboard history key");
                security_framework::passwords::set_generic_password_options(&key, options)
                    .map_err(fail)?;
                Ok(key)
            }
            Err(e) => Err(fail(e)),
        }
    }
}

impl KeychainKey {
    /// Removes the key: every sealed item becomes unreadable (crypto-shredding). Not used by `clear`.
    pub fn delete(&self) -> Result<(), Error> {
        delete_generic_password(SERVICE, ACCOUNT)
            .map_err(|e| Error::Failed(format!("keychain: {e}")))
    }
}

const BACKUP_EXCLUDE_ATTR: &str = "com.apple.metadata:com_apple_backup_excludeItem";

/// Sets the sticky Time Machine exclusion (the xattr `tmutil addexclusion` writes).
pub struct TimeMachineExclusion;

fn exclusion_value() -> Vec<u8> {
    let mut out = Vec::new();
    plist::to_writer_binary(&mut out, &"com.apple.backupd").expect("serialising a string");
    out
}

impl BackupExclusion for TimeMachineExclusion {
    fn exclude(&self, path: &Path) -> Result<(), Error> {
        use std::os::unix::ffi::OsStrExt;
        let c_path = CString::new(path.as_os_str().as_bytes())
            .map_err(|_| Error::Failed("path has a NUL".into()))?;
        let attr = CString::new(BACKUP_EXCLUDE_ATTR).expect("constant");
        let value = exclusion_value();
        // SAFETY: both strings are NUL-terminated and `value` outlives the call; position 0, no options.
        let rc = unsafe {
            libc::setxattr(
                c_path.as_ptr(),
                attr.as_ptr(),
                value.as_ptr().cast(),
                value.len(),
                0,
                0,
            )
        };
        if rc == 0 {
            Ok(())
        } else {
            Err(Error::Failed(format!(
                "time machine exclusion: {}",
                std::io::Error::last_os_error()
            )))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read_attr(path: &Path) -> Option<Vec<u8>> {
        use std::os::unix::ffi::OsStrExt;
        let c_path = CString::new(path.as_os_str().as_bytes()).unwrap();
        let attr = CString::new(BACKUP_EXCLUDE_ATTR).unwrap();
        let mut buf = vec![0u8; 256];
        // SAFETY: valid NUL-terminated strings and a writable buffer of the stated length.
        let n = unsafe {
            libc::getxattr(
                c_path.as_ptr(),
                attr.as_ptr(),
                buf.as_mut_ptr().cast(),
                buf.len(),
                0,
                0,
            )
        };
        (n >= 0).then(|| buf[..n as usize].to_vec())
    }

    #[test]
    fn the_exclusion_attribute_lands_on_a_temp_directory_and_is_idempotent() {
        let d = tempfile::tempdir().unwrap();
        assert_eq!(read_attr(d.path()), None);
        TimeMachineExclusion.exclude(d.path()).unwrap();
        TimeMachineExclusion.exclude(d.path()).unwrap();
        let v = read_attr(d.path()).expect("attribute set");
        assert_eq!(v, exclusion_value());
        assert!(v.starts_with(b"bplist00"));
        assert!(
            TimeMachineExclusion
                .exclude(&d.path().join("missing"))
                .is_err()
        );
    }

    /// Reads only the change counter of the real pasteboard; run on purpose with `--ignored`.
    #[test]
    #[ignore = "reads the live pasteboard change counter"]
    fn live_change_count_is_readable() {
        assert!(SystemPasteboard.change_count() >= 0);
    }
}
