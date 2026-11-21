//! Limits shared by folder and archive listings (R70, R71). A caller may tighten
//! them through the options JSON but never lift them past the hard ceilings.

use std::time::{Duration, Instant};

use serde_json::{Value, json};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Limits {
    pub max_entries: usize,
    /// Folders: levels listed below the root (1 = the folder itself). Archives: deepest path shown.
    pub max_depth: usize,
    /// Archives: sum of the declared (unpacked) sizes the listing may report.
    pub max_total_bytes: u64,
    pub time_ms: u64,
}

pub const CEIL_ENTRIES: usize = 100_000;
pub const CEIL_DEPTH: usize = 64;
pub const CEIL_TIME_MS: u64 = 10_000;

impl Limits {
    pub const DIR: Limits = Limits {
        max_entries: 5_000,
        max_depth: 1,
        max_total_bytes: u64::MAX,
        time_ms: 2_000,
    };
    pub const ARCHIVE: Limits = Limits {
        max_entries: 5_000,
        max_depth: 32,
        max_total_bytes: 16 << 30,
        time_ms: 2_000,
    };

    /// Applies `{"max_entries":..,"max_depth":..,"max_total_bytes":..,"time_ms":..}` over
    /// `self`; unknown keys are ignored, values are clamped to the ceilings.
    pub fn with_options(mut self, options: Option<&str>) -> Result<Self, String> {
        let Some(text) = options.filter(|t| !t.trim().is_empty()) else {
            return Ok(self);
        };
        let v: Value = serde_json::from_str(text).map_err(|e| format!("options: {e}"))?;
        let get = |k: &str| v.get(k).and_then(Value::as_u64);
        if let Some(n) = get("max_entries") {
            self.max_entries = usize::try_from(n).unwrap_or(usize::MAX).min(CEIL_ENTRIES);
        }
        if let Some(n) = get("max_depth") {
            self.max_depth = usize::try_from(n)
                .unwrap_or(usize::MAX)
                .clamp(1, CEIL_DEPTH);
        }
        if let Some(n) = get("max_total_bytes") {
            self.max_total_bytes = self.max_total_bytes.min(n);
        }
        if let Some(n) = get("time_ms") {
            self.time_ms = n.min(CEIL_TIME_MS);
        }
        Ok(self)
    }
}

/// A started stopwatch against `Limits::time_ms`.
#[derive(Clone, Copy)]
pub struct Deadline(Instant);

impl Deadline {
    pub fn start(limits: &Limits) -> Self {
        Self(Instant::now() + Duration::from_millis(limits.time_ms))
    }
    pub fn passed(&self) -> bool {
        Instant::now() >= self.0
    }
    pub fn remaining(&self) -> Duration {
        self.0.saturating_duration_since(Instant::now())
    }
}

/// Partial results carry notices instead of failing (architecture 6.3).
#[derive(Default)]
pub struct Notices(Vec<String>);

impl Notices {
    pub fn add(&mut self, text: impl Into<String>) {
        let text = text.into();
        if !self.0.contains(&text) {
            self.0.push(text);
        }
    }
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
    pub fn into_json(self) -> Value {
        json!(self.0)
    }
}

/// Names are data from outside: control characters never reach the preview.
pub fn clean_name(raw: &str) -> String {
    raw.chars()
        .map(|c| if c.is_control() { '?' } else { c })
        .collect()
}
