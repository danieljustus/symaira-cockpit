//! `ai-usage serve` answers against the real v0.12.2 binary: the files in
//! `fixtures/ai-usage-api` hold requests and the exact bytes `symcockpit ai-usage serve`
//! (Swift) answered, over loopback, from the synthetic cache files next to them. Only
//! the clock differs: each answer's `generated_at` is fed back in as "now".

use std::collections::BTreeSet;
use std::path::PathBuf;

use serde_json::Value;
use symcockpit_core::ai_usage_api::{Response, cached_rows, route};
use symcockpit_store::parse_iso8601;

fn fixture() -> (Value, PathBuf) {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/ai-usage-api");
    let text = std::fs::read_to_string(dir.join("swift-v0.12.2.json")).unwrap();
    (serde_json::from_str(&text).unwrap(), dir.join("cache"))
}

/// The `generated_at` of an answer, or a fixed instant when it has none.
fn now_of(body: &str) -> f64 {
    serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|v| v["generated_at"].as_str().and_then(parse_iso8601))
        .unwrap_or(1_795_000_000.0)
}

fn answer(
    request: &str,
    expected_body: &str,
    cache: &std::path::Path,
    enabled: &BTreeSet<String>,
) -> Response {
    // The request as the server sees it: up to the blank line, with the port filled in.
    let header = request.replace("{port}", "6737");
    let end = header.find("\r\n\r\n").map_or(header.len(), |i| i + 4);
    let now = now_of(expected_body);
    route(&header.as_bytes()[..end], 6737, now, || {
        cached_rows(cache, enabled, now)
    })
}

fn enabled(fixture: &Value) -> BTreeSet<String> {
    fixture["enabled_providers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn the_documents_are_byte_for_byte_what_the_swift_server_sent() {
    let (fixture, cache) = fixture();
    let enabled = enabled(&fixture);
    let cases = fixture["cases"].as_object().unwrap();
    assert!(cases.len() >= 8);
    for (path, expected) in cases {
        let body = expected["body"].as_str().unwrap();
        let got = answer(
            &format!("GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{{port}}\r\n\r\n"),
            body,
            &cache,
            &enabled,
        );
        assert_eq!(
            u64::from(got.status),
            expected["status"].as_u64().unwrap(),
            "{path}"
        );
        assert_eq!(String::from_utf8(got.body).unwrap(), body, "{path}");
    }
}

#[test]
fn every_refusal_and_edge_of_the_request_is_the_swift_response_with_its_headers() {
    let (fixture, cache) = fixture();
    let enabled = enabled(&fixture);
    let requests = fixture["requests"].as_object().unwrap();
    assert!(requests.len() >= 20);
    for (name, case) in requests {
        let expected = case["response"].as_str().unwrap().replace("{port}", "6737");
        let body = expected.split_once("\r\n\r\n").unwrap().1;
        let got = answer(case["request"].as_str().unwrap(), body, &cache, &enabled);
        assert_eq!(
            String::from_utf8(got.http_bytes()).unwrap(),
            expected,
            "{name}"
        );
    }
}

#[test]
fn a_header_over_8192_bytes_is_refused_before_anything_else() {
    let big = format!(
        "GET /v1/limits HTTP/1.1\r\nHost: x\r\nX: {}\r\n\r\n",
        "a".repeat(9000)
    );
    let got = route(big.as_bytes(), 6737, 0.0, || panic!("the cache was read"));
    assert_eq!(
        (got.status, got.body),
        (431, br#"{"error":"headers_too_large"}"#.to_vec())
    );
}

#[test]
fn only_enabled_providers_are_served_and_none_enabled_means_none() {
    let (_, cache) = fixture();
    let none = cached_rows(&cache, &BTreeSet::new(), 1_795_000_000.0);
    assert!(none.is_empty());
    let one = cached_rows(
        &cache,
        &BTreeSet::from(["nous".to_owned()]),
        1_795_000_000.0,
    );
    assert_eq!(one.len(), 1);
    assert_eq!(one[0].provider_id, "nous");
    // A catalog provider without a file is a row without a snapshot.
    let missing = cached_rows(
        &cache,
        &BTreeSet::from(["copilot".to_owned()]),
        1_795_000_000.0,
    );
    assert_eq!((missing.len(), missing[0].snapshot.is_none()), (1, true));
}

#[test]
fn the_cache_reader_refuses_what_the_swift_reader_refuses() {
    use symcockpit_core::ai_usage_api::parse_cache_entry;
    let good = br#"{"version":1,"snapshot":{"providerId":"claude","meters":[],"fetchedAt":100.0,"source":"oauth"}}"#;
    let now = 978_307_200.0 + 100.0;
    assert!(parse_cache_entry(good, "claude", now).is_some());
    // Another provider's file, an unknown version, a future date and junk are all nothing.
    assert!(parse_cache_entry(good, "codex", now).is_none());
    assert!(parse_cache_entry(&good.replace_version(2), "claude", now).is_none());
    assert!(parse_cache_entry(good, "claude", now - 61.0).is_none());
    assert!(parse_cache_entry(good, "claude", now - 60.0).is_some());
    assert!(parse_cache_entry(b"{not json", "claude", now).is_none());
    let big = vec![b' '; 262_145];
    assert!(parse_cache_entry(&big, "claude", now).is_none());
    // A meter with an unknown unit invalidates the whole entry.
    let bad_unit = br#"{"version":1,"snapshot":{"providerId":"claude","meters":[{"label":"x","unit":{"bits":{}}}],"fetchedAt":100.0,"source":"s"}}"#;
    assert!(parse_cache_entry(bad_unit, "claude", now).is_none());
}

trait ReplaceVersion {
    fn replace_version(&self, v: u8) -> Vec<u8>;
}

impl ReplaceVersion for [u8] {
    fn replace_version(&self, v: u8) -> Vec<u8> {
        String::from_utf8_lossy(self)
            .replace("\"version\":1", &format!("\"version\":{v}"))
            .into_bytes()
    }
}
