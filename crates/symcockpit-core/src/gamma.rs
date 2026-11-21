//! The one owner of every display's gamma table (port of `DisplayGamma` and
//! `DisplayGammaController`; tuning/AGENTS.md "One owner for the gamma table").
//!
//! Warmth and extended brightness both write the same hardware LUT. Both are
//! expressed here as multipliers on top of the ramp the display had *before*
//! any override, so neutral input reproduces that ramp exactly and nothing
//! rebuilds a ramp from scratch. No other module may write a gamma table:
//! the only write path is the [`GammaIo`] port this controller owns.

use std::cell::RefCell;
use std::collections::BTreeMap;

use symcockpit_contract::Error;

/// Green attenuation at full warmth (small: green carries the luminance).
pub const WARMTH_GREEN_ATTENUATION: f32 = 0.05;
/// Blue attenuation at full warmth: the actual colour-temperature shift.
pub const WARMTH_BLUE_ATTENUATION: f32 = 0.30;

/// One display's transfer table. Values above `1.0` are the mechanism behind
/// extended brightness (they render into EDR headroom instead of clipping).
#[derive(Clone, Debug, PartialEq)]
pub struct GammaRamp {
    pub red: Vec<f32>,
    pub green: Vec<f32>,
    pub blue: Vec<f32>,
}

impl GammaRamp {
    /// The straight ramp: input maps to output unchanged.
    pub fn identity(sample_count: usize) -> Self {
        assert!(sample_count > 1, "a gamma ramp needs at least two samples");
        let values: Vec<f32> = (0..sample_count)
            .map(|i| i as f32 / (sample_count - 1) as f32)
            .collect();
        Self {
            red: values.clone(),
            green: values.clone(),
            blue: values,
        }
    }

    pub fn sample_count(&self) -> usize {
        self.red.len()
    }

    /// Every channel has the same sample count, at least two.
    pub fn is_well_formed(&self) -> bool {
        self.red.len() > 1
            && self.red.len() == self.green.len()
            && self.red.len() == self.blue.len()
    }
}

/// `GammaComposition.compose`: `None` for a malformed base (an empty or ragged
/// ramp must never reach the hardware).
pub fn compose(base: &GammaRamp, warmth: f32, boost: f32) -> Option<GammaRamp> {
    if !base.is_well_formed() {
        return None;
    }
    let warmth = warmth.clamp(0.0, 1.0);
    let boost = boost.max(0.0);
    let green_scale = boost * (1.0 - warmth * WARMTH_GREEN_ATTENUATION);
    let blue_scale = boost * (1.0 - warmth * WARMTH_BLUE_ATTENUATION);
    // Headroom for the whole table: 1.0 normally, `boost` when boosting.
    let ceiling = 1.0_f32.max(boost);
    let scale = |channel: &[f32], factor: f32| -> Vec<f32> {
        channel
            .iter()
            .map(|v| (v * factor).clamp(0.0, ceiling))
            .collect()
    };
    Some(GammaRamp {
        red: scale(&base.red, boost),
        green: scale(&base.green, green_scale),
        blue: scale(&base.blue, blue_scale),
    })
}

/// Whether `warmth`/`boost` mean "leave the display alone".
pub fn is_neutral(warmth: f32, boost: f32) -> bool {
    warmth <= 0.0005 && (boost - 1.0).abs() <= 0.0005
}

/// Port over the CoreGraphics gamma calls.
pub trait GammaIo {
    fn read_ramp(&self, display_id: u32, sample_count: usize) -> Option<GammaRamp>;
    /// `false` when CoreGraphics rejected the table.
    fn write_ramp(&self, ramp: &GammaRamp, display_id: u32) -> bool;
    /// Hands every display back to its ColorSync calibration.
    fn restore_system_ramps(&self);
}

struct DisplayState {
    base: GammaRamp,
    warmth: f32,
    boost: f32,
}

pub struct GammaController {
    io: Box<dyn GammaIo>,
    sample_count: usize,
    states: RefCell<BTreeMap<u32, DisplayState>>,
}

impl GammaController {
    pub fn new(io: Box<dyn GammaIo>) -> Self {
        Self {
            io,
            sample_count: 256,
            states: RefCell::default(),
        }
    }

    /// Applied warmth for a display (`0` when untouched).
    pub fn warmth(&self, display_id: u32) -> f32 {
        self.states
            .borrow()
            .get(&display_id)
            .map_or(0.0, |s| s.warmth)
    }

    /// Applied brightness boost for a display (`1.0` when untouched).
    pub fn boost(&self, display_id: u32) -> f32 {
        self.states
            .borrow()
            .get(&display_id)
            .map_or(1.0, |s| s.boost)
    }

