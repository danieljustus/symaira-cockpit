//! `status --watch` and `ai-usage serve` in-process: the loop bodies against fakes (an
//! interrupt that is a channel, a writer that breaks, loopback sockets). The signals
//! themselves are exercised on the real binary in `no_swift.rs`.

mod common;

use std::io::{self, Read, Write};
use std::net::TcpStream;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use common::{Overrides, app};
use serde_json::{Value, json};
use symcockpit::app::{App, Context, Output};
use symcockpit::loops::{Interrupt, ai_usage_serve, status_watch};
use symcockpit_core::ai_usage_api::{Dec, Meter, Row, Snapshot, Unit};
use symcockpit_store::Config;

/// Interrupts after `ticks` waits and records the waits.
struct After {
    ticks: usize,
    waits: Vec<Duration>,
}

impl Interrupt for After {
    fn wait(&mut self, timeout: Duration) -> bool {
        self.waits.push(timeout);
        self.waits.len() > self.ticks
    }
}

fn status_app(home: &std::path::Path) -> App {
    let mut a = app(home);
    a.handlers.register("sensors", |_, _| {
        Ok(Output::Json(
            json!({"thermal_pressure": "nominal", "smc_supported": true}),
        ))
    });
    a.handlers.register("battery", |_, _| {
        Ok(Output::Json(json!({"present": true, "health_percent": 86})))
    });
    a.handlers.register("displays", |_, _| {
        Ok(Output::Json(json!({"displays": [], "notes": []})))
    });
    a.services.overrides = Some(Box::new(Overrides(json!({}), false)));
    a
}

fn ctx<'a>(a: &'a App, config: &'a Config) -> Context<'a> {
    Context {
        config,
        paths: &a.paths,
        data_dir: &a.paths.data_dir,
        data_dir_override: None,
        env: &a.env,
        services: &a.services,
    }
}

#[test]
fn watch_prints_one_compact_line_at_once_then_one_per_interval_and_ends_on_the_interrupt() {
    let tmp = tempfile::tempdir().unwrap();
    let a = status_app(tmp.path());
    let config = Config::default();
    let mut out = Vec::new();
    let mut interrupt = After {
        ticks: 2,
        waits: Vec::new(),
    };
    assert_eq!(
        status_watch(&a, &ctx(&a, &config), 0.5, &mut out, &mut interrupt),
        0
    );
    let text = String::from_utf8(out).unwrap();
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(
        lines.len(),
        3,
        "a report at once, then one per wait that ran out: {text}"
    );
    for line in &lines {
        assert!(
            !line.contains('\n') && !line.contains(": "),
            "compact NDJSON: {line}"
        );
        let report: Value = serde_json::from_str(line).unwrap();
        assert_eq!(report["health_score"], 100);
    }
    // The sleep is the interval, and the interrupt ends it at once.
    assert_eq!(interrupt.waits, vec![Duration::from_millis(500); 3]);
}

