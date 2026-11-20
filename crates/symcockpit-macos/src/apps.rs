//! Live [`Apps`]: bundle metadata from `Info.plist`, Team ID from
//! `codesign`, installer receipts from `pkgutil` and running state from `ps`.
//!
//! External programs (architecture §10): fixed absolute path, argument list
//! (no shell), empty environment, timeout and an explicit list of accepted
//! exit codes.

use std::{
    fs,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

use symcockpit_contract::Error;
use symcockpit_core::{
    plan::Running,
    storage::uninstall::{AppInfo, Apps, Receipt},
};

const TOOL_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_OUTPUT: u64 = 8 << 20;

/// Runs `program` with `args`; returns stdout and stderr when the exit code
/// is in `ok_codes`. Output is capped and the child is killed on timeout.
fn run_tool(
    program: &str,
    args: &[&str],
    ok_codes: &[i32],
) -> Result<(i32, String, String), String> {
    let mut child = Command::new(program)
        .args(args)
        .env_clear()
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("{program}: {e}"))?;
    let drain = |mut r: Box<dyn Read + Send>| {
        thread::spawn(move || {
            let mut buf = Vec::new();
            let _ = (&mut r).take(MAX_OUTPUT).read_to_end(&mut buf);
            String::from_utf8_lossy(&buf).into_owned()
        })
    };
    let out = drain(Box::new(child.stdout.take().ok_or("no stdout")?));
    let err = drain(Box::new(child.stderr.take().ok_or("no stderr")?));
    let start = Instant::now();
    let status = loop {
        if let Some(s) = child.try_wait().map_err(|e| e.to_string())? {
            break s;
        }
        if start.elapsed() > TOOL_TIMEOUT {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!("{program}: timed out"));
        }
        thread::sleep(Duration::from_millis(10));
    };
    let code = status.code().unwrap_or(-1);
    if !ok_codes.contains(&code) {
        return Err(format!("{program}: exit {code}"));
    }
    Ok((
        code,
        out.join().unwrap_or_default(),
        err.join().unwrap_or_default(),
    ))
}

/// `TeamIdentifier=ABCDE12345` from `codesign -d --verbose=2` (stderr).
pub fn parse_team_id(codesign_stderr: &str) -> Option<String> {
    let id = codesign_stderr
        .lines()
        .find_map(|l| l.strip_prefix("TeamIdentifier="))?;
    (id.len() == 10 && id.bytes().all(|b| b.is_ascii_alphanumeric())).then(|| id.to_owned())
}

/// `(volume, location)` from `pkgutil --pkg-info`.
pub fn parse_pkg_info(text: &str) -> (String, String) {
    let field = |key: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(key))
            .map(|v| v.trim().to_owned())
            .unwrap_or_default()
    };
    (field("volume:"), field("location:"))
}

/// Absolute paths for the relative entries of `pkgutil --files`.
pub fn receipt_paths(volume: &str, location: &str, files: &str) -> Vec<PathBuf> {
    let base = Path::new(volume).join(location.trim_start_matches('/'));
    files
        .lines()
        .filter(|l| !l.is_empty() && !l.split('/').any(|c| c == ".."))
        .map(|l| base.join(l))
        .collect()
}

/// Bundle ids are passed to `pkgutil` as arguments; keep them plain.
fn plain_id(id: &str) -> bool {
    !id.is_empty()
        && !id.starts_with(['-', '.'])
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-' || b == b'_')
}

pub struct SystemApps {
    home: PathBuf,
}

impl SystemApps {
    pub fn new(home: &Path) -> Self {
        Self {
            home: home.to_owned(),
        }
    }

    fn read_bundle(&self, path: &Path) -> Result<AppInfo, Error> {
        let meta = fs::symlink_metadata(path)
            .map_err(|e| Error::Usage(format!("{}: {e}", path.display())))?;
        if !meta.is_dir() || path.extension().is_none_or(|e| e != "app") {
            return Err(Error::Usage(format!(
                "not an app bundle: {}",
                path.display()
            )));
        }
        let plist = plist::Value::from_file(path.join("Contents/Info.plist"))
            .map_err(|e| Error::Usage(format!("no readable Info.plist: {e}")))?;
        let dict = plist
            .as_dictionary()
            .ok_or_else(|| Error::Usage("Info.plist is not a dictionary".to_owned()))?;
        let get = |k: &str| dict.get(k).and_then(|v| v.as_string()).map(str::to_owned);
        let bundle_id = get("CFBundleIdentifier")
            .filter(|b| plain_id(b))
            .ok_or_else(|| Error::Usage("app has no usable bundle id".to_owned()))?;
        let name = get("CFBundleDisplayName")
            .or_else(|| get("CFBundleName"))
            .or_else(|| path.file_stem().map(|s| s.to_string_lossy().into_owned()))
            .unwrap_or_else(|| bundle_id.clone());
        let team_id = run_tool(
            "/usr/bin/codesign",
            &["-d", "--verbose=2", &path.to_string_lossy()],
            &[0, 1], // 1: not signed
        )
        .ok()
        .and_then(|(_, _, stderr)| parse_team_id(&stderr));
        Ok(AppInfo {
            path: path.to_owned(),
            bundle_id,
            name,
            team_id,
        })
    }
}