    pub fn has_overrides(&self) -> bool {
        !self.states.borrow().is_empty()
    }

    pub fn set_warmth(&self, warmth: f32, display_id: u32) -> Result<(), Error> {
        self.update(display_id, |s| s.warmth = warmth.clamp(0.0, 1.0))
    }

    /// Callers must have clamped to the headroom the display granted.
    pub fn set_boost(&self, boost: f32, display_id: u32) -> Result<(), Error> {
        self.update(display_id, |s| s.boost = boost.max(1.0))
    }

    /// Drops every override on one display and hands it back to ColorSync.
    pub fn reset(&self, display_id: u32) {
        let had = self.states.borrow_mut().remove(&display_id).is_some();
        if had {
            self.restore_and_reapply_others();
        }
    }

    pub fn reset_all(&self) {
        let had = !self.states.borrow().is_empty();
        self.states.borrow_mut().clear();
        if had {
            self.io.restore_system_ramps();
        }
    }

    /// Hands every display back to ColorSync, whether or not this controller
    /// holds state (a restore must not trust bookkeeping alone).
    pub fn restore_all_displays(&self) {
        self.io.restore_system_ramps();
    }

    /// Re-writes the composed tables (macOS drops them on display wake).
    pub fn reassert(&self) {
        for (id, s) in self.states.borrow().iter() {
            if let Some(ramp) = compose(&s.base, s.warmth, s.boost) {
                let _ = self.io.write_ramp(&ramp, *id);
            }
        }
    }

    /// `CGDisplayRestoreColorSyncSettings` is all-displays: re-apply the others
    /// so resetting one display cannot silently clear its neighbour.
    fn restore_and_reapply_others(&self) {
        self.io.restore_system_ramps();
        self.reassert();
    }

