//! The display write surface (port of `HardwareDisplayWriteService`,
//! `DisplayService`'s write half and `DimOverlay`): built-in brightness,
//! warmth, extended brightness and the dim overlay, composed from ports so
//! tests never touch a display.
//!
//! Warmth and extended brightness share one [`GammaController`]; nothing here
//! writes a gamma table any other way.

use std::cell::Cell;
use std::rc::Rc;
use std::time::Instant;

use symcockpit_contract::Error;

use crate::display::{BrightnessSource, DisplayEnumerator};
use crate::edr::EdrOverlay;
use crate::gamma::GammaController;

/// Port: writes the 0.0–1.0 brightness of one display.
pub trait BrightnessSink {
    fn set_brightness(&self, display_id: u32, value: f32) -> Result<(), Error>;
}

/// Port: the software dim windows. `show` covers every display with a black
/// layer of `1 - opacity`; `hide` removes them all.
pub trait DimOverlayPort {
    fn show(&self, opacity: f32);
    fn hide(&self);
}

pub struct DisplayWriter {
    displays: Box<dyn DisplayEnumerator>,
    brightness: Box<dyn BrightnessSource>,
    sink: Box<dyn BrightnessSink>,
    gamma: Rc<GammaController>,
    edr: EdrOverlay,
    dim: Box<dyn DimOverlayPort>,
    dim_level: Cell<f32>,
}

impl DisplayWriter {
    pub fn new(
        displays: Box<dyn DisplayEnumerator>,
        brightness: Box<dyn BrightnessSource>,
        sink: Box<dyn BrightnessSink>,
        gamma: Rc<GammaController>,
        edr: EdrOverlay,
        dim: Box<dyn DimOverlayPort>,
    ) -> Self {
        Self {
            displays,
            brightness,
            sink,
            gamma,
            edr,
            dim,
            dim_level: Cell::new(1.0),
        }
    }

    /// The first built-in display; `Unsupported` without one.
    pub fn builtin_display_id(&self) -> Result<u32, Error> {
        self.builtin_display_id_or_none()
            .ok_or_else(|| Error::Unsupported("No built-in display detected.".into()))
    }

    pub fn builtin_display_id_or_none(&self) -> Option<u32> {
        self.displays
            .enumerate_screens()
            .into_iter()
            .find(|s| s.is_builtin)
            .map(|s| s.display_id)
    }

    pub fn builtin_brightness(&self) -> Result<f64, Error> {
        self.brightness.brightness(self.builtin_display_id()?)
    }

    /// The caller clamps through the safety policy first.
    pub fn set_builtin_brightness(&self, value: f32) -> Result<(), Error> {
        self.sink.set_brightness(self.builtin_display_id()?, value)
    }

    /// Writes one named display (the record of an earlier run names its own).
    pub fn set_brightness_on(&self, display_id: u32, value: f32) -> Result<(), Error> {
        self.sink.set_brightness(display_id, value)
    }

    pub fn apply_warmth(&self, warmth: f32) -> Result<(), Error> {
        self.gamma.set_warmth(warmth, self.builtin_display_id()?)
    }

    /// Resets warmth, keeping any brightness boost.
    pub fn reset_warmth(&self) -> Result<(), Error> {
        self.gamma.set_warmth(0.0, self.builtin_display_id()?)
    }

    pub fn apply_extended_brightness(&self, multiplier: f64) -> Result<(), Error> {
        self.edr
            .apply(multiplier, self.builtin_display_id()?, Instant::now())
    }

    /// No dimming means no overlay: a transparent window left per display
    /// would keep the compositor blending an invisible layer.
    pub fn apply_dim(&self, opacity: f32) {
        if opacity < 1.0 {
            self.dim_level.set(opacity);
            self.dim.show(opacity);
        } else {
            self.reset_dim();
        }
    }

    pub fn reset_dim(&self) {
        self.dim.hide();
        self.dim_level.set(1.0);
    }

    pub fn dim_level(&self) -> f32 {
        self.dim_level.get()
    }

    /// Restores a tracked session, including extended brightness and ColorSync.
    pub fn restore_display_overrides(&self, brightness: Option<f32>, reset_gamma: bool) {
        if let Some(value) = brightness {
            let _ = self.set_builtin_brightness(value);
        }
        self.edr.remove_all();
        if reset_gamma {
            self.gamma.reset_all();
            self.gamma.restore_all_displays();
        }
    }

    /// Whether the run loop must be pumped (a headroom watch is waiting).
    pub fn needs_pump(&self) -> bool {
        self.edr.has_pending_watch()
    }

    /// Whether the dim windows or the extended-brightness trigger are on screen.
    pub fn has_overlay(&self) -> bool {
        self.dim_level.get() < 1.0 || self.edr.is_active()
    }

    pub fn pump(&self, now: Instant) {
        self.edr.tick(now);
    }

    /// Re-applies what the system dropped (display wake).
    pub fn reassert(&self) {
        self.edr.reassert(Instant::now());
        self.gamma.reassert();
    }

    pub fn extended_requested(&self, display_id: u32) -> Option<f64> {
        self.edr.requested(display_id)
    }

    pub fn extended_effective(&self, display_id: u32) -> Option<f64> {
        self.edr.effective(display_id)
    }

    /// Takes the extended-brightness trigger away (process end).
    pub fn remove_extended(&self) {
        self.edr.remove_all();
    }
}
