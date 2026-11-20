//! Input adapters: CGEvent tap (Finder cut), MultitouchSupport (haptics),
//! `afplay` (material sound), a JSON settings file.

mod haptics;
mod settings;
mod sound;
mod tap;

pub use haptics::MultitouchHaptics;
pub use settings::JsonFileSettings;
pub use sound::AfplaySound;
pub use tap::{FinderCutTap, LiveProbe};
