//! Bluetooth (R50 to R53): paired devices with battery, BLE explorer, log export.
//!
//! Pure logic behind ports. Platform adapters live in `symcockpit-macos`,
//! fakes in `symcockpit-testkit`. Nothing here touches hardware.

mod ble;
mod commands;
mod devices;
mod log;
mod write;

pub use ble::{
    Advertisement, BleCentral, BleLink, Characteristic, Notification, ScanFilter, Service,
    WriteAck, normalize_uuid,
};
pub use commands::{
    ble_export_json, ble_read_json, ble_scan_json, ble_services_json, ble_subscribe_json,
    ble_write_json, bt_devices_json, plan_ble_write_json,
};
pub use devices::{Battery, Level, PairedDevice, PairedDevices, parse_system_profiler};
pub use log::{BleLog, ExportFormat, LogEntry, LogKind, export_csv, export_json};
pub use write::{
    AckState, BLE_WRITE_KIND, BlePlanAction, BleWriteAction, LinkWriteAction, StageRecord,
    WriteReport, WriteRequest, WriteStage, from_hex, item_result, to_hex, write_on_link,
};
