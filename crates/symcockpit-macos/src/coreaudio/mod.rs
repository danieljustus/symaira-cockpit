//! CoreAudio adapters: the device HAL, process taps and the signals a
//! foreground mixer needs. Live tests are `#[ignore]` and read only.

mod hal;
mod objc;
mod props;
mod signals;
mod tap;

pub use hal::RealAudioHal;
pub use signals::{install_signal_handlers, interrupted};
pub use tap::RealTapHal;

#[cfg(test)]
mod live {
    use std::sync::Arc;
    use symcockpit_core::audio::cli::{self, Context};
    use symcockpit_core::audio::commands as c;
    use symcockpit_core::audio::mixer::TapHal;
    use symcockpit_core::audio::{AudioHal, AudioService, Scope};

    use super::*;

    /// Reads the real devices, formats and process list; changes nothing.
    /// `cargo test -p symcockpit-macos live -- --ignored --nocapture`
    #[test]
    #[ignore = "reads the real audio devices of this Mac"]
    fn read_only_device_and_format_listing() {
        let hal = Arc::new(RealAudioHal::new());
        let snapshot = hal.snapshot().expect("snapshot");
        assert!(!snapshot.devices.is_empty(), "no audio devices at all");
        let svc = AudioService::new(hal.clone());
        let v = c::devices_json(&svc).unwrap();
        let n = v["devices"].as_array().unwrap().len();
        // Print counts and structure only, never names or UIDs.
        eprintln!(
            "devices: {n}; default output present: {}",
            v["default_output_uid"].is_string()
        );
        for d in snapshot.devices.iter() {
            assert!(!d.uid.is_empty());
            let f = c::format_get_json(&svc, &d.uid).unwrap();
            eprintln!(
                "  {:?} transport={} in_ch={} out_ch={} rate={:?} rates={} out_formats={}",
                d.kind,
                d.transport,
                d.input.channels,
                d.output.channels,
                d.sample_rate,
                d.sample_rates.len(),
                f["output"]["formats"].as_array().map_or(0, Vec::len)
            );
        }
        let with_volume = snapshot.devices.iter().filter(|d| d.output.volume.is_some() || d.input.volume.is_some()).count();
        let settable = snapshot.devices.iter().filter(|d| d.output.volume_settable || d.input.volume_settable).count();
        eprintln!("devices with a readable volume: {with_volume}, settable: {settable}");
        // listener registration (process-local; also detaches the HAL from the main run loop)
        let watched = RealAudioHal::watch().expect("listeners");
        assert_eq!(watched.change_epoch(), 0, "no change yet");
        drop(watched);
        let out = hal.default_device(Scope::Output).unwrap();
        assert_eq!(out.is_some(), v["default_output_uid"].is_string());
        // the process list is read-only and needs no permission
        let taps = RealTapHal::new();
        eprintln!("process taps supported: {}", taps.supported());
        if taps.supported() {
            let p = taps.processes().expect("process list");
            eprintln!("audio processes: {}", p.len());
        }
        // the CLI path end to end
        let midi = symcockpit_core::midi::MidiService::new(Arc::new(
            crate::coremidi::RealMidiHal::new().unwrap(),
        ));
        let ctx = Context {
            audio: &svc,
            midi: &midi,
            tap: None,
            mixer: None,
            stop: &|| true,
        };
        let cmd = cli::parse_audio(&["devices".to_owned(), "--json".to_owned()]).unwrap();
        assert!(cli::run(&cmd, &ctx).is_ok());
    }
}
