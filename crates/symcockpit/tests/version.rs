//! `symcockpit version` with the update check against fake and local transports: the
//! policy, the texts (v0.12.2 outputs), the cache file under HOME, and the curl adapter
//! against a loopback server. Nothing here reaches the network.

mod common;

use std::cell::RefCell;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::rc::Rc;

use common::{app, done};
use symcockpit::app::{App, ReleaseSource};
use symcockpit::platform::CurlReleases;
use symcockpit_core::update_check::Fetched;

/// Answers with `reply` and counts the requests.
struct Fake {
    reply: Fetched,
    asked: Rc<RefCell<u32>>,
}

impl ReleaseSource for Fake {
    fn latest(&self) -> Fetched {
        *self.asked.borrow_mut() += 1;
        self.reply.clone()
    }
}

fn release(tag: &str) -> Fetched {
    Ok((
        200,
        format!(r#"{{"tag_name":"{tag}","html_url":"https://example.test/{tag}","assets":[]}}"#)
            .into_bytes(),
    ))
}

fn terminal_app(home: &std::path::Path, reply: Fetched) -> (App, Rc<RefCell<u32>>) {
    let asked = Rc::new(RefCell::new(0));
    let mut a = app(home);
    a.services.stdout_is_terminal = true;
    a.services.release_source = Box::new(Fake {
        reply,
        asked: asked.clone(),
    });
    (a, asked)
}

const V: &str = symcockpit::VERSION;

#[test]
fn without_a_terminal_or_a_request_nothing_is_asked_and_the_swift_bytes_come_out() {
    let tmp = tempfile::tempdir().unwrap();
    let a = app(tmp.path()); // its source panics when asked
    let text = done(&a, &["version"]);
    assert_eq!(
        text.stdout,
        format!("symcockpit {V} \u{2014} update check skipped\n")
    );
    // The v0.12.2 `version --json`, byte for byte (also captured from the real binary).
    let json = done(&a, &["version", "--json"]).stdout;
    assert_eq!(
        json,
        format!(
            "{{\n  \"families\" : [\n\n  ],\n  \"schema_version\" : 1,\n  \"tool\" : \"symcockpit\",\n  \"update\" : {{\n    \"status\" : \"skipped\",\n    \"update_available\" : false\n  }},\n  \"version\" : \"{V}\"\n}}\n"
        )
    );
    // Aliases take the same road.
    assert_eq!(done(&a, &["-V"]).stdout, text.stdout);
    assert_eq!(done(&a, &["--version", "extra"]).stdout, text.stdout);
}

#[test]
fn on_a_terminal_a_newer_release_is_reported_and_cached_for_a_day() {
    let tmp = tempfile::tempdir().unwrap();
    let (a, asked) = terminal_app(tmp.path(), release("v99.0.0"));
    // Pre-1.0 builds are not offered 1.0: use the check's own rule for the expectation.
    assert_eq!(
        done(&a, &["version"]).stdout,
        format!("symcockpit {V} \u{2014} up to date\n")
    );
    assert_eq!(*asked.borrow(), 1);
    let cache = tmp
        .path()
        .join("Library/Caches")
        .join(symcockpit_core::update_check::cache_file_name());
    assert!(cache.is_file(), "the answer is cached");
    // The second call is served from the file: the source would count another request.
    assert_eq!(
        done(&a, &["version"]).stdout,
        format!("symcockpit {V} \u{2014} up to date\n")
    );
    assert_eq!(*asked.borrow(), 1);

    // A patch release of this very line is "available", in both forms.
    let tmp = tempfile::tempdir().unwrap();
    let (major_minor, _) = V.rsplit_once('.').unwrap();
    let newer = format!(
        "v{major_minor}.{}",
        V.rsplit_once('.').unwrap().1.parse::<u32>().unwrap() + 1
    );
    let (a, _) = terminal_app(tmp.path(), release(&newer));
    assert_eq!(
        done(&a, &["version"]).stdout,
        format!("symcockpit {V} \u{2014} update available: {newer}\n")
    );
    let json = done(&a, &["version", "--json"]).stdout;
    assert!(json.contains(&format!(
        "\"update\" : {{\n    \"latest_version\" : \"{newer}\",\n    \"release_url\" : \"https://example.test/{newer}\",\n    \"status\" : \"available\",\n    \"update_available\" : true\n  }}"
    )), "{json}");
}

#[test]
fn a_failing_check_says_unavailable_and_the_version_still_prints() {
    let tmp = tempfile::tempdir().unwrap();
    let (a, _) = terminal_app(tmp.path(), Err(28));
    assert_eq!(
        done(&a, &["version"]).stdout,
        format!("symcockpit {V} \u{2014} update check unavailable\n")
    );
    let json = done(&a, &["version", "--json"]).stdout;
    assert!(
        json.contains("\"error\" : \"The request timed out.\""),
        "{json}"
    );
    assert!(json.contains("\"status\" : \"unavailable\""));
    assert!(
        !tmp.path().join("Library").exists(),
        "a failure is not cached"
    );
}

#[test]
fn every_opt_out_and_opt_in_is_honoured() {
    let skipped = format!("symcockpit {V} \u{2014} update check skipped\n");
    let tmp = tempfile::tempdir().unwrap();
    let ask = |env: &[(&str, &str)], args: &[&str], config: Option<&str>, tty: bool| {
        let dir = tempfile::tempdir_in(tmp.path()).unwrap();
        let (mut a, asked) = terminal_app(dir.path(), Err(28));
        a.services.stdout_is_terminal = tty;
        for (k, v) in env {
            a.env.insert((*k).into(), (*v).into());
        }
        if let Some(text) = config {
            let file = a.paths.config_file();
            std::fs::create_dir_all(file.parent().unwrap()).unwrap();
            std::fs::write(file, text).unwrap();
        }
        let out = done(&a, args).stdout;
        (out, *asked.borrow())
    };
    // Opt-outs on a terminal.
    assert_eq!(
        ask(&[], &["version", "--no-update-check"], None, true),
        (skipped.clone(), 0)
    );
    assert_eq!(
        ask(
            &[("SYMCOCKPIT_CHECK_UPDATES", "off")],
            &["version"],
            None,
            true
        ),
        (skipped.clone(), 0)
    );
    assert_eq!(
        ask(&[("SYMTUNE_CHECK_UPDATES", "0")], &["version"], None, true),
        (skipped.clone(), 0)
    );
    assert_eq!(
        ask(
            &[],
            &["version"],
            Some("[general]\ncheck_updates = false\n"),
            true
        ),
        (skipped.clone(), 0)
    );
    // The same file does not apply when the environment decides.
    assert_eq!(
        ask(
            &[("SYMTUNE_CHECK_UPDATES", "1")],
            &["version"],
            Some("[general]\ncheck_updates = false\n"),
            true
        )
        .1,
        1
    );
    // Opt-in without a terminal; but never against an opt-out.
    assert_eq!(
        ask(
            &[("SYMCOCKPIT_CHECK_UPDATES", "1")],
            &["version"],
            None,
            false
        )
        .1,
        1
    );
    assert_eq!(
        ask(
            &[("SYMCOCKPIT_CHECK_UPDATES", "1")],
            &["version", "--no-update-check"],
            None,
            false
        ),
        (skipped, 0)
    );
    // Not on a terminal and not asked: no request.
    assert_eq!(ask(&[], &["version"], None, false).1, 0);
}

// ------------------------------------------------------------------ the curl adapter

/// One request, answered with `status` and `body`; returns the request text.
fn serve_once(status: &str, body: &str) -> (String, std::thread::JoinHandle<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!(
        "http://127.0.0.1:{}/repos/o/r/releases/latest",
        listener.local_addr().unwrap().port()
    );
    let reply = format!(
        "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let handle = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut request = vec![0u8; 4096];
        let n = stream.read(&mut request).unwrap();
        stream.write_all(reply.as_bytes()).unwrap();
        String::from_utf8_lossy(&request[..n]).into_owned()
    });
    (url, handle)
}

