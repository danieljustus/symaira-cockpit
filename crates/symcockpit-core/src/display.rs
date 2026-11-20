//! Display enumeration and built-in brightness, read side only (port of
//! `DisplayService.list()` / `getBuiltinBrightness()` and `DisplaysReport`,
//! `BrightnessReadback` from `tuning/Sources/SymCockpitCore`).
//!
//! No gamma, overlay or brightness write exists here: the gamma table has one
//! owner (tuning/AGENTS.md "Hard Rules"), and it is not part of the read path.

use serde::Serialize;
use serde_json::Value;
use symcockpit_contract::Error;

/// One display as seen by the platform (Swift `ScreenSnapshot`).
#[derive(Clone, Debug, PartialEq)]
pub struct ScreenSnapshot {
    pub name: String,
    pub display_id: u32,
    pub is_builtin: bool,
    pub max_edr_headroom: f64,
    pub potential_edr_headroom: f64,
    pub backing_scale_factor: f64,
}

/// Port: lists the attached displays. Infallible like the Swift source: an
/// empty list means "no GUI session".
pub trait DisplayEnumerator {
    fn enumerate_screens(&self) -> Vec<ScreenSnapshot>;
}

/// Port: reads the 0.0–1.0 brightness of one display.
pub trait BrightnessSource {
    fn brightness(&self, display_id: u32) -> Result<f64, Error>;
}

/// Swift `DisplayInfo`. `is_builtin` is optional in Swift (nil is omitted) but
/// is always set by `DisplayService.list()`.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct DisplayInfo {
    pub name: String,
    pub display_id: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_builtin: Option<bool>,
    pub max_edr_headroom: f64,
    pub potential_edr_headroom: f64,
    pub edr_capable: bool,
    pub backing_scale_factor: f64,
}

/// Swift `DisplaysReport`.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct DisplaysReport {
    pub displays: Vec<DisplayInfo>,
    pub notes: Vec<String>,
}

/// Swift `BrightnessReadback`; `notes` is always empty on the read path.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct BrightnessReadback {
    pub brightness: f64,
    pub notes: Vec<String>,
}

pub const NO_DISPLAYS_NOTE: &str =
    "No displays reported — symtune must run inside a logged-in GUI session.";
pub const EDR_NOTE: &str =
    "potential_edr_headroom > 1.0 means extended (>100%) brightness is possible on that display.";

/// Output of `symcockpit displays --help` (stdout, byte for byte).
pub const DISPLAYS_HELP: &str = "Usage: symcockpit displays [--json]\n\nDisplays with EDR headroom / extended-brightness capability (JSON).\n--json is accepted for consistency with other read commands; it is a no-op here.\n";

pub fn list(source: &dyn DisplayEnumerator) -> DisplaysReport {
    let displays: Vec<DisplayInfo> = source
        .enumerate_screens()
        .into_iter()
        .map(|s| DisplayInfo {
            edr_capable: s.potential_edr_headroom > 1.0,
            name: s.name,
            display_id: s.display_id,
            is_builtin: Some(s.is_builtin),
            max_edr_headroom: s.max_edr_headroom,
            potential_edr_headroom: s.potential_edr_headroom,
            backing_scale_factor: s.backing_scale_factor,
        })
        .collect();
    let note = if displays.is_empty() {
        NO_DISPLAYS_NOTE
    } else {
        EDR_NOTE
    };
    DisplaysReport {
        displays,
        notes: vec![note.to_string()],
    }
}

/// Whether any attached display offers extended-brightness headroom.
pub fn any_edr_capable(source: &dyn DisplayEnumerator) -> bool {
    source
        .enumerate_screens()
        .iter()
        .any(|s| s.potential_edr_headroom > 1.0)
}

/// Brightness of the first built-in display; `Unsupported` without one.
pub fn builtin_brightness(
    displays: &dyn DisplayEnumerator,
    brightness: &dyn BrightnessSource,
) -> Result<f64, Error> {
    let builtin = displays
        .enumerate_screens()
        .into_iter()
        .find(|s| s.is_builtin)
        .ok_or_else(|| Error::Unsupported("No built-in display detected.".into()))?;
    brightness.brightness(builtin.display_id)
}

