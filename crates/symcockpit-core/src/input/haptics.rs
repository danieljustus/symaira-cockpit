//! Trackpad haptics with material sound (R61, ADR 0004).
//!
//! The haptic actuator comes from the private MultitouchSupport framework, so
//! it can disappear with any macOS update. The sound does not depend on it:
//! when haptics fail, `trigger` reports a named failure level for that channel,
//! still plays the sound, and leaves the settings alone.

use serde::Serialize;

use super::settings::InputSettings;
use super::sound::{Material, material_wav};

/// Why haptics are or are not available. Each level is a distinct,
/// named cause so the UI and `doctor` can say what failed.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum HapticLevel {
    Available,
    FrameworkMissing,
    /// The framework loaded but this symbol is gone.
    SymbolMissing(String),
    /// No trackpad with an actuator (desktop Mac, no Magic Trackpad).
    NoDevice,
    OpenFailed,
    ActuationFailed,
}

impl HapticLevel {
    pub fn name(&self) -> &'static str {
        match self {
            HapticLevel::Available => "available",
            HapticLevel::FrameworkMissing => "framework_missing",
            HapticLevel::SymbolMissing(_) => "symbol_missing",
            HapticLevel::NoDevice => "no_device",
            HapticLevel::OpenFailed => "actuator_open_failed",
            HapticLevel::ActuationFailed => "actuation_failed",
        }
    }

    pub fn detail(&self) -> Option<&str> {
        match self {
            HapticLevel::SymbolMissing(symbol) => Some(symbol),
            _ => None,
        }
    }
}

/// One actuation. Ids are the private framework's; they are not verified
/// against Apple documentation, only against hardware (acceptance by Daniel).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct HapticPattern {
    pub actuation_id: i32,
}

impl HapticPattern {
    pub fn for_material(material: Material) -> HapticPattern {
        HapticPattern {
            actuation_id: match material {
                Material::Wood => 3,
                Material::Glass => 1,
                Material::Metal => 6,
                Material::Rubber => 4,
            },
        }
    }
}

/// Port: the trackpad actuator.
pub trait HapticBackend {
    /// Checks the framework and every symbol without actuating anything.
    fn probe(&self) -> HapticLevel;
    /// `Err` carries the failure level (never `Available`).
    fn actuate(&self, pattern: HapticPattern) -> Result<(), HapticLevel>;
}

/// Port: plays a rendered WAV.
pub trait SoundBackend {
    fn play(&self, wav: &[u8]) -> Result<(), String>;
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ChannelResult {
    /// `ok`, `skipped_disabled`, a haptic level name, or `failed` for sound.
    pub status: String,
    pub detail: Option<String>,
}

impl ChannelResult {
    fn new(status: &str, detail: Option<&str>) -> ChannelResult {
        ChannelResult {
            status: status.to_owned(),
            detail: detail.map(str::to_owned),
        }
    }

    pub fn is_ok(&self) -> bool {
        self.status == "ok"
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct TriggerReport {
    pub material: &'static str,
    pub haptic: ChannelResult,
    pub sound: ChannelResult,
    /// True when any enabled channel did not work.
    pub degraded: bool,
}

/// Fires haptic and sound for `settings.material`. `force` ignores the on/off
/// switches (the explicit `haptics test` command). The settings are only read.
pub fn trigger(
    settings: &InputSettings,
    force: bool,
    haptic: &dyn HapticBackend,
    sound: &dyn SoundBackend,
) -> TriggerReport {
    let haptic_result = if !(force || settings.haptics) {
        ChannelResult::new("skipped_disabled", None)
    } else {
        match haptic.actuate(HapticPattern::for_material(settings.material)) {
            Ok(()) => ChannelResult::new("ok", None),
            Err(level) => ChannelResult::new(level.name(), level.detail()),
        }
    };
    // The sound never waits for, or depends on, the haptic result.
    let sound_result = if !(force || settings.sound) {
        ChannelResult::new("skipped_disabled", None)
    } else {
        match sound.play(&material_wav(settings.material)) {
            Ok(()) => ChannelResult::new("ok", None),
            Err(e) => ChannelResult::new("failed", Some(&e)),
        }
    };
    let degraded = [&haptic_result, &sound_result]
        .iter()
        .any(|r| !r.is_ok() && r.status != "skipped_disabled");
    TriggerReport {
        material: settings.material.name(),
        haptic: haptic_result,
        sound: sound_result,
        degraded,
    }
}
