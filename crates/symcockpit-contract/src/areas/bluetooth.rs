//! Bluetooth commands (R50 to R53). [`specs`] joins the register through [`super::all`].

use serde_json::json;

use crate::{CommandSpec, Risk};

const AREA: &str = "bluetooth";

fn object(properties: serde_json::Value, required: &[&str]) -> serde_json::Value {
    json!({"type": "object", "properties": properties, "required": required})
}

fn gatt_address() -> serde_json::Value {
    json!({
        "device_id": {"type": "string", "description": "Peripheral id from scan_ble."},
        "service": {"type": "string", "description": "Service UUID (4, 8 or 36 characters)."},
        "characteristic": {"type": "string", "description": "Characteristic UUID."}
    })
}

pub fn specs() -> Vec<CommandSpec> {
    let spec = |name, cli_path, mcp_name, risk, input_schema| CommandSpec {
        name,
        cli_path,
        mcp_name,
        area: AREA,
        risk,
        input_schema,
    };
    let mut write_props = gatt_address();
    write_props["value_hex"] =
        json!({"type": "string", "description": "Bytes to write as hex, 1 to 512 bytes."});
    write_props["with_response"] = json!({
        "type": "boolean",
        "description": "Write with response (default true): the peripheral acknowledges."
    });
    vec![
        spec(
            "bt.devices",
            "bt devices",
            Some("list_bluetooth_devices"),
            Risk::Read,
            object(json!({}), &[]),
        ),
        spec(
            "ble.scan",
            "ble scan",
            Some("scan_ble"),
            Risk::Read,
            object(
                json!({
                    "timeout_seconds": {"type": "number", "minimum": 1, "maximum": 30,
                        "description": "Scan duration (default 5)."},
                    "filter": {"type": "string",
                        "description": "Shows only devices whose name, id or service matches. Never disconnects."}
                }),
                &[],
            ),
        ),
        spec(
            "ble.read",
            "ble read",
            Some("read_ble_characteristic"),
            Risk::Read,
            object(gatt_address(), &["device_id", "service", "characteristic"]),
        ),
        // Streams until its time limit: CLI only.
        spec(
            "ble.subscribe",
            "ble subscribe",
            None,
            Risk::Read,
            object(json!({}), &[]),
        ),
        spec(
            "ble.write",
            "ble write",
            Some("plan_ble_write"),
            Risk::Risky,
            object(
                write_props,
                &["device_id", "service", "characteristic", "value_hex"],
            ),
        ),
        // Raw logs leave the machine only when a human asks (Q08).
        spec(
            "ble.export",
            "ble export",
            None,
            Risk::Read,
            object(json!({}), &[]),
        ),
    ]
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::*;
    use crate::commands;

    #[test]
    fn mcp_surface_is_exactly_the_four_agreed_tools() {
        let tools: Vec<_> = specs()
            .into_iter()
            .filter_map(|s| s.mcp_name.map(|m| (m, s.risk)))
            .collect();
        assert_eq!(
            tools,
            [
                ("list_bluetooth_devices", Risk::Read),
                ("scan_ble", Risk::Read),
                ("read_ble_characteristic", Risk::Read),
                ("plan_ble_write", Risk::Risky),
            ]
        );
    }

    #[test]
    fn writing_is_risky_and_reaches_agents_only_as_a_plan() {
        let write = specs().into_iter().find(|s| s.name == "ble.write").unwrap();
        assert_eq!(write.risk, Risk::Risky);
        assert!(write.mcp_name.unwrap().starts_with("plan_"));
    }

    #[test]
    fn schemas_declare_their_required_properties() {
        for s in specs() {
            assert_eq!(s.input_schema["type"], "object");
            for r in s.input_schema["required"].as_array().unwrap() {
                assert!(
                    s.input_schema["properties"]
                        .get(r.as_str().unwrap())
                        .is_some()
                );
            }
        }
    }
}
