//! Per-interface byte counters via `getifaddrs`.
//! Port of `readNetwork()` in `SystemMetricsSource.swift`.

use std::collections::BTreeMap;
use std::ffi::CStr;

use symcockpit_core::metrics::NetworkInterfaceStatistics;

/// Cumulative bytes per interface, merged by name and sorted by name.
/// The kernel's counters are 32-bit (`if_data`), as in Swift; they wrap at 4 GiB.
pub fn read_network() -> Vec<NetworkInterfaceStatistics> {
    let mut list: *mut libc::ifaddrs = std::ptr::null_mut();
    // SAFETY: `list` is a valid out-pointer; on success it owns a list freed below.
    if unsafe { libc::getifaddrs(&mut list) } != 0 || list.is_null() {
        return Vec::new();
    }
    let mut merged: BTreeMap<String, (u64, u64)> = BTreeMap::new();
    let mut current = list;
    while !current.is_null() {
        // SAFETY: `current` is a node of the list returned by getifaddrs, alive until freeifaddrs.
        let entry = unsafe { &*current };
        // SAFETY: for AF_LINK entries `ifa_data` points to an `if_data`, and `ifa_name` is NUL-terminated.
        let link = !entry.ifa_addr.is_null()
            && !entry.ifa_data.is_null()
            && unsafe { (*entry.ifa_addr).sa_family } == libc::AF_LINK as libc::sa_family_t;
        if link && let Ok(name) = unsafe { CStr::from_ptr(entry.ifa_name) }.to_str() {
            // SAFETY: see above (AF_LINK).
            let data = unsafe { &*entry.ifa_data.cast::<libc::if_data>() };
            let counters = merged.entry(name.to_string()).or_default();
            counters.0 = counters.0.wrapping_add(u64::from(data.ifi_ibytes));
            counters.1 = counters.1.wrapping_add(u64::from(data.ifi_obytes));
        }
        current = entry.ifa_next;
    }
    // SAFETY: `list` came from getifaddrs and is freed exactly once; no reference into it survives.
    unsafe { libc::freeifaddrs(list) };
    merged
        .into_iter()
        .map(|(name, (bytes_in, bytes_out))| NetworkInterfaceStatistics {
            name,
            bytes_in,
            bytes_out,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lists_interfaces_sorted_and_unique() {
        let interfaces = read_network();
        assert!(!interfaces.is_empty(), "every Mac has a loopback interface");
        assert!(interfaces.windows(2).all(|w| w[0].name < w[1].name));
    }
}
