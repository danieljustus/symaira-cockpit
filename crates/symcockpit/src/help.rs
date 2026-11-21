//! The help texts of the read commands, byte for byte as v0.12 prints them
//! (checked against `oracle/v0.12/cases/*-help.stdout` in the tests below).
//! The `--help` of the write families (`dim`, `warmth`, `fan`, `battery-limit`) is
//! plain usage text and answered here too.

/// `symcockpit help` / `--help` / `-h`; also printed on stderr for usage errors.
pub const ROOT_USAGE: &str = "symcockpit — this machine: hardware and system tuning\n\nUsage:\n  symcockpit <command> [options]\n\nCommands:\n  sensors, battery, displays, metrics, status, processes, top\n  awake, brightness, extbright, dim, warmth, restore, profile\n  fan, battery-limit, ai-usage, doctor, permissions, history, serve\n\n  version [--json] [--no-update-check]    symcockpit version plus the component versions\n  --version, -V                           aliases for `symcockpit version`\n  help                This text\n\nExamples:\n  symcockpit doctor\n\nsymcockpit covers this machine's thermals, power, display and brightness.\nOperate and Scope moved to Symaira Brain as optional modules; the legacy\ndispatcher commands are removed.\n\nThe `symcockpit tune <command>` prefix was removed in v0.12 after its\ndeprecation window (v0.8 and v0.9); run `symcockpit <command>` directly.\n";

/// The always-JSON read commands: usage line plus one description.
pub fn always_json(command: &str) -> Option<String> {
    let description = match command {
        "doctor" => "Capabilities, host info, and recommendations (JSON).",
        "sensors" => "Thermal pressure + (when available) temps/fan RPM (JSON).",
        "battery" => "Battery health: charge %, cycles, capacity, condition (JSON).",
        "displays" => "Displays with EDR headroom / extended-brightness capability (JSON).",
        "permissions" => "Permission & SMC write status (JSON).",
        _ => return None,
    };
    Some(format!(
        "Usage: symcockpit {command} [--json]\n\n{description}\n--json is accepted for consistency with other read commands; it is a no-op here.\n"
    ))
}

pub const METRICS: &str = "Usage: symcockpit metrics [--json]\n\nPrint system metrics: CPU utilization, memory pressure, GPU utilization, disk usage,\nmounted storage volumes, and network throughput. All values are read-only snapshots.\n--json is accepted for consistency with other read commands; it is a no-op here.\n";

/// `dim --help`, `warmth --help`, `fan --help`, `battery-limit --help`.
pub fn write_family(command: &str) -> Option<&'static str> {
    Some(match command {
        "dim" => "Usage: symcockpit dim set <0.15-1.0>\n       symcockpit dim reset\n",
        "warmth" => "Usage: symcockpit warmth set <0.0-1.0>\n       symcockpit warmth reset\n",
        "fan" => {
            "Usage: symcockpit fan set <0.0-1.0>\n       symcockpit fan auto\n       symcockpit fan profile [system|comfort|performance]\n       symcockpit fan status\n       symcockpit fan target [<50-85>|off]   (Cool: max average CPU/GPU cluster \u{b0}C)\n       symcockpit fan governor [--state <path>]   (requires root)\n"
        }
        "battery-limit" => {
            "Usage: symcockpit battery-limit set <50-100>\n       symcockpit battery-limit clear\n"
        }
        _ => return None,
    })
}

/// `processes --help` really says `symtune` in v0.12; kept for byte parity.
pub const PROCESSES: &str = "Usage: symtune processes [--sort cpu|memory|gpu] [--limit N] [--interval <seconds>] [--json]\n\nRank running processes by CPU, memory (RAM), or GPU usage. CPU is a rate,\nso the command samples twice --interval seconds apart (default 1.0) before\nreporting. Processes owned by another user are counted but not readable\nwithout elevation. GPU time is read from the IORegistry without root;\nonly when the registry exposes no per-process GPU usage does the root-only\npowermetrics fallback apply (run this command with sudo then).\n";

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> String {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../oracle/v0.12/cases")
            .join(name);
        std::fs::read_to_string(path).unwrap()
    }

    #[test]
    fn texts_equal_the_oracle_fixtures() {
        assert_eq!(ROOT_USAGE, fixture("help.stdout"));
        assert_eq!(ROOT_USAGE, fixture("help-flag.stdout"));
        assert_eq!(ROOT_USAGE, fixture("help-short.stdout"));
        for c in ["sensors", "battery", "displays", "permissions", "doctor"] {
            assert_eq!(
                always_json(c).unwrap(),
                fixture(&format!("{c}-help.stdout")),
                "{c}"
            );
        }
        assert_eq!(METRICS, fixture("metrics-help.stdout"));
        assert_eq!(PROCESSES, fixture("processes-help.stdout"));
        for c in ["dim", "warmth", "fan", "battery-limit"] {
            assert_eq!(
                write_family(c).unwrap(),
                fixture(&format!("{c}-help.stdout")),
                "{c}"
            );
        }
        assert_eq!(always_json("status"), None);
    }
}
