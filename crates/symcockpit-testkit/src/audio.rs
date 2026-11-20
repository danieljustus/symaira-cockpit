//! Fake HAL for audio: no hardware is touched. Failure injection per operation,
//! devices that vanish in the middle of a call, writes the "device" ignores
//! (so the readback differs), and a leak-checking fake for process taps.
//!
//! Tests of the core logic through these fakes live here, because the fakes
//! implement traits of `symcockpit-core` (a dev-dependency of core on this
//! crate would see two copies of the traits).

use std::collections::{BTreeSet, HashMap};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

use symcockpit_core::audio::mixer::{AudioProcess, IoHandle, Shared, Tap, TapHal};
use symcockpit_core::audio::{
    AggregateSpec, AudioHal, DeviceKind, HalError, HalErrorKind, HalSnapshot, ObjectId, RateRange,
    RawDevice, Scope, ScopeState, StreamFormat,
};

/// A synthetic stereo output device with a volume and mute control and a
/// small set of formats. Names and UIDs are invented.
pub fn output_device(uid: &str) -> RawDevice {
    let formats = |channels| {
        [(44100.0, 16), (44100.0, 24), (48000.0, 24), (96000.0, 24)]
            .into_iter()
            .map(|(rate, bits)| StreamFormat {
                rate,
                bits,
                channels,
            })
            .collect()
    };
    RawDevice {
        object: ObjectId(0),
        uid: uid.to_owned(),
        name: format!("Fake {uid}"),
        manufacturer: Some("Fake Audio Co".into()),
        transport: "usb".into(),
        kind: DeviceKind::Physical,
        input: ScopeState::default(),
        output: ScopeState {
            channels: 2,
            volume: Some(0.5),
            volume_settable: true,
            muted: Some(false),
            mute_settable: true,
            format: Some(StreamFormat {
                rate: 44100.0,
                bits: 16,
                channels: 2,
            }),
            formats: formats(2),
        },
        sample_rate: Some(44100.0),
        sample_rates: vec![
            RateRange {
                min: 44100.0,
                max: 44100.0,
            },
            RateRange {
                min: 48000.0,
                max: 48000.0,
            },
            RateRange {
                min: 96000.0,
                max: 96000.0,
            },
        ],
        members: vec![],
    }
}

/// A synthetic one-channel input device.
pub fn input_device(uid: &str) -> RawDevice {
    let mut d = output_device(uid);
    d.input = std::mem::take(&mut d.output);
    d.input.channels = 1;
    d.input.format = d.input.format.map(|f| StreamFormat { channels: 1, ..f });
    d
}

#[derive(Default)]
struct Inner {
    devices: Vec<RawDevice>,
    default_input: Option<ObjectId>,
    default_output: Option<ObjectId>,
    next_object: u32,
    /// (operation, remaining calls to let pass, error)
    failures: Vec<(String, u32, HalError)>,
    /// Operations whose write returns `Ok` but changes nothing.
    ignored: BTreeSet<String>,
    /// Unplug this device (by UID) just before the named operation runs.
    vanish_before: Vec<(String, String)>,
    /// A created aggregate holds only its first member.
    partial_aggregates: bool,
    log: Vec<String>,
}

pub struct FakeAudioHal {
    inner: Mutex<Inner>,
    epoch: AtomicU64,
}

fn status(op: &str, kind: HalErrorKind, message: &str) -> HalError {
    HalError {
        kind,
        op: op.to_owned(),
        status: Some(-1),
        message: message.to_owned(),
    }
}

impl FakeAudioHal {
    pub fn new(devices: Vec<RawDevice>) -> Self {
        let hal = FakeAudioHal {
            inner: Mutex::new(Inner {
                next_object: 100,
                ..Default::default()
            }),
            epoch: AtomicU64::new(0),
        };
        for d in devices {
            hal.plug(d);
        }
        hal
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap()
    }

    /// Add a device; every appearance gets a fresh object id.
    pub fn plug(&self, mut device: RawDevice) -> ObjectId {
        let mut s = self.lock();
        s.next_object += 1;
        device.object = ObjectId(s.next_object);
        let id = device.object;
        s.devices.push(device);
        self.epoch.fetch_add(1, Ordering::SeqCst);
        id
    }

    pub fn unplug(&self, uid: &str) {
        let mut s = self.lock();
        let gone: Vec<ObjectId> = s
            .devices
            .iter()
            .filter(|d| d.uid == uid)
            .map(|d| d.object)
            .collect();
        s.devices.retain(|d| d.uid != uid);
        for o in gone {
            if s.default_input == Some(o) {
                s.default_input = None;
            }
            if s.default_output == Some(o) {
                s.default_output = None;
            }
        }
        self.epoch.fetch_add(1, Ordering::SeqCst);
    }

    pub fn set_defaults(&self, input: Option<&str>, output: Option<&str>) {
        let mut s = self.lock();
        let find = |s: &Inner, uid: Option<&str>| {
            uid.and_then(|u| s.devices.iter().find(|d| d.uid == u).map(|d| d.object))
        };
        s.default_input = find(&s, input);
        s.default_output = find(&s, output);
    }

    /// Make the `nth` (0-based) next call of `op` fail with `kind`.
    pub fn fail(&self, op: &str, nth: u32, kind: HalErrorKind) {
        self.lock()
            .failures
            .push((op.to_owned(), nth, status(op, kind, "injected failure")));
    }

    /// Writes of `op` report success and change nothing.
    pub fn ignore_writes(&self, op: &str) {
        self.lock().ignored.insert(op.to_owned());
    }

    /// The device disappears right before `op` runs, after the caller already resolved it.
    pub fn vanish_before(&self, op: &str, uid: &str) {
        self.lock()
            .vanish_before
            .push((op.to_owned(), uid.to_owned()));
    }

    pub fn partial_aggregates(&self) {
        self.lock().partial_aggregates = true;
    }

    pub fn device(&self, uid: &str) -> Option<RawDevice> {
        self.lock().devices.iter().find(|d| d.uid == uid).cloned()
    }

    pub fn log(&self) -> Vec<String> {
        self.lock().log.clone()
    }

    pub fn bump_epoch(&self) {
        self.epoch.fetch_add(1, Ordering::SeqCst);
    }

