//! Bluetooth adapters: paired devices via `system_profiler`, BLE via CoreBluetooth.

mod central;
mod profiler;

pub use central::CoreBluetoothCentral;
pub use profiler::SystemProfiler;
