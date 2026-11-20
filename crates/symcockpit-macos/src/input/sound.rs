//! Plays the rendered material sound through `/usr/bin/afplay`.
//!
//! shortcut: a child process per click, no audio framework. Upgrade to a
//! persistent AVAudioEngine voice if click latency is noticeable on hardware.

use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

use symcockpit_core::input::SoundBackend;

static COUNTER: AtomicU64 = AtomicU64::new(0);

pub struct AfplaySound {
    program: PathBuf,
    dir: PathBuf,
}

impl Default for AfplaySound {
    fn default() -> Self {
        AfplaySound::with_program("/usr/bin/afplay", std::env::temp_dir())
    }
}

impl AfplaySound {
    /// Another player program and scratch directory, for tests.
    pub fn with_program(program: impl Into<PathBuf>, dir: impl Into<PathBuf>) -> Self {
        AfplaySound {
            program: program.into(),
            dir: dir.into(),
        }
    }
}

impl SoundBackend for AfplaySound {
    fn play(&self, wav: &[u8]) -> Result<(), String> {
        let file = self.dir.join(format!(
            "symcockpit-click-{}-{}.wav",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::write(&file, wav).map_err(|e| format!("cannot write the sound: {e}"))?;
        let mut child = Command::new(&self.program)
            .arg(&file)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| {
                let _ = std::fs::remove_file(&file);
                format!("cannot start {}: {e}", self.program.display())
            })?;
        // Return at once; a thread reaps the child and removes the file.
        std::thread::spawn(move || {
            let _ = child.wait();
            let _ = std::fs::remove_file(&file);
        });
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn files(dir: &std::path::Path) -> usize {
        std::fs::read_dir(dir).unwrap().count()
    }

    #[test]
    fn missing_player_is_reported_and_leaves_no_file() {
        let dir = tempfile::tempdir().unwrap();
        let err = AfplaySound::with_program("/nonexistent/afplay", dir.path())
            .play(&[1, 2, 3])
            .unwrap_err();
        assert!(err.contains("cannot start"));
        assert_eq!(files(dir.path()), 0);
    }

    #[test]
    fn file_is_removed_after_playback() {
        let dir = tempfile::tempdir().unwrap();
        AfplaySound::with_program("/usr/bin/true", dir.path())
            .play(&[0; 8])
            .unwrap();
        for _ in 0..100 {
            if files(dir.path()) == 0 {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        panic!("sound file was not removed");
    }
}