    /// Common entry of every operation: log, vanish hook, injected failure.
    fn enter(&self, op: &str) -> Result<std::sync::MutexGuard<'_, Inner>, HalError> {
        let mut s = self.lock();
        s.log.push(op.to_owned());
        let hooks: Vec<String> = s
            .vanish_before
            .iter()
            .filter(|(o, _)| o == op)
            .map(|(_, u)| u.clone())
            .collect();
        s.vanish_before.retain(|(o, _)| o != op);
        for uid in hooks {
            let gone: Vec<ObjectId> = s
                .devices
                .iter()
                .filter(|d| d.uid == uid)
                .map(|d| d.object)
                .collect();
            s.devices.retain(|d| d.uid != uid);
            for o in gone {
                if s.default_input == Some(o) {
                    s.default_input = None;
                }
                if s.default_output == Some(o) {
                    s.default_output = None;
                }
            }
            self.epoch.fetch_add(1, Ordering::SeqCst);
        }
        if let Some(i) = s.failures.iter().position(|(o, _, _)| o == op) {
            if s.failures[i].1 == 0 {
                return Err(s.failures.remove(i).2);
            }
            s.failures[i].1 -= 1;
        }
        Ok(s)
    }

    fn with_device<T>(
        &self,
        op: &str,
        object: ObjectId,
        f: impl FnOnce(&mut RawDevice, bool) -> T,
    ) -> Result<T, HalError> {
        let mut s = self.enter(op)?;
        let ignored = s.ignored.contains(op);
        match s.devices.iter_mut().find(|d| d.object == object) {
            Some(d) => Ok(f(d, ignored)),
            None => Err(status(op, HalErrorKind::NoSuchObject, "no such object")),
        }
    }
}

impl AudioHal for FakeAudioHal {
    fn snapshot(&self) -> Result<HalSnapshot, HalError> {
        let s = self.enter("snapshot")?;
        Ok(HalSnapshot {
            devices: s.devices.clone(),
            default_input: s.default_input,
            default_output: s.default_output,
        })
    }

    fn device_uid(&self, object: ObjectId) -> Result<String, HalError> {
        let s = self.lock();
        s.devices
            .iter()
            .find(|d| d.object == object)
            .map(|d| d.uid.clone())
            .ok_or_else(|| status("device_uid", HalErrorKind::NoSuchObject, "no such object"))
    }

    fn default_device(&self, scope: Scope) -> Result<Option<ObjectId>, HalError> {
        let s = self.enter("default_device")?;
        Ok(match scope {
            Scope::Input => s.default_input,
            Scope::Output => s.default_output,
        })
    }

    fn set_default_device(&self, scope: Scope, object: ObjectId) -> Result<(), HalError> {
        let mut s = self.enter("set_default_device")?;
        if !s.devices.iter().any(|d| d.object == object) {
            return Err(status(
                "set_default_device",
                HalErrorKind::NoSuchObject,
                "no such object",
            ));
        }
        if !s.ignored.contains("set_default_device") {
            match scope {
                Scope::Input => s.default_input = Some(object),
                Scope::Output => s.default_output = Some(object),
            }
        }
        Ok(())
    }

    fn volume(&self, object: ObjectId, scope: Scope) -> Result<Option<f32>, HalError> {
        self.with_device("volume", object, |d, _| d.scope(scope).volume)
    }

    fn set_volume(&self, object: ObjectId, scope: Scope, value: f32) -> Result<(), HalError> {
        self.with_device("set_volume", object, |d, ignored| {
            if !ignored {
                let s = if scope == Scope::Input {
                    &mut d.input
                } else {
                    &mut d.output
                };
                s.volume = Some(value);
            }
        })
    }

    fn mute(&self, object: ObjectId, scope: Scope) -> Result<Option<bool>, HalError> {
        self.with_device("mute", object, |d, _| d.scope(scope).muted)
    }

    fn set_mute(&self, object: ObjectId, scope: Scope, muted: bool) -> Result<(), HalError> {
        self.with_device("set_mute", object, |d, ignored| {
            if !ignored {
                let s = if scope == Scope::Input {
                    &mut d.input
                } else {
                    &mut d.output
                };
                s.muted = Some(muted);
            }
        })
    }

    fn sample_rate(&self, object: ObjectId) -> Result<f64, HalError> {
        self.with_device("sample_rate", object, |d, _| d.sample_rate.unwrap_or(0.0))
    }

    fn set_sample_rate(&self, object: ObjectId, hz: f64) -> Result<(), HalError> {
        self.with_device("set_sample_rate", object, |d, ignored| {
            if !ignored {
                d.sample_rate = Some(hz);
                for s in [&mut d.input, &mut d.output] {
                    if let Some(f) = &mut s.format {
                        f.rate = hz;
                    }
                }
            }
        })
    }

    fn format(&self, object: ObjectId, scope: Scope) -> Result<Option<StreamFormat>, HalError> {
        self.with_device("format", object, |d, _| d.scope(scope).format)
    }

    fn set_format(
        &self,
        object: ObjectId,
        scope: Scope,
        format: StreamFormat,
    ) -> Result<(), HalError> {
        self.with_device("set_format", object, |d, ignored| {
            if !ignored {
                d.sample_rate = Some(format.rate);
                let s = if scope == Scope::Input {
                    &mut d.input
                } else {
                    &mut d.output
                };
                s.format = Some(format);
            }
        })
    }

    fn create_aggregate(&self, spec: &AggregateSpec) -> Result<ObjectId, HalError> {
        let mut s = self.enter("create_aggregate")?;
        s.next_object += 1;
        let object = ObjectId(s.next_object);
        let mut members = spec.member_uids.clone();
        if s.partial_aggregates {
            members.truncate(1);
        }
        let mut dev = output_device(&spec.uid);
        dev.object = object;
        dev.name = spec.name.clone();
        dev.kind = DeviceKind::Aggregate;
        dev.transport = "aggregate".into();
        dev.members = members;
        s.devices.push(dev);
        self.epoch.fetch_add(1, Ordering::SeqCst);
        Ok(object)
    }

    fn aggregate_members(&self, object: ObjectId) -> Result<Vec<String>, HalError> {
        self.with_device("aggregate_members", object, |d, _| d.members.clone())
    }

    fn destroy_aggregate(&self, object: ObjectId) -> Result<(), HalError> {
        let mut s = self.enter("destroy_aggregate")?;
        if !s
            .devices
            .iter()
            .any(|d| d.object == object && d.kind == DeviceKind::Aggregate)
        {
            return Err(status(
                "destroy_aggregate",
                HalErrorKind::NoSuchObject,
                "no such aggregate",
            ));
        }
        if !s.ignored.contains("destroy_aggregate") {
            s.devices.retain(|d| d.object != object);
        }
        self.epoch.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }

    fn change_epoch(&self) -> u64 {
        self.epoch.load(Ordering::SeqCst)
    }
}

// ------------------------------------------------------------------- taps

#[derive(Default)]
struct TapInner {
    log: Vec<String>,
    failures: Vec<(String, u32)>,
    counts: HashMap<String, u32>,
    next: u32,
    next_aggregate: u32,
    taps: BTreeSet<u32>,
    aggregates: BTreeSet<u32>,
    ioprocs: BTreeSet<usize>,
    started: BTreeSet<usize>,
    processes: Vec<AudioProcess>,
    unsupported: bool,
}

