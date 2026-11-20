//! Paired devices and battery levels from `system_profiler SPBluetoothDataType`.
//!
//! Apple's own binary carries the `com.apple.bluetooth.system` entitlement, so
//! this read needs no Bluetooth permission and shows no dialog (checked with
//! `codesign` on macOS 27.2.1).

use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use symcockpit_contract::Error;
use symcockpit_core::bluetooth::{PairedDevice, PairedDevices, parse_system_profiler};

const SYSTEM_PROFILER: &str = "/usr/sbin/system_profiler";
const TIMEOUT: Duration = Duration::from_secs(20);

pub struct SystemProfiler;

impl PairedDevices for SystemProfiler {
    fn paired(&self) -> Result<Vec<PairedDevice>, Error> {
        let out = run_bounded(
            Command::new(SYSTEM_PROFILER).args(["SPBluetoothDataType", "-json"]),
            TIMEOUT,
        )?;
        let root = serde_json::from_slice(&out)
            .map_err(|e| Error::Failed(format!("system_profiler output is not JSON: {e}")))?;
        parse_system_profiler(&root)
    }
}

/// Runs `command` with a fixed path and argument list (no shell) and returns
/// its stdout; kills it when `timeout` passes.
fn run_bounded(command: &mut Command, timeout: Duration) -> Result<Vec<u8>, Error> {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| Error::Failed(format!("cannot start {:?}: {e}", command.get_program())))?;
    let mut stdout = child.stdout.take().expect("stdout is piped");
    let reader = std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = stdout.read_to_end(&mut buf);
        buf
    });
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let out = reader.join().unwrap_or_default();
                return if status.success() {
                    Ok(out)
                } else {
                    Err(Error::Failed(format!(
                        "system_profiler exited with {status}"
                    )))
                };
            }
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(25)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(Error::Failed("system_profiler timed out".into()));
            }
            Err(e) => return Err(Error::Failed(format!("system_profiler: {e}"))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_hanging_command_is_killed_at_the_timeout() {
        let started = Instant::now();
        let err = run_bounded(
            Command::new("/bin/sleep").arg("30"),
            Duration::from_millis(200),
        )
        .unwrap_err();
        assert!(err.to_string().contains("timed out"));
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn output_is_returned_on_success_and_failure_is_an_error() {
        let out = run_bounded(Command::new("/bin/echo").arg("hi"), Duration::from_secs(5)).unwrap();
        assert_eq!(out, b"hi\n");
        assert!(run_bounded(&mut Command::new("/usr/bin/false"), Duration::from_secs(5)).is_err());
    }

    /// Reads this Mac's paired devices once. Prints counts only, never names.
    #[test]
    #[ignore = "reads the real Bluetooth device list"]
    fn live_paired_devices_parse() {
        let devices = SystemProfiler.paired().unwrap();
        let unknown = devices
            .iter()
            .filter(|d| d.battery.main == symcockpit_core::bluetooth::Level::Unknown)
            .count();
        println!(
            "live: {} paired, {} connected, {} with unknown main battery",
            devices.len(),
            devices.iter().filter(|d| d.connected).count(),
            unknown
        );
        let json = symcockpit_core::bluetooth::bt_devices_json(&SystemProfiler).unwrap();
        assert_eq!(json["count"], devices.len());
    }
}
