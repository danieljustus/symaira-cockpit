//! Audio and MIDI commands (R40 to R44). [`specs`] joins the register
//! through [`super::all`].
//!
//! Risk classes: reading and the reversible scalars (default device, volume,
//! mute, per-app volume) act directly; format changes and aggregates are audio
//! device configuration and therefore risky (decision D10): agents reach them
//! only as `plan_*` tools.

use serde_json::{Value, json};

use crate::{CommandSpec, Risk};

fn object(properties: Value, required: &[&str]) -> Value {
    json!({"type": "object", "properties": properties, "required": required})
}

fn uid_prop() -> Value {
    json!({"type": "string", "description": "Stable device UID as listed by list_audio_devices."})
}

fn direction_prop() -> Value {
    json!({"type": "string", "enum": ["input", "output"], "description": "Which side of the device; default: output if it has the control, else input."})
}

/// All audio and MIDI commands, in a stable order.
pub fn specs() -> Vec<CommandSpec> {
    use Risk::{Read, Reversible, Risky};
    let spec = |name, cli_path, mcp_name, area, risk, input_schema| CommandSpec {
        name,
        cli_path,
        mcp_name,
        area,
        risk,
        input_schema,
    };
    let none = || object(json!({}), &[]);
    let uid_only = || object(json!({"uid": uid_prop()}), &["uid"]);
    vec![
        spec(
            "audio.devices",
            "audio devices",
            Some("list_audio_devices"),
            "audio",
            Read,
            none(),
        ),
        spec(
            "audio.device",
            "audio device",
            Some("get_audio_device"),
            "audio",
            Read,
            uid_only(),
        ),
        spec(
            "audio.default.get",
            "audio default get",
            None,
            "audio",
            Read,
            none(),
        ),
        spec(
            "audio.volume.get",
            "audio volume get",
            None,
            "audio",
            Read,
            uid_only(),
        ),
        spec(
            "audio.format.get",
            "audio format get",
            None,
            "audio",
            Read,
            uid_only(),
        ),
        spec(
            "audio.mixer.status",
            "audio mixer status",
            None,
            "audio",
            Read,
            none(),
        ),
        spec(
            "midi.devices",
            "midi devices",
            Some("list_midi_devices"),
            "midi",
            Read,
            none(),
        ),
        spec(
            "audio.default.set",
            "audio default set",
            Some("set_default_audio_device"),
            "audio",
            Reversible,
            object(
                json!({
                    "direction": {"type": "string", "enum": ["input", "output"]},
                    "uid": uid_prop()
                }),
                &["direction", "uid"],
            ),
        ),
        spec(
            "audio.volume.set",
            "audio volume set",
            Some("set_audio_volume"),
            "audio",
            Reversible,
            object(
                json!({
                    "uid": uid_prop(),
                    "value": {"type": "number", "minimum": 0, "maximum": 1},
                    "direction": direction_prop()
                }),
                &["uid", "value"],
            ),
        ),
        spec(
            "audio.mute.set",
            "audio mute",
            Some("set_audio_mute"),
            "audio",
            Reversible,
            object(
                json!({"uid": uid_prop(), "muted": {"type": "boolean"}, "direction": direction_prop()}),
                &["uid", "muted"],
            ),
        ),
        // Needs a running mixer (the app agent's, or `audio mixer run`); the
        // one-shot CLI form answers exit 4 when none is reachable.
        spec(
            "audio.app-volume.set",
            "audio mixer set",
            Some("set_audio_app_volume"),
            "audio",
            Reversible,
            object(
                json!({
                    "app": {"type": "string", "description": "Process id or bundle identifier of an app that plays audio."},
                    "volume": {"type": "number", "minimum": 0, "maximum": 1},
                    "muted": {"type": "boolean"}
                }),
                &["app", "volume"],
            ),
        ),
        spec(
            "audio.mixer.run",
            "audio mixer run",
            None,
            "audio",
            Reversible,
            none(),
        ),
        spec(
            "audio.format.set",
            "audio format set",
            Some("plan_audio_format"),
            "audio",
            Risky,
            object(
                json!({
                    "uid": uid_prop(),
                    "rate": {"type": "number", "description": "Sample rate in Hz."},
                    "bits": {"type": "integer", "description": "Bits per sample; omit to change the rate only."}
                }),
                &["uid", "rate"],
            ),
        ),
        spec(
            "audio.aggregate.create",
            "audio aggregate create",
            Some("plan_audio_aggregate"),
            "audio",
            Risky,
            object(
                json!({
                    "name": {"type": "string"},
                    "members": {"type": "array", "items": {"type": "string"}, "minItems": 2, "description": "Device UIDs."},
                    "main": {"type": "string", "description": "Clock source UID; default: the first member."},
                    "multi_output": {"type": "boolean", "description": "Play the same audio on every member."}
                }),
                &["name", "members"],
            ),
        ),
        // Deleting is CLI only: agents do not remove devices.
        spec(
            "audio.aggregate.delete",
            "audio aggregate delete",
            None,
            "audio",
            Risky,
            none(),
        ),
    ]
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::*;

    #[test]
    fn the_mandated_mcp_surface_is_exactly_what_is_exposed() {
        let got: BTreeSet<_> = specs().iter().filter_map(|s| s.mcp_name).collect();
        let want: BTreeSet<_> = [
            "list_audio_devices",
            "get_audio_device",
            "list_midi_devices",
            "set_default_audio_device",
            "set_audio_volume",
            "set_audio_mute",
            "set_audio_app_volume",
            "plan_audio_aggregate",
            "plan_audio_format",
        ]
        .into_iter()
        .collect();
        assert_eq!(got, want);
    }

    #[test]
    fn risk_classes() {
        let risk = |n: &str| specs().into_iter().find(|s| s.name == n).unwrap().risk;
        for n in [
            "audio.devices",
            "audio.device",
            "midi.devices",
            "audio.mixer.status",
        ] {
            assert_eq!(risk(n), Risk::Read, "{n}");
        }
        for n in [
            "audio.default.set",
            "audio.volume.set",
            "audio.mute.set",
            "audio.app-volume.set",
        ] {
            assert_eq!(risk(n), Risk::Reversible, "{n}");
        }
        for n in [
            "audio.format.set",
            "audio.aggregate.create",
            "audio.aggregate.delete",
        ] {
            assert_eq!(risk(n), Risk::Risky, "{n}");
        }
    }

    #[test]
    fn schemas_declare_their_required_properties() {
        for s in specs() {
            assert_eq!(s.input_schema["type"], "object", "{}", s.name);
            for r in s.input_schema["required"].as_array().unwrap() {
                assert!(
                    s.input_schema["properties"]
                        .get(r.as_str().unwrap())
                        .is_some(),
                    "{}",
                    s.name
                );
            }
        }
    }

    #[test]
    fn cli_paths_match_the_mandated_surface() {
        let paths: BTreeSet<_> = specs().iter().map(|s| s.cli_path).collect();
        for p in [
            "audio devices",
            "audio default get",
            "audio volume get",
            "audio volume set",
            "audio mute",
            "audio format get",
            "audio format set",
            "audio aggregate create",
            "audio aggregate delete",
            "audio mixer run",
            "audio mixer status",
            "midi devices",
        ] {
            assert!(paths.contains(p), "{p}");
        }
    }
}
