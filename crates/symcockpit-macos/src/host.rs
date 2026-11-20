//! Host statistics (CPU ticks, memory) and the assembled live metrics source.
//! Port of `HardwareSystemMetricsSource` in `SystemMetricsSource.swift`.

use std::sync::OnceLock;
use std::time::Instant;

use symcockpit_core::metrics::{
    CpuStatistics, GpuReport, GpuUtilizationReading, MemoryReport, PowerReading,
    StorageVolumeService, SystemMetricsService, SystemMetricsSnapshot, SystemMetricsSource,
    memory_statistics,
};

use crate::{gpu::IoRegistryGpuReader, network, volumes};

fn start() -> &'static Instant {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now)
}

/// Monotonic seconds since first use. Swift differenced wall-clock time; a
/// monotonic clock gives the same deltas and survives clock changes.
pub fn monotonic_seconds() -> f64 {
    start().elapsed().as_secs_f64()
}

/// Monotonic nanoseconds, the `uptimeNanoseconds` of the GPU process source.
pub fn monotonic_nanoseconds() -> u64 {
    start().elapsed().as_nanos() as u64
}

/// Cumulative CPU ticks `[user, system, idle, nice]`, summed and per core; empty on failure.
pub fn read_cpu() -> CpuStatistics {
    let mut processor_count: libc::natural_t = 0;
    let mut info: libc::processor_info_array_t = std::ptr::null_mut();
    let mut info_count: libc::mach_msg_type_number_t = 0;
    // SAFETY: all out-pointers are valid locals; on success the kernel
    // allocates `info_count` integers at `info`, released below.
    #[allow(deprecated)]
    let result = unsafe {
        libc::host_processor_info(
            libc::mach_host_self(),
            libc::PROCESSOR_CPU_LOAD_INFO,
            &mut processor_count,
            &mut info,
            &mut info_count,
        )
    };
    if result != libc::KERN_SUCCESS || info.is_null() {
        return CpuStatistics::default();
    }
    // SAFETY: the call above succeeded, so `info` points to `info_count` readable integers.
    let ticks = unsafe { std::slice::from_raw_parts(info, info_count as usize) };
    let stride = libc::CPU_STATE_MAX as usize;
    let per_core: Vec<Vec<u64>> = ticks
        .chunks_exact(stride)
        .take(processor_count as usize)
        .map(|core| core.iter().map(|t| (*t).max(0) as u64).collect())
        .collect();
    let total = (0..stride)
        .map(|i| {
            per_core
                .iter()
                .fold(0u64, |sum, core| sum.wrapping_add(core[i]))
        })
        .collect();
    // SAFETY: releases exactly the region the kernel allocated above; `ticks` is not used afterwards.
    #[allow(deprecated)]
    unsafe {
        libc::vm_deallocate(
            libc::mach_task_self(),
            info as libc::vm_address_t,
            info_count as libc::vm_size_t * size_of::<libc::integer_t>(),
        );
    }
    CpuStatistics { total, per_core }
}

