use std::{
    ffi::{CStr, CString, c_char},
    fs,
    io::{Read, Write},
    path::Path,
};

use serde_json::{Value, json};
use tempfile::TempDir;

use super::*;

fn names(v: &Value) -> Vec<&str> {
    v["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["path"].as_str().unwrap())
        .collect()
}

fn notices(v: &Value) -> String {
    v["notices"].to_string()
}

// ---- folders (R70) ----

#[test]
fn folder_lists_one_level_folders_first() {
    let d = TempDir::new().unwrap();
    fs::create_dir_all(d.path().join("sub/deeper")).unwrap();
    fs::write(d.path().join("b.txt"), b"hi").unwrap();
    fs::write(d.path().join("A.txt"), b"hello").unwrap();
    fs::write(d.path().join("sub/inner.txt"), b"x").unwrap();
    let v = list_dir(d.path().to_str().unwrap(), None);
    assert_eq!(v["ok"], true);
    assert_eq!(names(&v), ["sub", "A.txt", "b.txt"]);
    assert_eq!(v["truncated"], true, "the subfolder was not descended");
    assert!(notices(&v).contains("depth 1"));
    assert_eq!(v["entries"][1]["size"], 5);
}

#[test]
fn folder_depth_option_descends_level_by_level() {
    let d = TempDir::new().unwrap();
    fs::create_dir_all(d.path().join("sub/deeper")).unwrap();
    fs::write(d.path().join("sub/inner.txt"), b"x").unwrap();
    fs::write(d.path().join("sub/deeper/leaf.txt"), b"x").unwrap();
    let v = list_dir(d.path().to_str().unwrap(), Some(r#"{"max_depth":2}"#));
    assert_eq!(names(&v), ["sub", "sub/deeper", "sub/inner.txt"]);
    assert_eq!(v["entries"][1]["depth"], 2);
    assert_eq!(v["truncated"], true, "deeper was not descended");
    let v = list_dir(d.path().to_str().unwrap(), Some(r#"{"max_depth":3}"#));
    assert_eq!(v["truncated"], false);
    assert_eq!(v["entries"].as_array().unwrap().len(), 4);
}

#[test]
fn folder_entry_limit_gives_a_partial_result_with_a_notice() {
    let d = TempDir::new().unwrap();
    for i in 0..10 {
        fs::write(d.path().join(format!("f{i}")), b"").unwrap();
    }
    let v = list_dir(d.path().to_str().unwrap(), Some(r#"{"max_entries":4}"#));
    assert_eq!(v["ok"], true);
    assert_eq!(v["entries"].as_array().unwrap().len(), 4);
    assert_eq!(v["truncated"], true);
    assert!(notices(&v).contains("entry limit 4"));
}

#[test]
fn folder_time_limit_stops_with_a_notice() {
    let d = TempDir::new().unwrap();
    fs::write(d.path().join("a"), b"").unwrap();
    let v = list_dir(d.path().to_str().unwrap(), Some(r#"{"time_ms":0}"#));
    assert_eq!(v["ok"], true);
    assert_eq!(v["truncated"], true);
    assert!(notices(&v).contains("time limit"));
}

#[test]
fn folder_symlinks_are_reported_not_followed() {
    let d = TempDir::new().unwrap();
    let outside = TempDir::new().unwrap();
    fs::write(outside.path().join("secret.txt"), b"x").unwrap();
    std::os::unix::fs::symlink(outside.path(), d.path().join("link")).unwrap();
    let v = list_dir(d.path().to_str().unwrap(), Some(r#"{"max_depth":3}"#));
    assert_eq!(names(&v), ["link"]);
    assert_eq!(v["entries"][0]["kind"], "symlink");
    assert_eq!(v["truncated"], false);
}

#[test]
fn control_characters_in_names_are_replaced() {
    let d = TempDir::new().unwrap();
    fs::write(d.path().join("a\u{7}b\nc"), b"").unwrap();
    let v = list_dir(d.path().to_str().unwrap(), None);
    assert_eq!(names(&v), ["a?b?c"]);
}

#[test]
fn options_cannot_lift_the_ceilings_and_bad_json_is_an_error() {
    let l = Limits::DIR
        .with_options(Some(
            r#"{"max_entries":999999999,"time_ms":99999999,"max_depth":999}"#,
        ))
        .unwrap();
    assert_eq!(
        (l.max_entries, l.time_ms, l.max_depth),
        (
            limits::CEIL_ENTRIES,
            limits::CEIL_TIME_MS,
            limits::CEIL_DEPTH
        )
    );
    assert_eq!(list_dir("/", Some("{nope"))["ok"], false);
}

// ---- archives (R71) ----

fn zip_path(dir: &Path, entries: &[(&str, &[u8])]) -> std::path::PathBuf {
    let p = dir.join("t.zip");
    let mut w = zip::ZipWriter::new(fs::File::create(&p).unwrap());
    let o =
        zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
    for (name, body) in entries {
        if name.ends_with('/') {
            w.add_directory(*name, o).unwrap();
        } else {
            w.start_file(*name, o).unwrap();
            w.write_all(body).unwrap();
        }
    }
    w.finish().unwrap();
    p
}

#[test]
fn zip_is_listed_without_unpacking() {
    let d = TempDir::new().unwrap();
    let p = zip_path(
        d.path(),
        &[("docs/", b""), ("docs/readme.txt", b"12345678")],
    );
    let v = list_archive(p.to_str().unwrap(), None);
    assert_eq!(v["ok"], true, "{v}");
    assert_eq!(v["format"], "zip");
    assert_eq!(v["total_entries"], 2);
    assert_eq!(v["truncated"], false);
    assert_eq!(names(&v), ["docs", "docs/readme.txt"]);
    assert_eq!(v["entries"][0]["kind"], "dir");
    assert_eq!(v["entries"][1]["name"], "readme.txt");
    assert_eq!(v["entries"][1]["size"], 8);
    // Nothing was written next to the archive.
    assert_eq!(fs::read_dir(d.path()).unwrap().count(), 1);
}

/// A "bomb" by declaration: ten tiny stored entries whose central directory claims 4 GiB each.
/// Listing must stop at the size limit, report the cause and never touch the bodies.
fn bomb_zip(dir: &Path) -> std::path::PathBuf {
    let entries: Vec<(String, &[u8])> = (0..10)
        .map(|i| (format!("bomb{i}.bin"), &b"x"[..]))
        .collect();
    let refs: Vec<(&str, &[u8])> = entries.iter().map(|(n, b)| (n.as_str(), *b)).collect();
    let p = zip_path(dir, &refs);
    let mut bytes = fs::read(&p).unwrap();
    let mut patched = 0;
    for i in 0..bytes.len() - 46 {
        if bytes[i..i + 4] == [0x50, 0x4b, 0x01, 0x02] {
            // central directory header: uncompressed size at offset 24
            bytes[i + 24..i + 28].copy_from_slice(&0xF000_0000u32.to_le_bytes());
            patched += 1;
        }
    }
    assert_eq!(patched, 10);
    fs::write(&p, bytes).unwrap();
    p
}

#[test]
fn zip_bomb_by_declared_size_is_cut_with_a_notice() {
    let d = TempDir::new().unwrap();
    let p = bomb_zip(d.path());
    let size_before = fs::metadata(&p).unwrap().len();
    assert!(size_before < 2_000);
    let v = list_archive(
        p.to_str().unwrap(),
        Some(r#"{"max_total_bytes":8589934592}"#),
    );
    assert_eq!(v["ok"], true, "{v}");
    assert_eq!(v["truncated"], true);
    assert!(notices(&v).contains("declared total size limit"), "{v}");
    assert!(notices(&v).contains("compression ratio"), "{v}");
    let listed = v["entries"].as_array().unwrap().len();
    assert!((1..10).contains(&listed), "partial, not empty: {listed}");
    assert_eq!(v["total_entries"], 10);
    assert!(v["declared_bytes"].as_u64().unwrap() <= 8 << 30);
}

#[test]
fn zip_with_too_many_entries_is_cut_at_the_entry_limit() {
    let d = TempDir::new().unwrap();
    let entries: Vec<(String, &[u8])> = (0..300).map(|i| (format!("f{i}"), &b""[..])).collect();
    let refs: Vec<(&str, &[u8])> = entries.iter().map(|(n, b)| (n.as_str(), *b)).collect();
    let p = zip_path(d.path(), &refs);
    let v = list_archive(p.to_str().unwrap(), Some(r#"{"max_entries":100}"#));
    assert_eq!(v["entries"].as_array().unwrap().len(), 100);
    assert_eq!(v["total_entries"], 300);
    assert_eq!(v["truncated"], true);
    assert!(notices(&v).contains("entry limit 100"));
}

#[test]
fn zip_depth_limit_hides_deep_entries_and_says_so() {
    let d = TempDir::new().unwrap();
    let p = zip_path(d.path(), &[("a.txt", b""), ("x/y/z/deep.txt", b"")]);
    let v = list_archive(p.to_str().unwrap(), Some(r#"{"max_depth":2}"#));
    assert_eq!(names(&v), ["a.txt"]);
    assert_eq!(v["truncated"], true);
    assert!(notices(&v).contains("deeper than 2"));
}

#[test]
fn archive_time_limit_gives_a_partial_result() {
    let d = TempDir::new().unwrap();
    let p = zip_path(d.path(), &[("a", b""), ("b", b"")]);
    let v = list_archive(p.to_str().unwrap(), Some(r#"{"time_ms":0}"#));
    assert_eq!(v["ok"], true);
    assert_eq!(v["truncated"], true);
    assert!(notices(&v).contains("time limit"));
}

#[test]
fn tar_is_listed() {
    let d = TempDir::new().unwrap();
    let p = d.path().join("t.tar");
    let mut b = tar::Builder::new(fs::File::create(&p).unwrap());
    for (name, body) in [("dir/a.txt", &b"hello"[..]), ("b.txt", b"x")] {
        let mut h = tar::Header::new_gnu();
        h.set_size(body.len() as u64);
        h.set_cksum();
        b.append_data(&mut h, name, body).unwrap();
    }
    b.finish().unwrap();
    let v = list_archive(p.to_str().unwrap(), None);
    assert_eq!(v["ok"], true, "{v}");
    assert_eq!(v["format"], "tar");
    assert_eq!(names(&v), ["dir/a.txt", "b.txt"]);
    assert_eq!(v["entries"][0]["size"], 5);
    assert_eq!(v["total_entries"], 2);
    let cut = list_archive(p.to_str().unwrap(), Some(r#"{"max_entries":1}"#));
    assert_eq!(cut["truncated"], true);
    assert_eq!(cut["total_entries"], Value::Null, "unknown when cut short");
}

#[test]
fn sevenz_is_listed_and_a_big_declaration_is_cut() {
    let d = TempDir::new().unwrap();
    let p = d.path().join("t.7z");
    let mut w = sevenz_rust2::ArchiveWriter::create(&p).unwrap();
    for (name, size) in [("zeros1.bin", 2usize << 20), ("zeros2.bin", 2 << 20)] {
        w.push_archive_entry(
            sevenz_rust2::ArchiveEntry::new_file(name),
            Some(std::io::repeat(0).take(size as u64)),
        )
        .unwrap();
    }
    w.push_archive_entry::<&[u8]>(sevenz_rust2::ArchiveEntry::new_directory("folder"), None)
        .unwrap();
    w.finish().unwrap();
    assert!(
        fs::metadata(&p).unwrap().len() < 100_000,
        "compressed far below the declared size"
    );
    let v = list_archive(p.to_str().unwrap(), None);
    assert_eq!(v["ok"], true, "{v}");
    assert_eq!(v["format"], "7z");
    assert_eq!(v["total_entries"], 3);
    assert_eq!(v["entries"].as_array().unwrap().len(), 3);
    let cut = list_archive(p.to_str().unwrap(), Some(r#"{"max_total_bytes":3000000}"#));
    assert_eq!(cut["truncated"], true);
    assert!(notices(&cut).contains("declared total size limit"), "{cut}");
    assert_eq!(cut["entries"].as_array().unwrap().len(), 1);
}

#[test]
fn sevenz_header_with_a_giant_size_claim_is_rejected_not_allocated() {
    // 7z start header claiming a ~4 EiB next header: the reader must refuse it.
    let d = TempDir::new().unwrap();
    let p = d.path().join("evil.7z");
    let mut f = Vec::new();
    f.extend_from_slice(b"7z\xBC\xAF\x27\x1C\x00\x04");
    let mut start = Vec::new();
    start.extend_from_slice(&0u64.to_le_bytes()); // next header offset
    start.extend_from_slice(&(1u64 << 62).to_le_bytes()); // next header size
    start.extend_from_slice(&0u32.to_le_bytes()); // next header crc
    f.extend_from_slice(&crc32(&start).to_le_bytes());
    f.extend_from_slice(&start);
    fs::write(&p, f).unwrap();
    let v = list_archive(p.to_str().unwrap(), None);
    assert_eq!(v["ok"], false, "{v}");
}

fn crc32(data: &[u8]) -> u32 {
    let mut c = !0u32;
    for b in data {
        c ^= u32::from(*b);
        for _ in 0..8 {
            c = if c & 1 == 1 {
                (c >> 1) ^ 0xEDB8_8320
            } else {
                c >> 1
            };
        }
    }
    !c
}

#[test]
fn unsupported_and_broken_inputs_are_json_errors() {
    let d = TempDir::new().unwrap();
    let junk = d.path().join("junk.zip");
    fs::write(&junk, b"not an archive").unwrap();
    let v = list_archive(junk.to_str().unwrap(), None);
    assert_eq!(v["ok"], false);
    assert!(v["error"].as_str().unwrap().contains("not a ZIP"));
    let gz = d.path().join("x.tar.gz");
    fs::write(&gz, [0x1f, 0x8b, 8, 0, 0, 0, 0, 0]).unwrap();
    assert!(
        list_archive(gz.to_str().unwrap(), None)["error"]
            .as_str()
            .unwrap()
            .contains(".tar.gz")
    );
    assert_eq!(list_archive("/nonexistent/x.zip", None)["ok"], false);
    assert_eq!(list_dir("/nonexistent", None)["ok"], false);
    // A truncated ZIP (valid magic, no central directory).
    let cut = d.path().join("cut.zip");
    fs::write(&cut, b"PK\x03\x04 truncated").unwrap();
    assert_eq!(list_archive(cut.to_str().unwrap(), None)["ok"], false);
}

#[test]
fn a_panic_never_crosses_the_boundary() {
    let v = run(|| panic!("boom"));
    assert_eq!(v, json!({"ok": false, "error": "internal error"}));
}

// ---- the C ABI itself ----

type CFn = extern "C" fn(*const c_char, *const c_char) -> *mut c_char;

fn c_call(f: CFn, path: Option<&str>, options: Option<&str>) -> Value {
    let p = path.map(|s| CString::new(s).unwrap());
    let o = options.map(|s| CString::new(s).unwrap());
    let raw = f(
        p.as_ref().map_or(std::ptr::null(), |c| c.as_ptr()),
        o.as_ref().map_or(std::ptr::null(), |c| c.as_ptr()),
    );
    assert!(!raw.is_null());
    // SAFETY: `raw` is a NUL-terminated string this library just returned.
    let text = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_owned();
    ffi::symcockpit_free_string(raw);
    serde_json::from_str(&text).unwrap()
}

#[test]
fn c_abi_round_trip_null_and_non_utf8_arguments() {
    let d = TempDir::new().unwrap();
    fs::write(d.path().join("a"), b"").unwrap();
    let p = zip_path(d.path(), &[("x.txt", b"1")]);
    let v = c_call(ffi::symcockpit_list_dir_json, d.path().to_str(), None);
    assert_eq!(v["ok"], true);
    let v = c_call(
        ffi::symcockpit_list_archive_json,
        p.to_str(),
        Some(r#"{"max_entries":1}"#),
    );
    assert_eq!(v["format"], "zip");
    for f in [
        ffi::symcockpit_list_dir_json as CFn,
        ffi::symcockpit_list_archive_json,
    ] {
        assert_eq!(
            c_call(f, None, None),
            json!({"ok": false, "error": "path is null"})
        );
        assert_eq!(
            c_call(f, Some("/"), Some("{bad")).get("ok"),
            Some(&json!(false))
        );
    }
    let bad = [0xff_u8, 0xfe, 0];
    let raw = ffi::symcockpit_list_dir_json(bad.as_ptr().cast(), std::ptr::null());
    // SAFETY: as above.
    let text = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_owned();
    ffi::symcockpit_free_string(raw);
    assert!(text.contains("not UTF-8"));
    ffi::symcockpit_free_string(std::ptr::null_mut());
}

#[test]
fn abi_and_crate_versions() {
    assert_eq!(ffi::symcockpit_ffi_abi_version(), ABI_VERSION);
    // SAFETY: static NUL-terminated string.
    let v = unsafe { CStr::from_ptr(ffi::symcockpit_ffi_version()) }
        .to_str()
        .unwrap();
    assert_eq!(v, env!("CARGO_PKG_VERSION"));
    let header = include_str!("../include/symcockpit_ffi.h");
    assert!(header.contains(&format!("#define SYMCOCKPIT_FFI_ABI_VERSION {ABI_VERSION}")));
    for sym in [
        "symcockpit_list_dir_json",
        "symcockpit_list_archive_json",
        "symcockpit_free_string",
        "symcockpit_ffi_abi_version",
        "symcockpit_ffi_version",
    ] {
        assert!(header.contains(sym), "{sym} missing in the header");
    }
}
