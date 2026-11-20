//! XDG-style path resolution, mirroring `ConfigPaths` in
//! `tuning/Sources/SymCockpitCore/Config.swift`. The directory name stays
//! `symtune` (grandfathered, AGENTS.md).

use std::path::{Path, PathBuf};

/// Environment lookup; a closure keeps every consumer testable without
/// touching the process environment.
pub type Env<'a> = &'a dyn Fn(&str) -> Option<String>;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Paths {
    pub home: PathBuf,
    pub config_dir: PathBuf,
    pub cache_dir: PathBuf,
    pub data_dir: PathBuf,
}

impl Paths {
    /// `XDG_*_HOME` wins when set and non-empty, otherwise `home/<fallback>`.
    pub fn resolve(env: Env, home: &Path) -> Self {
        let base = |key: &str, fallback: &str| {
            env(key)
                .filter(|v| !v.is_empty())
                .map_or_else(|| home.join(fallback), PathBuf::from)
        };
        Self {
            home: home.to_path_buf(),
            config_dir: base("XDG_CONFIG_HOME", ".config").join("symtune"),
            cache_dir: base("XDG_CACHE_HOME", ".cache").join("symtune"),
            data_dir: base("XDG_DATA_HOME", ".local/share").join("symtune"),
        }
    }

    /// Paths of the running process. `home_dir` is HOME, then the passwd entry.
    /// shortcut: under `sudo` Swift resolves the invoking user's home through
    /// getpwnam; here `/Users/<SUDO_USER>` is used when it exists. Replace with
    /// a passwd lookup in symcockpit-macos when the write wave needs it.
    pub fn from_process(env: Env, running_as_root: bool) -> Self {
        let sudo_home = env("SUDO_USER")
            .filter(|_| running_as_root)
            .map(|user| PathBuf::from("/Users").join(user))
            .filter(|p| p.is_dir());
        let home = sudo_home
            .or_else(|| env("HOME").filter(|h| !h.is_empty()).map(PathBuf::from))
            .or_else(std::env::home_dir)
            .unwrap_or_else(|| PathBuf::from("/var/empty"));
        Self::resolve(env, &home)
    }

    pub fn config_file(&self) -> PathBuf {
        self.config_dir.join("config.toml")
    }

    /// The fan profile lives under `~/.symtune`, which XDG variables do not move
    /// (`FanProfileStore.defaultURL`).
    pub fn fan_profile_file(&self) -> PathBuf {
        self.home.join(".symtune/fan-profile.json")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env_of<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
        move |k| {
            pairs
                .iter()
                .find(|(key, _)| *key == k)
                .map(|(_, v)| (*v).to_owned())
        }
    }

    #[test]
    fn falls_back_to_home_when_xdg_is_unset_or_empty() {
        let env = env_of(&[("XDG_DATA_HOME", "")]);
        let p = Paths::resolve(&env, Path::new("/h"));
        assert_eq!(p.config_dir, Path::new("/h/.config/symtune"));
        assert_eq!(p.cache_dir, Path::new("/h/.cache/symtune"));
        assert_eq!(p.data_dir, Path::new("/h/.local/share/symtune"));
        assert_eq!(p.config_file(), Path::new("/h/.config/symtune/config.toml"));
        assert_eq!(
            p.fan_profile_file(),
            Path::new("/h/.symtune/fan-profile.json")
        );
    }

    #[test]
    fn xdg_overrides_win() {
        let env = env_of(&[
            ("XDG_CONFIG_HOME", "/c"),
            ("XDG_CACHE_HOME", "/ca"),
            ("XDG_DATA_HOME", "/d"),
        ]);
        let p = Paths::resolve(&env, Path::new("/h"));
        assert_eq!(p.config_dir, Path::new("/c/symtune"));
        assert_eq!(p.cache_dir, Path::new("/ca/symtune"));
        assert_eq!(p.data_dir, Path::new("/d/symtune"));
        // The fan profile ignores XDG on purpose.
        assert_eq!(
            p.fan_profile_file(),
            Path::new("/h/.symtune/fan-profile.json")
        );
    }

    #[test]
    fn home_variable_beats_the_passwd_entry() {
        let env = env_of(&[("HOME", "/tmp/fake-home")]);
        assert_eq!(
            Paths::from_process(&env, false).home,
            Path::new("/tmp/fake-home")
        );
    }
}
