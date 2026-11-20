//! One `*_json` function per `input` command. All of them are `human_only`.

use serde_json::{Value, json};
use symcockpit_contract::Error;

use super::haptics::{HapticBackend, SoundBackend, trigger};
use super::settings::SettingsStore;
use super::{Access, InputProbe};

fn haptic_state(haptic: &dyn HapticBackend) -> Value {
    let level = haptic.probe();
    json!({"level": level.name(), "detail": level.detail()})
}

/// `symcockpit input status`.
pub fn input_status_json(
    store: &dyn SettingsStore,
    probe: &dyn InputProbe,
    haptic: &dyn HapticBackend,
) -> Result<Value, Error> {
    let s = store.load()?;
    Ok(json!({
        "finder_cut": {
            "enabled": s.finder_cut,
            "event_tap_access": match probe.event_tap_access() {
                Access::Granted => "granted",
                Access::Denied => "denied",
            },
            "secure_input_active": probe.secure_input_active(),
        },
        "haptics": {"enabled": s.haptics, "state": haptic_state(haptic)},
        "sound": {"enabled": s.sound, "material": s.material.name()},
    }))
}

/// `symcockpit input finder-cut on|off`: stores the preference; the app agent
/// owns the running tap.
pub fn input_finder_cut_json(store: &dyn SettingsStore, enabled: bool) -> Result<Value, Error> {
    let mut s = store.load()?;
    s.finder_cut = enabled;
    store.save(&s)?;
    Ok(json!({"finder_cut": {"enabled": enabled}}))
}

/// `symcockpit input haptics status`.
pub fn input_haptics_status_json(
    store: &dyn SettingsStore,
    haptic: &dyn HapticBackend,
) -> Result<Value, Error> {
    let s = store.load()?;
    Ok(json!({
        "enabled": s.haptics,
        "sound_enabled": s.sound,
        "material": s.material.name(),
        "state": haptic_state(haptic),
    }))
}

/// `symcockpit input haptics test`: one click with sound, regardless of the switches.
/// A failing channel is reported, not an error; settings are never written.
pub fn input_haptics_test_json(
    store: &dyn SettingsStore,
    haptic: &dyn HapticBackend,
    sound: &dyn SoundBackend,
) -> Result<Value, Error> {
    let report = trigger(&store.load()?, true, haptic, sound);
    serde_json::to_value(report).map_err(|e| Error::Failed(e.to_string()))
}