#[test]
fn curl_returns_status_and_body_and_sends_the_github_headers() {
    let (url, request) = serve_once("200 OK", r#"{"tag_name":"v1.2.3","html_url":"u"}"#);
    let source = CurlReleases {
        curl: "/usr/bin/curl".into(),
        url,
    };
    let (status, body) = source.latest().unwrap();
    assert_eq!(
        (status, body.as_slice()),
        (200, br#"{"tag_name":"v1.2.3","html_url":"u"}"#.as_slice())
    );
    let request = request.join().unwrap().to_lowercase();
    assert!(
        request.starts_with("get /repos/o/r/releases/latest http/1.1"),
        "{request}"
    );
    assert!(
        request.contains("accept: application/vnd.github+json"),
        "{request}"
    );
    assert!(
        request.contains(&format!("user-agent: symcockpit/{V}")),
        "{request}"
    );
}

#[test]
fn curl_reports_an_error_status_as_is_and_a_dead_port_as_curls_exit_code() {
    let (url, request) = serve_once("403 Forbidden", "{}");
    let source = CurlReleases {
        curl: "/usr/bin/curl".into(),
        url,
    };
    assert_eq!(source.latest().unwrap().0, 403);
    request.join().unwrap();
    // Nothing listens any more: curl's "could not connect" (7).
    let dead = CurlReleases {
        curl: "/usr/bin/curl".into(),
        url: source.url.clone(),
    };
    assert_eq!(dead.latest().unwrap_err(), 7);
    // No curl at all counts as a failed connection, not a crash.
    let missing = CurlReleases {
        curl: "/nonexistent/curl".into(),
        url: source.url,
    };
    assert_eq!(missing.latest().unwrap_err(), 7);
}
