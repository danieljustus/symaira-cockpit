//! A fake legacy (Swift) binary: a shell script that logs its arguments, one
//! `[arg]` line each, and answers with canned output and exit status.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

pub struct FakeLegacy {
    pub path: PathBuf,
    log: PathBuf,
}

fn quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

impl FakeLegacy {
    /// Creates `dir/fake-legacy`. It prints `stdout`, writes `stderr` to
    /// standard error and exits with `exit`.
    pub fn new(dir: &Path, stdout: &str, stderr: &str, exit: i32) -> Self {
        let path = dir.join("fake-legacy");
        let log = dir.join("fake-legacy.log");
        let script = format!(
            "#!/bin/sh\nprintf 'call\\n' >> {log}\nfor a in \"$@\"; do printf '[%s]\\n' \"$a\" >> {log}; done\nprintf '%s' {out}\nprintf '%s' {err} >&2\nexit {exit}\n",
            log = quote(&log.to_string_lossy()),
            out = quote(stdout),
            err = quote(stderr),
        );
        std::fs::write(&path, script).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        Self { path, log }
    }

    /// Every invocation so far, each as its argument list.
    pub fn calls(&self) -> Vec<Vec<String>> {
        let text =
            String::from_utf8_lossy(&std::fs::read(&self.log).unwrap_or_default()).into_owned();
        let mut calls: Vec<Vec<String>> = Vec::new();
        for line in text.lines() {
            if line == "call" {
                calls.push(Vec::new());
            } else if let (Some(call), Some(arg)) = (
                calls.last_mut(),
                line.strip_prefix('[').and_then(|l| l.strip_suffix(']')),
            ) {
                call.push(arg.to_owned());
            }
        }
        calls
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_arguments_and_replies() {
        let tmp = tempfile::tempdir().unwrap();
        let fake = FakeLegacy::new(tmp.path(), "{\"applied\":true}", "symcockpit: no\n", 3);
        let out = std::process::Command::new(&fake.path)
            .args(["dim", "set", "0.5"])
            .output()
            .unwrap();
        assert_eq!(out.status.code(), Some(3));
        assert_eq!(out.stdout, b"{\"applied\":true}");
        assert_eq!(out.stderr, b"symcockpit: no\n");
        assert_eq!(fake.calls(), [["dim", "set", "0.5"]]);
    }
}
