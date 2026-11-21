//! What each action does. Platform effects (pasteboard, Terminal) sit behind a port; creating
//! a file is plain `std::fs` with `create_new`, so a name is never overwritten.

use std::{
    fs::OpenOptions,
    io,
    path::{Path, PathBuf},
};

use super::job::{Action, Job};

/// Port: the two things only the platform can do.
pub trait FinderPlatform {
    fn copy_text(&self, text: &str) -> Result<(), String>;
    /// Opens Terminal at `dir`. The path is one argument, never part of a command string.
    fn open_in_terminal(&self, dir: &Path) -> Result<(), String>;
}

/// Runs a validated job; `Err` becomes a `failed` result.
pub trait Executor {
    fn run(&self, job: &Job) -> Result<String, String>;
}

pub struct Runner<'a> {
    pub platform: &'a dyn FinderPlatform,
}

fn folder_of(path: &str) -> PathBuf {
    let p = Path::new(path);
    if p.is_dir() {
        p.to_path_buf()
    } else {
        p.parent()
            .map_or_else(|| PathBuf::from("/"), Path::to_path_buf)
    }
}

/// Creates `untitled.txt` (then `untitled 2.txt`, ...) in `dir` and returns its path.
pub fn new_file_in(dir: &Path) -> io::Result<PathBuf> {
    for n in 1..=1000 {
        let name = if n == 1 {
            "untitled.txt".to_owned()
        } else {
            format!("untitled {n}.txt")
        };
        let path = dir.join(name);
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(_) => return Ok(path),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e),
        }
    }
    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "no free untitled name",
    ))
}

impl Executor for Runner<'_> {
    fn run(&self, job: &Job) -> Result<String, String> {
        match job.action {
            Action::CopyPath => {
                self.platform.copy_text(&job.paths.join("\n"))?;
                Ok(format!("copied {} path(s)", job.paths.len()))
            }
            Action::NewFile => {
                let dir = folder_of(&job.paths[0]);
                new_file_in(&dir)
                    .map(|p| format!("created {}", p.display()))
                    .map_err(|e| e.to_string())
            }
            Action::OpenInTerminal => {
                let dir = folder_of(&job.paths[0]);
                self.platform.open_in_terminal(&dir)?;
                Ok(format!("opened {}", dir.display()))
            }
        }
    }
}