/// Fake of the process-tap HAL. Tracks every live object, so a test can assert
/// that nothing is left behind (a leftover tap means a silenced app).
#[derive(Default)]
pub struct FakeTapHal {
    inner: Mutex<TapInner>,
}

impl FakeTapHal {
    pub fn new() -> Self {
        Self::default()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, TapInner> {
        self.inner.lock().unwrap()
    }

    pub fn set_processes(&self, processes: Vec<AudioProcess>) {
        self.lock().processes = processes;
    }

    pub fn set_unsupported(&self) {
        self.lock().unsupported = true;
    }

    /// The `nth` (1-based, counted over the whole life of the fake) call of `op` fails.
    pub fn fail(&self, op: &str, nth: u32) {
        self.lock().failures.push((op.to_owned(), nth));
    }

    pub fn log(&self) -> Vec<String> {
        self.lock().log.clone()
    }

    pub fn clear_log(&self) {
        self.lock().log.clear();
    }

    /// Everything still alive: taps, aggregates, IOProcs. Empty means clean.
    pub fn live(&self) -> Vec<String> {
        let s = self.lock();
        let mut v: Vec<String> = s.taps.iter().map(|t| format!("tap {t}")).collect();
        v.extend(s.aggregates.iter().map(|a| format!("aggregate {a}")));
        v.extend(s.ioprocs.iter().map(|i| format!("ioproc {i}")));
        v
    }

    pub fn live_taps(&self) -> usize {
        self.lock().taps.len()
    }

    fn call(
        &self,
        op: &str,
        detail: String,
    ) -> Result<std::sync::MutexGuard<'_, TapInner>, HalError> {
        let mut s = self.lock();
        let n = {
            let c = s.counts.entry(op.to_owned()).or_insert(0);
            *c += 1;
            *c
        };
        s.log.push(format!("{op}({detail})"));
        if s.failures.contains(&(op.to_owned(), n)) {
            return Err(HalError::new(
                HalErrorKind::Other,
                op,
                &format!("call #{n} failed"),
            ));
        }
        Ok(s)
    }
}

pub fn process(pid: i32, object: u32) -> AudioProcess {
    AudioProcess {
        object,
        pid,
        bundle_id: Some(format!("test.app.p{pid}")),
        running_output: true,
    }
}

impl TapHal for FakeTapHal {
    fn supported(&self) -> bool {
        !self.lock().unsupported
    }

    fn processes(&self) -> Result<Vec<AudioProcess>, HalError> {
        Ok(self.call("processes", String::new())?.processes.clone())
    }

    fn create_tap(&self, process_object: u32) -> Result<Tap, HalError> {
        let mut s = self.call("create_tap", process_object.to_string())?;
        s.next += 1;
        let id = 1000 + s.next;
        s.taps.insert(id);
        Ok(Tap {
            id,
            uid: format!("tap-uid-{id}"),
        })
    }

    fn create_aggregate(&self, output_uid: &str, tap_uid: &str) -> Result<u32, HalError> {
        let mut s = self.call("create_aggregate", format!("{output_uid},{tap_uid}"))?;
        s.next_aggregate += 1;
        let id = 2000 + s.next_aggregate;
        s.aggregates.insert(id);
        Ok(id)
    }

    fn create_ioproc(
        &self,
        aggregate: u32,
        _shared: std::sync::Arc<Shared>,
    ) -> Result<IoHandle, HalError> {
        let mut s = self.call("create_ioproc", aggregate.to_string())?;
        let io = aggregate as usize + 5000;
        s.ioprocs.insert(io);
        Ok(io)
    }

    fn start(&self, aggregate: u32, io: IoHandle) -> Result<(), HalError> {
        self.call("start", aggregate.to_string())?
            .started
            .insert(io);
        Ok(())
    }

    fn stop(&self, aggregate: u32, io: IoHandle) -> Result<(), HalError> {
        self.call("stop", aggregate.to_string())?
            .started
            .remove(&io);
        Ok(())
    }

    fn destroy_ioproc(&self, aggregate: u32, io: IoHandle) -> Result<(), HalError> {
        self.call("destroy_ioproc", aggregate.to_string())?
            .ioprocs
            .remove(&io);
        Ok(())
    }

    fn destroy_aggregate(&self, aggregate: u32) -> Result<(), HalError> {
        self.call("destroy_aggregate", aggregate.to_string())?
            .aggregates
            .remove(&aggregate);
        Ok(())
    }

