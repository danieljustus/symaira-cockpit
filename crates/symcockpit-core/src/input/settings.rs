//! Persisted input preferences. A failing feature never changes them (R61).

use serde::{Deserialize, Serialize};
use symcockpit_contract::Error;

use super::sound::Material;

/// Everything is off until the user turns it on.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct InputSettings {
    pub finder_cut: bool,
    pub haptics: bool,
    pub sound: bool,
    pub material: Material,
}

impl Default for InputSettings {
    fn default() -> Self {
        InputSettings {
            finder_cut: false,
            haptics: false,
            sound: false,
            material: Material::Wood,
        }
    }
}

/// Port: where the settings live. A missing store yields the defaults.
pub trait SettingsStore {
    fn load(&self) -> Result<InputSettings, Error>;
    fn save(&self, settings: &InputSettings) -> Result<(), Error>;
}
