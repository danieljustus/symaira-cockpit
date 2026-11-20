//! `config.toml` and the `SYMTUNE_*` overrides (`TuneConfig` in
//! `tuning/Sources/SymCockpitCore/Config.swift`).
//!
//! Only the keys the CLI, MCP server and the write wave consume are ported:
//! the safety bounds, charge-limit hysteresis, default profile and MCP mode.
//! The metrics/popover keys only the menu-bar GUI reads stay with Swift.
//! Like Swift, loading never fails: a missing or malformed file yields the
//! defaults. The one reportable problem (inverted bounds) comes back as an
//! `Error::Config` warning, whose Display is exactly the Swift stderr text.

use symcockpit_contract::Error;

use crate::paths::{Env, Paths};
use crate::toml::{self, Table};

/// Hard limits from `SafetyPolicy.swift`; configuration can only narrow them.
pub mod safety {
    pub const EXTENDED_BRIGHTNESS_MIN: f64 = 1.0;
    pub const EXTENDED_BRIGHTNESS_MAX: f64 = 1.6;
    pub const DIM_MIN: f64 = 0.15;
    pub const DIM_MAX: f64 = 1.0;
    pub const BRIGHTNESS_MIN: f64 = 0.0;
    pub const BRIGHTNESS_MAX: f64 = 1.0;
    pub const FAN_FRACTION_MIN: f64 = 0.0;
    pub const FAN_FRACTION_MAX: f64 = 1.0;
    pub const CHARGE_LIMIT_MIN: i64 = 50;
    pub const CHARGE_LIMIT_MAX: i64 = 100;
    pub const CHARGE_LIMIT_HYSTERESIS: i64 = 5;
    pub const CHARGE_LIMIT_HYSTERESIS_MAX: i64 = 20;
}

#[derive(Clone, Debug, PartialEq)]
pub struct Config {
    pub extended_brightness_min: f64,
    pub extended_brightness_max: f64,
    pub dim_min: f64,
    pub dim_max: f64,
    pub brightness_min: f64,
    pub brightness_max: f64,
    pub fan_fraction_min: f64,
    pub fan_fraction_max: f64,
    pub charge_limit_min: i64,
    pub charge_limit_max: i64,
    pub charge_limit_hysteresis_percent: i64,
    pub default_profile: String,
    pub mcp_mode: String,
}

impl Default for Config {
    fn default() -> Self {
        use safety::*;
        Self {
            extended_brightness_min: EXTENDED_BRIGHTNESS_MIN,
            extended_brightness_max: EXTENDED_BRIGHTNESS_MAX,
            dim_min: DIM_MIN,
            dim_max: DIM_MAX,
            brightness_min: BRIGHTNESS_MIN,
            brightness_max: BRIGHTNESS_MAX,
            fan_fraction_min: FAN_FRACTION_MIN,
            fan_fraction_max: FAN_FRACTION_MAX,
            charge_limit_min: CHARGE_LIMIT_MIN,
            charge_limit_max: CHARGE_LIMIT_MAX,
            charge_limit_hysteresis_percent: CHARGE_LIMIT_HYSTERESIS,
            default_profile: "default".into(),
            mcp_mode: "full".into(),
        }
    }
}

/// A loaded configuration plus the problems found while loading.
#[derive(Clone, Debug, PartialEq)]
pub struct Loaded {
    pub config: Config,
    /// Printed by the caller as `symcockpit: <warning>` on stderr.
    pub warnings: Vec<Error>,
}

impl Config {
    pub fn is_mcp_read_only(&self) -> bool {
        matches!(
            self.mcp_mode.to_lowercase().as_str(),
            "read-only" | "read_only" | "readonly"
        )
    }

    /// Reads `config.toml` (missing or unreadable means empty), applies the
    /// `SYMTUNE_*` overrides, clamps to the safety limits and validates ranges.
    pub fn load(paths: &Paths, env: Env) -> Loaded {
        let table = std::fs::read(paths.config_file())
            .ok()
            .and_then(|bytes| String::from_utf8(bytes).ok())
            .map(|text| toml::parse(&text))
            .unwrap_or_default();
        Self::from_table(&table, env)
    }

