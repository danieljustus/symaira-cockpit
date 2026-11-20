//! JSON "shapes": the type structure of a value without its data.
//!
//! `{"type":"object","properties":{k:Shape}}`, `{"type":"array","items":Shape|null}`
//! or `{"type":"string"|"number"|"boolean"|"null"}`. Integers and floats are
//! both `number`.

use serde_json::{Map, Value, json};

/// Findings of a comparison: `errors` fail a case, `hints` are tolerated drift.
#[derive(Debug, Default, PartialEq)]
pub struct Diff {
    pub errors: Vec<String>,
    pub hints: Vec<String>,
}

/// Derive the shape of a JSON value. Array elements are merged into one item shape.
pub fn derive(value: &Value) -> Result<Value, String> {
    Ok(match value {
        Value::Null => json!({"type": "null"}),
        Value::Bool(_) => json!({"type": "boolean"}),
        Value::Number(_) => json!({"type": "number"}),
        Value::String(_) => json!({"type": "string"}),
        Value::Array(items) => {
            let mut merged = Value::Null;
            for item in items {
                merged = merge(&merged, &derive(item)?)?;
            }
            json!({"type": "array", "items": merged})
        }
        Value::Object(map) => {
            let mut properties = Map::new();
            for (key, item) in map {
                properties.insert(key.clone(), derive(item)?);
            }
            json!({"type": "object", "properties": properties})
        }
    })
}

fn kind(shape: &Value) -> &str {
    shape["type"].as_str().unwrap_or("?")
}

/// Merge two shapes; `Null` (no shape yet) and `{"type":"null"}` yield to the other side.
fn merge(a: &Value, b: &Value) -> Result<Value, String> {
    if a.is_null() || kind(a) == "null" {
        return Ok(b.clone());
    }
    if b.is_null() || kind(b) == "null" {
        return Ok(a.clone());
    }
    if kind(a) != kind(b) {
        return Err(format!("array mixes {} and {}", kind(a), kind(b)));
    }
    Ok(match kind(a) {
        "object" => {
            let mut properties = a["properties"].as_object().cloned().unwrap_or_default();
            for (key, shape) in b["properties"].as_object().into_iter().flatten() {
                let merged = match properties.get(key) {
                    Some(existing) => merge(existing, shape)?,
                    None => shape.clone(),
                };
                properties.insert(key.clone(), merged);
            }
            json!({"type": "object", "properties": properties})
        }
        "array" => json!({"type": "array", "items": merge(&a["items"], &b["items"])?}),
        _ => a.clone(),
    })
}

/// Compare an expected (fixture) shape with the actual one.
pub fn compare(expected: &Value, actual: &Value) -> Diff {
    let mut diff = Diff::default();
    walk(expected, actual, "$", &mut diff);
    diff
}

fn walk(expected: &Value, actual: &Value, path: &str, diff: &mut Diff) {
    let (e, a) = (kind(expected), kind(actual));
    if e == "null" || a == "null" {
        if e != a {
            diff.hints
                .push(format!("{path}: null on one side (expected {e}, got {a})"));
        }
        return;
    }
    if e != a {
        diff.errors
            .push(format!("{path}: expected type {e}, got {a}"));
        return;
    }
    match e {
        "object" => {
            let empty = Map::new();
            let ep = expected["properties"].as_object().unwrap_or(&empty);
            let ap = actual["properties"].as_object().unwrap_or(&empty);
            for key in ep.keys().filter(|k| !ap.contains_key(*k)) {
                diff.errors.push(format!("{path}: missing key '{key}'"));
            }
            for key in ap.keys().filter(|k| !ep.contains_key(*k)) {
                diff.errors.push(format!("{path}: unexpected key '{key}'"));
            }
            for (key, shape) in ep {
                if let Some(other) = ap.get(key) {
                    walk(shape, other, &format!("{path}.{key}"), diff);
                }
            }
        }
        "array" if !expected["items"].is_null() && !actual["items"].is_null() => {
            walk(
                &expected["items"],
                &actual["items"],
                &format!("{path}[]"),
                diff,
            );
        }
        _ => {}
    }
}

/// Deep JSON equality that treats numbers by value (`1` equals `1.0`); reports each difference.
pub fn equal(expected: &Value, actual: &Value) -> Vec<String> {
    let mut errors = Vec::new();
    equal_at(expected, actual, "$", &mut errors);
    errors
}

