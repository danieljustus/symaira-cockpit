//! The fan governor (port of `FanGovernor.swift`).
//!
//! The SMC has no "run this curve for me" register: a fan taken off the
//! firmware curve holds whatever target was last written, so the governed
//! positions are this loop, sampling the die temperature and re-writing the
//! target. It is deliberately *not* a fixed speed: an idle Mac stays at its
//! firmware minimum on every profile, and the loop gives up rather than
//! govern blind.
//!
//! [`Governor::tick`] is one iteration, driven by the caller (the helper's
//! scheduler or [`run`]); the loop's `defer` becomes [`Governor::finish`].

use std::time::Duration;

use crate::fan::{
    FanEnv, FanError, FanOriginalState, apply_fan, average_for, capture_original_states,
    effective_cool_target, governing_temperature, holds_applied_state, preflight_apply, restore,
    target_fraction, write_apply,
};
use crate::sensors::{FanProfile, FanSelection, read_sensors};

/// How often the die temperature is resampled.
pub const DEFAULT_INTERVAL: Duration = Duration::from_secs(5);
/// Speed may rise at once but fall only by this fraction of the range per
/// tick, so the fans do not audibly surge when a burst of work ends.
pub const MAX_DECREASE_PER_TICK: f64 = 0.05;
/// Smaller changes are not written, so a stable temperature is left alone.
pub const DEADBAND: f64 = 0.02;
/// Consecutive ticks without a governing temperature after which the fans go
/// back to the firmware (an empty poll is not "cold", but holding forever
/// would pin the fans with nothing governing them).
pub const MAX_CONSECUTIVE_MISSING_TEMPERATURES: u32 = 3;
/// Consecutive ticks on which the SMC did not hold the applied state, even
/// after re-asserting it, before the governor stops claiming control.
pub const MAX_CONSECUTIVE_UNVERIFIED_TICKS: u32 = 3;

/// The fraction to write this tick, or `None` when nothing should be written
/// (no curve, no reading and nothing applied yet, or a change inside the
/// deadband). A missing temperature holds the last applied value.
pub fn next_fraction(
    selection: &FanSelection,
    temperature: Option<f64>,
    average: Option<f64>,
    applied: Option<f64>,
) -> Option<f64> {
    crate::fan::profile_curve(selection.profile)?;
    // No reading is not "cold": hold what is applied.
    if temperature.is_none() {
        return applied;
    }
    let Some(target) = target_fraction(
        selection.profile,
        temperature,
        effective_cool_target(selection),
        average,
    ) else {
        return applied;
    };
    let Some(applied) = applied else {
        return Some(target);
    };
    let next = if target >= applied {
        target
    } else {
        target.max(applied - MAX_DECREASE_PER_TICK)
    };
    ((next - applied).abs() >= DEADBAND || (next >= 1.0 && applied < 1.0)).then_some(next)
}

/// `next_fraction(profile, temperature, applied)` for a selection without a Cool target.
pub fn next_fraction_for_profile(
    profile: FanProfile,
    temperature: Option<f64>,
    applied: Option<f64>,
) -> Option<f64> {
    next_fraction(
        &FanSelection::new(profile, None),
        temperature,
        None,
        applied,
    )
}

/// What one tick did.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Tick {
    /// The selection is `system`: stop, nothing to govern.
    Stop,
    Ran {
        temperature: Option<f64>,
        applied: Option<f64>,
    },
}

#[derive(Default)]
pub struct Governor {
    applied: Option<f64>,
    /// Captured lazily, immediately before the first write, and restored only
    /// if there was one: a loop that never overrode anything leaves the SMC
    /// completely untouched.
    originals: Option<Vec<(usize, FanOriginalState)>>,
    missing: u32,
    unverified: u32,
}

impl Governor {
    pub fn applied(&self) -> Option<f64> {
        self.applied
    }

    /// Whether this governor wrote anything (and so owes a restore).
    pub fn has_overridden(&self) -> bool {
        self.originals.is_some()
    }

