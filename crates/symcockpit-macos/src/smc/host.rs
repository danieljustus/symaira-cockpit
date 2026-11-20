//! Host facts for the sensor report: thermal pressure and chip generation.

use objc2_foundation::{NSProcessInfo, NSProcessInfoThermalState};
use symcockpit_core::sensors::{ChipGeneration, SensorHost};

/// `ProcessInfo.thermalState` and `machdep.cpu.brand_string`.
pub struct LiveHost;

impl SensorHost for LiveHost {
    fn thermal_pressure(&self) -> &'static str {
        let state = NSProcessInfo::processInfo().thermalState();
        if state == NSProcessInfoThermalState::Nominal {
            "nominal"
        } else if state == NSProcessInfoThermalState::Fair {
            "fair"
        } else if state == NSProcessInfoThermalState::Serious {
            "serious"
        } else if state == NSProcessInfoThermalState::Critical {
            "critical"
        } else {
            "unknown"
        }
    }

    fn chip_generation(&self) -> ChipGeneration {
        brand_string()
            .and_then(|b| ChipGeneration::from_brand_string(&b))
            .unwrap_or(ChipGeneration::Unknown)
    }
}

fn brand_string() -> Option<String> {
    let name = c"machdep.cpu.brand_string";
    let mut size = 0usize;
    // SAFETY: a null buffer asks sysctl for the required size; `size` is a valid out-pointer.
    let rc = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            std::ptr::null_mut(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if rc != 0 || size == 0 {
        return None;
    }
    let mut buffer = vec![0u8; size];
    // SAFETY: `buffer` is `size` bytes long and `size` tells sysctl so.
    let rc = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            buffer.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if rc != 0 {
        return None;
    }
    // The value is NUL-terminated: stop at the first NUL.
    let end = buffer.iter().position(|&b| b == 0).unwrap_or(buffer.len());
    String::from_utf8(buffer[..end].to_vec()).ok()
}
