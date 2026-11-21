//! Keep-awake (port of `AwakeOptions`, `DurationParser`, `UntilTimeParser`,
//! `PowerService` and `KeepAwakeCoordinator`).
//!
//! A power assertion lives exactly as long as the process that created it
//! (macOS releases it at exit), which is why `symcockpit awake` blocks and why
//! an MCP `keep_awake` session lives inside the `serve` process.

use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant, SystemTime};

use symcockpit_contract::Error;

use crate::power::{KeepAwakeSession, KeepAwakeStatus, reference_date_seconds};

/// Kind of keep-awake power assertion.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PowerAssertionType {
    PreventSystemSleep,
    PreventDisplaySleep,
}

/// Port: `IOPMAssertionCreateWithName` / `IOPMAssertionRelease`.
pub trait PowerAssertionPort: Send + Sync {
    fn create(&self, kind: PowerAssertionType, reason: &str) -> Result<u32, Error>;
    fn release(&self, assertion_id: u32);
}

// ------------------------------------------------------------------ parsing

/// `Double(String)` as Swift parses it: no surrounding whitespace.
fn swift_double(text: &str) -> Option<f64> {
    text.parse::<f64>().ok()
}

const WHITESPACE: &[char] = &[' ', '\t', '\n', '\r', '\u{b}', '\u{c}', '\u{85}', '\u{a0}'];

/// `DurationParser.parse`: `500ms`, `2s`, `1.5s`, `5m`, `1h` or raw seconds.
pub fn parse_duration(text: &str) -> Result<f64, Error> {
    let trimmed = text.trim_matches(WHITESPACE);
    if trimmed.is_empty() {
        return Err(Error::Usage("Duration string cannot be empty".into()));
    }
    let invalid = || Error::Usage(format!("Invalid numeric value for duration: '{trimmed}'"));
    let (number, factor) = if let Some(n) = trimmed.strip_suffix("ms") {
        (n, 0.001)
    } else if let Some(n) = trimmed.strip_suffix('s') {
        (n, 1.0)
    } else if let Some(n) = trimmed.strip_suffix('m') {
        (n, 60.0)
    } else if let Some(n) = trimmed.strip_suffix('h') {
        (n, 3600.0)
    } else {
        (trimmed, 1.0)
    };
    let value = swift_double(number).ok_or_else(invalid)?;
    // Swift divides by 1000 for ms; multiplying by 0.001 rounds differently.
    Ok(if factor == 0.001 {
        value / 1000.0
    } else {
        value * factor
    })
}

/// `UntilTimeParser.parse`: seconds from now until the next `HH:MM`
/// (rolling over to tomorrow). `today_at` maps hour and minute to the Unix
/// time of that wall-clock time today in the local zone (DST-correct, supplied
/// by the caller); `now` is the current Unix time.
pub fn parse_until(
    raw: &str,
    now: f64,
    today_at: &dyn Fn(u32, u32) -> Option<f64>,
) -> Result<f64, Error> {
    let trimmed = raw.trim_matches(WHITESPACE);
    let bad = || {
        Error::Usage(format!(
            "awake --until: expected HH:MM (24-hour), got '{trimmed}'."
        ))
    };
    let (hour, minute) = trimmed.split_once(':').ok_or_else(bad)?;
    let (Ok(hour), Ok(minute)) = (hour.parse::<i64>(), minute.parse::<i64>()) else {
        return Err(bad());
    };
    if !(0..=23).contains(&hour) || !(0..=59).contains(&minute) {
        return Err(bad());
    }
    let target = today_at(hour as u32, minute as u32).ok_or_else(|| {
        Error::Usage(format!(
            "awake --until: could not compute target date from {hour}:{minute}."
        ))
    })?;
    // Already passed today: schedule for tomorrow.
    let target = if target <= now {
        target + 86_400.0
    } else {
        target
    };
    Ok(target - now)
}

