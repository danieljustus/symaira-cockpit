//! Extended ("beyond 100%") brightness (port of `EDROverlayService`).
//!
//! It needs both halves (tuning/AGENTS.md): an on-screen EDR *trigger* that is
//! really rendered, so macOS grants headroom, and a gamma boost clamped to the
//! headroom that was granted. The boost goes through [`GammaController`] only.
//! The caller reports `requested` vs `effective` instead of assuming the request
//! took effect.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;
use std::time::{Duration, Instant};

use symcockpit_contract::Error;

use crate::gamma::GammaController;

/// Granted headroom above this counts as "EDR is engaged".
pub const ENGAGED_HEADROOM_THRESHOLD: f64 = 1.05;
/// How long to keep asking the display to engage EDR (it takes a second or two).
pub const ENGAGE_TIMEOUT: Duration = Duration::from_secs(20);
/// Poll cadence while waiting for EDR to engage.
pub const ENGAGE_POLL_INTERVAL: Duration = Duration::from_millis(250);
/// Tolerance for "the request is fully applied".
pub const HEADROOM_EPSILON: f64 = 0.005;
/// How far the gamma lift may go without EDR headroom: without it output above
/// SDR white clips, so the fallback stays well below the policy maximum.
pub const SOFTWARE_BOOST_CAP: f64 = 1.15;
pub const EXTENDED_BRIGHTNESS_MIN: f64 = 1.0;
pub const EXTENDED_BRIGHTNESS_MAX: f64 = 1.6;

/// The on-screen content that makes the system grant headroom.
pub trait EdrTrigger {
    /// Presents a frame (on creation and whenever the display reconfigures).
    fn render(&self);
    /// Takes the trigger off screen.
    fn remove(&self);
}

/// Port: headroom reading and trigger creation.
pub trait EdrPlatform {
    /// The headroom the system currently grants (`1.0` = SDR only).
    fn headroom(&self, display_id: u32) -> Option<f64>;
    fn create_trigger(&self, display_id: u32) -> Option<Box<dyn EdrTrigger>>;
}

struct Target {
    requested: f64,
    applied: Option<f64>,
    trigger: Box<dyn EdrTrigger>,
}

struct Watch {
    deadline: Instant,
    next_poll: Instant,
}

pub struct EdrOverlay {
    gamma: Rc<GammaController>,
    platform: Box<dyn EdrPlatform>,
    targets: RefCell<BTreeMap<u32, Target>>,
    watches: RefCell<BTreeMap<u32, Watch>>,
}

impl EdrOverlay {
    pub fn new(gamma: Rc<GammaController>, platform: Box<dyn EdrPlatform>) -> Self {
        Self {
            gamma,
            platform,
            targets: RefCell::default(),
            watches: RefCell::default(),
        }
    }

    /// Applies extended brightness to one display. Returns as soon as the
    /// trigger is on screen; the boost is written as soon as the display
    /// reports headroom, clamped to it, and [`tick`](Self::tick) keeps
    /// re-applying while the request is unmet.
    pub fn apply(&self, multiplier: f64, display_id: u32, now: Instant) -> Result<(), Error> {
        if !(EXTENDED_BRIGHTNESS_MIN..=EXTENDED_BRIGHTNESS_MAX).contains(&multiplier) {
            return Err(Error::Usage(format!(
                "Extended brightness must be between {EXTENDED_BRIGHTNESS_MIN:?} and {EXTENDED_BRIGHTNESS_MAX:?}."
            )));
        }
        // The SDR reference needs no trigger and no boost.
        if multiplier <= EXTENDED_BRIGHTNESS_MIN {
            self.remove(display_id);
            return Ok(());
        }
        let existing = self.targets.borrow_mut().get_mut(&display_id).map(|t| {
            t.requested = multiplier;
        });
        if existing.is_none() {
            let trigger = self.platform.create_trigger(display_id).ok_or_else(|| {
                Error::Failed(format!(
                    "Could not create the EDR trigger for display {display_id}."
                ))
            })?;
            self.targets.borrow_mut().insert(
                display_id,
                Target {
                    requested: multiplier,
                    applied: None,
                    trigger,
                },
            );
        }
        self.apply_boost_if_engaged(display_id, now)?;
        Ok(())
    }

    /// Removes the boost and the trigger for one display (restores SDR).
    pub fn remove(&self, display_id: u32) {
        self.watches.borrow_mut().remove(&display_id);
        let target = self.targets.borrow_mut().remove(&display_id);
        if let Some(target) = target {
            self.gamma.reset(display_id);
            target.trigger.remove();
        }
    }

    pub fn remove_all(&self) {
        self.watches.borrow_mut().clear();
        let all = std::mem::take(&mut *self.targets.borrow_mut());
        for (display_id, target) in all {
            self.gamma.reset(display_id);
            target.trigger.remove();
        }
    }

