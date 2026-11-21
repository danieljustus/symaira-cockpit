//! The production [`Platform`]: the real pasteboard, Keychain, process taps, CoreBluetooth,
//! event tap, trackpad actuator and Terminal. Every factory first asks
//! [`crate::service_blocked`], so a debug binary a test started
//! (`SYMCOCKPIT_TEST_NO_HARDWARE`) reports the service as `unsupported` instead of touching the
//! user's clipboard, audio, radio, keyboard or trackpad.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use symcockpit_contract::Error;
use symcockpit_core::audio::AudioHal;
use symcockpit_core::audio::mixer::TapHal;
use symcockpit_core::bluetooth::BleCentral;
use symcockpit_core::finder::FinderPlatform;
use symcockpit_core::input::{ActionHook, RunningTap, TapHost};
use symcockpit_macos::bluetooth::CoreBluetoothCentral;
use symcockpit_macos::clipboard::{KeychainKey, SystemPasteboard, TimeMachineExclusion};
use symcockpit_macos::coreaudio::{RealAudioHal, RealTapHal};
use symcockpit_macos::finder::MacFinderPlatform;
use symcockpit_macos::input::{
    AfplaySound, JsonFileSettings, LiveProbe, LiveTapHost, MultitouchHaptics,
};
use symcockpit_macos::runloop::RunLoopWaker;

use super::clipboard::ClipboardParts;
use super::input::Feedback;
use super::mixer::MixerParts;
use super::{Platform, RunLoop};
use crate::service_blocked;

/// The main run loop through a [`RunLoopWaker`]; built on the main thread.
pub struct MainRunLoop(RunLoopWaker);

impl MainRunLoop {
    pub fn new() -> Option<Self> {
        RunLoopWaker::new().map(Self)
    }
}

impl RunLoop for MainRunLoop {
    fn wake(&self) {
        self.0.wake();
    }
    fn run_for(&self, limit: std::time::Duration) {
        self.0.run_for(limit);
    }
}

/// Refuses every effect: stands in for the Finder platform when services are blocked.
struct BlockedFinder(Error);

impl FinderPlatform for BlockedFinder {
    fn copy_text(&self, _text: &str) -> Result<(), String> {
        Err(self.0.to_string())
    }
    fn open_in_terminal(&self, _dir: &Path) -> Result<(), String> {
        Err(self.0.to_string())
    }
}

struct BlockedTap(Error);

impl TapHost for BlockedTap {
    fn start(&self, _on_action: ActionHook) -> Result<Box<dyn RunningTap>, Error> {
        Err(self.0.clone())
    }
}

/// `config_dir/input.json` holds the input switches (the CLI's `input finder-cut` writes it).
pub fn platform(config_dir: PathBuf, run_loop: Option<MainRunLoop>) -> Platform {
    let settings_path = config_dir.join("input.json");
    Platform {
        clipboard: Arc::new(|| {
            service_blocked("the clipboard history")?;
            Ok(ClipboardParts {
                source: Box::new(SystemPasteboard),
                sink: Box::new(SystemPasteboard),
                keys: Box::new(KeychainKey),
                exclusion: Box::new(TimeMachineExclusion),
            })
        }),
        mixer: Arc::new(|| {
            service_blocked("per-app volume")?;
            Ok(MixerParts {
                tap: Arc::new(RealTapHal::new()) as Arc<dyn TapHal>,
                audio: Arc::new(RealAudioHal::new()) as Arc<dyn AudioHal>,
            })
        }),
        finder: Arc::new(|| match service_blocked("Finder actions") {
            Ok(()) => Box::new(MacFinderPlatform),
            Err(blocked) => Box::new(BlockedFinder(blocked)),
        }),
        central: Arc::new(|| {
            service_blocked("Bluetooth")?;
            CoreBluetoothCentral::new().map(|c| Box::new(c) as Box<dyn BleCentral>)
        }),
        tap: match service_blocked("the Finder event tap") {
            Ok(()) => Box::new(LiveTapHost),
            Err(blocked) => Box::new(BlockedTap(blocked)),
        },
        probe: Box::new(LiveProbe),
        input_settings: Arc::new(move || Box::new(JsonFileSettings::new(&settings_path))),
        feedback: Arc::new(|| {
            service_blocked("haptics and sound")?;
            Ok(Feedback {
                haptic: Box::new(MultitouchHaptics),
                sound: Box::new(AfplaySound::default()),
            })
        }),
        run_loop: run_loop.map(|l| Arc::new(l) as Arc<dyn RunLoop>),
    }
}