/// The resolved `awake` command line.
#[derive(Clone, Debug, PartialEq)]
pub struct AwakeOptions {
    pub subcommand: Option<AwakeSubcommand>,
    /// Wake duration in seconds (`None` = block until a signal).
    pub seconds: Option<f64>,
    pub prevent_display_sleep: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AwakeSubcommand {
    Status,
    Off,
}

/// `AwakeOptions.parseOptions`: `status`/`off` must be first; `--until` beats
/// `--for` beats `--seconds`; an unknown flag is an error.
pub fn parse_awake_options(
    args: &[String],
    now: f64,
    today_at: &dyn Fn(u32, u32) -> Option<f64>,
) -> Result<AwakeOptions, Error> {
    match args.first().map(String::as_str) {
        Some("status") => return Ok(subcommand(AwakeSubcommand::Status)),
        Some("off") => return Ok(subcommand(AwakeSubcommand::Off)),
        _ => {}
    }
    let (mut seconds, mut display) = (None, false);
    let (mut for_duration, mut until): (Option<&str>, Option<&str>) = (None, None);
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--display" => display = true,
            "--seconds" | "-s" => {
                i += 1;
                seconds = Some(
                    args.get(i)
                        .and_then(|v| swift_double(v))
                        .filter(|v| v.is_finite() && *v >= 0.0)
                        .ok_or_else(|| {
                            Error::Usage(
                                "awake --seconds requires a number that is finite and non-negative."
                                    .into(),
                            )
                        })?,
                );
            }
            "--for" => {
                i += 1;
                for_duration = Some(args.get(i).ok_or_else(|| {
                    Error::Usage("awake --for requires a duration, e.g. 30m, 2h.".into())
                })?);
            }
            "--until" => {
                i += 1;
                until = Some(args.get(i).ok_or_else(|| {
                    Error::Usage("awake --until requires a time in HH:MM format.".into())
                })?);
            }
            other => return Err(Error::Usage(format!("awake: unknown option '{other}'."))),
        }
        i += 1;
    }
    if let Some(text) = for_duration {
        seconds = Some(parse_duration(text)?);
    }
    if let Some(text) = until {
        seconds = Some(parse_until(text, now, today_at)?);
    }
    if seconds.is_some_and(|s| !s.is_finite() || s < 0.0) {
        return Err(Error::Usage(
            "awake duration must be finite and non-negative.".into(),
        ));
    }
    Ok(AwakeOptions {
        subcommand: None,
        seconds,
        prevent_display_sleep: display,
    })
}

fn subcommand(which: AwakeSubcommand) -> AwakeOptions {
    AwakeOptions {
        subcommand: Some(which),
        seconds: None,
        prevent_display_sleep: false,
    }
}

// ----------------------------------------------------------------- coordinator

struct Inner {
    token: Option<u32>,
    session: Option<KeepAwakeSession>,
    /// Bumped by every begin/end so a stale expiry thread does nothing.
    generation: u64,
}

struct Shared {
    port: Box<dyn PowerAssertionPort>,
    inner: Mutex<Inner>,
    wake: Condvar,
}

/// At most one keep-awake session; thread-safe (the expiry runs on its own thread).
#[derive(Clone)]
pub struct KeepAwakeCoordinator(Arc<Shared>);

impl KeepAwakeCoordinator {
    pub fn new(port: Box<dyn PowerAssertionPort>) -> Self {
        Self(Arc::new(Shared {
            port,
            inner: Mutex::new(Inner {
                token: None,
                session: None,
                generation: 0,
            }),
            wake: Condvar::new(),
        }))
    }

    /// Starts a session; while one is active the call returns it unchanged.
    pub fn begin(
        &self,
        duration: Option<f64>,
        prevent_display_sleep: bool,
        reason: &str,
    ) -> Result<KeepAwakeSession, Error> {
        if let Some(d) = duration
            && !(d.is_finite() && (0.0..=86_400.0).contains(&d))
        {
            return Err(Error::Usage(
                "Keep-awake duration must be finite and between 0 and 86400 seconds.".into(),
            ));
        }
        let mut inner = self.0.inner.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(existing) = inner.session.as_ref().filter(|s| s.active) {
            return Ok(existing.clone());
        }
        let kind = if prevent_display_sleep {
            PowerAssertionType::PreventDisplaySleep
        } else {
            PowerAssertionType::PreventSystemSleep
        };
        inner.token = Some(self.0.port.create(kind, reason)?);
        let started = SystemTime::now();
        let session = KeepAwakeSession {
            active: true,
            prevent_display_sleep,
            started_at: reference_date_seconds(started),
            expires_at: duration.map(|d| reference_date_seconds(started) + d),
            reason: reason.to_owned(),
        };
        inner.session = Some(session.clone());
        inner.generation += 1;
        if let Some(d) = duration {
            let (shared, generation) = (Arc::clone(&self.0), inner.generation);
            std::thread::spawn(move || {
                expire(
                    &shared,
                    generation,
                    Instant::now() + Duration::from_secs_f64(d),
                )
            });
        }
        Ok(session)
    }

    /// Ends the session if one is active. Idempotent.
    pub fn end(&self) {
        let mut inner = self.0.inner.lock().unwrap_or_else(|e| e.into_inner());
        inner.generation += 1;
        self.0.wake.notify_all();
        if let Some(token) = inner.token.take() {
            self.0.port.release(token);
            inner.session = Some(KeepAwakeSession::inactive(SystemTime::now()));
        }
    }

    pub fn is_active(&self) -> bool {
        self.0
            .inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .session
            .as_ref()
            .is_some_and(|s| s.active)
    }
}

