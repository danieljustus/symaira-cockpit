//! The one SMC write: `kSMCWriteKey` (command `6`) for the keys the fan and
//! charge-limit services need and nothing else.
//!
//! Layer by layer, a write has to get past: the caller's own policy (clamp,
//! thermal gate), [`symcockpit_core::smc_write::is_allowed`] (key and type),
//! and here the firmware's own description of the key (its real type and
//! size must match the payload). No test in this crate calls it on hardware.

use symcockpit_core::sensors::FourCc;
use symcockpit_core::smc_write::{SmcWriter, is_allowed};

use super::iokit::{Command, ParamBlock};
use super::live::{LiveSmc, key4};

/// `kSMCWriteKey`.
const WRITE_KEY: u8 = 6;
const MAX_PAYLOAD: usize = 32;

/// The request block of a write: key, the key's own keyInfo, size, payload.
fn write_block(key: [u8; 4], key_info: &ParamBlock, size: usize, payload: &[u8]) -> ParamBlock {
    let mut block = ParamBlock::new(Command::ReadKey);
    block.0[42] = WRITE_KEY;
    block.set_key(key);
    block.copy_key_info(key_info);
    block.set_data32(size as u32);
    block.0[48..48 + payload.len()].copy_from_slice(payload);
    block
}

impl SmcWriter for LiveSmc {
    fn write_key_raw(&self, key: &str, data_type: &FourCc, bytes: &[u8]) -> bool {
        if !self.is_open_for_write()
            || !is_allowed(key, data_type)
            || bytes.is_empty()
            || bytes.len() > MAX_PAYLOAD
        {
            return false;
        }
        let Some(key) = key4(key) else {
            return false;
        };
        let Some(info) = self.key_info(key) else {
            return false;
        };
        if info.data_type != *data_type || info.size != bytes.len() {
            return false;
        }
        let block = write_block(key, &info.block, info.size, bytes);
        self.call(&block).is_some_and(|out| out.result() == 0)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use super::super::iokit::Transport;
    use super::*;

    #[test]
    fn the_write_block_has_command_six_native_endian_key_and_payload_at_48() {
        let mut info = ParamBlock::new(Command::ReadKeyInfo);
        info.0[28..32].copy_from_slice(&4u32.to_ne_bytes());
        info.0[32..36].copy_from_slice(&u32::from_be_bytes(*b"ui32").to_ne_bytes());
        let block = write_block(*b"CHTE", &info, 4, &[0, 0, 0, 1]);
        assert_eq!(block.0[42], 6);
        assert_eq!(&block.0[0..4], b"ETHC"); // reversed: native-endian key (#185)
        assert_eq!(block.key_info_size(), 4);
        assert_eq!(block.key_info_type(), *b"ui32");
        assert_eq!(block.0[44..48], 4u32.to_ne_bytes());
        assert_eq!(block.0[48..52], [0, 0, 0, 1]);
        assert_eq!(block.0[52], 0);
    }

    /// A scripted SMC: `#KEY` and `F0Md` (ui8) exist; every command-6 block is recorded.
    struct Script {
        writes: Mutex<Vec<ParamBlock>>,
        reject: bool,
    }

    impl Transport for Arc<Script> {
        fn call(&self, input: &ParamBlock) -> Option<ParamBlock> {
            let mut out = ParamBlock([0; 80]);
            match input.0[42] {
                9 => {
                    let (size, ty) = match input.key() {
                        k if k == *b"#KEY" => (4u32, *b"ui32"),
                        k if k == *b"F0Md" => (1, *b"ui8 "),
                        _ => {
                            out.0[40] = 132;
                            return Some(out);
                        }
                    };
                    out.0[28..32].copy_from_slice(&size.to_ne_bytes());
                    out.0[32..36].copy_from_slice(&u32::from_be_bytes(ty).to_ne_bytes());
                    Some(out)
                }
                6 => {
                    self.writes.lock().unwrap().push(input.clone());
                    out.0[40] = u8::from(self.reject);
                    Some(out)
                }
                _ => None,
            }
        }
    }

    fn scripted(reject: bool) -> (LiveSmc, Arc<Script>) {
        let script = Arc::new(Script {
            writes: Mutex::default(),
            reject,
        });
        (LiveSmc::with_transport(Box::new(script.clone())), script)
    }

    #[test]
    fn an_allowed_write_sends_one_command_six_block() {
        let (smc, script) = scripted(false);
        assert!(smc.write_key_raw("F0Md", b"ui8 ", &[1]));
        let writes = script.writes.lock().unwrap();
        assert_eq!(writes.len(), 1);
        assert_eq!(
            (writes[0].0[42], writes[0].key(), writes[0].0[48]),
            (6, *b"F0Md", 1)
        );
    }

    #[test]
    fn nothing_else_reaches_the_firmware() {
        let (smc, script) = scripted(false);
        // Not on the allowlist, wrong type for the firmware's key, wrong size, absent key.
        assert!(!smc.write_key_raw("F0Mx", b"flt ", &[0, 0, 0, 0]));
        assert!(!smc.write_key_raw("F0Md", b"flt ", &[0, 0, 0, 0]));
        assert!(!smc.write_key_raw("F0Md", b"ui8 ", &[1, 2]));
        assert!(!smc.write_key_raw("F1Md", b"ui8 ", &[1]));
        assert!(!smc.write_key_raw("F0Md", b"ui8 ", &[]));
        assert!(script.writes.lock().unwrap().is_empty());
        // A firmware verdict other than 0 is a refused write.
        let (smc, _) = scripted(true);
        assert!(!smc.write_key_raw("F0Md", b"ui8 ", &[1]));
        // A closed connection writes nothing.
        assert!(!LiveSmc::closed().write_key_raw("F0Md", b"ui8 ", &[1]));
    }

    #[test]
    fn command_six_is_only_built_in_this_file() {
        // The read-path module has no write variant and never names command 6.
        let iokit = include_str!("iokit.rs");
        let (before_tests, _) = iokit.split_once("#[cfg(test)]").unwrap();
        assert!(!before_tests.contains("= 6"));
        let live = include_str!("live.rs");
        assert!(!live.split_once("#[cfg(test)]").unwrap().0.contains("[42]"));
    }
}
