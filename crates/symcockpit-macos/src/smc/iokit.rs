//! Raw IOKit transport to the AppleSMC driver. The only module with `unsafe`.
//!
//! The 80-byte param block is a C struct the driver reads in **host** byte
//! order: `key`, `keyInfo.dataSize`/`dataType` and `data32` are plain `u32`
//! members, not big-endian wire fields (issue #185: encoding them big-endian
//! makes every key, `#KEY` included, answer `kSMCKeyNotFound`). The payload
//! at bytes 48-79 is the opposite: wire data with a per-type byte order,
//! decoded by `symcockpit_core::sensors::convert_value`.
//!
//! Layout: key 0..4, keyInfo 28..40 (size 28, type 32, attributes 36),
//! result 40, status 41, data8 (command) 42, data32 44..48, payload 48..80.

use std::ffi::{c_char, c_void};

pub(super) const BLOCK: usize = 80;
/// `kSMCHandleYPCCommand`: the one IOConnect selector the driver dispatches on.
const SELECTOR_YPC: u32 = 2;

/// The only commands this crate can send. There is deliberately no write
/// variant (`6`): stage 1 reads only, and the type system keeps it that way.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum Command {
    ReadKey = 5,
    KeyFromIndex = 8,
    ReadKeyInfo = 9,
}

impl Command {
    #[cfg(test)]
    pub(super) const ALL: [Command; 3] = [Self::ReadKey, Self::KeyFromIndex, Self::ReadKeyInfo];
}

/// One request or response block.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct ParamBlock(pub(super) [u8; BLOCK]);

impl ParamBlock {
    pub(super) fn new(command: Command) -> Self {
        let mut block = Self([0; BLOCK]);
        block.0[42] = command as u8;
        block
    }

    fn u32_at(&self, offset: usize) -> u32 {
        u32::from_ne_bytes([
            self.0[offset],
            self.0[offset + 1],
            self.0[offset + 2],
            self.0[offset + 3],
        ])
    }

    fn set_u32(&mut self, offset: usize, value: u32) {
        self.0[offset..offset + 4].copy_from_slice(&value.to_ne_bytes());
    }

    /// Set the key from its four characters (`b"#KEY"`).
    pub(super) fn set_key(&mut self, key: [u8; 4]) {
        self.set_u32(0, u32::from_be_bytes(key));
    }

    pub(super) fn key(&self) -> [u8; 4] {
        self.u32_at(0).to_be_bytes()
    }

    pub(super) fn set_data32(&mut self, value: u32) {
        self.set_u32(44, value);
    }

    pub(super) fn key_info_size(&self) -> u32 {
        self.u32_at(28)
    }

    /// The data type in readable order (`b"ui8 "`).
    pub(super) fn key_info_type(&self) -> [u8; 4] {
        self.u32_at(32).to_be_bytes()
    }

    /// Copy the 12-byte keyInfo block (bytes 28..40) from a keyInfo response.
    pub(super) fn copy_key_info(&mut self, from: &ParamBlock) {
        self.0[28..40].copy_from_slice(&from.0[28..40]);
    }

    /// Firmware verdict; `0` is success, `132` is `kSMCKeyNotFound`.
    pub(super) fn result(&self) -> u8 {
        self.0[40]
    }

    /// The first `count` payload bytes (at most 32).
    pub(super) fn payload(&self, count: usize) -> Vec<u8> {
        self.0[48..48 + count.min(32)].to_vec()
    }
}

/// One param-block round trip. `None` is a transport failure; the firmware's
/// own verdict is in `ParamBlock::result`.
pub(super) trait Transport: Send + Sync {
    fn call(&self, input: &ParamBlock) -> Option<ParamBlock>;
}

type KernReturn = i32;
type MachPort = u32;

#[link(name = "IOKit", kind = "framework")]
unsafe extern "C" {
    fn IOServiceMatching(name: *const c_char) -> *mut c_void;
    fn IOServiceGetMatchingService(main_port: MachPort, matching: *mut c_void) -> MachPort;
    fn IOServiceOpen(
        service: MachPort,
        owning_task: MachPort,
        kind: u32,
        conn: *mut MachPort,
    ) -> KernReturn;
    fn IOServiceClose(conn: MachPort) -> KernReturn;
    fn IOObjectRelease(obj: MachPort) -> KernReturn;
    fn IOConnectCallStructMethod(
        conn: MachPort,
        selector: u32,
        input: *const c_void,
        input_size: usize,
        output: *mut c_void,
        output_size: *mut usize,
    ) -> KernReturn;
}

unsafe extern "C" {
    static mach_task_self_: MachPort;
}