fn equal_at(expected: &Value, actual: &Value, path: &str, errors: &mut Vec<String>) {
    match (expected, actual) {
        (Value::Object(e), Value::Object(a)) => {
            for key in e.keys().filter(|k| !a.contains_key(*k)) {
                errors.push(format!("{path}: missing key '{key}'"));
            }
            for key in a.keys().filter(|k| !e.contains_key(*k)) {
                errors.push(format!("{path}: unexpected key '{key}'"));
            }
            for (key, value) in e {
                if let Some(other) = a.get(key) {
                    equal_at(value, other, &format!("{path}.{key}"), errors);
                }
            }
        }
        (Value::Array(e), Value::Array(a)) => {
            if e.len() != a.len() {
                errors.push(format!(
                    "{path}: expected {} items, got {}",
                    e.len(),
                    a.len()
                ));
            }
            for (i, (x, y)) in e.iter().zip(a).enumerate() {
                equal_at(x, y, &format!("{path}[{i}]"), errors);
            }
        }
        (Value::Number(e), Value::Number(a)) if e.as_f64() == a.as_f64() => {}
        _ if expected == actual => {}
        _ => errors.push(format!("{path}: expected {expected}, got {actual}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shape(value: Value) -> Value {
        derive(&value).unwrap()
    }

    #[test]
    fn derives_and_merges_array_items() {
        let s = shape(json!({"a": [1, 2.5], "b": [{"x": 1}, {"y": "s"}], "c": [], "d": null}));
        assert_eq!(
            s["properties"]["a"],
            json!({"type": "array", "items": {"type": "number"}})
        );
        assert_eq!(s["properties"]["c"]["items"], Value::Null);
        assert_eq!(s["properties"]["d"], json!({"type": "null"}));
        let b = &s["properties"]["b"]["items"]["properties"];
        assert!(b.get("x").is_some() && b.get("y").is_some());
        assert!(derive(&json!([1, "a"])).is_err());
    }

    #[test]
    fn identical_shapes_have_no_findings() {
        let s = shape(json!({"a": 1, "b": [true]}));
        assert_eq!(compare(&s, &s), Diff::default());
    }

    #[test]
    fn missing_extra_and_wrong_type_are_errors() {
        let expected = shape(json!({"a": 1, "b": "x"}));
        let missing = compare(&expected, &shape(json!({"a": 1})));
        assert_eq!(missing.errors, ["$: missing key 'b'"]);
        let extra = compare(&expected, &shape(json!({"a": 1, "b": "x", "c": 0})));
        assert_eq!(extra.errors, ["$: unexpected key 'c'"]);
        let wrong = compare(&expected, &shape(json!({"a": "1", "b": "x"})));
        assert_eq!(wrong.errors, ["$.a: expected type number, got string"]);
        let nested = compare(
            &shape(json!({"l": [{"k": 1}]})),
            &shape(json!({"l": [{"k": true}]})),
        );
        assert_eq!(
            nested.errors,
            ["$.l[].k: expected type number, got boolean"]
        );
    }

    #[test]
    fn null_and_empty_arrays_are_tolerated() {
        let with_value = shape(json!({"a": 1, "l": [1]}));
        let relaxed = shape(json!({"a": null, "l": []}));
        for diff in [
            compare(&with_value, &relaxed),
            compare(&relaxed, &with_value),
        ] {
            assert!(diff.errors.is_empty(), "{:?}", diff.errors);
        }
        assert_eq!(compare(&with_value, &relaxed).hints.len(), 1);
    }

    #[test]
    fn integers_and_floats_are_both_numbers() {
        assert_eq!(
            compare(&shape(json!(1)), &shape(json!(1.5))),
            Diff::default()
        );
    }

    #[test]
    fn equal_compares_numbers_by_value_and_reports_differences() {
        assert!(equal(&json!({"m": 1, "t": [0.5]}), &json!({"m": 1.0, "t": [0.5]})).is_empty());
        assert_eq!(
            equal(&json!({"m": 1}), &json!({"m": 2})),
            ["$.m: expected 1, got 2"]
        );
        assert_eq!(
            equal(&json!([1, 2]), &json!([1])),
            ["$: expected 2 items, got 1"]
        );
        assert_eq!(equal(&json!({"a": 1}), &json!({"b": 1})).len(), 2);
    }
}
