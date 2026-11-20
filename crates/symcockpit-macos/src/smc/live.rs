//! `SmcPort` over the AppleSMC transport (`HardwareSMCConnection` in Swift).

use std::collections::HashMap;
use std::sync::Mutex;

use symcockpit_core::sensors::{RawKey, SmcPort};

use super::iokit::{Command, IoKit, ParamBlock, Transport};

/// Sanity cap for the `#KEY` count; no shipping Mac exposes more.
const MAX_ENUMERATION_KEYS: usize = 4096;
/// `#KEY` exists on every Mac with an SMC (a fanless Mac may lack `FNum`), so
/// asking for it separates "fanless" from "SMC unreachable".
const PROBE_KEY: [u8; 4] = *b"#KEY";

#[derive(Clone)]
struct KeyInfo {
    size: usize,
    data_type: [u8; 4],
    block: ParamBlock,
}

/// Live, read-only AppleSMC connection. Closed (`is_open() == false`) when the
/// driver is missing, refuses the user client, or answers `kSMCKeyNotFound` to
/// `#KEY` (macOS builds that block unprivileged SMC access, issue #210).
pub struct LiveSmc {
    transport: Option<Box<dyn Transport>>,
    // A key's type and size are fixed by the firmware; a cached `None` records
    // a key this Mac does not implement.
    key_info: Mutex<HashMap<[u8; 4], Option<KeyInfo>>>,
    enumeration: Mutex<Option<Option<Vec<String>>>>,
}

impl LiveSmc {
    /// Connect to `AppleSMC`; a failed connection yields a closed `LiveSmc`.
    pub fn open() -> Self {
        IoKit::connect().map_or_else(Self::closed, |io| Self::with_transport(Box::new(io)))
    }

    fn closed() -> Self {
        Self {
            transport: None,
            key_info: Mutex::default(),
            enumeration: Mutex::default(),
        }
    }

    /// A transport success only proves the driver answered; the firmware's own
    /// verdict (`result == 0` for `#KEY`) decides whether the SMC is usable.
    fn with_transport(transport: Box<dyn Transport>) -> Self {
        let mut probe = ParamBlock::new(Command::ReadKeyInfo);
        probe.set_key(PROBE_KEY);
        let open = transport.call(&probe).is_some_and(|out| out.result() == 0);
        Self {
            transport: open.then_some(transport),
            ..Self::closed()
        }
    }

    fn call(&self, input: &ParamBlock) -> Option<ParamBlock> {
        self.transport.as_ref()?.call(input)
    }

    /// `READ_KEYINFO` for a key, cached. `None` for keys this Mac lacks.
    fn key_info(&self, key: [u8; 4]) -> Option<KeyInfo> {
        if let Some(cached) = self.key_info.lock().unwrap().get(&key) {
            return cached.clone();
        }
        let mut input = ParamBlock::new(Command::ReadKeyInfo);
        input.set_key(key);
        let resolved = self
            .call(&input)
            .filter(|out| out.result() == 0 && (1..=32).contains(&out.key_info_size()))
            .map(|out| KeyInfo {
                size: out.key_info_size() as usize,
                data_type: out.key_info_type(),
                block: out,
            });
        self.key_info.lock().unwrap().insert(key, resolved.clone());
        resolved
    }

    fn enumerate(&self) -> Option<Vec<String>> {
        let count_raw = self.read_key_raw("#KEY").filter(|r| !r.bytes.is_empty())?;
        let count = parse_key_count(&count_raw.bytes);
        let mut keys = Vec::new();
        for index in 0..count.min(MAX_ENUMERATION_KEYS) {
            let mut input = ParamBlock::new(Command::KeyFromIndex);
            input.set_data32(index as u32);
            let out = self.call(&input)?;
            // kSMCKeyNotFound: past the end of the key table.
            if out.result() != 0 {
                break;
            }
            // Firmware without the index selector returns empty or
            // non-printable key codes: that is the end of the table.
            let key = out.key();
            if !key.iter().all(|b| (0x21..=0x7e).contains(b)) {
                break;
            }
            keys.push(String::from_utf8_lossy(&key).into_owned());
        }
        (!keys.is_empty()).then_some(keys)
    }
}

