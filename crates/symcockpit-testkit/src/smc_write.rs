//! Fakes for the write side: an SMC with a key table that accepts writes
//! (nothing touches hardware), a fake PowerUI charge limit, a fake clock and a
//! helper-ports bundle. Plausible numbers, not captures.

use std::collections::{BTreeSet, HashMap};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use symcockpit_core::battery::{BatterySource, BatterySourceResult};
use symcockpit_core::charge_limit::MacChargeLimit;
use symcockpit_core::clock::Monotonic;
use symcockpit_core::helper_engine::HelperPorts;
use symcockpit_core::sensors::{FourCc, RawKey, SensorHost, SmcPort};
use symcockpit_core::smc_write::SmcWriter;
use symcockpit_store::Config;

use crate::battery::{FakeBatterySource, sample_battery};
use crate::smc::{FakeHost, FakeSmc};

/// One accepted write.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Write {
    pub key: String,
    pub data_type: FourCc,
    pub bytes: Vec<u8>,
}

struct Inner {
    smc: FakeSmc,
    writes: Vec<Write>,
    /// Keys the firmware refuses to write (as an unprivileged caller would see).
    reject: BTreeSet<String>,
    /// Keys the firmware accepts but does not keep (it takes control back).
    forget: BTreeSet<String>,
}

/// In-memory SMC that accepts writes. Writing an absent key, or with another
/// type than the key has, is refused like the real one refuses it.
#[derive(Clone)]
pub struct FakeSmcRw(Arc<Mutex<Inner>>);

impl FakeSmcRw {
    pub fn new(smc: FakeSmc) -> Self {
        Self(Arc::new(Mutex::new(Inner {
            smc,
            writes: Vec::new(),
            reject: BTreeSet::new(),
            forget: BTreeSet::new(),
        })))
    }

    /// An M4 Pro-like Mac with the fan write keys (`Ftst`); no charge-limit key.
    pub fn m4_pro_like() -> Self {
        Self::new(FakeSmc::m4_pro_like().with_ui8("Ftst", 0))
    }

    /// The same Mac with the modern charge-limit key.
    pub fn with_chte(self, inhibit: bool) -> Self {
        self.set_raw("CHTE", b"ui32", &u32::from(inhibit).to_be_bytes());
        self
    }

    pub fn with_ch0b(self, value: u8) -> Self {
        self.set_raw("CH0B", b"ui8 ", &[value]);
        self.set_raw("CH0C", b"ui8 ", &[value]);
        self
    }

    pub fn reject_writes_to(&self, key: &str) {
        self.0.lock().unwrap().reject.insert(key.into());
    }

    pub fn forget_writes_to(&self, key: &str) {
        self.0.lock().unwrap().forget.insert(key.into());
    }

    /// The firmware changing a value by itself (sleep, thermal management).
    pub fn set_raw(&self, key: &str, data_type: &FourCc, bytes: &[u8]) {
        let mut g = self.0.lock().unwrap();
        g.smc.keys.insert(
            key.into(),
            RawKey {
                data_type: *data_type,
                bytes: bytes.to_vec(),
            },
        );
    }

    pub fn set_flt(&self, key: &str, value: f32) {
        self.set_raw(key, b"flt ", &value.to_le_bytes());
    }

    pub fn set_ui8(&self, key: &str, value: u8) {
        self.set_raw(key, b"ui8 ", &[value]);
    }

    pub fn get(&self, key: &str) -> Option<RawKey> {
        self.0.lock().unwrap().smc.keys.get(key).cloned()
    }

    pub fn get_ui8(&self, key: &str) -> Option<u8> {
        self.get(key).and_then(|r| r.bytes.first().copied())
    }

    pub fn get_flt(&self, key: &str) -> Option<f32> {
        self.get(key)
            .and_then(|r| <[u8; 4]>::try_from(r.bytes.as_slice()).ok())
            .map(f32::from_le_bytes)
    }

    pub fn writes(&self) -> Vec<Write> {
        self.0.lock().unwrap().writes.clone()
    }

    /// Every key written so far, in order (duplicates kept).
    pub fn written_keys(&self) -> Vec<String> {
        self.writes().into_iter().map(|w| w.key).collect()
    }

    pub fn clear_writes(&self) {
        self.0.lock().unwrap().writes.clear();
    }
}

impl SmcPort for FakeSmcRw {
    fn is_open(&self) -> bool {
        self.0.lock().unwrap().smc.is_open()
    }

    fn read_key_raw(&self, key: &str) -> Option<RawKey> {
        self.0.lock().unwrap().smc.read_key_raw(key)
    }

    fn enumerate_keys(&self) -> Option<Vec<String>> {
        self.0.lock().unwrap().smc.enumerate_keys()
    }
}

