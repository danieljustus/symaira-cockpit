//! `fan profile <name>` and `fan target <°C>|off` (`runFanProfile`, `runFanTarget`,
//! `FanProfileStore` of v0.12): the parsing and the bytes of the one small file
//! they write. Neither command touches hardware; a running governor reads the
//! file on its next tick.

use symcockpit_contract::Error;

use crate::sensors::{COOL_TARGET_RANGE, FanProfile, FanSelection};

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Change {
    Profile(FanProfile),
    /// `None`: `off`, `none` or `clear`.
    Target(Option<f64>),
}

/// `sub` is `profile` or `target`; `args` follow it and are not empty.
pub fn parse(sub: &str, args: &[String]) -> Result<Change, Error> {
    let command = format!("fan {sub}");
    if let Some(extra) = args.get(1) {
        return Err(Error::Usage(format!(
            "{command}: unexpected argument '{extra}'"
        )));
    }
    let arg = args[0].as_str();
    if sub == "profile" {
        return FanProfile::parse(arg).map(Change::Profile).ok_or_else(|| {
            Error::Usage("fan profile: expected one of system, comfort, performance.".into())
        });
    }
    if ["off", "none", "clear"].contains(&arg.to_lowercase().as_str()) {
        return Ok(Change::Target(None));
    }
    arg.parse::<f64>()
        .ok()
        .filter(|v| v.is_finite() && COOL_TARGET_RANGE.contains(v))
        .map(|v| Change::Target(Some(v)))
        .ok_or_else(|| {
            Error::Usage(format!(
                "fan target: expected a number from {} to {} (\u{b0}C), or 'off'.",
                COOL_TARGET_RANGE.start(),
                COOL_TARGET_RANGE.end()
            ))
        })
}

/// The selection with `change` applied; the profile keeps the stored target and
/// the target keeps the stored profile (`write`, `writeCoolTarget`).
pub fn apply(current: FanSelection, change: Change) -> FanSelection {
    match change {
        Change::Profile(profile) => FanSelection::new(profile, current.cool_target_celsius),
        Change::Target(target) => FanSelection::new(current.profile, target),
    }
}

/// `{"profile":"comfort","cool_target_celsius":70}`: the key order and the
/// number format of Swift's `JSONEncoder` (whole numbers without `.0`, no key
/// for no target).
pub fn encode(selection: &FanSelection) -> String {
    let mut text = format!("{{\"profile\":\"{}\"", selection.profile.as_str());
    if let Some(target) = selection.cool_target_celsius {
        text.push_str(&format!(",\"cool_target_celsius\":{target}"));
    }
    text.push('}');
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(list: &[&str]) -> Vec<String> {
        list.iter().map(ToString::to_string).collect()
    }

    // Vectors: the v0.12 binary, `fan profile|target` with these arguments.
    #[test]
    fn profile_and_target_arguments_parse_like_swift() {
        assert_eq!(
            parse("profile", &words(&["Performance"])),
            Ok(Change::Profile(FanProfile::Performance))
        );
        assert_eq!(
            parse("target", &words(&["72.5"])),
            Ok(Change::Target(Some(72.5)))
        );
        for off in ["off", "NONE", "Clear"] {
            assert_eq!(parse("target", &words(&[off])), Ok(Change::Target(None)));
        }
        let usage = |sub, list: &[&str]| parse(sub, &words(list)).unwrap_err().to_string();
        assert_eq!(
            usage("profile", &["bogus"]),
            "fan profile: expected one of system, comfort, performance."
        );
        for bad in ["90", "49.9", "abc", "nan", "inf", ""] {
            assert_eq!(
                usage("target", &[bad]),
                "fan target: expected a number from 50 to 85 (\u{b0}C), or 'off'."
            );
        }
        assert_eq!(
            usage("target", &["60", "x"]),
            "fan target: unexpected argument 'x'"
        );
        assert_eq!(
            usage("profile", &["system", "x"]),
            "fan profile: unexpected argument 'x'"
        );
    }

    #[test]
    fn the_file_keeps_the_swift_bytes_and_the_other_half() {
        // The v0.12 file, byte for byte.
        let stored = FanSelection::from_json(br#"{"profile":"system","cool_target_celsius":85}"#);
        assert_eq!(
            encode(&stored),
            r#"{"profile":"system","cool_target_celsius":85}"#
        );
        let comfort = apply(stored, Change::Profile(FanProfile::Comfort));
        assert_eq!(comfort.cool_target_celsius, Some(85.0));
        let target = apply(comfort, Change::Target(Some(72.5)));
        assert_eq!(
            encode(&target),
            r#"{"profile":"comfort","cool_target_celsius":72.5}"#
        );
        let cleared = apply(target, Change::Target(None));
        assert_eq!(encode(&cleared), r#"{"profile":"comfort"}"#);
        assert_eq!(cleared.profile, FanProfile::Comfort);
    }
}