    /// The multiplier the user asked for, `None` when the display is neutral.
    pub fn requested(&self, display_id: u32) -> Option<f64> {
        self.targets.borrow().get(&display_id).map(|t| t.requested)
    }

    /// The boost actually in effect, `None` when nothing is applied.
    pub fn effective(&self, display_id: u32) -> Option<f64> {
        self.targets
            .borrow()
            .get(&display_id)
            .and_then(|t| t.applied)
    }

    /// Re-applies active boosts the system dropped (display wake).
    pub fn reassert(&self, now: Instant) {
        let ids: Vec<u32> = self.targets.borrow().keys().copied().collect();
        for id in ids {
            let _ = self.apply_boost_if_engaged(id, now);
        }
    }

    /// Whether a watch is waiting for headroom (the caller must keep pumping).
    pub fn has_pending_watch(&self) -> bool {
        !self.watches.borrow().is_empty()
    }

    /// Advances the headroom watch: the granted headroom *grows* over a second
    /// or two after EDR engages, so a single clamp at apply time would leave a
    /// request stuck at what happened to be available in that instant.
    pub fn tick(&self, now: Instant) {
        let due: Vec<u32> = self
            .watches
            .borrow()
            .iter()
            .filter(|(_, w)| now >= w.next_poll)
            .map(|(id, _)| *id)
            .collect();
        for id in due {
            let expired = self
                .watches
                .borrow()
                .get(&id)
                .is_none_or(|w| now >= w.deadline);
            if expired || !self.targets.borrow().contains_key(&id) {
                self.watches.borrow_mut().remove(&id);
                continue;
            }
            if let Some(w) = self.watches.borrow_mut().get_mut(&id) {
                w.next_poll = now + ENGAGE_POLL_INTERVAL;
            }
            // Also re-renders the trigger: content that stops being presented
            // can stop counting as on-screen EDR.
            if self.apply_boost_if_engaged(id, now) == Ok(true) {
                self.watches.borrow_mut().remove(&id);
            }
        }
    }