impl SmcWriter for FakeSmcRw {
    fn write_key_raw(&self, key: &str, data_type: &FourCc, bytes: &[u8]) -> bool {
        let mut g = self.0.lock().unwrap();
        if !g.smc.is_open() || g.reject.contains(key) {
            return false;
        }
        let Some(existing) = g.smc.keys.get(key) else {
            return false;
        };
        if existing.data_type != *data_type || existing.bytes.len() != bytes.len() {
            return false;
        }
        g.writes.push(Write {
            key: key.into(),
            data_type: *data_type,
            bytes: bytes.to_vec(),
        });
        if !g.forget.contains(key) {
            g.smc.keys.get_mut(key).unwrap().bytes = bytes.to_vec();
        }
        true
    }
}

/// A clock that only moves when told to, or when something sleeps.
#[derive(Clone, Default)]
pub struct FakeClock(Arc<AtomicU64>);

impl FakeClock {
    pub fn advance_ms(&self, ms: u64) {
        self.0.fetch_add(ms, Ordering::SeqCst);
    }
}

impl Monotonic for FakeClock {
    fn now_ms(&self) -> u64 {
        self.0.load(Ordering::SeqCst)
    }

    fn sleep(&self, duration: Duration) {
        self.advance_ms(duration.as_millis() as u64);
    }
}

struct MacState {
    supported: bool,
    enabled: bool,
    limit: u8,
    /// `setMCLLimit:` returns success but the limit does not change.
    ignore_set: bool,
    fail_enable: bool,
    calls: Vec<String>,
}

/// `PowerUISmartChargeClient` as a fake: never calls the private framework.
#[derive(Clone)]
pub struct FakePowerUi(Arc<Mutex<MacState>>);

impl FakePowerUi {
    pub fn new(supported: bool) -> Self {
        Self(Arc::new(Mutex::new(MacState {
            supported,
            enabled: false,
            limit: 100,
            ignore_set: false,
            fail_enable: false,
            calls: Vec::new(),
        })))
    }

    pub fn ignoring_set_limit(self) -> Self {
        self.0.lock().unwrap().ignore_set = true;
        self
    }

    pub fn failing_enable(self) -> Self {
        self.0.lock().unwrap().fail_enable = true;
        self
    }

    pub fn calls(&self) -> Vec<String> {
        self.0.lock().unwrap().calls.clone()
    }

    pub fn state(&self) -> (bool, u8) {
        let g = self.0.lock().unwrap();
        (g.enabled, g.limit)
    }
}

impl MacChargeLimit for FakePowerUi {
    fn is_supported(&self) -> bool {
        self.0.lock().unwrap().supported
    }

    fn is_enabled(&self) -> Option<bool> {
        Some(self.0.lock().unwrap().enabled)
    }

    fn limit(&self) -> Option<u8> {
        Some(self.0.lock().unwrap().limit)
    }

    fn enable(&self) -> Result<(), String> {
        let mut g = self.0.lock().unwrap();
        g.calls.push("enable".into());
        if g.fail_enable {
            return Err("domain=PowerUI code=4".into());
        }
        g.enabled = true;
        Ok(())
    }

    fn disable(&self) -> Result<(), String> {
        let mut g = self.0.lock().unwrap();
        g.calls.push("disable".into());
        g.enabled = false;
        Ok(())
    }

    fn set_limit(&self, percent: u8) -> Result<(), String> {
        let mut g = self.0.lock().unwrap();
        g.calls.push(format!("set_limit {percent}"));
        if !g.ignore_set {
            g.limit = percent;
        }
        Ok(())
    }
}

/// A battery on AC power (or not).
pub fn battery_on_ac(on_ac: bool) -> FakeBatterySource {
    let mut p = sample_battery();
    p.external_connected = Some(on_ac);
    FakeBatterySource(BatterySourceResult::Success(p))
}

/// Everything the helper engine needs, over one fake SMC and one fake clock.
pub struct FakePorts {
    pub smc: FakeSmcRw,
    pub clock: FakeClock,
    pub host: FakeHost,
    pub battery: FakeBatterySource,
    pub config: Config,
    pub legacy_governor: bool,
}

impl FakePorts {
    pub fn new(smc: FakeSmcRw, clock: FakeClock) -> Self {
        Self {
            smc,
            clock,
            host: FakeHost::default(),
            battery: battery_on_ac(true),
            config: Config::default(),
            legacy_governor: false,
        }
    }
}

impl HelperPorts for FakePorts {
    fn smc(&self) -> &dyn SmcPort {
        &self.smc
    }

    fn writer(&self) -> &dyn SmcWriter {
        &self.smc
    }

    fn host(&self) -> &dyn SensorHost {
        &self.host
    }

    fn battery(&self) -> &dyn BatterySource {
        &self.battery
    }

    fn clock(&self) -> &dyn Monotonic {
        &self.clock
    }

    fn config(&self) -> &Config {
        &self.config
    }

    fn legacy_governor_running(&self) -> bool {
        self.legacy_governor
    }
}

/// Counts of keys by name, handy in assertions.
pub fn count_by_key(writes: &[Write]) -> HashMap<String, usize> {
    let mut m = HashMap::new();
    for w in writes {
        *m.entry(w.key.clone()).or_default() += 1;
    }
    m
}