impl KeepAwakeStatus for KeepAwakeCoordinator {
    /// Never absent: an inactive session stands for "none".
    fn status(&self) -> KeepAwakeSession {
        self.0
            .inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .session
            .clone()
            .unwrap_or_else(|| KeepAwakeSession::inactive(SystemTime::now()))
    }
}

fn expire(shared: &Shared, generation: u64, deadline: Instant) {
    let mut inner = shared.inner.lock().unwrap_or_else(|e| e.into_inner());
    loop {
        if inner.generation != generation {
            return;
        }
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            break;
        }
        inner = shared
            .wake
            .wait_timeout(inner, left)
            .unwrap_or_else(|e| e.into_inner())
            .0;
    }
    if let Some(token) = inner.token.take() {
        shared.port.release(token);
    }
    inner.session = Some(KeepAwakeSession::inactive(SystemTime::now()));
}

/// `PowerService` + the token count of `TuneController`: the blocking
/// `symcockpit awake` takes one assertion and releases it when done.
pub struct AssertionToken {
    port: Arc<dyn PowerAssertionPort>,
    id: u32,
}

impl AssertionToken {
    pub fn begin(
        port: Arc<dyn PowerAssertionPort>,
        reason: &str,
        prevent_display_sleep: bool,
    ) -> Result<Self, Error> {
        let kind = if prevent_display_sleep {
            PowerAssertionType::PreventDisplaySleep
        } else {
            PowerAssertionType::PreventSystemSleep
        };
        let id = port.create(kind, reason)?;
        Ok(Self { port, id })
    }
}