    fn destroy_tap(&self, tap: u32) -> Result<(), HalError> {
        self.call("destroy_tap", tap.to_string())?.taps.remove(&tap);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use serde_json::{Value, json};
    use symcockpit_contract::{Error, Outcome};
    use symcockpit_core::audio::cli::{self, Command, Context};
    use symcockpit_core::audio::commands as c;
    use symcockpit_core::audio::mixer::{
        AppMixer, AppSetting, Mixer, MixerControl, Shared, State, run_loop,
    };
    use symcockpit_core::audio::{AudioService, BoundAudioPlan, PlannedAction, Readback};

    use super::*;

    fn world(devices: Vec<RawDevice>) -> (Arc<FakeAudioHal>, AudioService) {
        let hal = Arc::new(FakeAudioHal::new(devices));
        let svc = AudioService::new(hal.clone()).with_readback(Readback {
            attempts: 3,
            delay: Duration::ZERO,
        });
        (hal, svc)
    }

    fn two() -> (Arc<FakeAudioHal>, AudioService) {
        let (hal, svc) = world(vec![output_device("a"), output_device("b")]);
        hal.set_defaults(None, Some("a"));
        (hal, svc)
    }

    fn count(hal: &FakeAudioHal, op: &str) -> usize {
        hal.log().iter().filter(|l| *l == op).count()
    }

    fn exit_of(r: Result<Value, Error>) -> u8 {
        match r {
            Ok(v) => c::exit_code_of(&v),
            Err(e) => e.exit_code(),
        }
    }

    // ------------------------------------------------------------- R40 identity

    #[test]
    fn vanished_device_is_offline_and_a_returning_one_gets_a_new_object_id() {
        let (hal, svc) = two();
        let v = c::devices_json(&svc).unwrap();
        let first = v["devices"][0]["object_id"].as_u64().unwrap();
        svc.refresh().unwrap();
        let old = svc.registry().handle("a").unwrap();

        hal.unplug("a");
        let v = c::devices_json(&svc).unwrap();
        let a = v["devices"]
            .as_array()
            .unwrap()
            .iter()
            .find(|d| d["uid"] == "a")
            .unwrap();
        assert_eq!(a["online"], false);
        assert_eq!(a["object_id"], Value::Null);
        assert_eq!(v["default_output_uid"], Value::Null);
        assert!(svc.registry().validate(&old).is_err());
        assert!(
            matches!(c::volume_get_json(&svc, "a"), Err(Error::Failed(m)) if m.contains("offline"))
        );

        hal.plug(output_device("a"));
        let v = c::devices_json(&svc).unwrap();
        let a = v["devices"]
            .as_array()
            .unwrap()
            .iter()
            .find(|d| d["uid"] == "a")
            .unwrap();
        assert_eq!(a["online"], true);
        assert_eq!(a["epoch"], 2);
        assert!(
            a["object_id"].as_u64().unwrap() > first,
            "an old object id was reused"
        );
        assert!(svc.registry().validate(&old).is_err());
    }

    #[test]
    fn device_vanishing_during_a_write_is_failed_and_shows_offline() {
        let (hal, svc) = two();
        hal.vanish_before("set_volume", "b");
        let r = svc.set_volume("b", None, 0.9).unwrap();
        assert_eq!(r.outcome, Outcome::Failed);
        assert!(r.detail.as_deref().unwrap().contains("disappeared"));
        assert_eq!(r.before, r.after);
        assert_eq!(r.exit_code(), 1);
        let v = c::devices_json(&svc).unwrap();
        let b = v["devices"]
            .as_array()
            .unwrap()
            .iter()
            .find(|d| d["uid"] == "b")
            .unwrap();
        assert_eq!(b["online"], false);
    }

    #[test]
    fn registry_lists_changes_for_the_epoch_consumer() {
        let (hal, svc) = two();
        let before = hal.change_epoch();
        hal.unplug("b");
        assert_ne!(hal.change_epoch(), before);
        svc.refresh().unwrap();
        let changes = svc.refresh().unwrap();
        assert_eq!(changes, Default::default());
    }

    // --------------------------------------------------------- R41 set + readback

    #[test]
    fn volume_is_confirmed_by_readback() {
        let (hal, svc) = two();
        let r = svc.set_volume("a", None, 0.8).unwrap();
        assert_eq!(r.outcome, Outcome::Confirmed);
        assert_eq!(r.before, json!(0.5));
        assert_eq!(r.after, json!(0.8f32));
        assert_eq!(hal.device("a").unwrap().output.volume, Some(0.8));
    }

    #[test]
    fn volume_readback_that_differs_is_unconfirmed_and_keeps_the_previous_state_visible() {
        let (hal, svc) = two();
        hal.ignore_writes("set_volume");
        let r = svc.set_volume("a", None, 0.8).unwrap();
        assert_eq!(r.outcome, Outcome::Unconfirmed);
        assert_eq!(r.before, json!(0.5));
        assert_eq!(r.after, json!(0.5));
        assert!(r.error.is_none());
        let json = r.into_json().unwrap();
        assert_eq!(json["outcome"], "unconfirmed");
        assert_eq!(c::exit_code_of(&json), 1);
        assert_eq!(
            count(&hal, "volume"),
            3,
            "the readback polls up to the configured attempts"
        );
    }

    #[test]
    fn a_failing_status_is_failed_never_success() {
        for (kind, code) in [
            (HalErrorKind::Other, 1),
            (HalErrorKind::Permission, 3),
            (HalErrorKind::NotSupported, 4),
        ] {
            let (hal, svc) = two();
            hal.fail("set_volume", 0, kind);
            let r = svc.set_volume("a", None, 0.8).unwrap();
            assert_ne!(r.outcome, Outcome::Confirmed);
            assert_eq!(r.before, r.after);
            assert_eq!(r.exit_code(), code);
            assert_eq!(r.into_json().unwrap_err().exit_code(), code);
        }
    }

    #[test]
    fn volume_preconditions() {
        let (_, svc) = two();
        assert_eq!(exit_of(c::volume_set_json(&svc, "a", None, 1.5)), 2);
        assert_eq!(exit_of(c::volume_set_json(&svc, "a", None, f32::NAN)), 2);
        assert_eq!(exit_of(c::volume_set_json(&svc, "missing", None, 0.5)), 2);
        let mut fixed = output_device("fixed");
        fixed.output.volume_settable = false;
        let (hal, svc) = world(vec![fixed, input_device("mic")]);
        assert_eq!(exit_of(c::volume_set_json(&svc, "fixed", None, 0.5)), 4);
        assert_eq!(
            exit_of(c::mute_json(&svc, "mic", Some(Scope::Output), true)),
            4
        );
        assert_eq!(
            count(&hal, "set_volume") + count(&hal, "set_mute"),
            0,
            "no write after a failed precondition"
        );
    }

    #[test]
    fn mute_confirmed_and_unconfirmed() {
        let (hal, svc) = two();
        assert_eq!(
            svc.set_mute("a", None, true).unwrap().outcome,
            Outcome::Confirmed
        );
        assert_eq!(hal.device("a").unwrap().output.muted, Some(true));
        hal.ignore_writes("set_mute");
        let r = svc.set_mute("a", None, false).unwrap();
        assert_eq!(r.outcome, Outcome::Unconfirmed);
        assert_eq!(r.after, json!(true));
    }

    #[test]
    fn default_device_confirmed_unconfirmed_and_unsupported() {
        let (hal, svc) = two();
        let r = svc.set_default(Scope::Output, "b").unwrap();
        assert_eq!(
            (r.outcome, r.before.clone(), r.after.clone()),
            (Outcome::Confirmed, json!("a"), json!("b"))
        );
        assert_eq!(c::default_get_json(&svc).unwrap()["output"], "b");

        hal.ignore_writes("set_default_device");
        let r = svc.set_default(Scope::Output, "a").unwrap();
        assert_eq!((r.outcome, r.after), (Outcome::Unconfirmed, json!("b")));

        assert_eq!(exit_of(c::default_set_json(&svc, Scope::Input, "a")), 4);
    }

    #[test]
    fn rate_is_confirmed() {
        let (hal, svc) = two();
        let plan = svc.plan_format("a", 48000.0, None).unwrap();
        let r = svc.execute(&plan);
        assert_eq!(r.outcome, Outcome::Confirmed);
        assert_eq!(hal.device("a").unwrap().sample_rate, Some(48000.0));
    }

    #[test]
    fn rate_and_bits_are_one_physical_format_write() {
        let (hal, svc) = two();
        let r = c::format_set_json(&svc, "a", 96000.0, Some(24)).unwrap();
        assert_eq!(r["outcome"], "confirmed");
        let d = hal.device("a").unwrap();
        assert_eq!(
            (d.sample_rate, d.output.format.unwrap().bits),
            (Some(96000.0), 24)
        );
        assert_eq!(count(&hal, "set_format"), 1);
        assert_eq!(count(&hal, "set_sample_rate"), 0);
    }

    #[test]
    fn rate_readback_that_differs_is_unconfirmed() {
        let (hal, svc) = two();
        hal.ignore_writes("set_sample_rate");
        let r = c::format_set_json(&svc, "a", 48000.0, None).unwrap();
        assert_eq!(r["outcome"], "unconfirmed");
        assert_eq!(r["before"]["rate"], 44100.0);
        assert_eq!(r["after"]["rate"], 44100.0);
        assert_eq!(c::exit_code_of(&r), 1);
    }

    #[test]
    fn format_set_failure_is_failed_and_changes_nothing() {
        let (hal, svc) = two();
        hal.fail("set_sample_rate", 0, HalErrorKind::Other);
        assert_eq!(exit_of(c::format_set_json(&svc, "a", 48000.0, None)), 1);
        assert_eq!(hal.device("a").unwrap().sample_rate, Some(44100.0));
    }

    #[test]
    fn format_preconditions() {
        let (hal, svc) = two();
        assert_eq!(
            exit_of(c::format_set_json(&svc, "a", 32000.0, None).map(|_| Value::Null)),
            4,
            "rate not offered"
        );
        assert_eq!(
            exit_of(c::format_set_json(&svc, "a", 48000.0, Some(16)).map(|_| Value::Null)),
            4,
            "no such format"
        );
        assert_eq!(
            exit_of(c::format_set_json(&svc, "a", -1.0, None).map(|_| Value::Null)),
            2
        );
        assert_eq!(
            count(&hal, "set_sample_rate") + count(&hal, "set_format"),
            0
        );
    }

    #[test]
    fn already_set_is_confirmed_without_a_write() {
        let (hal, svc) = two();
        let r = c::format_set_json(&svc, "a", 44100.0, Some(16)).unwrap();
        assert_eq!(r["outcome"], "confirmed");
        assert_eq!(r["detail"], "already set");
        assert_eq!(
            count(&hal, "set_format") + count(&hal, "set_sample_rate"),
            0
        );
    }

    #[test]
    fn a_plan_is_skipped_when_the_device_changed_afterwards() {
        let (hal, svc) = two();
        let plan = svc.plan_format("a", 48000.0, None).unwrap();
        let object = svc.registry().handle("a").unwrap().object;
        hal.set_sample_rate(object, 96000.0).unwrap(); // someone else changed it
        let r = svc.execute(&plan);
        assert_eq!(r.outcome, Outcome::SkippedChanged);
        assert_eq!(
            count(&hal, "set_sample_rate"),
            1,
            "only the outside change, none from the plan"
        );
        assert_eq!(c::exit_code_of(&r.to_json()), 1);

        let plan = svc.plan_format("b", 48000.0, None).unwrap();
        hal.unplug("b");
        assert_eq!(svc.execute(&plan).outcome, Outcome::SkippedChanged);
    }

    #[test]
    fn device_loss_between_resolve_and_format_write_is_failed() {
        let (hal, svc) = two();
        let plan = svc.plan_format("a", 48000.0, None).unwrap();
        hal.vanish_before("set_sample_rate", "a");
        let r = svc.execute(&plan);
        assert_eq!(r.outcome, Outcome::Failed);
        assert!(r.detail.unwrap().contains("disappeared"));
    }

    #[test]
    fn plans_are_risky_and_run_through_the_planned_action_trait() {
        let (hal, svc) = two();
        let svc = Arc::new(svc);
        let plan = svc.plan_format("a", 48000.0, None).unwrap();
        let item = plan.item();
        assert_eq!(item["risk"], "risky");
        assert_eq!(item["action"], "audio.format.set");
        let action: Box<dyn PlannedAction> = Box::new(BoundAudioPlan {
            service: svc.clone(),
            plan,
        });
        assert_eq!(action.risk(), symcockpit_contract::Risk::Risky);
        assert_eq!(action.execute().outcome, Outcome::Confirmed);
        assert_eq!(hal.device("a").unwrap().sample_rate, Some(48000.0));
    }

    // ----------------------------------------------------------- R42 aggregates

    fn uids(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn aggregate_is_created_verified_and_deleted() {
        let (hal, svc) = two();
        let r = c::aggregate_create_json(&svc, "Mix", &uids(&["a", "b"]), None, true).unwrap();
        assert_eq!(r["outcome"], "confirmed");
        let uid = r["uid"].as_str().unwrap().to_owned();
        let v = c::devices_json(&svc).unwrap();
        let agg = v["devices"]
            .as_array()
            .unwrap()
            .iter()
            .find(|d| d["uid"] == uid.as_str())
            .unwrap();
        assert_eq!(agg["kind"], "aggregate");
        assert_eq!(agg["members"], json!(["a", "b"]));

        let r = c::aggregate_delete_json(&svc, &uid).unwrap();
        assert_eq!(r["outcome"], "confirmed");
        assert!(hal.device(&uid).is_none());
        assert_eq!(
            exit_of(c::aggregate_delete_json(&svc, "a")),
            4,
            "only aggregates can be deleted"
        );
    }

    #[test]
    fn aggregate_requests_are_validated_before_anything_is_created() {
        let (hal, svc) = world(vec![
            output_device("a"),
            output_device("b"),
            input_device("mic"),
        ]);
        let create = |name: &str, members: &[&str], main: Option<&str>, stacked: bool| {
            exit_of(c::aggregate_create_json(
                &svc,
                name,
                &uids(members),
                main,
                stacked,
            ))
        };
        assert_eq!(create("x", &["a"], None, false), 2);
        assert_eq!(create("x", &["a", "a"], None, false), 2);
        assert_eq!(create("x", &["a", "b"], Some("mic"), false), 2);
        assert_eq!(create("", &["a", "b"], None, false), 2);
        assert_eq!(create("x", &["a", "missing"], None, false), 2);
        assert_eq!(
            create("x", &["a", "mic"], None, true),
            4,
            "multi-output needs output streams"
        );
        assert_eq!(count(&hal, "create_aggregate"), 0);
        let made = c::aggregate_create_json(&svc, "x", &uids(&["a", "b"]), None, false).unwrap();
        let nested = made["uid"].as_str().unwrap().to_owned();
        assert_eq!(
            create("y", &["a", &nested], None, false),
            2,
            "aggregates do not nest"
        );
    }

    #[test]
    fn a_failing_create_leaves_nothing_behind() {
        let (hal, svc) = two();
        hal.fail("create_aggregate", 0, HalErrorKind::Other);
        assert_eq!(
            exit_of(c::aggregate_create_json(
                &svc,
                "x",
                &uids(&["a", "b"]),
                None,
                false
            )),
            1
        );
        assert_eq!(hal.snapshot().unwrap().devices.len(), 2);
    }

    #[test]
    fn a_partially_built_aggregate_is_removed_and_the_error_reported() {
        let (hal, svc) = two();
        hal.partial_aggregates();
        let err = c::aggregate_create_json(&svc, "x", &uids(&["a", "b"]), None, false).unwrap_err();
        assert!(
            matches!(&err, Error::Failed(m) if m.contains("holds 1 of 2") && m.contains("was removed")),
            "{err}"
        );
        assert_eq!(
            hal.snapshot().unwrap().devices.len(),
            2,
            "the partial device is gone"
        );
        assert_eq!(count(&hal, "destroy_aggregate"), 1);
    }

    #[test]
    fn a_failed_cleanup_is_reported_not_hidden() {
        let (hal, svc) = two();
        hal.partial_aggregates();
        hal.fail("destroy_aggregate", 0, HalErrorKind::Other);
        let err = c::aggregate_create_json(&svc, "x", &uids(&["a", "b"]), None, false).unwrap_err();
        assert!(
            matches!(&err, Error::Failed(m) if m.contains("leaked") && m.contains("holds 1 of 2")),
            "{err}"
        );
    }

    #[test]
    fn aggregate_plan_is_skipped_when_a_member_disappeared() {
        let (hal, svc) = two();
        let plan = svc
            .plan_aggregate_create("x", &uids(&["a", "b"]), None, false)
            .unwrap();
        hal.unplug("b");
        assert_eq!(svc.execute(&plan).outcome, Outcome::SkippedChanged);
        assert_eq!(count(&hal, "create_aggregate"), 0);
    }

    #[test]
    fn aggregate_delete_failure_and_slow_destruction() {
        let (hal, svc) = two();
        let uid =
            c::aggregate_create_json(&svc, "x", &uids(&["a", "b"]), None, false).unwrap()["uid"]
                .as_str()
                .unwrap()
                .to_owned();
        hal.fail("destroy_aggregate", 0, HalErrorKind::Other);
        assert_eq!(exit_of(c::aggregate_delete_json(&svc, &uid)), 1);
        assert!(hal.device(&uid).is_some());
        hal.ignore_writes("destroy_aggregate");
        let r = c::aggregate_delete_json(&svc, &uid).unwrap();
        assert_eq!(r["outcome"], "unconfirmed");
        assert_eq!(r["after"]["present"], true);
    }

    // ------------------------------------------------- R44 per-app mixer (S4 port)

    fn tap_world() -> Arc<FakeTapHal> {
        let hal = Arc::new(FakeTapHal::new());
        hal.set_processes(vec![process(10, 500), process(11, 501)]);
        hal
    }

    fn pipeline(hal: &Arc<FakeTapHal>) -> Mixer {
        Mixer::new(hal.clone(), Arc::new(Shared::new(0.5, false)))
    }

    #[test]
    fn pipeline_builds_in_order_and_stops_in_reverse() {
        let hal = tap_world();
        let mut m = pipeline(&hal);
        m.start(7, "A").unwrap();
        assert_eq!(
            hal.log(),
            [
                "create_tap(7)",
                "create_aggregate(A,tap-uid-1001)",
                "create_ioproc(2001)",
                "start(2001)"
            ]
        );
        hal.clear_log();
        assert!(m.stop().is_empty());
        assert_eq!(
            hal.log(),
            [
                "stop(2001)",
                "destroy_ioproc(2001)",
                "destroy_aggregate(2001)",
                "destroy_tap(1001)"
            ]
        );
        assert!(hal.live().is_empty());
        assert!(m.stop().is_empty());
        assert_eq!(hal.log().len(), 4, "a second stop does nothing");
    }

    #[test]
    fn output_change_rebuilds_the_aggregate_and_keeps_the_tap() {
        let hal = tap_world();
        let mut m = pipeline(&hal);
        m.start(7, "A").unwrap();
        assert_eq!(m.on_default_output_changed("A"), Ok(false));
        hal.clear_log();
        assert_eq!(m.on_default_output_changed("B"), Ok(true));
        assert_eq!(
            hal.log(),
            [
                "stop(2001)",
                "destroy_ioproc(2001)",
                "destroy_aggregate(2001)",
                "create_aggregate(B,tap-uid-1001)",
                "create_ioproc(2002)",
                "start(2002)"
            ]
        );
        assert_eq!(m.tap_id(), Some(1001));
    }

    #[test]
    fn every_failure_destroys_the_tap_so_the_sound_returns() {
        for failing in ["create_aggregate", "create_ioproc", "start"] {
            let hal = tap_world();
            hal.fail(failing, 1);
            let mut m = pipeline(&hal);
            assert!(m.start(7, "A").is_err(), "{failing}");
            assert_eq!(*m.state(), State::Failed);
            assert!(hal.live().is_empty(), "{failing} left {:?}", hal.live());
        }
        // a failing rebuild after a device change
        let hal = tap_world();
        let mut m = pipeline(&hal);
        m.start(7, "A").unwrap();
        hal.fail("create_aggregate", 2);
        assert!(m.on_default_output_changed("B").is_err());
        assert!(hal.live().is_empty());
        // and a failing tap creation touches nothing else
        let hal = tap_world();
        hal.fail("create_tap", 1);
        assert!(pipeline(&hal).start(7, "A").is_err());
        assert_eq!(hal.log(), ["create_tap(7)"]);
    }

    #[test]
    fn teardown_continues_after_a_failing_step_and_retries_the_tap() {
        let hal = tap_world();
        hal.fail("stop", 1);
        hal.fail("destroy_tap", 1);
        let mut m = pipeline(&hal);
        m.start(7, "A").unwrap();
        hal.clear_log();
        let errs = m.stop();
        assert_eq!(errs.len(), 2);
        assert_eq!(hal.log().last().unwrap(), "destroy_tap(1001)");
        assert_eq!(hal.live_taps(), 1);
        assert!(m.stop().is_empty(), "the next stop retries what failed");
        assert!(hal.live().is_empty());
    }

    #[test]
    fn dropping_a_pipeline_destroys_everything() {
        let hal = tap_world();
        let mut m = pipeline(&hal);
        m.start(7, "A").unwrap();
        drop(m);
        assert!(hal.live().is_empty());
    }

    fn app(volume: f32, muted: bool) -> AppSetting {
        AppSetting { volume, muted }
    }

    #[test]
    fn app_volume_tap_lifecycle_never_leaves_an_app_silent() {
        let hal = tap_world();
        let mut am = AppMixer::new(hal.clone());
        am.on_default_output(Some("A"));
        assert_eq!(am.set_app(10, app(0.5, false)).unwrap().state, "active");
        assert_eq!(hal.live_taps(), 1);
        // identity settings need no tap
        assert_eq!(
            am.set_app(10, app(1.0, false)).unwrap().state,
            "passthrough"
        );
        assert!(hal.live().is_empty());
        // mute is a tap at gain 0
        assert_eq!(am.set_app(10, app(1.0, true)).unwrap().state, "active");
        // the output disappears: everything is released, the wish is kept
        am.on_default_output(None);
        assert!(hal.live().is_empty());
        assert_eq!(am.status()[0].state, "pending");
        // an output is back: the wish is applied again
        am.on_default_output(Some("B"));
        assert_eq!(am.status()[0].state, "active");
        assert_eq!(hal.live_taps(), 1);
        drop(am);
        assert!(hal.live().is_empty());
    }

    #[test]
    fn a_failing_rebuild_releases_the_app_and_reports_it() {
        let hal = tap_world();
        let mut am = AppMixer::new(hal.clone());
        am.on_default_output(Some("A"));
        am.set_app(10, app(0.5, false)).unwrap();
        am.set_app(11, app(0.0, false)).unwrap();
        hal.fail("create_aggregate", 3); // the rebuild of the first app
        let errors = am.on_default_output(Some("B"));
        assert_eq!(errors.len(), 1);
        let status = am.status();
        assert_eq!(status[0].state, "failed");
        assert_eq!(status[1].state, "active");
        assert_eq!(hal.live_taps(), 1, "only the healthy app keeps a tap");
    }

    #[test]
    fn a_pending_app_attaches_when_it_starts_playing_and_a_gone_app_is_released() {
        let hal = Arc::new(FakeTapHal::new());
        let mut am = AppMixer::new(hal.clone());
        am.on_default_output(Some("A"));
        assert_eq!(am.set_app(10, app(0.5, false)).unwrap().state, "pending");
        hal.set_processes(vec![process(10, 500)]);
        am.reconcile().unwrap();
        assert_eq!(am.status()[0].state, "active");
        hal.set_processes(vec![]);
        am.reconcile().unwrap();
        assert!(hal.live().is_empty());
    }

    #[test]
    fn mixer_refuses_without_process_taps_and_bad_volumes() {
        let hal = tap_world();
        let mut am = AppMixer::new(hal.clone());
        assert!(matches!(
            am.set_app(10, app(1.5, false)),
            Err(Error::Usage(_))
        ));
        assert!(matches!(
            am.set_app(10, app(f32::NAN, false)),
            Err(Error::Usage(_))
        ));
        hal.set_unsupported();
        assert_eq!(am.set_app(10, app(0.5, false)).unwrap_err().exit_code(), 4);
    }

    fn loop_world() -> (Arc<FakeAudioHal>, Arc<FakeTapHal>, Mutex<AppMixer>) {
        let audio = Arc::new(FakeAudioHal::new(vec![
            output_device("a"),
            output_device("b"),
        ]));
        audio.set_defaults(None, Some("a"));
        let taps = tap_world();
        (audio, taps.clone(), Mutex::new(AppMixer::new(taps)))
    }

    #[test]
    fn run_loop_follows_the_default_output_and_releases_on_stop() {
        let (audio, taps, mixer) = loop_world();
        mixer.set_app_volume(10, 0.5, false).unwrap();
        let ticks = Cell::new(0u32);
        let stop = || ticks.get() >= 20;
        let sleep = |_: Duration| {
            ticks.set(ticks.get() + 1);
            if ticks.get() == 3 {
                audio.set_defaults(None, Some("b"));
                audio.bump_epoch();
            }
        };
        let summary = run_loop(&mixer, audio.as_ref(), &stop, &sleep);
        assert_eq!(summary.output_changes, 1);
        assert!(
            taps.log()
                .iter()
                .any(|l| l.starts_with("create_aggregate(") && l.contains(",tap-uid")),
            "{:?}",
            taps.log()
        );
        assert!(
            taps.log().iter().any(|l| l.contains("create_aggregate(b,")),
            "rebuilt on the new output"
        );
        assert!(summary.teardown_errors.is_empty());
        assert!(taps.live().is_empty(), "SIGINT-style stop leaves nothing");
    }

    #[test]
    fn run_loop_releases_every_app_when_the_output_vanishes() {
        let (audio, taps, mixer) = loop_world();
        mixer.set_app_volume(10, 0.5, false).unwrap();
        // the mixer is driven by run_loop; the first iteration installs the output
        let ticks = Cell::new(0u32);
        let silent_while_gone = Cell::new(false);
        let stop = || ticks.get() >= 20;
        let sleep = |_: Duration| {
            ticks.set(ticks.get() + 1);
            if ticks.get() == 3 {
                audio.unplug("a");
            }
            if ticks.get() == 15 {
                silent_while_gone.set(taps.live_taps() == 0);
            }
        };
        let summary = run_loop(&mixer, audio.as_ref(), &stop, &sleep);
        assert!(
            silent_while_gone.get(),
            "no tap may stay while there is no output"
        );
        assert!(
            summary
                .events
                .iter()
                .any(|e| e.contains("all apps released"))
        );
        assert!(taps.live().is_empty());
    }

    #[test]
    fn run_loop_stopped_at_once_still_cleans_up() {
        let (audio, taps, mixer) = loop_world();
        mixer.set_app_volume(10, 0.5, false).unwrap();
        let summary = run_loop(&mixer, audio.as_ref(), &|| true, &|_| {});
        assert_eq!(summary.output_changes, 0);
        assert!(taps.live().is_empty());
    }

    // ---------------------------------------------------------------- the CLI

    fn context<'a>(
        svc: &'a AudioService,
        midi: &'a symcockpit_core::midi::MidiService,
        taps: Option<Arc<FakeTapHal>>,
        mixer: Option<&'a dyn MixerControl>,
    ) -> Context<'a> {
        Context {
            audio: svc,
            midi,
            tap: taps.map(|t| t as Arc<dyn TapHal>),
            mixer,
            stop: &|| true,
        }
    }