/// `#KEY` payload: a big-endian integer, or (some Intel firmware) four ASCII digits.
fn parse_key_count(bytes: &[u8]) -> usize {
    if bytes.len() == 4 && bytes.iter().all(u8::is_ascii_digit) {
        return std::str::from_utf8(bytes)
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
    }
    bytes
        .iter()
        .fold(0usize, |acc, &b| (acc << 8) | usize::from(b))
}

/// Swift encodes a key that is not exactly four bytes as 0, which never exists.
fn key4(key: &str) -> Option<[u8; 4]> {
    key.as_bytes().try_into().ok()
}

impl SmcPort for LiveSmc {
    fn is_open(&self) -> bool {
        self.transport.is_some()
    }

    fn read_key_raw(&self, key: &str) -> Option<RawKey> {
        self.transport.as_ref()?;
        let key = key4(key)?;
        let info = self.key_info(key)?;
        let mut input = ParamBlock::new(Command::ReadKey);
        input.set_key(key);
        input.copy_key_info(&info.block);
        let out = self.call(&input).filter(|out| out.result() == 0)?;
        Some(RawKey {
            data_type: info.data_type,
            bytes: out.payload(info.size),
        })
    }

    fn enumerate_keys(&self) -> Option<Vec<String>> {
        self.transport.as_ref()?;
        let mut cached = self.enumeration.lock().unwrap();
        if let Some(result) = cached.as_ref() {
            return result.clone();
        }
        // The lock is held across the probe so concurrent callers do not repeat it.
        // `read_key_raw` takes only `key_info`, never `enumeration`: no cycle.
        let result = self.enumerate();
        *cached = Some(result.clone());
        result
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    // Vectors: tuning/Tests/SymCockpitCoreTests/SMCTransportTests.swift and
    // SMCServiceTests.swift (open probe, testHardwareConnectionEnumeratesKeysByIndex).

    const TYPE: [u8; 4] = *b"flt4";
    const PAYLOAD: [u8; 4] = [0x3F, 0x80, 0x00, 0x00];

    /// Scripted transport: keyInfo (9) answers a 4-byte `flt4` block, read (5)
    /// answers `PAYLOAD`; failures can be injected per stage. Counts keyInfo calls.
    #[derive(Default)]
    struct Script {
        fail_key_info: bool,
        fail_read: bool,
        key_info_result: u8,
        read_result: u8,
        key_info_calls: AtomicUsize,
        commands: Mutex<Vec<u8>>,
    }

    impl Transport for Arc<Script> {
        fn call(&self, input: &ParamBlock) -> Option<ParamBlock> {
            let command = input.0[42];
            self.commands.lock().unwrap().push(command);
            let mut out = ParamBlock([0; 80]);
            match command {
                9 => {
                    self.key_info_calls.fetch_add(1, Ordering::SeqCst);
                    if self.fail_key_info {
                        return None;
                    }
                    out.0[40] = self.key_info_result;
                    out.0[28..32].copy_from_slice(&4u32.to_ne_bytes());
                    out.0[32..36].copy_from_slice(&u32::from_be_bytes(TYPE).to_ne_bytes());
                }
                5 => {
                    if self.fail_read {
                        return None;
                    }
                    out.0[40] = self.read_result;
                    out.0[48..52].copy_from_slice(&PAYLOAD);
                }
                _ => return None,
            }
            Some(out)
        }
    }

    /// An open connection over a scripted transport. The open probe uses the
    /// same script, so stage failures are set up on a second script afterwards.
    fn open_with(script: Script) -> (LiveSmc, Arc<Script>) {
        let script = Arc::new(script);
        let mut live = LiveSmc::with_transport(Box::new(Arc::new(Script::default())));
        live.transport = Some(Box::new(script.clone()));
        (live, script)
    }

    #[test]
    fn closed_connection_reads_nothing() {
        let live = LiveSmc::closed();
        assert!(!live.is_open());
        assert_eq!(live.read_key_raw("TEST"), None);
        assert_eq!(live.enumerate_keys(), None);
    }

    #[test]
    fn open_probe_follows_the_firmware_verdict() {
        // testOpenProbeSucceeds / FailsWhenTheSMCRejectsTheKey (#210) / FailsWhenTransportFails
        let open = |s: Script| LiveSmc::with_transport(Box::new(Arc::new(s))).is_open();
        assert!(open(Script::default()));
        assert!(!open(Script {
            key_info_result: 132,
            ..Script::default()
        }));
        assert!(!open(Script {
            fail_key_info: true,
            ..Script::default()
        }));
    }

    #[test]
    fn read_returns_type_and_payload() {
        let (live, _) = open_with(Script::default());
        let raw = live.read_key_raw("TEST").unwrap();
        assert_eq!((raw.data_type, raw.bytes), (TYPE, PAYLOAD.to_vec()));
    }

    #[test]
    fn read_fails_per_stage() {
        for script in [
            Script {
                fail_read: true,
                ..Script::default()
            },
            Script {
                read_result: 1,
                ..Script::default()
            },
            Script {
                fail_key_info: true,
                ..Script::default()
            },
            Script {
                key_info_result: 7,
                ..Script::default()
            },
        ] {
            let (live, _) = open_with(script);
            assert_eq!(live.read_key_raw("TEST"), None);
        }
    }

    #[test]
    fn key_that_is_not_four_bytes_is_absent_without_io() {
        let (live, script) = open_with(Script::default());
        assert_eq!(live.read_key_raw("FS!"), None);
        assert!(script.commands.lock().unwrap().is_empty());
    }

    #[test]
    fn key_info_is_cached_including_absence() {
        let (live, script) = open_with(Script::default());
        for _ in 0..3 {
            live.read_key_raw("TEST");
        }
        assert_eq!(script.key_info_calls.load(Ordering::SeqCst), 1);

        let (live, script) = open_with(Script {
            fail_key_info: true,
            ..Script::default()
        });
        live.read_key_raw("NOPE");
        live.read_key_raw("NOPE");
        assert_eq!(script.key_info_calls.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn only_read_commands_are_sent() {
        let (live, script) = open_with(Script::default());
        live.read_key_raw("TEST");
        live.enumerate_keys();
        let commands = script.commands.lock().unwrap();
        assert!(!commands.is_empty());
        assert!(commands.iter().all(|c| [5, 8, 9].contains(c)));
    }

    /// Transport exposing a fixed key table: `#KEY` as a ui32 count, keys by index.
    struct Table(Vec<&'static str>);

    impl Transport for Table {
        fn call(&self, input: &ParamBlock) -> Option<ParamBlock> {
            let mut out = ParamBlock([0; 80]);
            match input.0[42] {
                8 => {
                    let index = u32::from_ne_bytes(input.0[44..48].try_into().unwrap()) as usize;
                    match self.0.get(index) {
                        Some(key) => out.set_key(key.as_bytes().try_into().unwrap()),
                        None => out.0[40] = 132,
                    }
                }
                code @ (5 | 9) if input.key() == *b"#KEY" => {
                    out.0[28..32].copy_from_slice(&4u32.to_ne_bytes());
                    out.0[32..36].copy_from_slice(&u32::from_be_bytes(*b"ui32").to_ne_bytes());
                    if code == 5 {
                        out.0[48..52].copy_from_slice(&(self.0.len() as u32).to_be_bytes());
                    }
                }
                _ => return None,
            }
            Some(out)
        }
    }

    #[test]
    fn enumerates_keys_by_index_and_caches() {
        let live = LiveSmc::with_transport(Box::new(Table(vec!["TCMz", "Te05", "Te0S", "TRDX"])));
        assert!(live.is_open());
        let want = ["TCMz", "Te05", "Te0S", "TRDX"].map(String::from).to_vec();
        assert_eq!(live.enumerate_keys(), Some(want.clone()));
        assert_eq!(live.enumerate_keys(), Some(want));
    }

    #[test]
    fn enumeration_stops_at_non_printable_keys_and_reports_absence_as_none() {
        let live = LiveSmc::with_transport(Box::new(Table(vec![
            "TCMz",
            "\u{1}\u{1}\u{1}\u{1}",
            "TRDX",
        ])));
        assert_eq!(live.enumerate_keys(), Some(vec!["TCMz".to_string()]));
        let none = LiveSmc::with_transport(Box::new(Table(vec!["\u{1}\u{1}\u{1}\u{1}"])));
        assert_eq!(none.enumerate_keys(), None);
    }

    #[test]
    fn key_count_accepts_both_encodings() {
        assert_eq!(parse_key_count(&[0, 0, 0x0d, 0x2e]), 3374); // ui32 (Apple Silicon)
        assert_eq!(parse_key_count(b"0512"), 512); // ASCII decimal (some Intel firmware)
        assert_eq!(parse_key_count(&[]), 0);
    }
}