#[test]
fn a_closed_stdout_ends_the_watch_quietly_with_exit_0() {
    struct Closed(usize);
    impl Write for Closed {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            self.0 += 1;
            if self.0 > 1 {
                return Err(io::ErrorKind::BrokenPipe.into());
            }
            Ok(buf.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    let tmp = tempfile::tempdir().unwrap();
    let a = status_app(tmp.path());
    let config = Config::default();
    let mut interrupt = After {
        ticks: 100,
        waits: Vec::new(),
    };
    assert_eq!(
        status_watch(&a, &ctx(&a, &config), 0.01, &mut Closed(0), &mut interrupt),
        0
    );
    assert_eq!(
        interrupt.waits.len(),
        1,
        "it stopped at the second report, not after 100"
    );
}

#[test]
fn a_status_that_cannot_run_ends_the_watch_with_its_exit_code() {
    let tmp = tempfile::tempdir().unwrap();
    let a = app(tmp.path()); // no handlers
    let config = Config::default();
    let mut out = Vec::new();
    let mut interrupt = After {
        ticks: 5,
        waits: Vec::new(),
    };
    assert_eq!(
        status_watch(&a, &ctx(&a, &config), 1.0, &mut out, &mut interrupt),
        4
    );
    assert!(out.is_empty() && interrupt.waits.is_empty());
}

// ------------------------------------------------------------------ ai-usage serve

/// Ticks every 10 ms, ends when told to.
struct Stop(mpsc::Receiver<()>);

impl Interrupt for Stop {
    fn wait(&mut self, _: Duration) -> bool {
        !matches!(
            self.0.recv_timeout(Duration::from_millis(10)),
            Err(mpsc::RecvTimeoutError::Timeout)
        )
    }
}

#[derive(Clone, Default)]
struct Shared(Arc<Mutex<Vec<u8>>>);

impl Write for Shared {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn row(id: &str, used: f64) -> Row {
    Row {
        provider_id: id.into(),
        error: None,
        snapshot: Some(Snapshot {
            provider_id: id.into(),
            meters: vec![Meter {
                label: "Weekly".into(),
                used: Dec::from_f64(used),
                limit: Dec::from_f64(100.0),
                unit: Unit::Percent,
                resets_at: None,
            }],
            balance: None,
            currency: None,
            fetched_at: 1_795_000_000.0,
        }),
    }
}

struct Server {
    port: u16,
    stop: mpsc::Sender<()>,
    thread: Option<std::thread::JoinHandle<u8>>,
    rows: Arc<Mutex<Vec<Row>>>,
}

impl Server {
    fn start() -> Self {
        let rows = Arc::new(Mutex::new(vec![row("claude", 12.5)]));
        let (stop, rx) = mpsc::channel();
        let out = Shared::default();
        let (shared, source) = (out.clone(), rows.clone());
        let thread = std::thread::spawn(move || {
            let mut out = shared;
            ai_usage_serve(
                0,
                &|| source.lock().unwrap().clone(),
                &mut out,
                &mut Stop(rx),
            )
        });
        let port = loop {
            let line = String::from_utf8(out.0.lock().unwrap().clone()).unwrap();
            if let Some(rest) = line.strip_prefix("AI usage API: http://127.0.0.1:") {
                let (port, tail) = rest.split_once(' ').unwrap();
                assert_eq!(tail, "(cache only; Ctrl-C to stop)\n");
                break port.parse().unwrap();
            }
            std::thread::sleep(Duration::from_millis(5));
        };
        Self {
            port,
            stop,
            thread: Some(thread),
            rows,
        }
    }

    fn connect(&self) -> TcpStream {
        let s = TcpStream::connect(("127.0.0.1", self.port)).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        s
    }

    fn get(&self, raw: &str) -> String {
        let mut s = self.connect();
        s.write_all(raw.replace("{port}", &self.port.to_string()).as_bytes())
            .unwrap();
        let mut text = String::new();
        let _ = s.read_to_string(&mut text);
        text
    }

    fn end(mut self) -> u8 {
        self.stop.send(()).unwrap();
        self.thread.take().unwrap().join().unwrap()
    }
}

#[test]
fn the_server_answers_from_the_cache_rows_and_picks_up_a_refresh() {
    let server = Server::start();
    let ask = "GET /v1/usage/claude HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n";
    let first = server.get(ask);
    assert!(
        first.starts_with("HTTP/1.1 200 OK\r\n") && first.contains("\"used\":12.5"),
        "{first}"
    );
    assert!(
        first.contains("Connection: close\r\n") && first.contains("Cache-Control: no-store\r\n")
    );
    // The next refresh tick (every 10 ms here) re-reads the rows; a request never does.
    *server.rows.lock().unwrap() = vec![row("claude", 40.0)];
    let mut second = String::new();
    for _ in 0..200 {
        second = server.get(ask);
        if second.contains("\"used\":40") {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(second.contains("\"used\":40"), "{second}");
    // Refusals keep their statuses on the wire.
    assert!(
        server
            .get("GET /v1/usage/claude HTTP/1.1\r\nHost: localhost:{port}\r\n\r\n")
            .starts_with("HTTP/1.1 403 Forbidden")
    );
    assert!(
        server
            .get("GET /v1/limits HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\nbody")
            .starts_with("HTTP/1.1 413 Content Too Large")
    );
    let big = format!(
        "GET /v1/limits HTTP/1.1\r\nHost: x\r\nX: {}\r\n\r\n",
        "a".repeat(9000)
    );
    assert!(
        server
            .get(&big)
            .starts_with("HTTP/1.1 431 Request Header Fields Too Large")
    );
    // Ended by the interrupt: exit 0.
    assert_eq!(server.end(), 0);
}

#[test]
fn a_silent_client_gets_408_after_three_seconds_and_a_closed_one_400() {
    let server = Server::start();
    let started = std::time::Instant::now();
    let mut silent = server.connect();
    let mut text = String::new();
    let _ = silent.read_to_string(&mut text);
    assert!(text.starts_with("HTTP/1.1 408 Request Timeout"), "{text}");
    assert!(
        started.elapsed() >= Duration::from_secs(3) && started.elapsed() < Duration::from_secs(8)
    );
    // Half a request, then the client closes its side: bad request, not a hang.
    let mut half = server.connect();
    half.write_all(b"GET /v1/lim").unwrap();
    half.shutdown(std::net::Shutdown::Write).unwrap();
    let mut text = String::new();
    let _ = half.read_to_string(&mut text);
    assert!(text.starts_with("HTTP/1.1 400 Bad Request"), "{text}");
    server.end();
}

#[test]
fn the_sixteenth_connection_gets_503_and_more_are_dropped_unanswered() {
    let server = Server::start();
    let idle: Vec<TcpStream> = (0..15).map(|_| server.connect()).collect();
    // The accept loop counts a connection when it takes it: wait until all 15 are held.
    std::thread::sleep(Duration::from_millis(300));
    let mut sixteenth = server.connect();
    let mut text = String::new();
    let _ = sixteenth.read_to_string(&mut text);
    assert!(
        text.starts_with("HTTP/1.1 503 Service Unavailable"),
        "{text}"
    );
    assert!(text.contains("server_busy"));
    let mut seventeenth_slot = server.connect();
    // 16 are in use while idle ones and the busy answer's thread finish; a connection beyond that
    // may be refused outright: either way it never gets a data answer.
    let mut bytes = Vec::new();
    let _ = seventeenth_slot.read_to_end(&mut bytes);
    assert!(!String::from_utf8_lossy(&bytes).contains("200 OK"));
    drop(idle);
    server.end();
}

#[test]
fn a_port_in_use_is_exit_1_without_a_startup_line() {
    let first = Server::start();
    let mut out = Vec::new();
    let (_tx, rx) = mpsc::channel();
    assert_eq!(
        ai_usage_serve(first.port, &Vec::new, &mut out, &mut Stop(rx)),
        1
    );
    assert!(out.is_empty(), "no startup line when the bind failed");
    first.end();
}