fn physical_memory() -> Option<u64> {
    let mut value: u64 = 0;
    let mut size = size_of::<u64>();
    // SAFETY: `value`/`size` describe a valid 8-byte buffer for the `hw.memsize` integer.
    let rc = unsafe {
        libc::sysctlbyname(
            c"hw.memsize".as_ptr(),
            (&mut value as *mut u64).cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    (rc == 0).then_some(value)
}

/// Memory as Activity Monitor counts it; all `None` on failure.
pub fn read_memory() -> MemoryReport {
    let mut stats = std::mem::MaybeUninit::<libc::vm_statistics64>::zeroed();
    let mut count = (size_of::<libc::vm_statistics64>() / size_of::<libc::integer_t>())
        as libc::mach_msg_type_number_t;
    // SAFETY: `stats` is a writable vm_statistics64 and `count` its size in integers, as HOST_VM_INFO64 requires.
    #[allow(deprecated)]
    let result = unsafe {
        libc::host_statistics64(
            libc::mach_host_self(),
            libc::HOST_VM_INFO64,
            stats.as_mut_ptr().cast(),
            &mut count,
        )
    };
    // SAFETY: sysconf has no preconditions.
    let page_size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    let (Some(physical), true, true) = (
        physical_memory(),
        result == libc::KERN_SUCCESS,
        page_size > 0,
    ) else {
        return MemoryReport::default();
    };
    // SAFETY: zero-initialised and fully written by the successful call above.
    let stats = unsafe { stats.assume_init() };
    memory_statistics(
        u64::from(stats.internal_page_count),
        u64::from(stats.purgeable_count),
        u64::from(stats.wire_count),
        u64::from(stats.compressor_page_count),
        page_size as u64,
        physical,
    )
}

/// The real machine: host statistics, getifaddrs, volumes and the IORegistry GPU
/// utilization. Power (SMC/battery) is injected, since another area owns it.
pub struct LiveSystemMetricsSource {
    power: Box<dyn PowerReading>,
    gpu: Box<dyn GpuUtilizationReading>,
    volumes: StorageVolumeService,
}

impl LiveSystemMetricsSource {
    pub fn new(power: Box<dyn PowerReading>) -> Self {
        Self {
            power,
            gpu: Box::new(IoRegistryGpuReader),
            volumes: StorageVolumeService::new(Box::new(volumes::LiveVolumeSource)),
        }
    }
}

impl SystemMetricsSource for LiveSystemMetricsSource {
    fn read_snapshot(&self) -> SystemMetricsSnapshot {
        SystemMetricsSnapshot {
            timestamp: monotonic_seconds(),
            cpu: read_cpu(),
            memory: read_memory(),
            disk: volumes::read_disk(),
            network: network::read_network(),
            power: self.power.read_power(),
            gpu: self
                .gpu
                .read_utilization_percent()
                .map(|utilization_percent| GpuReport {
                    utilization_percent,
                }),
            volumes: self.volumes.read(),
        }
    }
}

/// The metrics service of one process (keep it: rates need the previous read).
pub fn live_metrics_service(power: Box<dyn PowerReading>) -> SystemMetricsService {
    SystemMetricsService::new(Box::new(LiveSystemMetricsSource::new(power)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_counters_are_plausible_and_monotonic() {
        let cpu = read_cpu();
        assert_eq!(cpu.total.len(), 4);
        assert!(!cpu.per_core.is_empty() && cpu.per_core.iter().all(|c| c.len() == 4));
        let mem = read_memory();
        let (used, free) = (mem.used_bytes.unwrap(), mem.free_bytes.unwrap());
        assert_eq!(Some(used + free), physical_memory());
        let a = monotonic_seconds();
        assert!(monotonic_seconds() >= a);
    }

    /// Live read-only check, run once by hand: `cargo test -p symcockpit-macos -- --ignored live`.
    /// Two reads of the real machine must match the v0.12 oracle shapes (first read: no rates).
    #[test]
    #[ignore = "reads the real machine"]
    fn live_metrics_match_the_oracle_shapes() {
        use symcockpit_core::metrics::{NoPower, metrics_json};
        use symcockpit_testkit::metrics::assert_matches_oracle_shape;
        let service = live_metrics_service(Box::new(NoPower));
        let first = metrics_json(&service).unwrap();
        // The live machine has no injected power block, so compare against a shape without it.
        let mut shape_input = first.clone();
        shape_input["power"] = serde_json::json!({
            "adapter_source": "smc_pdtr", "adapter_watts": 1.0, "amps": 1.0,
            "system_source": "smc_pstr", "system_watts": 1.0, "volts": 1.0, "watts": 1.0
        });
        for fixture in [
            "metrics-json.shape.json",
            "mcp-call-get_system_metrics.shape.json",
        ] {
            assert_matches_oracle_shape(fixture, &shape_input);
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
        let second = metrics_json(&service).unwrap();
        assert!(
            second["cpu"]["total_utilization"].as_f64().is_some(),
            "second read has CPU utilization"
        );
        assert!(second["network"]["interfaces"][0]["bytes_in_per_second"].is_number());
        // Names, paths and UUIDs stay out of the output; capacities and flags are enough to compare with Swift.
        let volumes: Vec<_> = second["volumes"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|v| {
                (
                    &v["is_internal"],
                    &v["is_local"],
                    &v["is_read_only"],
                    &v["space"],
                )
            })
            .collect();
        println!(
            "live: cpu_cores={} interfaces={} gpu={} memory={} disk={} volumes={volumes:?} notes={}",
            second["cpu"]["per_core_utilization"]
                .as_array()
                .map_or(0, Vec::len),
            second["network"]["interfaces"]
                .as_array()
                .map_or(0, Vec::len),
            second.get("gpu").map_or(String::new(), ToString::to_string),
            second["memory"],
            second["disk"],
            second["notes"],
        );
    }
}
