//! Child processes for oracle cases: isolated environment, hard timeout, and
//! a small newline-delimited JSON-RPC client for `serve`.

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use tempfile::TempDir;

/// Environment rules from the manifest.
#[derive(Clone, Debug, Default, serde::Deserialize)]
pub struct EnvSpec {
    #[serde(default)]
    pub isolate_xdg: bool,
    #[serde(default)]
    pub set: BTreeMap<String, String>,
}

pub struct Output {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub code: Option<i32>,
}

/// Build the command; the returned directory (if any) must outlive the process.
fn command(bin: &Path, args: &[&str], env: &EnvSpec) -> Result<(Command, Option<TempDir>), String> {
    let mut cmd = Command::new(bin);
    cmd.args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let dir = if env.isolate_xdg {
        let dir = tempfile::tempdir().map_err(|e| format!("tempdir: {e}"))?;
        for (var, sub) in [
            ("XDG_CONFIG_HOME", "config"),
            ("XDG_DATA_HOME", "data"),
            ("XDG_CACHE_HOME", "cache"),
        ] {
            let path = dir.path().join(sub);
            std::fs::create_dir(&path).map_err(|e| format!("mkdir {}: {e}", path.display()))?;
            cmd.env(var, path);
        }
        Some(dir)
    } else {
        None
    };
    cmd.envs(&env.set);
    Ok((cmd, dir))
}

fn drain(mut pipe: impl Read + Send + 'static) -> std::thread::JoinHandle<Vec<u8>> {
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = pipe.read_to_end(&mut buf);
        buf
    })
}

/// Run to completion; a process still alive after `timeout` is killed and reported as a failure.
pub fn run_cli(
    bin: &Path,
    argv: &[String],
    env: &EnvSpec,
    timeout: Duration,
) -> Result<Output, String> {
    let args: Vec<&str> = argv.iter().map(String::as_str).collect();
    let (mut cmd, _dir) = command(bin, &args, env)?;
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("cannot start {}: {e}", bin.display()))?;
    let out = drain(child.stdout.take().expect("piped"));
    let err = drain(child.stderr.take().expect("piped"));
    let deadline = Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!("timed out after {}s", timeout.as_secs()));
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    Ok(Output {
        stdout: out.join().unwrap_or_default(),
        stderr: err.join().unwrap_or_default(),
        code: status.code(),
    })
}

/// A running `<bin> serve` spoken to as JSON-RPC 2.0 over NDJSON.
pub struct McpSession {
    child: Child,
    stdin: Option<ChildStdin>,
    lines: Receiver<String>,
    deadline: Instant,
    next_id: u64,
    _dir: Option<TempDir>,
}

impl McpSession {
    /// Start the server and complete the `initialize` handshake.
    pub fn start(
        bin: &Path,
        env: &EnvSpec,
        init_params: &Value,
        timeout: Duration,
    ) -> Result<Self, String> {
        let (mut cmd, dir) = command(bin, &["serve"], env)?;
        cmd.stdin(Stdio::piped());
        let mut child = cmd
            .spawn()
            .map_err(|e| format!("cannot start {} serve: {e}", bin.display()))?;
        let stdin = child.stdin.take();
        let stdout = child.stdout.take().expect("piped");
        let (tx, lines) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
        let mut session = Self {
            child,
            stdin,
            lines,
            deadline: Instant::now() + timeout,
            next_id: 1,
            _dir: dir,
        };
        session.request("initialize", init_params.clone())?;
        session.send(&json!({"jsonrpc": "2.0", "method": "notifications/initialized"}))?;
        Ok(session)
    }

    fn send(&mut self, message: &Value) -> Result<(), String> {
        let stdin = self.stdin.as_mut().ok_or("stdin closed")?;
        writeln!(stdin, "{message}")
            .and_then(|()| stdin.flush())
            .map_err(|e| format!("write to serve: {e}"))
    }

    /// Send a request and return its `result`; stdout must carry JSON-RPC only.
    pub fn request(&mut self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.next_id;
        self.next_id += 1;
        self.send(&json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}))?;
        loop {
            let remaining = self.deadline.saturating_duration_since(Instant::now());
            let line = self
                .lines
                .recv_timeout(remaining)
                .map_err(|_| format!("no response to {method} (timeout or server exited)"))?;
            let message: Value = serde_json::from_str(&line)
                .map_err(|_| format!("non-JSON-RPC line on stdout: {line}"))?;
            if message["id"] == json!(id) {
                if let Some(error) = message.get("error") {
                    return Err(format!("{method} returned error: {error}"));
                }
                return message
                    .get("result")
                    .cloned()
                    .ok_or_else(|| format!("{method}: response has no result"));
            }
        }
    }
}

impl Drop for McpSession {
    fn drop(&mut self) {
        self.stdin = None;
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn isolation_gives_each_run_fresh_xdg_dirs_and_applies_set() {
        let env = EnvSpec {
            isolate_xdg: true,
            set: BTreeMap::from([("ORACLE_PROBE".to_owned(), "yes".to_owned())]),
        };
        let run = || {
            let out = run_cli(
                Path::new("/usr/bin/env"),
                &[],
                &env,
                Duration::from_secs(10),
            )
            .unwrap();
            String::from_utf8(out.stdout).unwrap()
        };
        let (a, b) = (run(), run());
        let config = |text: &str| {
            text.lines()
                .find(|l| l.starts_with("XDG_CONFIG_HOME="))
                .unwrap()
                .to_owned()
        };
        assert_ne!(config(&a), config(&b));
        assert!(
            a.contains("ORACLE_PROBE=yes")
                && a.contains("XDG_DATA_HOME=")
                && a.contains("XDG_CACHE_HOME=")
        );
    }

    #[test]
    fn timeouts_are_failures_and_exit_codes_are_reported() {
        let env = EnvSpec::default();
        let err = run_cli(
            Path::new("/bin/sleep"),
            &["5".into()],
            &env,
            Duration::from_millis(200),
        )
        .err()
        .unwrap();
        assert!(err.contains("timed out"), "{err}");
        let out = run_cli(
            Path::new("/usr/bin/false"),
            &[],
            &env,
            Duration::from_secs(10),
        )
        .unwrap();
        assert_eq!(out.code, Some(1));
    }
}
