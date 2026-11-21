//! The four CLI commands. None of them returns clip content.

use serde_json::{Value, json};
use symcockpit_contract::Error;

use super::{ClipStore, SettingsStore};

/// Opens the history only if it already exists; creating it is the app's job.
pub type OpenStore<'a> = &'a dyn Fn() -> Result<Option<Box<dyn ClipStore>>, Error>;

/// `symcockpit clipboard status`.
pub fn clipboard_status_json(
    settings: &dyn SettingsStore,
    open: OpenStore,
) -> Result<Value, Error> {
    let s = settings.load()?;
    let items = match open()? {
        Some(store) => store.count()?,
        None => 0,
    };
    Ok(json!({
        "enabled": s.enabled, "paused": s.paused, "capturing": s.capturing(),
        "items": items, "excluded_apps": s.excluded_apps.len(),
        "max_items": s.max_items, "max_age_days": s.max_age_secs / 86400,
    }))
}

fn set_paused(settings: &dyn SettingsStore, paused: bool) -> Result<Value, Error> {
    let mut s = settings.load()?;
    s.paused = paused;
    settings.save(&s)?;
    Ok(json!({"paused": paused, "enabled": s.enabled}))
}

/// `symcockpit clipboard pause`: stops capturing; stored items stay.
pub fn clipboard_pause_json(settings: &dyn SettingsStore) -> Result<Value, Error> {
    set_paused(settings, true)
}

/// `symcockpit clipboard resume`. Does not enable the feature: that is the app's opt-in.
pub fn clipboard_resume_json(settings: &dyn SettingsStore) -> Result<Value, Error> {
    set_paused(settings, false)
}

/// `symcockpit clipboard clear`: metadata and attachments.
pub fn clipboard_clear_json(open: OpenStore) -> Result<Value, Error> {
    let removed = match open()? {
        Some(store) => store.delete_all()?,
        None => 0,
    };
    Ok(json!({"cleared": removed}))
}
