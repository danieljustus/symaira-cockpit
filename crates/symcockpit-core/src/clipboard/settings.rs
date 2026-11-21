//! Clipboard settings. The default is "off": nothing is captured until the human enables it.

use serde_json::{Value, json};

/// Password managers and keychain tools, excluded from the first use on.
pub const DEFAULT_EXCLUDED_APPS: [&str; 7] = [
    "com.1password.1password",
    "com.agilebits.onepassword7",
    "com.bitwarden.desktop",
    "org.keepassxc.keepassxc",
    "com.lastpass.LastPass",
    "com.apple.keychainaccess",
    "com.apple.Passwords",
];

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClipboardSettings {
    pub enabled: bool,
    pub paused: bool,
    pub excluded_apps: Vec<String>,
    pub max_items: usize,
    pub max_age_secs: i64,
    /// Larger payloads are not stored.
    pub max_item_bytes: usize,
}

impl Default for ClipboardSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            paused: false,
            excluded_apps: DEFAULT_EXCLUDED_APPS
                .iter()
                .map(|s| (*s).to_owned())
                .collect(),
            max_items: 500,
            max_age_secs: 30 * 24 * 3600,
            max_item_bytes: 5 << 20,
        }
    }
}

impl ClipboardSettings {
    /// Capture happens only when the feature is on and not paused.
    pub fn capturing(&self) -> bool {
        self.enabled && !self.paused
    }

    pub fn to_json(&self) -> Value {
        json!({
            "enabled": self.enabled, "paused": self.paused, "excluded_apps": self.excluded_apps,
            "max_items": self.max_items, "max_age_secs": self.max_age_secs,
            "max_item_bytes": self.max_item_bytes,
        })
    }

    /// Unknown or invalid fields fall back to the defaults, except that `enabled` is only
    /// ever true when the file says exactly `true`.
    pub fn from_json(v: &Value) -> Self {
        let d = Self::default();
        let uint = |k: &str| v.get(k).and_then(Value::as_u64);
        Self {
            enabled: v.get("enabled").and_then(Value::as_bool).unwrap_or(false),
            paused: v.get("paused").and_then(Value::as_bool).unwrap_or(false),
            excluded_apps: v.get("excluded_apps").and_then(Value::as_array).map_or(
                d.excluded_apps,
                |a| {
                    a.iter()
                        .filter_map(|s| s.as_str().map(str::to_owned))
                        .collect()
                },
            ),
            max_items: uint("max_items").map_or(d.max_items, |n| (n as usize).clamp(1, 100_000)),
            max_age_secs: uint("max_age_secs")
                .map_or(d.max_age_secs, |n| (n as i64).clamp(60, 3650 * 24 * 3600)),
            max_item_bytes: uint("max_item_bytes")
                .map_or(d.max_item_bytes, |n| (n as usize).clamp(1, 64 << 20)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn off_by_default_and_round_trips() {
        let d = ClipboardSettings::default();
        assert!(!d.enabled && !d.capturing());
        let mut s = d.clone();
        s.enabled = true;
        s.max_items = 7;
        assert_eq!(ClipboardSettings::from_json(&s.to_json()), s);
        assert!(s.capturing());
        s.paused = true;
        assert!(!s.capturing());
    }

    #[test]
    fn garbage_never_turns_the_feature_on() {
        for v in [
            json!({}),
            json!({"enabled": "yes"}),
            json!({"enabled": 1}),
            json!(null),
        ] {
            assert!(!ClipboardSettings::from_json(&v).enabled, "{v}");
        }
        let s =
            ClipboardSettings::from_json(&json!({"max_items": 0, "max_item_bytes": 1u64 << 60}));
        assert_eq!((s.max_items, s.max_item_bytes), (1, 64 << 20));
    }
}
