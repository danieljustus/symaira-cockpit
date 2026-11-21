//! Finder action platform (R72): the two effects only macOS can do.

use std::{
    path::Path,
    process::{Command, Stdio},
};

use objc2_app_kit::NSPasteboard;
use objc2_foundation::NSString;
use symcockpit_core::finder::FinderPlatform;

pub struct MacFinderPlatform;

/// Program and argument list for "open Terminal at `dir`": the path is one argument, there is
/// no shell and no string interpolation.
pub fn terminal_command(dir: &Path) -> (&'static str, Vec<std::ffi::OsString>) {
    (
        "/usr/bin/open",
        vec!["-a".into(), "Terminal".into(), dir.as_os_str().to_owned()],
    )
}

impl FinderPlatform for MacFinderPlatform {
    fn copy_text(&self, text: &str) -> Result<(), String> {
        let pb = NSPasteboard::generalPasteboard();
        pb.clearContents();
        if pb.setString_forType(
            &NSString::from_str(text),
            &NSString::from_str("public.utf8-plain-text"),
        ) {
            Ok(())
        } else {
            Err("the pasteboard refused the text".into())
        }
    }

    fn open_in_terminal(&self, dir: &Path) -> Result<(), String> {
        let (program, args) = terminal_command(dir);
        let status = Command::new(program)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map_err(|e| e.to_string())?;
        status
            .success()
            .then_some(())
            .ok_or_else(|| format!("open exited with {status}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_terminal_path_is_a_single_argument_whatever_it_contains() {
        let nasty = Path::new("/tmp/a b; echo hi $(x) 'q' \"r\" -n");
        let (program, args) = terminal_command(nasty);
        assert_eq!(program, "/usr/bin/open");
        assert_eq!(args.len(), 3);
        assert_eq!(args[2], nasty.as_os_str());
    }
}
