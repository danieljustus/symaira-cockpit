//! The two commands that run until interrupted: `status --watch` (one NDJSON line per
//! interval) and `ai-usage serve` (the cached usage as a loopback HTTP API). Both end on
//! SIGINT or SIGTERM through the self-pipe of `symcockpit_macos::signal`, so a sleep never
//! has to be polled, and a closed stdout ends `status --watch` quietly.

use std::io::{ErrorKind, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use symcockpit_contract::{Error, exit};
use symcockpit_core::ai_usage_api::{self, Row};

use crate::app::{App, Context, Params, Request};
use crate::json;

/// What ends a loop early: a signal, in production.
pub trait Interrupt {
    /// Sleeps up to `timeout`; `true` when interrupted before that.
    fn wait(&mut self, timeout: Duration) -> bool;
}

pub struct Signals(std::fs::File);

impl Signals {
    pub fn install() -> Result<Self, Error> {
        symcockpit_macos::signal::terminate_pipe()
            .map(Self)
            .map_err(|e| Error::Failed(format!("cannot handle signals: {e}")))
    }
}

impl Interrupt for Signals {
    fn wait(&mut self, timeout: Duration) -> bool {
        symcockpit_macos::signal::signalled(&self.0, timeout).unwrap_or(false)
    }
}

fn duration(seconds: f64) -> Duration {
    Duration::try_from_secs_f64(seconds).unwrap_or(Duration::MAX)
}

// ------------------------------------------------------------------ status --watch

/// `runStatus` with `--watch`: a report at once, then one every `interval` seconds.
/// Interrupted: 0, there is nothing to put back. A closed stdout: 0 as well (Swift dies
/// by SIGPIPE there; a pipe into `head` is a normal way to end the loop).
pub fn status_watch(
    app: &App,
    ctx: &Context,
    interval: f64,
    out: &mut dyn Write,
    interrupt: &mut dyn Interrupt,
) -> u8 {
    let request = Request {
        command: "status",
        json: true,
        params: Params::None,
    };
    loop {
        let line = match crate::native::run_read(app, ctx, &request)
            .and_then(|o| o.ok_or_else(|| unsupported("status")))
            .and_then(crate::cli::json_value)
        {
            Ok(report) => format!("{}\n", json::compact(&report)),
            Err(error) => {
                eprintln!("symcockpit: {error}");
                return error.exit_code();
            }
        };
        if out
            .write_all(line.as_bytes())
            .and_then(|()| out.flush())
            .is_err()
        {
            return exit::OK;
        }
        if interrupt.wait(duration(interval)) {
            return exit::OK;
        }
    }
}

pub fn unsupported(command: &str) -> Error {
    Error::Unsupported(format!("{command} is not available in this build"))
}

// ------------------------------------------------------------------ ai-usage serve

const MAX_CLIENTS: usize = 16;
const REQUEST_DEADLINE: Duration = Duration::from_secs(3);
const SEND_DEADLINE: Duration = Duration::from_secs(1);
const REFRESH: Duration = Duration::from_secs(2);

fn unix_now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

type Rows = Arc<Mutex<Vec<Row>>>;

/// One request per connection, no keep-alive: read the header within the deadline, answer,
/// close (`AIUsageLocalServer`). The reads of the cache happen in memory only.
fn serve_connection(mut stream: TcpStream, port: u16, rows: &Rows, busy: bool) {
    let deadline = Instant::now() + REQUEST_DEADLINE;
    let response = if busy {
        ai_usage_api::error_response(503, "server_busy")
    } else {
        let mut buffer = Vec::new();
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() || stream.set_read_timeout(Some(left)).is_err() {
                break ai_usage_api::error_response(408, "request_timeout");
            }
            let mut chunk = [0u8; 4096];
            let room = (8193 - buffer.len()).min(chunk.len());
            match stream.read(&mut chunk[..room]) {
                Ok(0) => break ai_usage_api::error_response(400, "bad_request"),
                Ok(n) => buffer.extend_from_slice(&chunk[..n]),
                Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {
                    break ai_usage_api::error_response(408, "request_timeout");
                }
                Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                Err(_) => break ai_usage_api::error_response(400, "bad_request"),
            }
            if buffer.len() > 8192 {
                break ai_usage_api::error_response(431, "headers_too_large");
            }
            if let Some(at) = buffer.windows(4).position(|w| w == b"\r\n\r\n") {
                break if at + 4 != buffer.len() {
                    ai_usage_api::error_response(413, "body_not_allowed")
                } else {
                    ai_usage_api::route(&buffer, port, unix_now(), || {
                        rows.lock().map(|r| r.clone()).unwrap_or_default()
                    })
                };
            }
        }
    };
    let _ = stream.set_write_timeout(Some(SEND_DEADLINE));
    let _ = stream.write_all(&response.http_bytes());
    let _ = stream.shutdown(std::net::Shutdown::Both);
}

/// Listens on 127.0.0.1 and answers until `interrupt`. `refresh` re-reads the cache every
/// two seconds, like Swift's loop; a request never triggers it.
pub fn ai_usage_serve(
    port: u16,
    refresh: &dyn Fn() -> Vec<Row>,
    out: &mut dyn Write,
    interrupt: &mut dyn Interrupt,
) -> u8 {
    let listener = match TcpListener::bind(("127.0.0.1", port)) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("symcockpit: ai-usage serve: cannot listen on 127.0.0.1:{port}: {e}");
            return exit::ERROR;
        }
    };
    let bound = listener.local_addr().map_or(port, |a| a.port());
    let rows: Rows = Arc::new(Mutex::new(refresh()));
    let active = Arc::new(AtomicUsize::new(0));
    {
        let (rows, active) = (rows.clone(), active.clone());
        // Ends with the process: the listener has no other owner to close it.
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let taken = active.fetch_add(1, Ordering::SeqCst);
                if taken >= MAX_CLIENTS {
                    active.fetch_sub(1, Ordering::SeqCst);
                    continue;
                }
                let (rows, active) = (rows.clone(), active.clone());
                std::thread::spawn(move || {
                    // The sixteenth slot answers a bounded 503.
                    serve_connection(stream, bound, &rows, taken + 1 >= MAX_CLIENTS);
                    active.fetch_sub(1, Ordering::SeqCst);
                });
            }
        });
    }
    let _ = writeln!(
        out,
        "AI usage API: http://127.0.0.1:{bound} (cache only; Ctrl-C to stop)"
    );
    let _ = out.flush();
    while !interrupt.wait(REFRESH) {
        if let Ok(mut current) = rows.lock() {
            *current = refresh();
        }
    }
    exit::OK
}
