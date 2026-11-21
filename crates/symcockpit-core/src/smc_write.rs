//! The SMC write port, value encoding and the key allowlist.
//!
//! Port of `SMCService.writeKeyValue` plus a policy the Swift core did not
//! have: the write port only ever accepts the handful of keys the fan and
//! charge-limit services need, with the type each one has on Apple Silicon.
//! `symcockpit-macos` implements [`SmcWriter`] (the only place command `6`
//! exists) and applies [`is_allowed`] again below the port, so neither a
//! caller of the port nor a message to the helper can name another key.
//!
//! arm64 only (D16): the Intel keys (`FS!`, `CHLC`) are not writable here.

use crate::sensors::FourCc;

/// Writes one SMC key. `bytes` are already encoded for `data_type`.
pub trait SmcWriter {
    /// `true` when the firmware accepted the write. A `true` is not proof the
    /// value holds: callers read back (Q01).
    fn write_key_raw(&self, key: &str, data_type: &FourCc, bytes: &[u8]) -> bool;
}

/// `SMCService.writeKeyValue`: encode `value` for `data_type` and write it.
/// An unsupported type is a refused write.
pub fn write_value(writer: &dyn SmcWriter, key: &str, value: f64, data_type: &FourCc) -> bool {
    match encode_value(data_type, value) {
        Some(bytes) => writer.write_key_raw(key, data_type, &bytes),
        None => false,
    }
}

/// Wire bytes for `value` (per-type byte order as on the read side: `flt ` is
/// little-endian, the integers and `fpe2` are big-endian). Integers clamp to
/// their range and truncate, like Swift's `UInt8(min(max(value, 0), 255))`.
pub fn encode_value(data_type: &FourCc, value: f64) -> Option<Vec<u8>> {
    Some(match data_type {
        b"fpe2" => ((value * 4.0).round() as u16).to_be_bytes().to_vec(),
        b"flt " => (value as f32).to_le_bytes().to_vec(),
        b"ui8 " => vec![value.clamp(0.0, 255.0) as u8],
        b"ui16" => (value.clamp(0.0, 65535.0) as u16).to_be_bytes().to_vec(),
        b"ui32" => (value.clamp(0.0, 4_294_967_295.0) as u32)
            .to_be_bytes()
            .to_vec(),
        _ => return None,
    })
}

/// Highest fan index the write path accepts (`read_fans` stops at four).
pub const MAX_FANS: u8 = 4;

/// The only keys that may be written, with their type:
/// `F{n}Md` (`ui8 `, mode), `F{n}Tg` (`flt `, target RPM), `Ftst` (`ui8 `,
/// diagnostic unlock), `CHTE` (`ui32`) and `CH0B`/`CH0C` (`ui8 `, charge inhibit).
pub fn is_allowed(key: &str, data_type: &FourCc) -> bool {
    match (key, data_type) {
        ("Ftst" | "CH0B" | "CH0C", b"ui8 ") | ("CHTE", b"ui32") => true,
        _ => match key.as_bytes() {
            [b'F', n, rest @ ..] if (n.wrapping_sub(b'0')) < MAX_FANS => {
                matches!((rest, data_type), (b"Md", b"ui8 ") | (b"Tg", b"flt "))
            }
            _ => false,
        },
    }
}

/// A writer that refuses everything outside [`is_allowed`] before it reaches
/// the inner one.
pub struct Policed<'a>(pub &'a dyn SmcWriter);

impl SmcWriter for Policed<'_> {
    fn write_key_raw(&self, key: &str, data_type: &FourCc, bytes: &[u8]) -> bool {
        is_allowed(key, data_type) && self.0.write_key_raw(key, data_type, bytes)
    }
}

/// What an unprivileged process gets: the kernel would refuse the write, so
/// nothing is attempted and the callers' own error paths report the missing
/// privilege exactly as they do for a rejected hardware write.
pub struct DeniedWriter;

impl SmcWriter for DeniedWriter {
    fn write_key_raw(&self, _: &str, _: &FourCc, _: &[u8]) -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Vectors: tuning/Tests/SymCockpitCoreTests/SMCServiceTests.swift (writeKeyValue).

    #[test]
    fn values_encode_per_type() {
        assert_eq!(
            encode_value(b"fpe2", 2000.0).unwrap(),
            8000u16.to_be_bytes()
        );
        assert_eq!(encode_value(b"flt ", 1.0).unwrap(), [0, 0, 0x80, 0x3F]); // little-endian
        assert_eq!(encode_value(b"ui8 ", 300.0).unwrap(), [255]);
        assert_eq!(encode_value(b"ui8 ", -4.0).unwrap(), [0]);
        assert_eq!(encode_value(b"ui16", 100.0).unwrap(), [0, 100]);
        assert_eq!(encode_value(b"ui32", 1.0).unwrap(), [0, 0, 0, 1]);
        assert_eq!(encode_value(b"sp78", 1.0), None);
    }

    #[test]
    fn only_the_fan_and_charge_keys_are_allowed() {
        for (key, t) in [
            ("F0Md", b"ui8 "),
            ("F3Md", b"ui8 "),
            ("F1Tg", b"flt "),
            ("Ftst", b"ui8 "),
            ("CH0B", b"ui8 "),
            ("CH0C", b"ui8 "),
            ("CHTE", b"ui32"),
        ] {
            assert!(is_allowed(key, t), "{key}");
        }
        for (key, t) in [
            ("F4Md", b"ui8 "), // no fifth fan
            ("F0Md", b"flt "), // wrong type for the key
            ("F0Tg", b"ui8 "),
            ("F0Mn", b"flt "), // minimum RPM is firmware data, never ours to write
            ("F0Mx", b"flt "),
            ("CHTE", b"ui8 "),
            ("CHIE", b"ui8 "), // forced discharge is out of scope
            ("BCLM", b"ui8 "),
            ("bfD0", b"ui8 "),
            ("FS! ", b"ui16"),
            ("CHLC", b"ui16"),
            ("", b"ui8 "),
            ("F", b"ui8 "),
        ] {
            assert!(!is_allowed(key, t), "{key}");
        }
    }

    #[test]
    fn the_policed_writer_stops_other_keys_before_the_inner_writer() {
        struct Count(std::cell::Cell<u32>);
        impl SmcWriter for Count {
            fn write_key_raw(&self, _: &str, _: &FourCc, _: &[u8]) -> bool {
                self.0.set(self.0.get() + 1);
                true
            }
        }
        let inner = Count(std::cell::Cell::new(0));
        let policed = Policed(&inner);
        assert!(write_value(&policed, "F0Md", 1.0, b"ui8 "));
        assert!(!write_value(&policed, "F0Mx", 1.0, b"flt "));
        assert!(!write_value(&policed, "F0Md", 1.0, b"sp78"));
        assert_eq!(inner.0.get(), 1);
        assert!(!write_value(&DeniedWriter, "F0Md", 1.0, b"ui8 "));
    }
}
