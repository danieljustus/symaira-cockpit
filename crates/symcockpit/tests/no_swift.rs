//! Nothing in the production binary hands work to the Swift core.
//!
//! The old hand-over found a Swift binary through `SYMCOCKPIT_LEGACY_BIN`, a
//! `symcockpit-legacy` next to the executable or one in `../libexec/symcockpit`. This test
//! plants a tripwire in all three places, runs every command that used to be forwarded
//! (and the rest of the register's v0.12 commands, and every v0.12 MCP tool) on the real
//! binary, and requires that the tripwire never fired. The sources are checked for the
//! hand-over's names, too.
//!
//! Everything runs with `SYMCOCKPIT_TEST_NO_HARDWARE=1`, an isolated HOME and XDG
//! directories and a cleared environment.

use std::ffi::OsStr;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::Value;

const TRIPWIRE: &str = "#!/bin/sh\necho \"called: $0 $*\" >> \"$TRIPWIRE_LOG\"\nexit 99\n";

struct Rig {
    dir: tempfile::TempDir,
    bin: PathBuf,
    log: PathBuf,
}

impl Rig {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("tripwire.log");
        let write = |path: PathBuf| {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, TRIPWIRE).unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
            path
        };
        // The binary is a copy, so the neighbours the old lookup searched are ours.
        let bin = dir.path().join("prefix/bin/symcockpit");
        std::fs::create_dir_all(bin.parent().unwrap()).unwrap();
        std::fs::copy(env!("CARGO_BIN_EXE_symcockpit"), &bin).unwrap();
        write(dir.path().join("prefix/bin/symcockpit-legacy"));
        write(
            dir.path()
                .join("prefix/libexec/symcockpit/symcockpit-legacy"),
        );
        write(dir.path().join("override-legacy"));
        Self { dir, bin, log }
    }

    fn home(&self) -> PathBuf {
        self.dir.path().join("home")
    }

    fn command(&self, args: &[&OsStr]) -> Command {
        let (home, tmp) = (self.home(), self.dir.path());
        std::fs::create_dir_all(&home).unwrap();
        let mut cmd = Command::new(&self.bin);
        cmd.args(args)
            .env_clear()
            .env("SYMCOCKPIT_TEST_NO_HARDWARE", "1")
            .env("PATH", "/usr/bin:/bin")
            .env("HOME", &home)
            .env("CFFIXED_USER_HOME", &home)
            .env("XDG_CONFIG_HOME", tmp.join("xdg/c"))
            .env("XDG_DATA_HOME", tmp.join("xdg/d"))
            .env("XDG_CACHE_HOME", tmp.join("xdg/ca"))
            .env("SYMCOCKPIT_CHECK_UPDATES", "0")
            .env("SYMCOCKPIT_LEGACY_BIN", tmp.join("override-legacy"))
            .env("TRIPWIRE_LOG", &self.log)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        cmd
    }

    fn fired(&self) -> String {
        std::fs::read_to_string(&self.log).unwrap_or_default()
    }
}