/// `displays` / MCP `list_displays` payload.
pub fn displays_json(source: &dyn DisplayEnumerator) -> Result<Value, Error> {
    let report = list(source);
    for d in &report.displays {
        if !d.max_edr_headroom.is_finite()
            || !d.potential_edr_headroom.is_finite()
            || !d.backing_scale_factor.is_finite()
        {
            // Swift's JSONEncoder throws on NaN/inf; serde would write null.
            return Err(Error::Failed(
                "display report holds a non-finite number".into(),
            ));
        }
    }
    to_value(&report)
}

/// `brightness get` / MCP `get_brightness` payload.
pub fn brightness_get_json(
    displays: &dyn DisplayEnumerator,
    brightness: &dyn BrightnessSource,
) -> Result<Value, Error> {
    let value = builtin_brightness(displays, brightness)?;
    if !value.is_finite() {
        return Err(Error::Failed("brightness is not a finite number".into()));
    }
    to_value(&BrightnessReadback {
        brightness: value,
        notes: Vec::new(),
    })
}

fn to_value<T: Serialize>(report: &T) -> Result<Value, Error> {
    serde_json::to_value(report).map_err(|e| Error::Failed(e.to_string()))
}

/// What the CLI should do for `displays <rest>`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DisplaysCall {
    /// Print [`DISPLAYS_HELP`], exit 0.
    Help,
    /// Print [`displays_json`].
    Run,
}

/// Mirrors `runAlwaysJSONCommand`: `--help`/`-h` anywhere wins, `--json` is a
/// no-op, anything else is a usage error (exit 2).
pub fn parse_displays_args(rest: &[String]) -> Result<DisplaysCall, Error> {
    if rest.iter().any(|a| a == "--help" || a == "-h") {
        return Ok(DisplaysCall::Help);
    }
    match rest.iter().find(|a| *a != "--json") {
        Some(arg) => Err(Error::Usage(format!(
            "displays: unexpected argument '{arg}'"
        ))),
        None => Ok(DisplaysCall::Run),
    }
}

