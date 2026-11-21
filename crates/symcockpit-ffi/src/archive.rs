//! Archive listings (R71): ZIP, TAR and 7z. Only directory structures are read; no entry
//! body is ever decoded or written anywhere. Every loop is bounded by `Limits`.

use std::{
    fs::File,
    io::{Read, Seek, SeekFrom},
    path::Path,
    sync::mpsc,
    thread,
};

use serde_json::{Value, json};

use crate::limits::{Deadline, Limits, Notices, clean_name};

/// One listed entry; sizes are what the archive declares, not what unpacking would yield.
struct Row {
    path: String,
    dir: bool,
    size: u64,
    compressed: Option<u64>,
}

/// Collects rows under all four limits; `push` says whether listing may go on.
struct Sink {
    limits: Limits,
    deadline: Deadline,
    rows: Vec<Row>,
    declared: u64,
    seen: u64,
    notices: Notices,
    ratio_warned: bool,
}

impl Sink {
    fn new(limits: Limits) -> Self {
        Self {
            limits,
            deadline: Deadline::start(&limits),
            rows: Vec::new(),
            declared: 0,
            seen: 0,
            notices: Notices::default(),
            ratio_warned: false,
        }
    }

    fn push(&mut self, raw_path: &str, dir: bool, size: u64, compressed: Option<u64>) -> bool {
        if self.deadline.passed() {
            self.notices.add("time limit reached");
            return false;
        }
        if self.rows.len() >= self.limits.max_entries {
            self.notices
                .add(format!("entry limit {} reached", self.limits.max_entries));
            return false;
        }
        self.seen += 1;
        let path = clean_name(raw_path.trim_end_matches('/'));
        let depth = path.split('/').filter(|c| !c.is_empty()).count();
        if depth > self.limits.max_depth {
            self.notices.add(format!(
                "entries deeper than {} levels are hidden",
                self.limits.max_depth
            ));
            return true;
        }
        let declared = self.declared.saturating_add(size);
        if declared > self.limits.max_total_bytes {
            self.notices.add("declared total size limit exceeded");
            return false;
        }
        self.declared = declared;
        if !self.ratio_warned
            && let Some(c) = compressed
            && c > 0
            && size >= 1 << 20
            && size / c >= 1000
        {
            self.ratio_warned = true;
            self.notices
                .add("very high compression ratio: this archive may be a decompression bomb");
        }
        self.rows.push(Row {
            path,
            dir,
            size,
            compressed,
        });
        true
    }

    fn finish(self, format: &str, total: Option<u64>) -> Value {
        let truncated = !self.notices.is_empty();
        let entries: Vec<Value> = self
            .rows
            .iter()
            .map(|r| {
                let name = r.path.rsplit('/').next().unwrap_or(&r.path);
                let depth = r.path.matches('/').count() + 1;
                let mut e = json!({
                    "name": name, "path": r.path, "kind": if r.dir { "dir" } else { "file" },
                    "size": r.size, "depth": depth,
                });
                if let Some(c) = r.compressed {
                    e["compressed"] = json!(c);
                }
                e
            })
            .collect();
        json!({
            "ok": true, "format": format, "entries": entries, "truncated": truncated,
            "total_entries": total, "declared_bytes": self.declared,
            "notices": self.notices.into_json(),
        })
    }
}

pub fn list(path: &Path, limits: Limits) -> Result<Value, String> {
    let mut file = File::open(path).map_err(|e| e.to_string())?;
    let mut magic = [0u8; 512];
    let n = read_up_to(&mut file, &mut magic).map_err(|e| e.to_string())?;
    file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
    let magic = &magic[..n];
    if magic.starts_with(b"PK\x03\x04") || magic.starts_with(b"PK\x05\x06") {
        zip_list(file, limits)
    } else if magic.starts_with(b"7z\xBC\xAF\x27\x1C") {
        sevenz_list(path, limits)
    } else if magic.len() >= 262 && &magic[257..262] == b"ustar" {
        tar_list(file, limits)
    } else if magic.starts_with(&[0x1f, 0x8b]) {
        Err("compressed tar archives (.tar.gz) are not supported".into())
    } else {
        Err("not a ZIP, TAR or 7z archive".into())
    }
}

fn read_up_to(file: &mut File, buf: &mut [u8]) -> std::io::Result<usize> {
    let mut n = 0;
    while n < buf.len() {
        match file.read(&mut buf[n..])? {
            0 => break,
            k => n += k,
        }
    }
    Ok(n)
}

fn zip_list(file: File, limits: Limits) -> Result<Value, String> {
    let mut sink = Sink::new(limits);
    let mut zip = zip::ZipArchive::new(file).map_err(|e| e.to_string())?;
    let total = zip.len() as u64;
    for i in 0..zip.len() {
        // by_index_raw: header only, the entry body is never decoded.
        let f = zip.by_index_raw(i).map_err(|e| e.to_string())?;
        let name = f
            .name()
            .map_or_else(|_| "<invalid name>".to_owned(), |n| n.into_owned());
        if !sink.push(&name, f.is_dir(), f.size(), Some(f.compressed_size())) {
            break;
        }
    }
    Ok(sink.finish("zip", Some(total)))
}

fn tar_list(file: File, limits: Limits) -> Result<Value, String> {
    let mut sink = Sink::new(limits);
    let mut archive = tar::Archive::new(file);
    let mut complete = true;
    for entry in archive.entries_with_seek().map_err(|e| e.to_string())? {
        let entry = entry.map_err(|e| e.to_string())?;
        let name = String::from_utf8_lossy(&entry.path_bytes()).into_owned();
        let dir = entry.header().entry_type().is_dir();
        if !sink.push(&name, dir, entry.size(), None) {
            complete = false;
            break;
        }
    }
    let total = complete.then_some(sink.seen);
    Ok(sink.finish("tar", total))
}

/// Header memory the 7z reader may allocate: far above a real header, far below RAM.
const SEVENZ_HEADER_KIB: usize = 16 * 1024;

fn sevenz_list(path: &Path, limits: Limits) -> Result<Value, String> {
    // shortcut: the 7z reader has no deadline of its own, so it runs in a thread that is
    // abandoned on timeout (its memory is capped by SEVENZ_HEADER_KIB); upgrade by
    // moving 7z parsing into a killable helper process if that ever bites.
    let deadline = Deadline::start(&limits);
    let path = path.to_path_buf();
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let result = File::open(&path)
            .map_err(|e| e.to_string())
            .and_then(|mut f| {
                sevenz_rust2::Archive::read_with_memory_limit(
                    &mut f,
                    &sevenz_rust2::Password::empty(),
                    SEVENZ_HEADER_KIB,
                )
                .map_err(|e| e.to_string())
            });
        let _ = tx.send(result);
    });
    let archive = rx
        .recv_timeout(deadline.remaining())
        .map_err(|_| "time limit reached while reading the 7z header".to_owned())??;
    let mut sink = Sink::new(limits);
    let total = archive.files.len() as u64;
    for f in &archive.files {
        if !sink.push(f.name(), f.is_directory(), f.size, Some(f.compressed_size)) {
            break;
        }
    }
    Ok(sink.finish("7z", Some(total)))
}