    fn words(s: &str) -> Vec<String> {
        s.split_whitespace().map(str::to_owned).collect()
    }

    #[test]
    fn cli_devices_renders_text_and_json() {
        let (_, svc) = two();
        let midi =
            symcockpit_core::midi::MidiService::new(Arc::new(crate::midi::FakeMidiHal::default()));
        let ctx = context(&svc, &midi, None, None);
        let cmd = cli::parse_audio(&words("devices")).unwrap();
        let v = cli::run(&cmd, &ctx).unwrap();
        let text = cli::render(&cmd, &v);
        assert!(
            text.contains("online") && text.lines().count() == 2,
            "{text}"
        );
        let cmd = cli::parse_audio(&words("devices --json")).unwrap();
        assert!(cli::render(&cmd, &v).trim_start().starts_with('{'));
    }

    #[test]
    fn cli_mixer_commands_need_taps_and_a_running_mixer() {
        let (_, svc) = two();
        let midi =
            symcockpit_core::midi::MidiService::new(Arc::new(crate::midi::FakeMidiHal::default()));
        let none = context(&svc, &midi, None, None);
        assert_eq!(
            cli::run(&Command::MixerStatus, &none)
                .unwrap_err()
                .exit_code(),
            4
        );
        let taps = tap_world();
        let ctx = context(&svc, &midi, Some(taps.clone()), None);
        let set = cli::parse_audio(&words("mixer set 10 0.5")).unwrap();
        assert_eq!(
            cli::run(&set, &ctx).unwrap_err().exit_code(),
            4,
            "no mixer in this process"
        );
        let mixer = Mutex::new(AppMixer::new(taps.clone()));
        let ctx = context(&svc, &midi, Some(taps.clone()), Some(&mixer));
        let v = cli::run(&set, &ctx).unwrap();
        assert_eq!(v["apps"][0]["pid"], 10);
        let unknown = cli::parse_audio(&words("mixer set 999 0.5")).unwrap();
        assert_eq!(cli::run(&unknown, &ctx).unwrap_err().exit_code(), 1);
    }

