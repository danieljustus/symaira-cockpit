//! Restore of SMC overrides (port of `SMCRestoreTracker.swift`).
//!
//! The captured originals are persisted to `smc-restore.json` the moment they
//! are captured, *before* the first write, so a process that is killed
//! (SIGKILL, panic, power-off) cannot strand the hardware: the next start
//! consumes the leftover record (Q05). The file is never trusted blindly: an
//! unreadable one is discarded, one from another architecture or version is
//! ignored, and charge values are only applied when the recorded key family
//! still matches this Mac.

use std::path::{Path, PathBuf};

use symcockpit_store::smc_restore::{self, CURRENT_VERSION, FanOriginal, KeyFamily, Record};
use symcockpit_store::state_perms::Owner;

use crate::fan::{FanEnv, FanOriginalState, original_state};
use crate::sensors::{
    ChargeLimitKeyFamily, detect_charge_limit_key_family, read_charge_inhibit_state,
};
use crate::smc_write::write_value;

/// Architecture string recorded next to captured values (arm64 only, D16).
pub const ARCHITECTURE: &str = "arm64";

fn family_of(f: ChargeLimitKeyFamily) -> KeyFamily {
    match f {
        ChargeLimitKeyFamily::Chte => KeyFamily::Chte,
        ChargeLimitKeyFamily::Ch0b => KeyFamily::Ch0b,
    }
}

/// What the tracker has to say about a leftover record (the caller prints it to stderr).
#[derive(Debug, Default, PartialEq)]
pub struct Consumed {
    pub warnings: Vec<String>,
    /// A record was found and applied.
    pub applied: bool,
}

pub struct RestoreTracker {
    dir: PathBuf,
    owner: Option<Owner>,
    fans: std::collections::BTreeMap<usize, (u8, f64)>,
    charge_family: Option<ChargeLimitKeyFamily>,
    charge_inhibit: Option<bool>,
    has_overrides: bool,
    /// Persisting failed once; reported once.
    pub persist_warning: Option<String>,
}

impl RestoreTracker {
    pub fn new(data_dir: &Path, owner: Option<Owner>) -> Self {
        Self {
            dir: data_dir.to_path_buf(),
            owner,
            fans: Default::default(),
            charge_family: None,
            charge_inhibit: None,
            has_overrides: false,
            persist_warning: None,
        }
    }

    pub fn record_path(&self) -> PathBuf {
        smc_restore::path_in(&self.dir)
    }

    /// Save the original mode and target of fan `index` before the first override.
    pub fn save_fan_original(&mut self, env: &FanEnv, index: usize) {
        if !env.smc.is_open() {
            return;
        }
        if let std::collections::btree_map::Entry::Vacant(slot) = self.fans.entry(index)
            && let Some(FanOriginalState {
                mode: Some(mode),
                target_rpm,
            }) = original_state(env, index)
        {
            slot.insert((mode, target_rpm.unwrap_or(0.0)));
            self.has_overrides = true;
        }
        self.persist();
    }

    /// Save the original charge-inhibit state before the first override.
    pub fn save_charge_original(&mut self, env: &FanEnv) {
        if !env.smc.is_open() {
            return;
        }
        if self.charge_inhibit.is_none()
            && let Some(family) = detect_charge_limit_key_family(env.smc)
        {
            self.charge_family = Some(family);
            self.charge_inhibit = Some(read_charge_inhibit_state(env.smc).unwrap_or(false));
            self.has_overrides = true;
        }
        self.persist();
    }

    /// The fans were handed back by their owner (the governor restored what it
    /// captured): forget them, keep a pending charge-limit original, drop the
    /// file when nothing is left to restore. Writes nothing to the SMC.
    pub fn forget_fans(&mut self) {
        self.fans.clear();
        self.has_overrides = self.charge_inhibit.is_some();
        if self.has_overrides {
            self.persist();
        } else {
            smc_restore::remove(&self.dir);
        }
    }

