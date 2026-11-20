//! One `*_json` function per CLI/MCP command; the CLI prints the value for
//! `--json`, MCP returns it as the tool result.

use std::time::Duration;

use serde_json::{Value, json};
use symcockpit_contract::Error;

use super::ble::{BleCentral, ScanFilter, normalize_uuid};
use super::devices::PairedDevices;
use super::log::{BleLog, ExportFormat, LogKind, export_csv, export_json};
use super::write::{BleWriteAction, WriteReport, WriteRequest, to_hex};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// `symcockpit bt devices` / MCP `list_bluetooth_devices`.
pub fn bt_devices_json(source: &dyn PairedDevices) -> Result<Value, Error> {
    let devices = source.paired()?;
    Ok(json!({"count": devices.len(), "devices": devices}))
}

/// `symcockpit ble scan` / MCP `scan_ble`. The filter only selects what is
/// shown: `total_seen` counts everything the radio reported.
pub fn ble_scan_json(
    central: &dyn BleCentral,
    log: &mut BleLog,
    timeout: Duration,
    filter: &ScanFilter,
) -> Result<Value, Error> {
    let seen = central.scan(timeout)?;
    for ad in &seen {
        let rssi = ad
            .rssi
            .map_or_else(|| "rssi unknown".to_owned(), |r| format!("rssi {r}"));
        log.record(LogKind::Seen, &ad.id, "", "", &[], &rssi);
    }
    let shown: Vec<_> = seen.iter().filter(|a| filter.matches(a)).collect();
    Ok(json!({
        "timeout_ms": timeout.as_millis() as u64,
        "total_seen": seen.len(),
        "shown": shown.len(),
        "devices": shown,
    }))
}

/// `symcockpit ble read <device>`: the GATT tree.
pub fn ble_services_json(
    central: &dyn BleCentral,
    log: &mut BleLog,
    device_id: &str,
) -> Result<Value, Error> {
    let link = central.connect(device_id, CONNECT_TIMEOUT)?;
    log.record(LogKind::Connect, device_id, "", "", &[], "");
    let services = link.services();
    link.disconnect();
    log.record(LogKind::Disconnect, device_id, "", "", &[], "");
    let services = services?;
    Ok(json!({"device_id": device_id, "services": services}))
}

/// `symcockpit ble read <device> <service> <characteristic>` / MCP `read_ble_characteristic`.
pub fn ble_read_json(
    central: &dyn BleCentral,
    log: &mut BleLog,
    device_id: &str,
    service: &str,
    characteristic: &str,
    timeout: Duration,
) -> Result<Value, Error> {
    let (service, characteristic) = (normalize_uuid(service)?, normalize_uuid(characteristic)?);
    let link = central.connect(device_id, timeout)?;
    log.record(LogKind::Connect, device_id, "", "", &[], "");
    let value = link.read(&service, &characteristic);
    link.disconnect();
    log.record(LogKind::Disconnect, device_id, "", "", &[], "");
    let value = match value {
        Ok(v) => v,
        Err(e) => {
            log.record(
                LogKind::Error,
                device_id,
                &service,
                &characteristic,
                &[],
                &e.to_string(),
            );
            return Err(e);
        }
    };
    log.record(
        LogKind::Read,
        device_id,
        &service,
        &characteristic,
        &value,
        "",
    );
    Ok(json!({
        "device_id": device_id,
        "service": service,
        "characteristic": characteristic,
        "length": value.len(),
        "value_hex": to_hex(&value),
    }))
}

/// `symcockpit ble subscribe ...`: foreground, ends after `window`.
pub fn ble_subscribe_json(
    central: &dyn BleCentral,
    log: &mut BleLog,
    device_id: &str,
    service: &str,
    characteristic: &str,
    window: Duration,
) -> Result<Value, Error> {
    let (service, characteristic) = (normalize_uuid(service)?, normalize_uuid(characteristic)?);
    let link = central.connect(device_id, CONNECT_TIMEOUT)?;
    log.record(LogKind::Connect, device_id, "", "", &[], "");
    let mut values = Vec::new();
    let result = link.subscribe(&service, &characteristic, window, &mut |n| {
        log.record(
            LogKind::Notify,
            device_id,
            &service,
            &characteristic,
            &n.value,
            &format!("+{} ms", n.elapsed_ms),
        );
        values.push(json!({"elapsed_ms": n.elapsed_ms, "length": n.value.len(), "value_hex": to_hex(&n.value)}));
    });
    link.disconnect();
    log.record(LogKind::Disconnect, device_id, "", "", &[], "");
    result?;
    Ok(json!({
        "device_id": device_id,
        "service": service,
        "characteristic": characteristic,
        "window_ms": window.as_millis() as u64,
        "count": values.len(),
        "notifications": values,
    }))
}

/// MCP `plan_ble_write`: validates and describes the write; touches no device.
pub fn plan_ble_write_json(request: &WriteRequest) -> Result<Value, Error> {
    Ok(json!({
        "risk": "risky",
        "state": "requested",
        "item": request.to_plan_item(),
        "steps": ["request", "sent", "acknowledged", "readback"],
    }))
}

/// `symcockpit ble write ...` after confirmation (TTY prompt or plan).
pub fn ble_write_json(
    action: &dyn BleWriteAction,
    log: &mut BleLog,
    request: &WriteRequest,
) -> Result<Value, Error> {
    let (d, s, c) = (
        &request.device_id,
        &request.service,
        &request.characteristic,
    );
    log.record(LogKind::WriteRequested, d, s, c, &request.value, "");
    let report: WriteReport = action.execute(request)?;
    for stage in &report.stages {
        match (stage.stage, stage.status) {
            (super::WriteStage::Acknowledged, "ok") => {
                log.record(LogKind::WriteAcknowledged, d, s, c, &[], "");
            }
            (super::WriteStage::Readback, "ok" | "failed") => {
                let bytes = report.readback.as_deref().unwrap_or_default();
                log.record(LogKind::WriteReadback, d, s, c, bytes, &stage.detail);
            }
            (_, "failed") => log.record(LogKind::Error, d, s, c, &[], &stage.detail),
            _ => {}
        }
    }
    Ok(report.to_json())
}

/// `symcockpit ble export --format csv|json`: only on explicit request (Q08).
pub fn ble_export_json(log: &BleLog, format: ExportFormat) -> Result<Value, Error> {
    Ok(match format {
        ExportFormat::Csv => {
            json!({"format": "csv", "count": log.len(), "content": export_csv(log)})
        }
        ExportFormat::Json => {
            let mut doc = export_json(log);
            doc["format"] = json!("json");
            doc["count"] = json!(log.len());
            doc
        }
    })
}