    pub fn from_table(table: &Table, env: Env) -> Loaded {
        use safety::*;
        // The environment wins over the file, an unusable value falls through.
        let double = |section: &str, key: &str, env_key: &str, fallback: f64| {
            env(env_key)
                .filter(|raw| !raw.is_empty())
                .and_then(|raw| raw.parse::<f64>().ok())
                .or_else(|| table.get(section, key).and_then(toml::Value::as_double))
                .unwrap_or(fallback)
        };
        let int = |section: &str, key: &str, env_key: &str, fallback: i64| {
            env(env_key)
                .filter(|raw| !raw.is_empty())
                .and_then(|raw| raw.parse::<i64>().ok())
                .or_else(|| table.get(section, key).and_then(toml::Value::as_int))
                .unwrap_or(fallback)
        };
        let string = |section: &str, key: &str, env_key: &str, fallback: &str| {
            env(env_key)
                .filter(|raw| !raw.is_empty())
                .or_else(|| {
                    table
                        .get(section, key)
                        .and_then(toml::Value::as_str)
                        .map(str::to_owned)
                })
                .unwrap_or_else(|| fallback.to_owned())
        };

        let mut config = Config {
            extended_brightness_min: double(
                "brightness",
                "extended_brightness_min",
                "SYMTUNE_EXTBRIGHT_MIN",
                EXTENDED_BRIGHTNESS_MIN,
            )
            .max(EXTENDED_BRIGHTNESS_MIN),
            extended_brightness_max: double(
                "brightness",
                "extended_brightness_max",
                "SYMTUNE_EXTBRIGHT_MAX",
                EXTENDED_BRIGHTNESS_MAX,
            )
            .min(EXTENDED_BRIGHTNESS_MAX),
            dim_min: double("brightness", "dim_min", "SYMTUNE_DIM_MIN", DIM_MIN).max(DIM_MIN),
            dim_max: double("brightness", "dim_max", "SYMTUNE_DIM_MAX", DIM_MAX).min(DIM_MAX),
            brightness_min: double(
                "brightness",
                "brightness_min",
                "SYMTUNE_BRIGHTNESS_MIN",
                BRIGHTNESS_MIN,
            )
            .max(BRIGHTNESS_MIN),
            brightness_max: double(
                "brightness",
                "brightness_max",
                "SYMTUNE_BRIGHTNESS_MAX",
                BRIGHTNESS_MAX,
            )
            .min(BRIGHTNESS_MAX),
            fan_fraction_min: double(
                "fan",
                "fan_fraction_min",
                "SYMTUNE_FAN_MIN",
                FAN_FRACTION_MIN,
            )
            .max(FAN_FRACTION_MIN),
            fan_fraction_max: double(
                "fan",
                "fan_fraction_max",
                "SYMTUNE_FAN_MAX",
                FAN_FRACTION_MAX,
            )
            .min(FAN_FRACTION_MAX),
            charge_limit_min: int(
                "charge",
                "charge_limit_min",
                "SYMTUNE_CHARGE_MIN",
                CHARGE_LIMIT_MIN,
            )
            .max(CHARGE_LIMIT_MIN),
            charge_limit_max: int(
                "charge",
                "charge_limit_max",
                "SYMTUNE_CHARGE_MAX",
                CHARGE_LIMIT_MAX,
            )
            .min(CHARGE_LIMIT_MAX),
            charge_limit_hysteresis_percent: int(
                "charge",
                "limit_hysteresis_percent",
                "SYMTUNE_CHARGE_HYSTERESIS",
                CHARGE_LIMIT_HYSTERESIS,
            )
            .clamp(1, CHARGE_LIMIT_HYSTERESIS_MAX),
            default_profile: string(
                "general",
                "default_profile",
                "SYMTUNE_DEFAULT_PROFILE",
                "default",
            ),
            mcp_mode: string("mcp", "mode", "SYMTUNE_MCP_MODE", "full"),
        };

        let ranges_valid = config.extended_brightness_min < config.extended_brightness_max
            && config.dim_min < config.dim_max
            && config.brightness_min < config.brightness_max
            && config.fan_fraction_min < config.fan_fraction_max
            && config.charge_limit_min < config.charge_limit_max;
        let mut warnings = Vec::new();
        if !ranges_valid {
            warnings.push(Error::Config(
                "inverted min/max range detected, falling back to defaults".into(),
            ));
            config = Config::default();
        }
        Loaded { config, warnings }
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::*;

    fn no_env(_: &str) -> Option<String> {
        None
    }

    fn with<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
        move |k| {
            pairs
                .iter()
                .find(|(key, _)| *key == k)
                .map(|(_, v)| (*v).to_owned())
        }
    }

