//! What only the human may do with the history (R73, D13): list, read, copy back, delete one
//! item, change the settings. Reachable from the app agent's own methods and nowhere else:
//! there is no register command, CLI path or MCP tool for any of it, so none of it prints a
//! clip outside the app.

use serde_json::{Map, Value, json};
use symcockpit_contract::Error;

use super::{
    ClipStore, ClipboardSettings, KeyStore, Kind, PasteboardSink, Payload, SettingsStore, open_item,
};

/// Metadata only: ids, time, kind and size. Never content, never the source app.
pub fn clip_list_json(store: &dyn ClipStore, limit: usize) -> Result<Value, Error> {
    let items: Vec<Value> = store
        .list(limit.clamp(1, 1000))?
        .into_iter()
        .map(|m| {
            json!({"id": m.id, "created_at": m.created_at, "kind": m.kind.name(), "size": m.size})
        })
        .collect();
    Ok(json!({"count": items.len(), "items": items}))
}

/// RFC 4648 base64 with padding (images travel as JSON strings).
pub fn base64(data: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let n = chunk
            .iter()
            .enumerate()
            .fold(0u32, |n, (i, b)| n | (u32::from(*b) << (16 - 8 * i)));
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

fn gone(id: &str) -> Error {
    Error::Failed(format!(
        "clipboard item {id} is gone or can no longer be opened"
    ))
}

/// One item with its content, decrypted. Text as `text`, images as `png_base64`.
pub fn clip_read_json(
    keys: &dyn KeyStore,
    store: &dyn ClipStore,
    id: &str,
) -> Result<Value, Error> {
    let meta = store.meta(id)?.ok_or_else(|| gone(id))?;
    let clip = open_item(keys, store, &meta)?.ok_or_else(|| gone(id))?;
    let mut out = json!({
        "id": meta.id, "created_at": meta.created_at, "kind": meta.kind.name(),
        "size": meta.size, "source": clip.source,
    });
    match clip.payload {
        Payload::Text(text) => out["text"] = json!(text),
        Payload::Png(png) => out["png_base64"] = json!(base64(&png)),
    }
    Ok(out)
}

/// Writes the item back to the pasteboard. Returns the pasteboard's new change count.
pub fn clip_copy_back(
    keys: &dyn KeyStore,
    store: &dyn ClipStore,
    sink: &dyn PasteboardSink,
    id: &str,
) -> Result<i64, Error> {
    let meta = store.meta(id)?.ok_or_else(|| gone(id))?;
    let clip = open_item(keys, store, &meta)?.ok_or_else(|| gone(id))?;
    match (meta.kind, &clip.payload) {
        (Kind::Text, Payload::Text(text)) => sink.write_text(text),
        (Kind::Image, Payload::Png(png)) => sink.write_png(png),
        _ => Err(gone(id)),
    }
}

/// Deletes one item: metadata and attachment.
pub fn clip_delete_json(store: &dyn ClipStore, id: &str) -> Result<Value, Error> {
    Ok(json!({"id": id, "deleted": store.delete(id)?}))
}

pub fn settings_json(settings: &dyn SettingsStore) -> Result<Value, Error> {
    Ok(settings.load()?.to_json())
}

fn usage(key: &str, expected: &str) -> Error {
    Error::Usage(format!("clipboard settings: '{key}' must be {expected}"))
}

/// Applies a partial update (`enabled`, `paused`, `excluded_apps`, `max_items`,
/// `max_age_secs`, `max_item_bytes`) after checking every type, then saves. Unknown keys are
/// refused: a typo must not silently leave the feature in the wrong state.
pub fn update_settings(
    settings: &dyn SettingsStore,
    patch: &Map<String, Value>,
) -> Result<ClipboardSettings, Error> {
    let mut merged = settings.load()?.to_json();
    for (key, value) in patch {
        let ok = match key.as_str() {
            "enabled" | "paused" => value.is_boolean(),
            "excluded_apps" => value
                .as_array()
                .is_some_and(|a| a.iter().all(Value::is_string)),
            "max_items" | "max_age_secs" | "max_item_bytes" => value.as_u64().is_some(),
            _ => {
                return Err(Error::Usage(format!(
                    "clipboard settings: unknown key '{key}'"
                )));
            }
        };
        if !ok {
            return Err(usage(
                key,
                match key.as_str() {
                    "enabled" | "paused" => "true or false",
                    "excluded_apps" => "a list of bundle ids",
                    _ => "a non-negative whole number",
                },
            ));
        }
        merged[key] = value.clone();
    }
    let updated = ClipboardSettings::from_json(&merged);
    settings.save(&updated)?;
    Ok(updated)
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;

    use super::*;

    #[test]
    fn base64_matches_the_rfc_4648_vectors() {
        for (plain, coded) in [
            ("", ""),
            ("f", "Zg=="),
            ("fo", "Zm8="),
            ("foo", "Zm9v"),
            ("foob", "Zm9vYg=="),
            ("fooba", "Zm9vYmE="),
            ("foobar", "Zm9vYmFy"),
        ] {
            assert_eq!(base64(plain.as_bytes()), coded, "{plain:?}");
        }
        assert_eq!(base64(&[0xfb, 0xff, 0xfe]), "+//+");
    }

    #[derive(Default)]
    struct Memory(RefCell<ClipboardSettings>);

    impl SettingsStore for Memory {
        fn load(&self) -> Result<ClipboardSettings, Error> {
            Ok(self.0.borrow().clone())
        }
        fn save(&self, s: &ClipboardSettings) -> Result<(), Error> {
            *self.0.borrow_mut() = s.clone();
            Ok(())
        }
    }

    fn patch(v: Value) -> Map<String, Value> {
        v.as_object().unwrap().clone()
    }

    #[test]
    fn a_settings_update_is_validated_merged_and_saved() {
        let store = Memory::default();
        assert!(!settings_json(&store).unwrap()["enabled"].as_bool().unwrap());
        let s = update_settings(
            &store,
            &patch(json!({"enabled": true, "max_items": 7, "excluded_apps": ["a.b"]})),
        )
        .unwrap();
        assert!(s.enabled && s.capturing());
        assert_eq!(
            (s.max_items, s.excluded_apps.clone()),
            (7, vec!["a.b".to_owned()])
        );
        assert_eq!(*store.0.borrow(), s);
        // Untouched keys stay as they were.
        let s = update_settings(&store, &patch(json!({"paused": true}))).unwrap();
        assert!(s.enabled && s.paused && s.max_items == 7);
    }

    #[test]
    fn bad_types_and_unknown_keys_change_nothing() {
        let store = Memory::default();
        for bad in [
            json!({"enabled": "yes"}),
            json!({"enabled": 1}),
            json!({"max_items": -1}),
            json!({"excluded_apps": [1]}),
            json!({"enabld": true}),
        ] {
            let err = update_settings(&store, &patch(bad.clone())).unwrap_err();
            assert!(matches!(err, Error::Usage(_)), "{bad}");
        }
        assert_eq!(*store.0.borrow(), ClipboardSettings::default());
    }
}