    pub fn tick(&mut self, env: &FanEnv, selection: &FanSelection) -> Result<Tick, FanError> {
        if selection.profile == FanProfile::System {
            return Ok(Tick::Stop);
        }
        let report = read_sensors(env.smc, env.host);
        let temperature = governing_temperature(&report);
        // Only computed when a target is set on Cool, so every other position
        // does exactly the work it always did.
        let average = average_for(selection, &report);
        self.missing = if temperature.is_none() {
            self.missing + 1
        } else {
            0
        };
        if self.missing >= MAX_CONSECUTIVE_MISSING_TEMPERATURES {
            return Err(FanError::Failed(format!(
                "fan governor: no die temperature for {} consecutive readings \
                 — handing the fans back to the firmware",
                self.missing
            )));
        }
        let mut next = next_fraction(selection, temperature, average, self.applied);
        // Inside the deadband nothing is written, so confirm the SMC still
        // holds the applied state (the firmware can take the fans back, e.g.
        // across sleep) and re-assert it when it does not.
        if next.is_none()
            && let Some(applied) = self.applied
        {
            if holds_applied_state(env, applied) {
                self.unverified = 0;
            } else {
                self.unverified += 1;
                if self.unverified >= MAX_CONSECUTIVE_UNVERIFIED_TICKS {
                    return Err(FanError::Failed(format!(
                        "fan governor: the SMC did not hold the applied fan state for {} \
                         consecutive checks — handing the fans back to the firmware",
                        self.unverified
                    )));
                }
                next = Some(applied);
            }
        }
        if let Some(next) = next {
            if self.originals.is_none() {
                self.originals = Some(capture_original_states(env));
            }
            apply_fan(env, next)?;
            self.applied = Some(next);
        }
        Ok(Tick::Ran {
            temperature,
            applied: self.applied,
        })
    }

    /// The way out: put every fan back to the state found before the first write.
    pub fn finish(&mut self, env: &FanEnv) {
        if let Some(originals) = self.originals.take() {
            restore(env, &originals);
        }
        self.applied = None;
    }
}

/// Run until `should_continue` says no or the selection becomes `system`,
/// then hand the fans back (also when a tick failed).
pub fn run(
    env: &FanEnv,
    selection: &dyn Fn() -> FanSelection,
    should_continue: &dyn Fn() -> bool,
    on_tick: &mut dyn FnMut(Option<f64>, Option<f64>),
) -> Result<(), FanError> {
    let mut governor = Governor::default();
    let result = (|| {
        while should_continue() {
            match governor.tick(env, &selection())? {
                Tick::Stop => return Ok(()),
                Tick::Ran {
                    temperature,
                    applied,
                } => on_tick(temperature, applied),
            }
            env.clock.sleep(DEFAULT_INTERVAL);
        }
        Ok(())
    })();
    governor.finish(env);
    result
}

/// A fixed fraction held for a lease (`fan set` through the helper): written
/// once, verified every tick, handed back when the lease ends. The thermal
/// gate of [`apply_fan`] still applies.
#[derive(Default)]
pub struct FixedHold {
    fraction: f64,
    originals: Option<Vec<(usize, FanOriginalState)>>,
    unverified: u32,
}

impl FixedHold {
    pub fn start(env: &FanEnv, fraction: f64) -> Result<Self, FanError> {
        // Refused (thermal gate, no fans, ...) before anything is captured or written.
        let (clamped, count) = preflight_apply(env, fraction)?;
        let mut hold = Self {
            fraction,
            originals: Some(capture_original_states(env)),
            ..Self::default()
        };
        if let Err(e) = write_apply(env, clamped, count) {
            hold.finish(env);
            return Err(e);
        }
        Ok(hold)
    }

    pub fn tick(&mut self, env: &FanEnv) -> Result<(), FanError> {
        if holds_applied_state(env, self.fraction) {
            self.unverified = 0;
            return Ok(());
        }
        self.unverified += 1;
        if self.unverified >= MAX_CONSECUTIVE_UNVERIFIED_TICKS {
            return Err(FanError::Failed(format!(
                "fan target: the SMC did not hold the applied fan state for {} consecutive \
                 checks — handing the fans back to the firmware",
                self.unverified
            )));
        }
        apply_fan(env, self.fraction)
    }

    pub fn finish(&mut self, env: &FanEnv) {
        if let Some(originals) = self.originals.take() {
            restore(env, &originals);
        }
    }
}