    fn load_env(pairs: &[(&str, &str)]) -> Config {
        Config::from_table(&Table::default(), &with(pairs)).config
    }

    // The tests below are ported from `TuneConfig` cases in
    // tuning/Tests/SymCockpitCoreTests/ConfigTests.swift.

    #[test]
    fn defaults_match_the_safety_policy() {
        let c = Config::default();
        assert_eq!(
            (c.extended_brightness_min, c.extended_brightness_max),
            (1.0, 1.6)
        );
        assert_eq!((c.dim_min, c.dim_max), (0.15, 1.0));
        assert_eq!((c.charge_limit_min, c.charge_limit_max), (50, 100));
        assert_eq!(c.charge_limit_hysteresis_percent, 5);
        assert_eq!(
            (c.default_profile.as_str(), c.mcp_mode.as_str()),
            ("default", "full")
        );
        assert!(!c.is_mcp_read_only());
    }

    #[test]
    fn mcp_mode_spellings_mean_read_only() {
        for m in ["read-only", "READ_ONLY", "readonly", "ReadOnly"] {
            let c = Config {
                mcp_mode: m.into(),
                ..Config::default()
            };
            assert!(c.is_mcp_read_only(), "{m}");
        }
        let c = Config {
            mcp_mode: "read only".into(),
            ..Config::default()
        };
        assert!(!c.is_mcp_read_only());
    }