    #[test]
    fn cli_mixer_run_holds_until_stopped_and_cleans_up() {
        let (audio, svc) = two();
        let _ = audio;
        let midi =
            symcockpit_core::midi::MidiService::new(Arc::new(crate::midi::FakeMidiHal::default()));
        let taps = tap_world();
        let ctx = context(&svc, &midi, Some(taps.clone()), None);
        let run =
            cli::parse_audio(&words("mixer run --app 10=0.5 --app test.app.p11=mute")).unwrap();
        let v = cli::run(&run, &ctx).unwrap();
        assert_eq!(v["stopped"], true);
        assert!(taps.live().is_empty());
        assert!(
            taps.log()
                .iter()
                .filter(|l| l.starts_with("create_tap"))
                .count()
                == 2
        );
    }

    // -------------------------------------------------------------- snapshots

    fn snapshot_values() -> Vec<(&'static str, Value)> {
        let hal = Arc::new(FakeAudioHal::new(vec![
            output_device("out"),
            output_device("out2"),
            input_device("mic"),
        ]));
        hal.set_defaults(Some("mic"), Some("out"));
        let svc = AudioService::new(hal.clone()).with_readback(Readback {
            attempts: 2,
            delay: Duration::ZERO,
        });
        let taps = tap_world();
        let mixer = Mutex::new(AppMixer::new(taps.clone()));
        let midi = symcockpit_core::midi::MidiService::new(Arc::new(crate::midi::sample_hal()));
        let created =
            c::aggregate_create_json(&svc, "Mix", &uids(&["out", "out2"]), None, true).unwrap();
        let agg = created["uid"].as_str().unwrap().to_owned();
        let ctx = Context {
            audio: &svc,
            midi: &midi,
            tap: Some(taps.clone()),
            mixer: None,
            stop: &|| true,
        };
        let run = Command::MixerRun {
            apps: vec![("10".into(), app(0.5, false))],
        };
        vec![
            ("audio.devices", c::devices_json(&svc).unwrap()),
            ("audio.device", c::device_json(&svc, "out").unwrap()),
            ("audio.default.get", c::default_get_json(&svc).unwrap()),
            ("audio.volume.get", c::volume_get_json(&svc, "out").unwrap()),
            ("audio.format.get", c::format_get_json(&svc, "out").unwrap()),
            (
                "audio.mixer.status",
                c::mixer_status_json(taps.as_ref(), Some(&mixer)).unwrap(),
            ),
            ("midi.devices", midi.devices_json().unwrap()),
            (
                "audio.default.set",
                c::default_set_json(&svc, Scope::Output, "out2").unwrap(),
            ),
            (
                "audio.volume.set",
                c::volume_set_json(&svc, "out", None, 0.25).unwrap(),
            ),
            (
                "audio.mute.set",
                c::mute_json(&svc, "out", None, true).unwrap(),
            ),
            (
                "audio.app-volume.set",
                c::app_volume_set_json(&mixer, taps.as_ref(), "10", 0.5, false).unwrap(),
            ),
            ("audio.mixer.run", cli::run(&run, &ctx).unwrap()),
            (
                "audio.format.set",
                c::format_set_json(&svc, "out", 48000.0, Some(24)).unwrap(),
            ),
            ("audio.aggregate.create", created),
            (
                "audio.aggregate.delete",
                c::aggregate_delete_json(&svc, &agg).unwrap(),
            ),
        ]
    }