    fn update(&self, display_id: u32, mutate: impl FnOnce(&mut DisplayState)) -> Result<(), Error> {
        let previous = self.states.borrow().get(&display_id).map(|s| DisplayState {
            base: s.base.clone(),
            warmth: s.warmth,
            boost: s.boost,
        });
        let mut state = match previous.as_ref() {
            Some(s) => DisplayState {
                base: s.base.clone(),
                warmth: s.warmth,
                boost: s.boost,
            },
            // Capture the display's own table once, before anything is applied.
            None => DisplayState {
                base: self
                    .io
                    .read_ramp(display_id, self.sample_count)
                    .ok_or_else(|| {
                        Error::Failed(format!(
                            "Could not read the gamma table for display {display_id}."
                        ))
                    })?,
                warmth: 0.0,
                boost: 1.0,
            },
        };
        mutate(&mut state);

        if is_neutral(state.warmth, state.boost) {
            self.states.borrow_mut().remove(&display_id);
            self.restore_and_reapply_others();
            return Ok(());
        }
        let ramp = compose(&state.base, state.warmth, state.boost).ok_or_else(|| {
            Error::Failed(format!(
                "Could not compose a gamma table for display {display_id}."
            ))
        })?;
        self.states.borrow_mut().insert(display_id, state);
        if self.io.write_ramp(&ramp, display_id) {
            return Ok(());
        }
        // Roll the recorded state back to what the hardware still has: an
        // optimistic value would report an override that was never applied.
        let mut states = self.states.borrow_mut();
        match previous {
            Some(p) => {
                states.insert(display_id, p);
            }
            None => {
                states.remove(&display_id);
            }
        }
        Err(Error::Failed(format!(
            "CGSetDisplayTransferByTable failed for display {display_id}."
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::rc::Rc;

    /// Records every call; no display is touched.
    #[derive(Default)]
    struct Recorder {
        reads: Cell<usize>,
        writes: RefCell<Vec<(u32, GammaRamp)>>,
        restores: Cell<usize>,
        fail_writes: Cell<bool>,
        unreadable: Cell<bool>,
    }
    struct Io(Rc<Recorder>);
    impl GammaIo for Io {
        fn read_ramp(&self, _: u32, n: usize) -> Option<GammaRamp> {
            self.0.reads.set(self.0.reads.get() + 1);
            (!self.0.unreadable.get()).then(|| GammaRamp::identity(n))
        }
        fn write_ramp(&self, ramp: &GammaRamp, id: u32) -> bool {
            self.0.writes.borrow_mut().push((id, ramp.clone()));
            !self.0.fail_writes.get()
        }
        fn restore_system_ramps(&self) {
            self.0.restores.set(self.0.restores.get() + 1);
        }
    }
    fn controller() -> (GammaController, Rc<Recorder>) {
        let rec = Rc::new(Recorder::default());
        (GammaController::new(Box::new(Io(rec.clone()))), rec)
    }

    // Vectors: tuning/Tests/SymCockpitCoreTests/DisplayGammaTests.swift (compose math).
    #[test]
    fn neutral_composition_reproduces_the_base_ramp() {
        let base = GammaRamp::identity(8);
        assert_eq!(compose(&base, 0.0, 1.0).unwrap(), base);
    }

    #[test]
    fn warmth_attenuates_green_a_little_and_blue_more() {
        let ramp = compose(&GammaRamp::identity(2), 1.0, 1.0).unwrap();
        assert_eq!(ramp.red, [0.0, 1.0]);
        assert!((ramp.green[1] - 0.95).abs() < 1e-6);
        assert!((ramp.blue[1] - 0.70).abs() < 1e-6);
    }

    #[test]
    fn boost_raises_the_ceiling_instead_of_clipping_at_one() {
        let ramp = compose(&GammaRamp::identity(2), 0.0, 1.4).unwrap();
        assert!((ramp.red[1] - 1.4).abs() < 1e-6);
        assert!(ramp.red.iter().all(|v| *v <= 1.4 + 1e-6));
    }

    #[test]
    fn malformed_bases_never_compose() {
        let ragged = GammaRamp {
            red: vec![0.0, 1.0],
            green: vec![0.0],
            blue: vec![0.0, 1.0],
        };
        assert!(compose(&ragged, 0.5, 1.0).is_none());
        assert!(
            compose(
                &GammaRamp {
                    red: vec![],
                    green: vec![],
                    blue: vec![]
                },
                0.0,
                1.0
            )
            .is_none()
        );
    }

    #[test]
    fn warmth_is_captured_once_and_composed_with_the_boost() {
        let (c, rec) = controller();
        c.set_warmth(0.5, 1).unwrap();
        c.set_boost(1.3, 1).unwrap();
        assert_eq!(
            rec.reads.get(),
            1,
            "base captured before the first override only"
        );
        assert_eq!((c.warmth(1), c.boost(1)), (0.5, 1.3));
        let (_, last) = rec.writes.borrow().last().cloned().unwrap();
        assert_eq!(last, compose(&GammaRamp::identity(256), 0.5, 1.3).unwrap());
    }

    #[test]
    fn returning_to_neutral_hands_the_display_back_to_colorsync() {
        let (c, rec) = controller();
        c.set_warmth(0.4, 1).unwrap();
        assert!(c.has_overrides());
        c.set_warmth(0.0, 1).unwrap();
        assert!(!c.has_overrides());
        assert_eq!(rec.restores.get(), 1);
        assert_eq!(
            rec.writes.borrow().len(),
            1,
            "no neutral table is ever written"
        );
    }

    #[test]
    fn resetting_one_display_reapplies_its_neighbour() {
        let (c, rec) = controller();
        c.set_warmth(0.4, 1).unwrap();
        c.set_warmth(0.6, 2).unwrap();
        let before = rec.writes.borrow().len();
        c.reset(1);
        assert_eq!(rec.restores.get(), 1);
        let writes = rec.writes.borrow();
        assert_eq!(writes.len(), before + 1);
        assert_eq!(writes.last().unwrap().0, 2);
        drop(writes);
        c.reset(1);
        assert_eq!(
            rec.restores.get(),
            1,
            "resetting an untouched display does nothing"
        );
    }

    #[test]
    fn a_rejected_write_rolls_the_state_back() {
        let (c, rec) = controller();
        c.set_warmth(0.2, 1).unwrap();
        rec.fail_writes.set(true);
        let err = c.set_warmth(0.8, 1).unwrap_err();
        assert_eq!(
            err,
            Error::Failed("CGSetDisplayTransferByTable failed for display 1.".into())
        );
        assert_eq!(c.warmth(1), 0.2);
        let (c2, rec2) = controller();
        rec2.fail_writes.set(true);
        assert!(c2.set_warmth(0.8, 1).is_err());
        assert!(!c2.has_overrides());
    }

    #[test]
    fn an_unreadable_base_is_a_named_error_and_writes_nothing() {
        let (c, rec) = controller();
        rec.unreadable.set(true);
        assert_eq!(
            c.set_warmth(0.5, 7).unwrap_err(),
            Error::Failed("Could not read the gamma table for display 7.".into())
        );
        assert!(rec.writes.borrow().is_empty());
    }

    #[test]
    fn reassert_rewrites_every_composed_table() {
        let (c, rec) = controller();
        c.set_warmth(0.3, 1).unwrap();
        c.reassert();
        assert_eq!(rec.writes.borrow().len(), 2);
        c.reset_all();
        assert_eq!(rec.restores.get(), 1);
        assert!(!c.has_overrides());
    }
}