/// Arguments after `brightness` for the read form: none, or `get` alone.
/// `set` and friends belong to the write path and are rejected here.
pub fn parse_brightness_get_args(rest: &[String]) -> Result<(), Error> {
    match rest.first().map(String::as_str) {
        None | Some("get") => match rest.get(1) {
            Some(arg) => Err(Error::Usage(format!(
                "brightness get: unexpected argument '{arg}'"
            ))),
            None => Ok(()),
        },
        Some(_) => Err(Error::Usage(
            "brightness: expected 'get' or 'set <value>'.".into(),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Screens(Vec<ScreenSnapshot>);
    impl DisplayEnumerator for Screens {
        fn enumerate_screens(&self) -> Vec<ScreenSnapshot> {
            self.0.clone()
        }
    }
    struct Fixed(Result<f64, Error>);
    impl BrightnessSource for Fixed {
        fn brightness(&self, _: u32) -> Result<f64, Error> {
            self.0.clone()
        }
    }

    fn screen(id: u32, builtin: bool, potential: f64, scale: f64) -> ScreenSnapshot {
        ScreenSnapshot {
            name: "X".into(),
            display_id: id,
            is_builtin: builtin,
            max_edr_headroom: 1.0,
            potential_edr_headroom: potential,
            backing_scale_factor: scale,
        }
    }

    // Vectors below: tuning/Tests/SymCockpitCoreTests/DisplayServiceTests.swift

    #[test] // testNoScreensReportsEmptyList
    fn no_screens_reports_empty_list_and_note() {
        let report = list(&Screens(vec![]));
        assert!(report.displays.is_empty());
        assert_eq!(report.notes[0], NO_DISPLAYS_NOTE);
    }

    #[test] // testEDRDetection
    fn edr_capable_when_potential_headroom_exceeds_one() {
        let s = Screens(vec![screen(1, false, 1.5, 1.0)]);
        assert!(any_edr_capable(&s));
        assert!(list(&s).displays[0].edr_capable);
        let flat = Screens(vec![screen(1, false, 1.0, 1.0)]);
        assert!(!any_edr_capable(&flat));
        assert!(!list(&flat).displays[0].edr_capable);
    }

    #[test] // testNoBuiltInDisplayThrowsUnsupported
    fn no_builtin_display_is_unsupported_exit_4() {
        let err = brightness_get_json(&Screens(vec![screen(1, false, 1.0, 1.0)]), &Fixed(Ok(0.5)))
            .unwrap_err();
        assert_eq!(
            err,
            Error::Unsupported("No built-in display detected.".into())
        );
        assert_eq!(err.exit_code(), symcockpit_contract::exit::UNSUPPORTED);
    }

    #[test] // testBuiltInDisplayFound
    fn builtin_display_is_reported() {
        let report = list(&Screens(vec![screen(2, true, 1.0, 2.0)]));
        assert_eq!(report.displays.len(), 1);
        assert_eq!(report.displays[0].is_builtin, Some(true));
        assert_eq!(report.displays[0].backing_scale_factor, 2.0);
        assert_eq!(report.notes, [EDR_NOTE]);
    }

    #[test]
    fn displays_json_has_exactly_the_swift_keys() {
        let v = displays_json(&Screens(vec![screen(2, true, 16.0, 2.0)])).unwrap();
        let mut keys: Vec<_> = v["displays"][0]
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect();
        keys.sort();
        assert_eq!(
            keys,
            [
                "backing_scale_factor",
                "display_id",
                "edr_capable",
                "is_builtin",
                "max_edr_headroom",
                "name",
                "potential_edr_headroom"
            ]
        );
        assert_eq!(v["notes"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn unset_is_builtin_is_omitted_like_swift_nil() {
        let mut info = list(&Screens(vec![screen(2, true, 1.0, 1.0)]))
            .displays
            .remove(0);
        info.is_builtin = None;
        assert!(
            serde_json::to_value(&info)
                .unwrap()
                .get("is_builtin")
                .is_none()
        );
    }

    #[test]
    fn brightness_json_has_value_and_empty_notes() {
        // 0.7242187261581421 is Double(Float(0.724218...)), as DisplayServices reports.
        let v = brightness_get_json(
            &Screens(vec![screen(1, true, 1.0, 2.0)]),
            &Fixed(Ok(f64::from(0.724_218_7_f32))),
        )
        .unwrap();
        assert_eq!(
            v["brightness"],
            serde_json::json!(f64::from(0.724_218_7_f32))
        );
        assert_eq!(v["notes"], serde_json::json!([]));
        assert_eq!(v.as_object().unwrap().len(), 2);
    }

    #[test]
    fn source_error_passes_through() {
        let err = brightness_get_json(
            &Screens(vec![screen(1, true, 1.0, 2.0)]),
            &Fixed(Err(Error::Failed("boom".into()))),
        )
        .unwrap_err();
        assert_eq!(err, Error::Failed("boom".into()));
    }

    #[test]
    fn non_finite_numbers_fail_like_swift_encoder() {
        let mut s = screen(1, true, 1.0, 2.0);
        s.max_edr_headroom = f64::NAN;
        assert!(displays_json(&Screens(vec![s])).is_err());
        assert!(
            brightness_get_json(
                &Screens(vec![screen(1, true, 1.0, 2.0)]),
                &Fixed(Ok(f64::INFINITY))
            )
            .is_err()
        );
    }

    fn args(a: &[&str]) -> Vec<String> {
        a.iter().map(ToString::to_string).collect()
    }

    // Swift 0.12.2 behaviour, recorded: `displays foo` -> exit 2, `brightness get extra` -> exit 2.
    #[test]
    fn displays_args_follow_swift() {
        assert_eq!(parse_displays_args(&args(&[])), Ok(DisplaysCall::Run));
        assert_eq!(
            parse_displays_args(&args(&["--json"])),
            Ok(DisplaysCall::Run)
        );
        assert_eq!(parse_displays_args(&args(&["-h"])), Ok(DisplaysCall::Help));
        assert_eq!(
            parse_displays_args(&args(&["foo", "--help"])),
            Ok(DisplaysCall::Help)
        );
        let err = parse_displays_args(&args(&["--json", "foo"])).unwrap_err();
        assert_eq!(
            err,
            Error::Usage("displays: unexpected argument 'foo'".into())
        );
        assert_eq!(err.exit_code(), 2);
    }

    #[test]
    fn brightness_args_follow_swift() {
        assert_eq!(parse_brightness_get_args(&args(&[])), Ok(()));
        assert_eq!(parse_brightness_get_args(&args(&["get"])), Ok(()));
        let err = parse_brightness_get_args(&args(&["get", "extra"])).unwrap_err();
        assert_eq!(
            err,
            Error::Usage("brightness get: unexpected argument 'extra'".into())
        );
        assert_eq!(err.exit_code(), 2);
        assert!(parse_brightness_get_args(&args(&["set", "0.5"])).is_err());
    }
}