/// An open user-client connection to `AppleSMC`.
pub(super) struct IoKit {
    conn: MachPort,
}

impl IoKit {
    /// Open the AppleSMC user client; `None` when the service is missing or refuses.
    pub(super) fn connect() -> Option<Self> {
        // SAFETY: plain IOKit calls. `IOServiceMatching` returns an owned
        // dictionary that `IOServiceGetMatchingService` consumes (also on
        // failure); the service handle is released once opened or failed;
        // `conn` is a valid out-pointer; `mach_task_self_` is a process-lifetime
        // constant exported by libSystem.
        unsafe {
            let matching = IOServiceMatching(c"AppleSMC".as_ptr());
            let service = IOServiceGetMatchingService(0, matching); // 0 = kIOMainPortDefault
            if service == 0 {
                return None;
            }
            let mut conn = 0;
            let kr = IOServiceOpen(service, mach_task_self_, 0, &mut conn);
            IOObjectRelease(service);
            (kr == 0 && conn != 0).then_some(Self { conn })
        }
    }
}

impl Transport for IoKit {
    fn call(&self, input: &ParamBlock) -> Option<ParamBlock> {
        let mut output = ParamBlock([0; BLOCK]);
        let mut out_size = BLOCK;
        // SAFETY: both pointers reference live, exclusively borrowed 80-byte
        // buffers for the duration of the call; the sizes passed match them;
        // `conn` stays open until `Drop`.
        let kr = unsafe {
            IOConnectCallStructMethod(
                self.conn,
                SELECTOR_YPC,
                input.0.as_ptr().cast(),
                BLOCK,
                output.0.as_mut_ptr().cast(),
                &mut out_size,
            )
        };
        (kr == 0).then_some(output)
    }
}

impl Drop for IoKit {
    fn drop(&mut self) {
        // SAFETY: `conn` was opened by `connect` and is closed exactly once.
        unsafe { IOServiceClose(self.conn) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Vectors: tuning/Tests/SymCockpitCoreTests/SMCParamBlockTests.swift

    #[test]
    fn only_read_commands_exist() {
        let codes: Vec<u8> = Command::ALL.iter().map(|c| *c as u8).collect();
        assert_eq!(codes, [5, 8, 9]); // 6 (kSMCWriteKey) must never appear
        // Every command byte the code can put on the wire comes from `Command`:
        // the only writer of the command byte (offset 42) is `ParamBlock::new`.
        let src = include_str!("iokit.rs");
        assert_eq!(src.matches(concat!("0[42]", " =")).count(), 1);
    }

    #[test]
    fn key_is_native_endian() {
        // testKeyRoundTripsNativeEndian / testProbeKeyIsEncodedForTheDriver
        let mut block = ParamBlock::new(Command::ReadKeyInfo);
        block.set_key(*b"#KEY");
        assert_eq!(&block.0[0..4], b"YEK#"); // ASCII bytes reversed (little-endian host)
        assert_eq!(block.key(), *b"#KEY");
    }

    #[test]
    fn data32_is_native_endian() {
        let mut block = ParamBlock::new(Command::KeyFromIndex);
        block.set_data32(0x0102_0304);
        assert_eq!(block.0[44..48], [0x04, 0x03, 0x02, 0x01]);
        assert_eq!(block.0[42], 8);
    }

    #[test]
    fn key_info_round_trips_and_copies_twelve_bytes() {
        let mut source = ParamBlock([0; BLOCK]);
        source.0[28..32].copy_from_slice(&8u32.to_ne_bytes());
        source.0[32..36].copy_from_slice(&u32::from_be_bytes(*b"flt ").to_ne_bytes());
        source.0[36] = 0x42;
        source.set_key(*b"ZZZZ"); // outside 28..40: must not be copied
        assert_eq!(
            (source.key_info_size(), source.key_info_type()),
            (8, *b"flt ")
        );
        let mut target = ParamBlock::new(Command::ReadKey);
        target.copy_key_info(&source);
        assert_eq!(
            (target.key_info_size(), target.key_info_type(), target.0[36]),
            (8, *b"flt ", 0x42)
        );
        assert_eq!(target.key(), [0; 4]);
        assert_eq!(target.0[42], 5);
    }

    #[test]
    fn payload_is_clamped_to_thirty_two_bytes() {
        let mut block = ParamBlock([0; BLOCK]);
        for i in 0..32 {
            block.0[48 + i] = i as u8;
        }
        assert_eq!(block.payload(4), [0, 1, 2, 3]);
        assert_eq!(block.payload(0), Vec::<u8>::new());
        assert_eq!(block.payload(64).len(), 32);
        assert_eq!(block.payload(64).last(), Some(&31));
    }
}