    #[test]
    fn loads_values_from_a_toml_file_under_xdg_config() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join(".config/symtune");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("config.toml"),
            "[brightness]\nextended_brightness_max = 1.4\ndim_min = 0.20\n[fan]\nfan_fraction_max = 0.8\n[charge]\ncharge_limit_min = 60\n[general]\ndefault_profile = \"work\"\n[mcp]\nmode = \"read-only\"\n",
        )
        .unwrap();
        let loaded = Config::load(&Paths::resolve(&no_env, tmp.path()), &no_env);
        let c = loaded.config;
        assert!(loaded.warnings.is_empty());
        assert_eq!(c.extended_brightness_max, 1.4);
        assert_eq!(c.dim_min, 0.20);
        assert_eq!(c.fan_fraction_max, 0.8);
        assert_eq!(c.charge_limit_min, 60);
        assert_eq!(c.default_profile, "work");
        assert!(c.is_mcp_read_only());
        // Unset values keep their defaults.
        assert_eq!(c.extended_brightness_min, 1.0);
    }

    #[test]
    fn missing_and_malformed_files_give_defaults() {
        let tmp = tempfile::tempdir().unwrap();
        let paths = Paths::resolve(&no_env, tmp.path());
        assert_eq!(Config::load(&paths, &no_env).config, Config::default());
        std::fs::create_dir_all(paths.config_dir.clone()).unwrap();
        std::fs::write(
            paths.config_file(),
            "this is not valid toml [[[\nkey without value\n",
        )
        .unwrap();
        assert_eq!(Config::load(&paths, &no_env).config, Config::default());
        // Invalid UTF-8 is an unreadable file, not an error.
        std::fs::write(paths.config_file(), [0xff, 0xfe]).unwrap();
        assert_eq!(Config::load(&paths, &no_env).config, Config::default());
    }

    #[test]
    fn partially_valid_file_keeps_the_valid_value() {
        let table =
            toml::parse("[brightness]\nextended_brightness_max = 1.3\n# garbage\n[[[[invalid\n");
        let c = Config::from_table(&table, &no_env).config;
        assert_eq!(c.extended_brightness_max, 1.3);
        assert_eq!(c.dim_min, 0.15);
    }

    #[test]
    fn environment_overrides_the_file_and_ignores_unusable_values() {
        let c = load_env(&[
            ("SYMTUNE_EXTBRIGHT_MAX", "1.3"),
            ("SYMTUNE_DIM_MIN", "0.25"),
            ("SYMTUNE_BRIGHTNESS_MAX", "0.9"),
            ("SYMTUNE_FAN_MIN", "0.1"),
            ("SYMTUNE_FAN_MAX", "0.9"),
            ("SYMTUNE_CHARGE_MIN", "55"),
            ("SYMTUNE_CHARGE_MAX", "90"),
            ("SYMTUNE_DEFAULT_PROFILE", "gaming"),
            ("SYMTUNE_MCP_MODE", "read-only"),
        ]);
        assert_eq!(c.extended_brightness_max, 1.3);
        assert_eq!(c.dim_min, 0.25);
        assert_eq!(c.brightness_max, 0.9);
        assert_eq!((c.fan_fraction_min, c.fan_fraction_max), (0.1, 0.9));
        assert_eq!((c.charge_limit_min, c.charge_limit_max), (55, 90));
        assert_eq!(c.default_profile, "gaming");
        assert!(c.is_mcp_read_only());
        assert_eq!(
            load_env(&[("SYMTUNE_EXTBRIGHT_MAX", "not-a-number")]).extended_brightness_max,
            1.6
        );
        assert_eq!(
            load_env(&[("SYMTUNE_EXTBRIGHT_MAX", "")]).extended_brightness_max,
            1.6
        );
        // An env value that is unusable falls through to the file value.
        let table = toml::parse("[mcp]\nmode = \"readonly\"\n");
        let loaded = Config::from_table(&table, &with(&[("SYMTUNE_MCP_MODE", "")]));
        assert!(loaded.config.is_mcp_read_only());
    }

    #[test]
    fn hysteresis_is_clamped_to_one_through_twenty() {
        assert_eq!(
            load_env(&[("SYMTUNE_CHARGE_HYSTERESIS", "999")]).charge_limit_hysteresis_percent,
            20
        );
        assert_eq!(
            load_env(&[("SYMTUNE_CHARGE_HYSTERESIS", "0")]).charge_limit_hysteresis_percent,
            1
        );
        assert_eq!(
            load_env(&[("SYMTUNE_CHARGE_HYSTERESIS", "8")]).charge_limit_hysteresis_percent,
            8
        );
    }

    #[test]
    fn bounds_are_clamped_to_the_safety_policy() {
        assert_eq!(load_env(&[("SYMTUNE_DIM_MIN", "0.0")]).dim_min, 0.15);
        assert_eq!(
            load_env(&[("SYMTUNE_FAN_MAX", "2.0")]).fan_fraction_max,
            1.0
        );
        assert_eq!(
            load_env(&[("SYMTUNE_CHARGE_MAX", "150")]).charge_limit_max,
            100
        );
        assert_eq!(
            load_env(&[("SYMTUNE_EXTBRIGHT_MAX", "2.0")]).extended_brightness_max,
            1.6
        );
        let c = load_env(&[("SYMTUNE_DIM_MIN", "0.2"), ("SYMTUNE_DIM_MAX", "0.9")]);
        assert_eq!((c.dim_min, c.dim_max), (0.2, 0.9));
    }

    #[test]
    fn inverted_ranges_fall_back_to_defaults_with_a_config_warning() {
        for pairs in [
            [
                ("SYMTUNE_BRIGHTNESS_MIN", "0.9"),
                ("SYMTUNE_BRIGHTNESS_MAX", "0.5"),
            ],
            [("SYMTUNE_DIM_MIN", "0.9"), ("SYMTUNE_DIM_MAX", "0.5")],
        ] {
            let loaded = Config::from_table(&Table::default(), &with(&pairs));
            assert_eq!(loaded.config, Config::default());
            assert_eq!(
                loaded
                    .warnings
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>(),
                ["config error: inverted min/max range detected, falling back to defaults"]
            );
            assert_eq!(loaded.warnings[0].exit_code(), 2);
        }
        let ok = load_env(&[
            ("SYMTUNE_BRIGHTNESS_MIN", "0.1"),
            ("SYMTUNE_BRIGHTNESS_MAX", "0.9"),
        ]);
        assert_eq!((ok.brightness_min, ok.brightness_max), (0.1, 0.9));
    }

    #[test]
    fn config_file_path_follows_xdg() {
        let p = Paths::resolve(&with(&[("XDG_CONFIG_HOME", "/x")]), Path::new("/h"));
        assert_eq!(p.config_file(), Path::new("/x/symtune/config.toml"));
    }
}
