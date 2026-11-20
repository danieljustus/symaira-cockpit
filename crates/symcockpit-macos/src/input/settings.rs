//! Input preferences as one JSON file, replaced atomically.

use std::path::PathBuf;

use symcockpit_contract::Error;
use symcockpit_core::input::{InputSettings, SettingsStore};

pub struct JsonFileSettings {
    path: PathBuf,
}

impl JsonFileSettings {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        JsonFileSettings { path: path.into() }
    }
}

impl SettingsStore for JsonFileSettings {
    /// A missing file yields the defaults; a corrupt one is a config error
    /// (it is never silently replaced).
    fn load(&self) -> Result<InputSettings, Error> {
        match std::fs::read(&self.path) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|e| Error::Config(format!("{}: {e}", self.path.display()))),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(InputSettings::default()),
            Err(e) => Err(Error::Failed(format!("{}: {e}", self.path.display()))),
        }
    }

    fn save(&self, settings: &InputSettings) -> Result<(), Error> {
        let io = |e: std::io::Error| Error::Failed(format!("{}: {e}", self.path.display()));
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir).map_err(io)?;
        }
        let tmp = self.path.with_extension("json.tmp");
        let text = serde_json::to_vec_pretty(settings).map_err(|e| Error::Failed(e.to_string()))?;
        std::fs::write(&tmp, text).map_err(io)?;
        std::fs::rename(&tmp, &self.path).map_err(io)
    }
}

#[cfg(test)]
mod tests {
    use symcockpit_core::input::Material;

    use super::*;

    #[test]
    fn missing_file_is_defaults_and_save_round_trips() {
        let dir = tempfile::tempdir().unwrap();
        let store = JsonFileSettings::new(dir.path().join("nested/input.json"));
        assert_eq!(store.load().unwrap(), InputSettings::default());
        let s = InputSettings {
            finder_cut: true,
            haptics: true,
            sound: false,
            material: Material::Glass,
        };
        store.save(&s).unwrap();
        assert_eq!(store.load().unwrap(), s);
        assert!(!dir.path().join("nested/input.json.tmp").exists());
    }

    #[test]
    fn corrupt_file_is_a_config_error_and_is_left_alone() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("input.json");
        std::fs::write(&path, "{not json").unwrap();
        let err = JsonFileSettings::new(&path).load().unwrap_err();
        assert_eq!(err.exit_code(), 2);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "{not json");
    }

    #[test]
    fn partial_file_keeps_defaults_for_missing_keys() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("input.json");
        std::fs::write(&path, r#"{"sound": true}"#).unwrap();
        let s = JsonFileSettings::new(&path).load().unwrap();
        assert!(s.sound && !s.finder_cut);
    }
}