fn strs<'a>(args: &'a [&'a str]) -> Vec<&'a OsStr> {
    args.iter().map(OsStr::new).collect()
}

fn finish(mut child: Child, limit: Duration) -> (Option<i32>, String, String) {
    let started = Instant::now();
    while child.try_wait().unwrap().is_none() {
        if started.elapsed() > limit {
            let _ = child.kill();
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let out = child.wait_with_output().unwrap();
    (
        out.status.code(),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

fn signal(child: &Child, name: &str) {
    let status = Command::new("/bin/kill")
        .args([&format!("-{name}"), &child.id().to_string()])
        .status()
        .unwrap();
    assert!(status.success());
}

#[test]
fn the_tripwire_itself_records_a_call() {
    // Without this the empty log below could mean a dead trap.
    let rig = Rig::new();
    let status = Command::new(rig.dir.path().join("prefix/bin/symcockpit-legacy"))
        .arg("sensors")
        .env("TRIPWIRE_LOG", &rig.log)
        .status()
        .unwrap();
    assert_eq!(status.code(), Some(99));
    assert!(rig.fired().contains("symcockpit-legacy sensors"));
}

#[test]
fn no_cli_command_reaches_a_swift_binary_even_with_one_planted_everywhere() {
    let rig = Rig::new();
    let commands: &[&[&str]] = &[
        // The five things that used to be handed over.
        &["fan", "profile", "comfort"],
        &["fan", "target", "70"],
        &["fan", "target", "off"],
        &["fan", "profile", "system"],
        // The rest of the v0.12 register, writes refused by the test switch.
        &["fan", "profile"],
        &["fan", "target"],
        &["fan", "status"],
        &["fan", "set", "0.5"],
        &["fan", "auto"],
        &["battery-limit", "set", "80"],
        &["battery-limit", "clear"],
        &["restore"],
        &["brightness", "set", "0.5"],
        &["brightness", "get"],
        &["dim", "set", "0.5"],
        &["dim", "reset"],
        &["warmth", "set", "0.5"],
        &["warmth", "reset"],
        &["extbright", "1.2"],
        &["profile", "save", "x"],
        &["profile", "load", "x"],
        &["profile", "list"],
        &["profile", "delete", "x"],
        &["awake", "off"],
        &["awake", "status"],
        &["history"],
        &["doctor"],
        &["permissions"],
        &["sensors"],
        &["battery"],
        &["displays"],
        &["metrics"],
        &["processes", "--json", "--limit", "1", "--interval", "0.1"],
        &["top", "--json", "--limit", "1", "--interval", "0.1"],
        &["status"],
        &["status", "--json"],
        &["ai-usage", "--json"],
        &["ai-usage", "serve", "--help"],
        &["ai-usage", "serve", "--port", "nope"],
        &["version"],
        &["version", "--json"],
        &["--version"],
        &["-V"],
        &["help"],
        &["tune", "sensors"],
        &["operate"],
        &["nope"],
        &[],
    ];
    for args in commands {
        let (code, _, stderr) = finish(
            rig.command(&strs(args)).spawn().unwrap(),
            Duration::from_secs(60),
        );
        // A real exit code of the documented set, never a panic (101) or a signal.
        assert!(matches!(code, Some(0..=4)), "{args:?}: {code:?} {stderr}");
        assert_eq!(rig.fired(), "", "{args:?} started the Swift binary");
    }
    // The bytes that are not UTF-8.
    let odd = [OsStr::from_bytes(b"\xff\xfe")];
    let (code, _, _) = finish(rig.command(&odd).spawn().unwrap(), Duration::from_secs(20));
    assert_eq!(code, Some(2));
    // `fan profile` and `fan target` really ran here: the file is the Swift file.
    let file = rig.home().join(".symtune/fan-profile.json");
    assert_eq!(
        std::fs::read_to_string(file).unwrap(),
        r#"{"profile":"system"}"#
    );
    assert_eq!(rig.fired(), "");
}

#[test]
fn no_mcp_tool_reaches_a_swift_binary() {
    let rig = Rig::new();
    let names: Vec<String> = {
        let fixture = std::fs::read_to_string(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../oracle/v0.12/cases/mcp-tools-list.json"),
        )
        .unwrap();
        let v: Value = serde_json::from_str(&fixture).unwrap();
        v["tools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap().to_owned())
            .collect()
    };
    assert_eq!(names.len(), 26);
    let mut child = rig
        .command(&strs(&["serve"]))
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    for (i, name) in names.iter().enumerate() {
        writeln!(
            stdin,
            r#"{{"jsonrpc":"2.0","id":{i},"method":"tools/call","params":{{"name":"{name}","arguments":{{}}}}}}"#
        )
        .unwrap();
    }
    drop(stdin);
    let (code, stdout, stderr) = finish(child, Duration::from_secs(120));
    assert_eq!(code, Some(0), "{stderr}");
    assert_eq!(stdout.lines().count(), 26, "one answer per tool");
    assert_eq!(rig.fired(), "", "an MCP tool started the Swift binary");
}

#[test]
fn the_sources_no_longer_name_the_hand_over() {
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    assert!(!src.join("legacy.rs").exists());
    let mut files = vec![src];
    let mut checked = 0;
    while let Some(path) = files.pop() {
        for entry in std::fs::read_dir(path).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                files.push(path);
            } else if path.extension() == Some(OsStr::new("rs")) {
                let text = std::fs::read_to_string(&path).unwrap();
                for needle in [
                    "LEGACY_BIN",
                    "symcockpit-legacy",
                    ".exec()",
                    "through_legacy",
                    "Action::Forward",
                ] {
                    assert!(
                        !text.contains(needle),
                        "{} still has {needle}",
                        path.display()
                    );
                }
                checked += 1;
            }
        }
    }
    assert!(checked > 20, "only {checked} files looked at");
}

#[test]
fn status_watch_streams_lines_and_ends_cleanly_on_sigint_and_on_a_closed_pipe() {
    let rig = Rig::new();
    let args = strs(&["status", "--watch", "--interval", "0.2"]);
    // SIGINT: two lines, then exit 0 with nothing after.
    let mut child = rig.command(&args).spawn().unwrap();
    let mut out = BufReader::new(child.stdout.take().unwrap());
    let mut lines = Vec::new();
    for _ in 0..2 {
        let mut line = String::new();
        out.read_line(&mut line).unwrap();
        lines.push(line);
    }
    signal(&child, "INT");
    let mut rest = String::new();
    out.read_to_string(&mut rest).unwrap();
    let (code, _, stderr) = finish(child, Duration::from_secs(20));
    assert_eq!(code, Some(0), "{stderr}");
    for line in lines.iter().chain(
        rest.lines()
            .map(|l| l.to_owned())
            .collect::<Vec<_>>()
            .iter(),
    ) {
        let report: Value = serde_json::from_str(line).unwrap_or_else(|e| panic!("{e}: {line}"));
        assert!(report.get("health_score").is_some(), "{line}");
    }
    // A reader that goes away (`| head -1`): the next write fails, the loop ends with 0.
    let mut child = rig.command(&args).spawn().unwrap();
    let mut out = BufReader::new(child.stdout.take().unwrap());
    let mut first = String::new();
    out.read_line(&mut first).unwrap();
    drop(out);
    let (code, _, stderr) = finish(child, Duration::from_secs(20));
    assert_eq!(code, Some(0), "{stderr}");
    assert_eq!(rig.fired(), "");
}

#[test]
fn ai_usage_serve_answers_on_loopback_ends_on_sigterm_and_refuses_a_second_bind() {
    let rig = Rig::new();
    let mut child = rig
        .command(&strs(&["ai-usage", "serve", "--port", "0"]))
        .spawn()
        .unwrap();
    let mut out = BufReader::new(child.stdout.take().unwrap());
    let mut line = String::new();
    out.read_line(&mut line).unwrap();
    let port: u16 = line
        .strip_prefix("AI usage API: http://127.0.0.1:")
        .and_then(|r| r.split(' ').next())
        .unwrap_or_else(|| panic!("{line}"))
        .parse()
        .unwrap();
    assert!(line.ends_with("(cache only; Ctrl-C to stop)\n"));
    let ask = |request: String| {
        let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        s.write_all(request.as_bytes()).unwrap();
        let mut text = String::new();
        let _ = s.read_to_string(&mut text);
        text
    };
    // Nothing is enabled in an isolated HOME: an empty, well-formed document.
    let ok = ask(format!(
        "GET /v1/limits HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n"
    ));
    assert!(ok.starts_with("HTTP/1.1 200 OK\r\n"), "{ok}");
    assert!(
        ok.contains(r#""providers":{},"schema":"symaira.cockpit.limits.v1""#),
        "{ok}"
    );
    assert!(
        ask(format!(
            "GET /v1/limits HTTP/1.1\r\nHost: localhost:{port}\r\n\r\n"
        ))
        .starts_with("HTTP/1.1 403")
    );
    // The same port twice: the second process says so and exits 1.
    let (code, _, stderr) = finish(
        rig.command(&strs(&["ai-usage", "serve", "--port", &port.to_string()]))
            .spawn()
            .unwrap(),
        Duration::from_secs(20),
    );
    assert_eq!(code, Some(1), "{stderr}");
    assert!(stderr.contains("cannot listen on 127.0.0.1"), "{stderr}");
    signal(&child, "TERM");
    let (code, _, stderr) = finish(child, Duration::from_secs(20));
    assert_eq!(code, Some(0), "{stderr}");
    assert_eq!(rig.fired(), "");
}
