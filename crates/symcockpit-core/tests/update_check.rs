//! The update check against what the real v0.12.2 binary left behind: the cache file it
//! wrote after asking GitHub (`fixtures/update-check/swift-v0.12.2-cache.json`, captured
//! with `SYMCOCKPIT_CHECK_UPDATES=1 symcockpit version`, which printed "up to date").

use symcockpit_core::ai_usage::REFERENCE_DATE_OFFSET;
use symcockpit_core::update_check::{Report, cache_file_name, check};

const CACHE: &[u8] = include_bytes!("fixtures/update-check/swift-v0.12.2-cache.json");

fn fetched_unix() -> f64 {
    let v: serde_json::Value = serde_json::from_slice(CACHE).unwrap();
    v["fetchedAt"].as_f64().unwrap() + REFERENCE_DATE_OFFSET
}

#[test]
fn the_cache_file_name_is_the_one_the_swift_binary_used() {
    // `find .../Library/Caches/symaira/updatecheck` after the v0.12.2 run.
    assert_eq!(
        cache_file_name(),
        "symaira/updatecheck/5f59116eff849ccde9508ace246d581da8ba8d043284a3bcaf58da2d66775fda.json"
    );
}

#[test]
fn a_fresh_swift_cache_answers_without_a_request() {
    let now = fetched_unix() + 3600.0;
    let nothing = || panic!("a request was made");
    // The release in the cache is v0.12.2: the same version is up to date, an older one is offered it.
    assert_eq!(
        check("0.12.2", now, Some(CACHE), nothing).0,
        Report::UpToDate
    );
    match check("0.12.1", now, Some(CACHE), nothing).0 {
        Report::Available(release) => {
            assert_eq!(release.tag, "v0.12.2");
            assert_eq!(
                release.html_url,
                "https://github.com/danieljustus/symaira-cockpit/releases/tag/v0.12.2"
            );
            assert_eq!(release.assets.len(), 4);
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn after_a_day_the_swift_cache_is_stale_and_the_release_is_asked_for_again() {
    let now = fetched_unix() + 24.0 * 3600.0 + 1.0;
    let asked = std::cell::Cell::new(false);
    let (report, store) = check("0.12.2", now, Some(CACHE), || {
        asked.set(true);
        Err(28)
    });
    assert!(asked.get());
    assert_eq!(report, Report::Unavailable("The request timed out.".into()));
    assert!(store.is_none());
}