    /// Writes the boost for the headroom the display grants now. Returns
    /// whether the request is fully met.
    fn apply_boost_if_engaged(&self, display_id: u32, now: Instant) -> Result<bool, Error> {
        let requested = {
            let targets = self.targets.borrow();
            let Some(target) = targets.get(&display_id) else {
                return Ok(true);
            };
            target.trigger.render();
            target.requested
        };
        let granted = self.platform.headroom(display_id).unwrap_or(1.0);
        let engaged = granted > ENGAGED_HEADROOM_THRESHOLD;
        // Never ask for more than the panel granted: beyond it the extra output
        // clips to white instead of getting brighter.
        let effective = if engaged {
            requested.min(granted)
        } else {
            requested.min(SOFTWARE_BOOST_CAP)
        };
        self.gamma.set_boost(effective as f32, display_id)?;
        if let Some(target) = self.targets.borrow_mut().get_mut(&display_id) {
            target.applied = Some(effective);
        }
        let satisfied = effective >= requested - HEADROOM_EPSILON;
        if !satisfied {
            self.watches
                .borrow_mut()
                .entry(display_id)
                .or_insert(Watch {
                    deadline: now + ENGAGE_TIMEOUT,
                    next_poll: now + ENGAGE_POLL_INTERVAL,
                });
        }
        Ok(satisfied)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gamma::{GammaIo, GammaRamp};
    use std::cell::Cell;

    #[derive(Default)]
    struct Log {
        renders: Cell<usize>,
        removed: Cell<usize>,
        headroom: Cell<f64>,
        no_trigger: Cell<bool>,
        boosts: RefCell<Vec<f32>>,
        restores: Cell<usize>,
    }
    struct Platform(Rc<Log>);
    struct Trigger(Rc<Log>);
    struct Io(Rc<Log>);
    impl EdrTrigger for Trigger {
        fn render(&self) {
            self.0.renders.set(self.0.renders.get() + 1);
        }
        fn remove(&self) {
            self.0.removed.set(self.0.removed.get() + 1);
        }
    }
    impl EdrPlatform for Platform {
        fn headroom(&self, _: u32) -> Option<f64> {
            Some(self.0.headroom.get())
        }
        fn create_trigger(&self, _: u32) -> Option<Box<dyn EdrTrigger>> {
            (!self.0.no_trigger.get()).then(|| Box::new(Trigger(self.0.clone())) as _)
        }
    }
    impl GammaIo for Io {
        fn read_ramp(&self, _: u32, n: usize) -> Option<GammaRamp> {
            Some(GammaRamp::identity(n))
        }
        fn write_ramp(&self, ramp: &GammaRamp, _: u32) -> bool {
            self.0
                .boosts
                .borrow_mut()
                .push(ramp.red[ramp.red.len() - 1]);
            true
        }
        fn restore_system_ramps(&self) {
            self.0.restores.set(self.0.restores.get() + 1);
        }
    }
    fn overlay(headroom: f64) -> (EdrOverlay, Rc<Log>) {
        let log = Rc::new(Log::default());
        log.headroom.set(headroom);
        let gamma = Rc::new(GammaController::new(Box::new(Io(log.clone()))));
        (EdrOverlay::new(gamma, Box::new(Platform(log.clone()))), log)
    }

    // Vectors: tuning/Tests/SymCockpitCoreTests/EDROverlayServiceTests.swift
    #[test]
    fn engaged_display_gets_the_full_request_clamped_to_the_grant() {
        let (edr, log) = overlay(1.3);
        edr.apply(1.5, 1, Instant::now()).unwrap();
        assert_eq!(edr.requested(1), Some(1.5));
        assert_eq!(
            edr.effective(1),
            Some(1.3),
            "never beyond what the panel granted"
        );
        assert!(edr.has_pending_watch(), "request not met, keep watching");
        assert!(
            log.renders.get() >= 1,
            "the trigger is rendered, not just created"
        );
    }

    #[test]
    fn a_display_without_headroom_gets_only_the_capped_software_lift() {
        let (edr, _) = overlay(1.0);
        edr.apply(1.5, 1, Instant::now()).unwrap();
        assert_eq!(edr.effective(1), Some(SOFTWARE_BOOST_CAP));
        let (small, _) = overlay(1.0);
        small.apply(1.1, 1, Instant::now()).unwrap();
        assert_eq!(small.effective(1), Some(1.1));
        assert!(!small.has_pending_watch());
    }

    #[test]
    fn the_watch_raises_the_boost_as_headroom_grows_and_then_ends() {
        let (edr, log) = overlay(1.0);
        let t0 = Instant::now();
        edr.apply(1.45, 1, t0).unwrap();
        assert_eq!(edr.effective(1), Some(SOFTWARE_BOOST_CAP));
        log.headroom.set(12.6);
        edr.tick(t0 + Duration::from_millis(100));
        assert_eq!(edr.effective(1), Some(SOFTWARE_BOOST_CAP), "not due yet");
        edr.tick(t0 + ENGAGE_POLL_INTERVAL);
        assert_eq!(edr.effective(1), Some(1.45));
        assert!(!edr.has_pending_watch());
    }

    #[test]
    fn the_watch_gives_up_after_the_engage_timeout() {
        let (edr, _) = overlay(1.0);
        let t0 = Instant::now();
        edr.apply(1.5, 1, t0).unwrap();
        edr.tick(t0 + ENGAGE_TIMEOUT + Duration::from_millis(1));
        assert!(!edr.has_pending_watch());
        assert_eq!(
            edr.effective(1),
            Some(SOFTWARE_BOOST_CAP),
            "keeps the capped lift"
        );
    }

    #[test]
    fn neutral_or_remove_takes_the_trigger_and_boost_away() {
        let (edr, log) = overlay(2.0);
        edr.apply(1.4, 1, Instant::now()).unwrap();
        edr.apply(1.0, 1, Instant::now()).unwrap();
        assert_eq!(edr.requested(1), None);
        assert_eq!((log.removed.get(), log.restores.get()), (1, 1));
        edr.apply(1.4, 1, Instant::now()).unwrap();
        edr.remove_all();
        assert_eq!(log.removed.get(), 2);
        edr.remove_all();
        assert_eq!(log.removed.get(), 2, "idempotent");
    }

    #[test]
    fn out_of_range_requests_and_missing_triggers_are_errors() {
        let (edr, log) = overlay(2.0);
        assert_eq!(
            edr.apply(1.7, 1, Instant::now()).unwrap_err(),
            Error::Usage("Extended brightness must be between 1.0 and 1.6.".into())
        );
        log.no_trigger.set(true);
        assert_eq!(
            edr.apply(1.2, 9, Instant::now()).unwrap_err(),
            Error::Failed("Could not create the EDR trigger for display 9.".into())
        );
        assert!(log.boosts.borrow().is_empty());
    }

    #[test]
    fn a_second_request_updates_the_target_without_a_second_trigger() {
        let (edr, log) = overlay(2.0);
        edr.apply(1.2, 1, Instant::now()).unwrap();
        edr.apply(1.5, 1, Instant::now()).unwrap();
        assert_eq!(edr.effective(1), Some(1.5));
        edr.reassert(Instant::now());
        assert_eq!(log.removed.get(), 0);
    }
}