impl Drop for AssertionToken {
    fn drop(&mut self) {
        self.port.release(self.id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    #[derive(Default)]
    struct FakePort {
        created: Mutex<Vec<(PowerAssertionType, String)>>,
        released: Mutex<Vec<u32>>,
        next: AtomicU32,
        fail: Mutex<bool>,
    }
    impl PowerAssertionPort for Arc<FakePort> {
        fn create(&self, kind: PowerAssertionType, reason: &str) -> Result<u32, Error> {
            if *self.fail.lock().unwrap() {
                return Err(Error::Failed("simulated assertion failure".into()));
            }
            self.created.lock().unwrap().push((kind, reason.into()));
            Ok(self.next.fetch_add(1, Ordering::SeqCst) + 123)
        }
        fn release(&self, id: u32) {
            self.released.lock().unwrap().push(id);
        }
    }
    fn coordinator() -> (KeepAwakeCoordinator, Arc<FakePort>) {
        let port = Arc::new(FakePort::default());
        (KeepAwakeCoordinator::new(Box::new(port.clone())), port)
    }
    fn args(a: &[&str]) -> Vec<String> {
        a.iter().map(ToString::to_string).collect()
    }
    /// 10:00 local "now"; today's HH:MM is `now + (HH:MM - 10:00)`.
    fn today(h: u32, m: u32) -> Option<f64> {
        Some(f64::from(h * 3600 + m * 60))
    }
    const NOW: f64 = 36_000.0;
    fn parse(a: &[&str]) -> Result<AwakeOptions, Error> {
        parse_awake_options(&args(a), NOW, &today)
    }

    // Vectors: tuning/Tests/SymCockpitCoreTests/CLIOptionParsingTests.swift, DurationParser cases.
    #[test]
    fn durations_parse_like_swift() {
        for (text, want) in [
            ("500ms", 0.5),
            ("2s", 2.0),
            ("1.5s", 1.5),
            ("5m", 300.0),
            ("1h", 3600.0),
            ("1.5h", 5400.0),
            ("2", 2.0),
            ("  30m\n", 1800.0),
        ] {
            assert_eq!(parse_duration(text), Ok(want), "{text}");
        }
        assert_eq!(
            parse_duration("  "),
            Err(Error::Usage("Duration string cannot be empty".into()))
        );
        assert_eq!(
            parse_duration("abcm"),
            Err(Error::Usage(
                "Invalid numeric value for duration: 'abcm'".into()
            ))
        );
        assert_eq!(
            parse_duration("ms"),
            Err(Error::Usage(
                "Invalid numeric value for duration: 'ms'".into()
            ))
        );
    }

    #[test]
    fn until_rolls_over_to_tomorrow() {
        assert_eq!(parse_until("10:30", NOW, &today), Ok(1800.0));
        assert_eq!(parse_until("9:30", NOW, &today), Ok(23.5 * 3600.0));
        assert_eq!(
            parse_until("10:00", NOW, &today),
            Ok(86_400.0),
            "equal means passed"
        );
        for bad in [
            "24:00", "10:60", "10", "x:y", ":30", "10:", "1:2:3", "-1:00", "",
        ] {
            assert_eq!(
                parse_until(bad, NOW, &today),
                Err(Error::Usage(format!(
                    "awake --until: expected HH:MM (24-hour), got '{bad}'."
                ))),
                "{bad:?}"
            );
        }
        assert_eq!(parse_until(" 10:30 ", NOW, &today), Ok(1800.0));
    }

    #[test]
    fn options_follow_the_precedence_and_error_texts() {
        assert_eq!(
            parse(&["status", "--bogus"]).unwrap().subcommand,
            Some(AwakeSubcommand::Status)
        );
        assert_eq!(
            parse(&["off"]).unwrap().subcommand,
            Some(AwakeSubcommand::Off)
        );
        let o = parse(&[
            "--display",
            "--seconds",
            "10",
            "--for",
            "1m",
            "--until",
            "10:30",
        ])
        .unwrap();
        assert_eq!((o.seconds, o.prevent_display_sleep), (Some(1800.0), true));
        assert_eq!(parse(&["-s", "5"]).unwrap().seconds, Some(5.0));
        assert_eq!(parse(&[]).unwrap().seconds, None);
        let usage = |m: &str| Err(Error::Usage(m.into()));
        assert_eq!(
            parse(&["--bogus"]),
            usage("awake: unknown option '--bogus'.")
        );
        assert_eq!(
            parse(&["--for"]),
            usage("awake --for requires a duration, e.g. 30m, 2h.")
        );
        assert_eq!(
            parse(&["--until"]),
            usage("awake --until requires a time in HH:MM format.")
        );
        for text in ["nan", "inf", "-inf", "-1", "1e309", "x"] {
            assert_eq!(
                parse(&["--seconds", text]),
                usage("awake --seconds requires a number that is finite and non-negative."),
                "{text}"
            );
        }
        assert_eq!(parse(&["--seconds"]).unwrap_err().exit_code(), 2);
        assert_eq!(
            parse(&["--for", "-5m"]),
            usage("awake duration must be finite and non-negative.")
        );
        assert_eq!(
            parse(&["--for", "inf"]),
            usage("awake duration must be finite and non-negative.")
        );
    }

    // Vectors: KeepAwakeCoordinatorTests.swift
    #[test]
    fn a_session_holds_one_assertion_and_end_releases_it() {
        let (c, port) = coordinator();
        assert!(!c.is_active());
        assert!(!c.status().active);
        let s = c.begin(None, true, "r").unwrap();
        assert!(s.active && s.prevent_display_sleep && s.expires_at.is_none());
        assert_eq!(
            port.created.lock().unwrap().as_slice(),
            [(PowerAssertionType::PreventDisplaySleep, "r".to_owned())]
        );
        let again = c.begin(Some(5.0), false, "other").unwrap();
        assert_eq!(again, s, "an active session is returned unchanged");
        assert_eq!(port.created.lock().unwrap().len(), 1);
        c.end();
        c.end();
        assert_eq!(port.released.lock().unwrap().as_slice(), [123]);
        assert!(!c.is_active() && !c.status().active);
    }

    #[test]
    fn invalid_durations_and_failed_assertions_leave_no_session() {
        let (c, port) = coordinator();
        for d in [-1.0, f64::NAN, f64::INFINITY, 86_401.0] {
            assert_eq!(
                c.begin(Some(d), false, "r").unwrap_err(),
                Error::Usage(
                    "Keep-awake duration must be finite and between 0 and 86400 seconds.".into()
                )
            );
        }
        assert!(port.created.lock().unwrap().is_empty());
        *port.fail.lock().unwrap() = true;
        assert!(c.begin(None, false, "r").is_err());
        assert!(!c.is_active());
    }

    #[test]
    fn a_timed_session_releases_itself_at_expiry() {
        let (c, port) = coordinator();
        let s = c.begin(Some(0.05), false, "r").unwrap();
        assert!(s.expires_at.is_some());
        for _ in 0..200 {
            if !c.is_active() {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(!c.is_active());
        assert_eq!(port.released.lock().unwrap().len(), 1);
    }

    #[test]
    fn ending_early_cancels_the_pending_expiry() {
        let (c, port) = coordinator();
        c.begin(Some(0.05), false, "r").unwrap();
        c.end();
        let second = c.begin(None, false, "again").unwrap();
        std::thread::sleep(Duration::from_millis(120));
        assert!(
            c.is_active(),
            "the stale expiry must not end the new session"
        );
        assert_eq!(c.status(), second);
        assert_eq!(port.released.lock().unwrap().len(), 1);
    }

    #[test]
    fn the_blocking_token_releases_on_drop() {
        let port = Arc::new(FakePort::default());
        let token =
            AssertionToken::begin(Arc::new(port.clone()), "symcockpit awake", false).unwrap();
        assert_eq!(port.created.lock().unwrap().len(), 1);
        drop(token);
        assert_eq!(port.released.lock().unwrap().as_slice(), [123]);
    }
}