impl Apps for SystemApps {
    fn resolve(&self, app: &str) -> Result<AppInfo, Error> {
        if app.contains('/') || app.ends_with(".app") {
            return self
                .read_bundle(&std::path::absolute(app).map_err(|e| Error::Usage(e.to_string()))?);
        }
        for dir in [
            PathBuf::from("/Applications"),
            PathBuf::from("/Applications/Utilities"),
            self.home.join("Applications"),
        ] {
            let mut bundles: Vec<PathBuf> = fs::read_dir(&dir)
                .into_iter()
                .flatten()
                .filter_map(Result::ok)
                .map(|e| e.path())
                .filter(|p| p.extension().is_some_and(|e| e == "app"))
                .collect();
            bundles.sort();
            for b in bundles {
                if let Ok(info) = self.read_bundle(&b)
                    && info.bundle_id == app
                {
                    return Ok(info);
                }
            }
        }
        Err(Error::Usage(format!(
            "no installed app with bundle id {app}"
        )))
    }

    fn receipt(&self, bundle_id: &str) -> Result<Option<Receipt>, Error> {
        if !plain_id(bundle_id) {
            return Ok(None);
        }
        let failed = |e: String| Error::Failed(e);
        let (code, info, _) =
            run_tool("/usr/sbin/pkgutil", &["--pkg-info", bundle_id], &[0, 1]).map_err(failed)?;
        if code == 1 {
            return Ok(None);
        }
        let (volume, location) = parse_pkg_info(&info);
        let (_, files, _) =
            run_tool("/usr/sbin/pkgutil", &["--files", bundle_id], &[0]).map_err(failed)?;
        Ok(Some(Receipt {
            pkg_id: bundle_id.to_owned(),
            files: receipt_paths(&volume, &location, &files),
        }))
    }
}

impl Running for SystemApps {
    /// Anything started from inside the bundle counts. If `ps` fails the app
    /// is assumed to be running: blocking is the safe answer.
    fn is_running(&self, bundle: &Path) -> bool {
        let inside = bundle.join("Contents");
        match run_tool("/bin/ps", &["-axww", "-o", "comm="], &[0]) {
            Ok((_, out, _)) => out
                .lines()
                .any(|l| Path::new(l.trim()).starts_with(&inside)),
            Err(_) => true,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn team_id_from_codesign_output() {
        assert_eq!(
            parse_team_id("Identifier=x\nTeamIdentifier=AB12CD34EF\n"),
            Some("AB12CD34EF".to_owned())
        );
        assert_eq!(parse_team_id("TeamIdentifier=not set\n"), None);
        assert_eq!(parse_team_id("TeamIdentifier=AB12\n"), None);
    }

    #[test]
    fn receipt_paths_are_absolute_and_never_climb() {
        let (v, l) = parse_pkg_info("package-id: x\nvolume: /\nlocation: usr/local\n");
        assert_eq!((v.as_str(), l.as_str()), ("/", "usr/local"));
        let paths = receipt_paths(&v, &l, "bin/tool\n../evil\n\nshare/doc\n");
        assert_eq!(
            paths,
            [
                PathBuf::from("/usr/local/bin/tool"),
                PathBuf::from("/usr/local/share/doc")
            ]
        );
    }

    #[test]
    fn ids_given_to_pkgutil_are_plain() {
        assert!(plain_id("com.example.App-1_x"));
        assert!(!plain_id("--force"));
        assert!(!plain_id("a b"));
    }

    /// Finder runs in every logged-in session; a bundle that cannot run does not.
    #[test]
    #[ignore = "reads the process list"]
    fn live_is_running_follows_the_process_list() {
        let apps = SystemApps::new(Path::new("/nonexistent"));
        assert!(apps.is_running(Path::new("/System/Library/CoreServices/Finder.app")));
        assert!(!apps.is_running(Path::new("/Applications/No Such App.app")));
    }
}
