//! Human input (R60, R61): Finder cut and paste, trackpad haptics with material sound.
//!
//! Everything here is `human_only` (architecture §5.3): no MCP tool and no
//! agent profile may trigger it. Pure logic behind ports; the live adapters
//! (CGEvent tap, MultitouchSupport) are in `symcockpit-macos`.

mod commands;
mod finder_cut;
mod haptics;
mod settings;
mod sound;

pub use commands::{
    input_finder_cut_json, input_haptics_status_json, input_haptics_test_json, input_status_json,
};
pub use finder_cut::{
    Action, DisabledReason, FINDER_BUNDLE_ID, FinderCut, FinderEnv, Key, KeyEvent, Modifiers,
    Synthetic, TapEvent,
};
pub use haptics::{
    ChannelResult, HapticBackend, HapticLevel, HapticPattern, SoundBackend, TriggerReport, trigger,
};
pub use settings::{InputSettings, SettingsStore};
pub use sound::{Material, material_wav};

/// Whether the event tap may be created (Input Monitoring / Accessibility).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Access {
    Granted,
    Denied,
}

/// Port: what this Mac lets the input features do right now. Reading it must
/// not show a permission dialog.
pub trait InputProbe {
    fn event_tap_access(&self) -> Access;
    fn secure_input_active(&self) -> bool;
}

/// Called on the tap's thread after it replaced a key; must return quickly.
pub type ActionHook = std::sync::Arc<dyn Fn(Synthetic) + Send + Sync>;

/// A running Finder-cut tap. Dropping it removes the tap.
pub trait RunningTap {}

/// Port: installs the Finder ⌘X/⌘V tap on the calling thread's run loop, which the caller (the
/// app agent's main thread) keeps spinning. `Error::Permission` without the permission.
pub trait TapHost {
    fn start(
        &self,
        on_action: ActionHook,
    ) -> Result<Box<dyn RunningTap>, symcockpit_contract::Error>;
}