    fn snapshot_dir() -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../snapshots/audio")
    }

    #[test]
    fn every_command_output_matches_its_shape_snapshot() {
        let update = std::env::var_os("SYMCOCKPIT_UPDATE_SNAPSHOTS").is_some();
        let dir = snapshot_dir();
        let mut ids = Vec::new();
        for (id, value) in snapshot_values() {
            ids.push(id);
            let actual = symcockpit_oracle::shape::derive(&value).unwrap();
            let file = dir.join(format!("{id}.shape.json"));
            if update {
                std::fs::create_dir_all(&dir).unwrap();
                std::fs::write(&file, serde_json::to_string_pretty(&actual).unwrap() + "\n")
                    .unwrap();
            }
            let expected: Value = serde_json::from_str(
                &std::fs::read_to_string(&file)
                    .unwrap_or_else(|e| panic!("{}: {e}", file.display())),
            )
            .unwrap();
            let diff = symcockpit_oracle::shape::compare(&expected, &actual);
            assert!(diff.errors.is_empty(), "{id}: {:?}", diff.errors);
        }
        // every audio/midi command has a snapshot and no snapshot is orphaned
        let mut specs: Vec<&str> = symcockpit_contract::areas::audio::specs()
            .iter()
            .map(|s| s.name)
            .collect();
        specs.sort_unstable();
        ids.sort_unstable();
        assert_eq!(ids, specs);
        let mut files: Vec<String> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| {
                e.unwrap()
                    .file_name()
                    .to_string_lossy()
                    .trim_end_matches(".shape.json")
                    .to_owned()
            })
            .collect();
        files.sort();
        assert_eq!(files, specs);
    }

    #[test]
    fn snapshots_hold_no_values_that_could_identify_a_machine() {
        let dir = snapshot_dir();
        for e in std::fs::read_dir(dir).unwrap() {
            let text = std::fs::read_to_string(e.unwrap().path()).unwrap();
            // shapes contain keys and type names only
            assert!(!text.contains("Fake"), "values leaked into a shape");
        }
    }
}
