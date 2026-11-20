//! Live [`Remover`]: the macOS Trash through `NSFileManager` (via the `trash`
//! crate) and permanent removal that never follows symlinks.

use std::{fs, path::Path};

use symcockpit_core::plan::Remover;
use trash::{
    TrashContext,
    macos::{DeleteMethod, TrashContextExtMacos},
};

pub struct SystemRemover;

impl Remover for SystemRemover {
    fn trash(&self, path: &Path) -> Result<(), String> {
        // NSFileManager needs no Finder automation permission and plays no
        // sound. There is deliberately no fallback to deleting.
        let mut ctx = TrashContext::default();
        ctx.set_delete_method(DeleteMethod::NsFileManager);
        ctx.delete(path).map_err(|e| e.to_string())
    }

    fn delete(&self, path: &Path) -> Result<(), String> {
        let meta = fs::symlink_metadata(path).map_err(|e| e.to_string())?;
        // `remove_dir_all` does not follow symlinks; a link itself is a file.
        let done = if meta.is_dir() {
            fs::remove_dir_all(path)
        } else {
            fs::remove_file(path)
        };
        done.map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Live check against the real Trash, with a file made here in the
    /// sandbox. Run once by hand: `cargo test -p symcockpit-macos -- --ignored`
    /// with `SYMCOCKPIT_SANDBOX` set to an existing sandbox directory.
    #[test]
    #[ignore = "uses the real Trash; needs SYMCOCKPIT_SANDBOX"]
    fn live_trash_moves_a_sandbox_file() {
        let sandbox = std::env::var("SYMCOCKPIT_SANDBOX").expect("SYMCOCKPIT_SANDBOX");
        let dir = tempfile::tempdir_in(sandbox).unwrap();
        let file = dir.path().join("symcockpit-live-trash-probe.txt");
        fs::write(&file, b"probe").unwrap();
        SystemRemover.trash(&file).unwrap();
        assert!(fs::symlink_metadata(&file).is_err(), "still in place");
    }

    #[test]
    fn delete_removes_a_link_not_its_target() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("target");
        fs::create_dir(&target).unwrap();
        fs::write(target.join("keep"), b"x").unwrap();
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        SystemRemover.delete(&link).unwrap();
        assert!(fs::symlink_metadata(&link).is_err());
        assert!(target.join("keep").exists());
        SystemRemover.delete(&target).unwrap();
        assert!(!target.exists());
    }
}
