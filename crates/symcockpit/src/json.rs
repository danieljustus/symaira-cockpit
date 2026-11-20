//! JSON text exactly as the Swift CLI prints it.
//!
//! `pretty` is `JSONEncoder` with `.prettyPrinted, .sortedKeys,
//! .withoutEscapingSlashes` (the CLI's `emitJSON`): `"key" : value`, two-space
//! indent, empty containers as `[` blank line `]`. `compact` is the MCP result
//! encoding (`.sortedKeys` only), which also escapes `/`. Both print a
//! whole-number `Double` without a fraction (`2`, not `2.0`) and switch to
//! exponent form above 2^53 or below 1e-4 (`1e+16`, `1e-05`). Object keys come
//! out sorted because `serde_json::Map` is a `BTreeMap` here.

use serde_json::{Number, Value};

/// A `Double` the way Swift's encoder writes it. Non-finite numbers cannot
/// occur in a `serde_json::Value`.
fn float(f: f64) -> String {
    if f == 0.0 {
        return if f.is_sign_negative() { "-0" } else { "0" }.into();
    }
    let magnitude = f.abs();
    if !(1e-4..=9_007_199_254_740_992.0).contains(&magnitude) {
        // Rust prints `1.5e-7`; Swift prints `1.5e-07` / `1e+16`.
        let text = format!("{f:e}");
        let (mantissa, exponent) = text.split_once('e').unwrap_or((&text, "0"));
        let exponent: i32 = exponent.parse().unwrap_or(0);
        return format!(
            "{mantissa}e{}{:02}",
            if exponent < 0 { '-' } else { '+' },
            exponent.abs()
        );
    }
    // Shortest round-trip digits; whole numbers lose the ".0" like Swift's.
    format!("{f}")
}

fn number(n: &Number) -> String {
    if n.is_f64() {
        float(n.as_f64().unwrap_or(0.0))
    } else {
        n.to_string()
    }
}

fn string(s: &str, escape_slash: bool, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '/' if escape_slash => out.push_str("\\/"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

fn write(value: &Value, pretty: bool, depth: usize, out: &mut String) {
    let indent = |n: usize, out: &mut String| out.push_str(&"  ".repeat(n));
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => out.push_str(&number(n)),
        Value::String(s) => string(s, !pretty, out),
        Value::Array(items) => {
            out.push('[');
            if pretty {
                out.push('\n');
                if items.is_empty() {
                    out.push('\n');
                }
            }
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push_str(if pretty { ",\n" } else { "," });
                }
                if pretty {
                    indent(depth + 1, out);
                }
                write(item, pretty, depth + 1, out);
            }
            if pretty {
                if !items.is_empty() {
                    out.push('\n');
                }
                indent(depth, out);
            }
            out.push(']');
        }
        Value::Object(map) => {
            out.push('{');
            if pretty {
                out.push('\n');
                if map.is_empty() {
                    out.push('\n');
                }
            }
            for (i, (key, item)) in map.iter().enumerate() {
                if i > 0 {
                    out.push_str(if pretty { ",\n" } else { "," });
                }
                if pretty {
                    indent(depth + 1, out);
                }
                string(key, !pretty, out);
                out.push_str(if pretty { " : " } else { ":" });
                write(item, pretty, depth + 1, out);
            }
            if pretty {
                if !map.is_empty() {
                    out.push('\n');
                }
                indent(depth, out);
            }
            out.push('}');
        }
    }
}

/// `emitJSON` without the trailing newline.
pub fn pretty(value: &Value) -> String {
    let mut out = String::new();
    write(value, true, 0, &mut out);
    out
}

/// The MCP tool-result encoding.
pub fn compact(value: &Value) -> String {
    let mut out = String::new();
    write(value, false, 0, &mut out);
    out
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    // Expected strings are the output of Swift's JSONEncoder for the same
    // values (probe run with the toolchain that builds v0.12).
    #[test]
    fn floats_follow_swift_description() {
        for (f, want) in [
            (1.0, "1"),
            (2.5, "2.5"),
            (0.1, "0.1"),
            (100_000.0, "100000"),
            (9_007_199_254_740_992.0, "9007199254740992"),
            (9_007_199_254_740_994.0, "9.007199254740994e+15"),
            (1e16, "1e+16"),
            (1e-5, "1e-05"),
            (0.0001, "0.0001"),
            (0.000_123_45, "0.00012345"),
            (1.2345678901234568e17, "1.2345678901234568e+17"),
            (1.5e300, "1.5e+300"),
            (5e-324, "5e-324"),
            (-0.0, "-0"),
            (-2.0, "-2"),
            (f64::from(1.2_f32), "1.2000000476837158"),
            (123_456_789_012_345.0, "123456789012345"),
        ] {
            assert_eq!(float(f), want, "{f:e}");
        }
    }

    #[test]
    fn pretty_matches_the_swift_layout() {
        let v = json!({"b": [], "a": {"k": [1, 2.0], "e": {}}, "s": "x/y \"q\" \u{1}é", "n": null, "t": true, "i": 12_345_678_901_234_i64, "u": u64::MAX});
        let want = "{\n  \"a\" : {\n    \"e\" : {\n\n    },\n    \"k\" : [\n      1,\n      2\n    ]\n  },\n  \"b\" : [\n\n  ],\n  \"i\" : 12345678901234,\n  \"n\" : null,\n  \"s\" : \"x/y \\\"q\\\" \\u0001é\",\n  \"t\" : true,\n  \"u\" : 18446744073709551615\n}";
        assert_eq!(pretty(&v), want);
        assert_eq!(pretty(&json!([])), "[\n\n]");
        assert_eq!(pretty(&json!({})), "{\n\n}");
    }

    #[test]
    fn compact_sorts_keys_and_escapes_slashes_like_the_mcp_encoder() {
        let v = json!({"z": 1.0, "a": ["a/b", {"d": 1e-5}], "e": [], "o": {}});
        assert_eq!(
            compact(&v),
            "{\"a\":[\"a\\/b\",{\"d\":1e-05}],\"e\":[],\"o\":{},\"z\":1}"
        );
        // Control characters and non-ASCII follow the probe: \u001f lowercase, DEL and U+2028 raw.
        assert_eq!(
            compact(&json!("\u{1f}\u{7f}\u{2028}\u{8}\u{c}\t\n\r\\ \"é😀")),
            "\"\\u001f\u{7f}\u{2028}\\b\\f\\t\\n\\r\\\\ \\\"é😀\""
        );
    }

    #[test]
    fn pretty_matches_the_real_cli_version_report() {
        // Same bytes as the `version --json` string in lib.rs (families empty).
        let v = json!({"families": [], "schema_version": 1, "tool": "symcockpit", "update": {"status": "skipped", "update_available": false}, "version": "0.12.2"});
        assert_eq!(
            pretty(&v),
            "{\n  \"families\" : [\n\n  ],\n  \"schema_version\" : 1,\n  \"tool\" : \"symcockpit\",\n  \"update\" : {\n    \"status\" : \"skipped\",\n    \"update_available\" : false\n  },\n  \"version\" : \"0.12.2\"\n}"
        );
    }
}