    fn record(&self) -> Record {
        Record {
            version: CURRENT_VERSION,
            architecture: ARCHITECTURE.into(),
            charge_key_family: self.charge_family.map(family_of),
            fan_originals: self
                .fans
                .iter()
                .map(|(i, (mode, target))| FanOriginal {
                    fan_index: *i as i64,
                    mode: *mode,
                    target_rpm: *target,
                })
                .collect(),
            fs_bitmask: None,
            charge_inhibit: self.charge_inhibit,
        }
    }

    fn persist(&mut self) {
        if !self.has_overrides {
            return;
        }
        if let Err(e) = smc_restore::write(&self.dir, &self.record(), self.owner) {
            self.persist_warning = Some(format!("failed to persist SMC restore state: {e}"));
        }
    }

    /// Apply a record a previous process left behind (it died before it could
    /// restore), then remove it. Called once at start, before any new override.
    pub fn consume_persisted(&mut self, env: &FanEnv) -> Consumed {
        let mut out = Consumed::default();
        let Some(read) = smc_restore::read(&self.dir) else {
            return out;
        };
        if !env.smc.is_open() {
            return out;
        }
        let Ok(record) = read else {
            out.warnings
                .push("discarding unreadable SMC restore file".into());
            smc_restore::remove(&self.dir);
            return out;
        };
        if record.version != CURRENT_VERSION || record.architecture != ARCHITECTURE {
            out.warnings
                .push("ignoring stale SMC restore file (architecture/version mismatch)".into());
            smc_restore::remove(&self.dir);
            return out;
        }
        let fans: Vec<(usize, u8, f64)> = record
            .fan_originals
            .iter()
            .map(|f| (f.fan_index as usize, f.mode, f.target_rpm))
            .collect();
        restore_fans(env, &fans);
        if let (Some(family), Some(inhibit)) = (record.charge_key_family, record.charge_inhibit) {
            if detect_charge_limit_key_family(env.smc).map(family_of) == Some(family) {
                restore_charge(env, inhibit, family);
            } else {
                out.warnings.push(
                    "skipping SMC charge restore (recorded key family no longer matches)".into(),
                );
            }
        }
        smc_restore::remove(&self.dir);
        out.applied = true;
        out
    }

    /// Put back everything captured, then clear the trail. A killed process
    /// leaves the file for the next start to consume.
    pub fn restore_all(&mut self, env: &FanEnv) {
        let fans: Vec<(usize, u8, f64)> =
            self.fans.iter().map(|(i, (m, t))| (*i, *m, *t)).collect();
        let charge = self.charge_inhibit.zip(self.charge_family);
        self.fans.clear();
        self.charge_inhibit = None;
        self.charge_family = None;
        self.has_overrides = false;
        if !env.smc.is_open() {
            return;
        }
        restore_fans(env, &fans);
        if let Some((inhibit, family)) = charge {
            restore_charge(env, inhibit, family_of(family));
        }
        smc_restore::remove(&self.dir);
    }
}

fn restore_fans(env: &FanEnv, originals: &[(usize, u8, f64)]) {
    for (index, mode, target) in originals {
        write_value(
            env.writer,
            &format!("F{index}Md"),
            f64::from(*mode),
            b"ui8 ",
        );
        if *mode == 1 {
            write_value(env.writer, &format!("F{index}Tg"), *target, b"flt ");
        }
    }
    if !originals.is_empty() {
        write_value(env.writer, "Ftst", 0.0, b"ui8 ");
    }
}

fn restore_charge(env: &FanEnv, inhibit: bool, family: KeyFamily) {
    let on = f64::from(u8::from(inhibit));
    match family {
        KeyFamily::Chte => {
            write_value(env.writer, "CHTE", on, b"ui32");
        }
        KeyFamily::Ch0b => {
            write_value(env.writer, "CH0B", on * 2.0, b"ui8 ");
            write_value(env.writer, "CH0C", on * 2.0, b"ui8 ");
        }
        // Intel (D16): never recorded on this Mac, nothing to write.
        KeyFamily::Chlc => {}
    }
}
