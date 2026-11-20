//! System metrics (`symcockpit metrics`, MCP `get_system_metrics`).
//!
//! Port of `SystemMetricsService.swift`, `SystemMetricsSource.swift`,
//! `StorageVolumeService.swift` and `GPURegistry.swift` (report part). Reports
//! serialize exactly like Swift v0.12 (snake_case, nil optionals omitted).
//! Rates and CPU utilization are deltas against the previous `read`, so the
//! service is stateful; the first read has none and says so in `notes`.

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, PoisonError};

use serde::Serialize;
use serde_json::Value;
use symcockpit_contract::Error;

/// `CPU_STATE_IDLE` of `host_processor_info` (user, system, idle, nice).
const CPU_STATE_IDLE: usize = 2;

/// What a command prints: JSON for the dispatcher to render, or text lines.
#[derive(Clone, Debug, PartialEq)]
pub enum Output {
    Json(Value),
    Text {
        stdout: Vec<String>,
        stderr: Vec<String>,
    },
}

// MARK: - Reports (wire types)

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct CpuReport {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total_utilization: Option<f64>,
    pub per_core_utilization: Vec<f64>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct MemoryReport {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub used_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub free_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wired_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub compressed_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pressure: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct DiskReport {
    pub capacity_bytes: u64,
    pub used_bytes: u64,
    pub free_bytes: u64,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct NetworkInterfaceReport {
    pub name: String,
    pub bytes_in: u64,
    pub bytes_out: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bytes_in_per_second: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bytes_out_per_second: Option<f64>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct NetworkReport {
    pub interfaces: Vec<NetworkInterfaceReport>,
    pub aggregate_bytes_in: u64,
    pub aggregate_bytes_out: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub aggregate_bytes_in_per_second: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub aggregate_bytes_out_per_second: Option<f64>,
}

// One system-power type for every consumer: see `sensors::read_system_power`.
pub use crate::sensors::{AdapterPowerSource, PowerReport, SystemPowerSource};

/// GPU device utilization in percent (0-100), the maximum across accelerators.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct GpuReport {
    pub utilization_percent: f64,
}

/// A mounted, user-visible filesystem. APFS volumes share capacity, so the
/// figures must not be summed. `space` is `None` when capacity is unreadable.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct StorageVolumeReport {
    pub name: String,
    pub mount_path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub uuid: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_internal: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_local: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_read_only: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub space: Option<DiskReport>,
}

impl StorageVolumeReport {
    pub fn is_boot(&self) -> bool {
        self.mount_path == "/"
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct SystemMetricsReport {
    pub cpu: CpuReport,
    pub memory: MemoryReport,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub disk: Option<DiskReport>,
    pub network: NetworkReport,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub power: Option<PowerReport>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gpu: Option<GpuReport>,
    pub volumes: Vec<StorageVolumeReport>,
    pub notes: Vec<String>,
}

// MARK: - Source port

/// Cumulative CPU ticks `[user, system, idle, nice]`, summed and per core.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct CpuStatistics {
    pub total: Vec<u64>,
    pub per_core: Vec<Vec<u64>>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct NetworkInterfaceStatistics {
    pub name: String,
    pub bytes_in: u64,
    pub bytes_out: u64,
}

/// One raw reading of the machine; `timestamp` is in seconds (any origin, monotonic).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SystemMetricsSnapshot {
    pub timestamp: f64,
    pub cpu: CpuStatistics,
    pub memory: MemoryReport,
    pub disk: Option<DiskReport>,
    pub network: Vec<NetworkInterfaceStatistics>,
    pub power: Option<PowerReport>,
    pub gpu: Option<GpuReport>,
    pub volumes: Vec<StorageVolumeReport>,
}

/// Reads the machine. Infallible like Swift: missing data degrades to empty
/// values that the service turns into `notes`.
pub trait SystemMetricsSource: Send + Sync {
    fn read_snapshot(&self) -> SystemMetricsSnapshot;
}

/// GPU device utilization in percent, `None` when the registry publishes none.
pub trait GpuUtilizationReading: Send + Sync {
    fn read_utilization_percent(&self) -> Option<f64>;
}

/// Live power draw (SMC `PSTR`/`PDTR`/`PD0R`/`VD0R`/`ID0R`, else the battery's
/// system load). Owned by the SMC/battery areas; `None` when not exposed.
pub trait PowerReading: Send + Sync {
    fn read_power(&self) -> Option<PowerReport>;
}

/// Used until the SMC/battery adapter is wired in: reports no power block.
pub struct NoPower;

impl PowerReading for NoPower {
    fn read_power(&self) -> Option<PowerReport> {
        None
    }
}

// MARK: - Service

pub struct SystemMetricsService {
    source: Box<dyn SystemMetricsSource>,
    previous: Mutex<Option<SystemMetricsSnapshot>>,
}

impl SystemMetricsService {
    pub fn new(source: Box<dyn SystemMetricsSource>) -> Self {
        Self {
            source,
            previous: Mutex::new(None),
        }
    }

    pub fn read(&self) -> SystemMetricsReport {
        let current = self.source.read_snapshot();
        let old = self
            .previous
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .replace(current.clone());
        let old = old.as_ref();

        let cpu = CpuReport {
            total_utilization: utilization(&current.cpu.total, old.map(|o| o.cpu.total.as_slice())),
            per_core_utilization: current
                .cpu
                .per_core
                .iter()
                .enumerate()
                .filter_map(|(i, values)| {
                    utilization(
                        values,
                        old.and_then(|o| o.cpu.per_core.get(i)).map(Vec::as_slice),
                    )
                })
                .collect(),
        };
        let interval = old.map(|o| current.timestamp - o.timestamp);
        let old_network: HashMap<&str, &NetworkInterfaceStatistics> = old
            .map(|o| o.network.iter().map(|n| (n.name.as_str(), n)).collect())
            .unwrap_or_default();
        let interfaces = current
            .network
            .iter()
            .map(|item| {
                let prior = old_network.get(item.name.as_str());
                NetworkInterfaceReport {
                    name: item.name.clone(),
                    bytes_in: item.bytes_in,
                    bytes_out: item.bytes_out,
                    bytes_in_per_second: rate(item.bytes_in, prior.map(|p| p.bytes_in), interval),
                    bytes_out_per_second: rate(
                        item.bytes_out,
                        prior.map(|p| p.bytes_out),
                        interval,
                    ),
                }
            })
            .collect();
        let sum = |list: &[NetworkInterfaceStatistics],
                   f: fn(&NetworkInterfaceStatistics) -> u64| {
            list.iter().fold(0u64, |a, n| a.wrapping_add(f(n)))
        };
        let (agg_in, agg_out) = (
            sum(&current.network, |n| n.bytes_in),
            sum(&current.network, |n| n.bytes_out),
        );
        let prior_in = old.map(|o| sum(&o.network, |n| n.bytes_in));
        let prior_out = old.map(|o| sum(&o.network, |n| n.bytes_out));
        let network = NetworkReport {
            interfaces,
            aggregate_bytes_in: agg_in,
            aggregate_bytes_out: agg_out,
            aggregate_bytes_in_per_second: rate(agg_in, prior_in, interval),
            aggregate_bytes_out_per_second: rate(agg_out, prior_out, interval),
        };

        let mut notes = Vec::new();
        if old.is_none() {
            notes.push("Rates and CPU utilization require a previous sample.");
        }
        if current.cpu.total.is_empty() {
            notes.push("CPU metrics unavailable.");
        }
        if current.memory.used_bytes.is_none() {
            notes.push("Memory metrics unavailable.");
        }
        if current.disk.is_none() {
            notes.push("Boot-volume disk metrics unavailable.");
        }
        if current.network.is_empty() {
            notes.push("Network metrics unavailable.");
        }
        if current.power.is_none() {
            notes.push("Power unavailable — neither SMC power keys (PSTR, PDTR/PD0R, VD0R/ID0R) nor battery SystemLoad are exposed.");
        }
        if current.gpu.is_none() {
            notes.push("GPU utilization unavailable — the IORegistry publishes no \"Device Utilization %\".");
        }
        SystemMetricsReport {
            cpu,
            memory: current.memory,
            disk: current.disk,
            network,
            power: current.power,
            gpu: current.gpu,
            volumes: current.volumes,
            notes: notes.into_iter().map(String::from).collect(),
        }
    }
}

fn utilization(current: &[u64], old: Option<&[u64]>) -> Option<f64> {
    let old = old?;
    if current.len() != old.len() || current.len() < 4 {
        return None;
    }
    let deltas: Vec<u64> = current
        .iter()
        .zip(old)
        .map(|(c, o)| c.wrapping_sub(*o))
        .collect();
    let total = deltas.iter().fold(0u64, |a, d| a.wrapping_add(*d));
    (total > 0).then(|| total.wrapping_sub(deltas[CPU_STATE_IDLE]) as f64 / total as f64)
}

/// A decreasing counter means the interface was reset or re-merged: skipping
/// the sample beats wrapping into an absurd multi-terabyte rate.
fn rate(current: u64, old: Option<u64>, interval: Option<f64>) -> Option<f64> {
    let (old, interval) = (old?, interval?);
    (interval > 0.0 && current >= old).then(|| (current - old) as f64 / interval)
}

/// Memory as Activity Monitor counts it: App Memory (internal pages less
/// purgeable) + Wired + Compressed; available is physical memory less used
/// (Swift issue #384).
pub fn memory_statistics(
    internal_pages: u64,
    purgeable_pages: u64,
    wired_pages: u64,
    compressor_pages: u64,
    page_size: u64,
    physical_memory: u64,
) -> MemoryReport {
    let app = internal_pages.saturating_sub(purgeable_pages) * page_size;
    let wired = wired_pages * page_size;
    let compressed = compressor_pages * page_size;
    let used = app
        .wrapping_add(wired)
        .wrapping_add(compressed)
        .min(physical_memory);
    let available = physical_memory - used;
    MemoryReport {
        used_bytes: Some(used),
        free_bytes: Some(available),
        wired_bytes: Some(wired),
        compressed_bytes: Some(compressed),
        pressure: pressure_level(available, physical_memory),
    }
}

fn pressure_level(available: u64, physical: u64) -> Option<String> {
    if physical == 0 {
        return None;
    }
    let ratio = available as f64 / physical as f64;
    Some(
        match ratio {
            r if r < 0.05 => "critical",
            r if r < 0.10 => "warning",
            _ => "nominal",
        }
        .into(),
    )
}

// MARK: - Storage volumes

/// Volume metadata as the platform reports it (every field may be missing).
#[derive(Clone, Debug, Default)]
pub struct VolumeResourceValues {
    pub name: Option<String>,
    pub uuid: Option<String>,
    pub is_internal: Option<bool>,
    pub is_local: Option<bool>,
    pub is_read_only: Option<bool>,
    pub is_browsable: Option<bool>,
    pub total_capacity: Option<i64>,
    pub available_capacity: Option<i64>,
    /// Includes purgeable APFS space, like Finder.
    pub available_capacity_for_important_usage: Option<i64>,
}

/// Native metadata reads only: no `diskutil`, file scan or mounting.
pub trait VolumeSource: Send + Sync {
    /// Mount paths of the mounted volumes, hidden ones excluded.
    fn mounted_volumes(&self) -> Vec<String>;
    /// `None` when the volume's metadata cannot be read.
    fn resource_values(&self, path: &str) -> Option<VolumeResourceValues>;
}

/// Capacity from resource values. Important-usage availability includes
/// purgeable space; non-APFS/network volumes report 0 for it though ordinary
/// availability is positive, so the latter wins then.
pub fn disk_statistics(values: &VolumeResourceValues) -> Option<DiskReport> {
    let important = values.available_capacity_for_important_usage;
    let ordinary = values.available_capacity;
    let total = values.total_capacity.filter(|t| *t > 0)?;
    let available = important
        .filter(|v| *v > 0)
        .or(ordinary.filter(|v| *v >= 0))
        .or(important.filter(|v| *v == 0))?;
    let capacity = total as u64;
    let free = (available as u64).min(capacity);
    Some(DiskReport {
        capacity_bytes: capacity,
        used_bytes: capacity - free,
        free_bytes: free,
    })
}

pub struct StorageVolumeService {
    source: Box<dyn VolumeSource>,
}

impl StorageVolumeService {
    pub fn new(source: Box<dyn VolumeSource>) -> Self {
        Self { source }
    }

    pub fn read(&self) -> Vec<StorageVolumeReport> {
        let mut seen = HashSet::new();
        let mut volumes: Vec<StorageVolumeReport> = self
            .source
            .mounted_volumes()
            .iter()
            .filter_map(|raw| {
                let path = standardized(raw);
                let last = path.rsplit('/').next().unwrap_or(&path).to_string();
                if path.starts_with("/System/Volumes/")
                    || last.starts_with('.')
                    || !seen.insert(path.clone())
                {
                    return None;
                }
                let values = self.source.resource_values(&path);
                if values.as_ref().and_then(|v| v.is_browsable) == Some(false) {
                    return None;
                }
                // The sealed root snapshot is not the writable startup data volume.
                let data = (path == "/")
                    .then(|| self.source.resource_values("/System/Volumes/Data"))
                    .flatten();
                let space = data
                    .as_ref()
                    .and_then(disk_statistics)
                    .or_else(|| values.as_ref().and_then(disk_statistics));
                let pick = |f: fn(&VolumeResourceValues) -> Option<bool>| {
                    data.as_ref()
                        .and_then(f)
                        .or_else(|| values.as_ref().and_then(f))
                };
                Some(StorageVolumeReport {
                    name: values
                        .as_ref()
                        .and_then(|v| v.name.clone())
                        .unwrap_or_else(|| {
                            if path == "/" {
                                "Startup volume".into()
                            } else {
                                last
                            }
                        }),
                    uuid: data
                        .as_ref()
                        .and_then(|v| v.uuid.clone())
                        .or_else(|| values.as_ref().and_then(|v| v.uuid.clone())),
                    is_internal: values.as_ref().and_then(|v| v.is_internal),
                    is_local: values.as_ref().and_then(|v| v.is_local),
                    is_read_only: pick(|v| v.is_read_only),
                    space,
                    mount_path: path,
                })
            })
            .collect();
        volumes.sort_by(|l, r| {
            r.is_boot()
                .cmp(&l.is_boot())
                .then_with(|| (r.is_internal == Some(true)).cmp(&(l.is_internal == Some(true))))
                .then_with(|| localized_standard_compare(&l.name, &r.name))
                .then_with(|| l.mount_path.cmp(&r.mount_path))
        });
        volumes
    }
}

/// `URL.standardizedFileURL.path` for the absolute paths a mount table holds.
fn standardized(path: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/').filter(|p| !p.is_empty() && *p != ".") {
        if part == ".." {
            parts.pop();
        } else {
            parts.push(part);
        }
    }
    format!("/{}", parts.join("/"))
}

/// Case-insensitive, digit runs compared by value ("USB 2" < "USB 10").
// shortcut: no Unicode collation or diacritic folding like Foundation's
// `localizedStandardCompare`; upgrade if non-ASCII volume names must sort exactly like Finder.
fn localized_standard_compare(a: &str, b: &str) -> Ordering {
    let (mut a, mut b) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (a.peek().copied(), b.peek().copied()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let run = |it: &mut std::iter::Peekable<std::str::Chars>| {
                    let mut digits = String::new();
                    while let Some(c) = it.next_if(char::is_ascii_digit) {
                        digits.push(c);
                    }
                    digits.trim_start_matches('0').to_string()
                };
                let (da, db) = (run(&mut a), run(&mut b));
                let order = da.len().cmp(&db.len()).then_with(|| da.cmp(&db));
                if order != Ordering::Equal {
                    return order;
                }
            }
            (Some(x), Some(y)) => {
                let order = x.to_lowercase().cmp(y.to_lowercase());
                if order != Ordering::Equal {
                    return order;
                }
                a.next();
                b.next();
            }
        }
    }
}

// MARK: - Commands

/// Swift CLI usage for `metrics --help`.
pub const METRICS_USAGE: [&str; 5] = [
    "Usage: symcockpit metrics [--json]",
    "",
    "Print system metrics: CPU utilization, memory pressure, GPU utilization, disk usage,",
    "mounted storage volumes, and network throughput. All values are read-only snapshots.",
    "--json is accepted for consistency with other read commands; it is a no-op here.",
];

/// The JSON of one read; MCP `get_system_metrics` and `metrics [--json]` share it.
pub fn metrics_json(service: &SystemMetricsService) -> Result<Value, Error> {
    serde_json::to_value(service.read()).map_err(|e| Error::Failed(e.to_string()))
}

/// `symcockpit metrics [--json]`. One snapshot, so rates and CPU utilization
/// are absent (as in v0.12); `--json` is a no-op.
pub fn metrics_command(args: &[String], service: &SystemMetricsService) -> Result<Output, Error> {
    if args.iter().any(|a| a == "--help" || a == "-h") {
        return Ok(Output::Text {
            stdout: METRICS_USAGE.iter().map(|l| l.to_string()).collect(),
            stderr: Vec::new(),
        });
    }
    if let Some(arg) = args.iter().find(|a| *a != "--json") {
        return Err(Error::Usage(format!(
            "metrics: unexpected argument '{arg}'"
        )));
    }
    metrics_json(service).map(Output::Json)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Vectors: tuning/Tests/SymCockpitCoreTests/MemoryStatisticsTests.swift
    const PAGE: u64 = 16_384;
    const PHYSICAL: u64 = 24 * 1_073_741_824;

    #[test]
    fn used_matches_activity_monitors_formula() {
        let m = memory_statistics(524_529, 7_050, 235_041, 397_504, PAGE, PHYSICAL);
        assert_eq!(
            m.used_bytes,
            Some((524_529 - 7_050 + 235_041 + 397_504) * PAGE)
        );
        assert_eq!(m.wired_bytes, Some(235_041 * PAGE));
        assert_eq!(m.compressed_bytes, Some(397_504 * PAGE));
        let gib = m.used_bytes.unwrap() as f64 / 1_073_741_824.0;
        assert!((gib - 17.55).abs() < 0.01);
    }

    #[test]
    fn used_and_available_add_up() {
        let m = memory_statistics(300_000, 2_000, 150_000, 50_000, PAGE, PHYSICAL);
        assert_eq!(m.used_bytes.unwrap() + m.free_bytes.unwrap(), PHYSICAL);
        assert_eq!(m.pressure.as_deref(), Some("nominal"));
    }

    #[test]
    fn overshoot_clamps_to_physical_memory() {
        let m = memory_statistics(2_000_000, 3_000_000, 1_000_000, 1_000_000, PAGE, PHYSICAL);
        assert_eq!((m.used_bytes, m.free_bytes), (Some(PHYSICAL), Some(0)));
        assert_eq!(m.pressure.as_deref(), Some("critical"));
        assert_eq!(
            pressure_level(PHYSICAL / 12, PHYSICAL).as_deref(),
            Some("warning")
        );
        assert_eq!(pressure_level(1, 0), None);
    }

    // Vectors: StorageVolumeServiceTests.swift testDiscoveryAndCapacityFallbacks
    #[test]
    fn capacity_fallbacks() {
        let input = |t, o, i| VolumeResourceValues {
            total_capacity: t,
            available_capacity: o,
            available_capacity_for_important_usage: i,
            ..Default::default()
        };
        let cases = [
            (input(Some(100), Some(10), Some(30)), Some(30)),
            (input(Some(100), Some(10), Some(0)), Some(10)),
            (input(Some(100), Some(10), None), Some(10)),
            (input(Some(100), Some(10), Some(-1)), Some(10)),
            (input(Some(100), Some(0), Some(0)), Some(0)),
            (input(Some(100), None, Some(0)), Some(0)),
            (input(Some(100), Some(200), None), Some(100)),
            (input(Some(100), None, None), None),
            (input(None, Some(10), Some(30)), None),
            (input(Some(0), Some(10), Some(30)), None),
            (input(Some(-1), Some(10), Some(30)), None),
            (input(Some(100), Some(-1), Some(-1)), None),
        ];
        for (values, expected) in cases {
            let got = disk_statistics(&values);
            assert_eq!(got.as_ref().map(|d| d.free_bytes), expected, "{values:?}");
            if let Some(d) = got {
                assert_eq!(d.used_bytes + d.free_bytes, d.capacity_bytes);
            }
        }
    }

    #[test]
    fn natural_compare_orders_numbers_by_value() {
        use Ordering::*;
        assert_eq!(localized_standard_compare("USB 2", "USB 10"), Less);
        assert_eq!(localized_standard_compare("usb", "USB 1"), Less);
        assert_eq!(localized_standard_compare("Backup", "backup"), Equal);
        assert_eq!(localized_standard_compare("b", "A"), Greater);
    }

    #[test]
    fn standardized_paths() {
        assert_eq!(standardized("/"), "/");
        assert_eq!(standardized("/Volumes/USB/"), "/Volumes/USB");
        assert_eq!(standardized("/a/./b/../c"), "/a/c");
    }

    #[test]
    fn service_unavailable_and_usage() {
        let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        struct Empty;
        impl SystemMetricsSource for Empty {
            fn read_snapshot(&self) -> SystemMetricsSnapshot {
                SystemMetricsSnapshot::default()
            }
        }
        let svc = SystemMetricsService::new(Box::new(Empty));
        let err = metrics_command(&args(&["--bogus"]), &svc).unwrap_err();
        assert_eq!(
            err,
            Error::Usage("metrics: unexpected argument '--bogus'".into())
        );
        assert_eq!(err.exit_code(), 2);
        assert!(matches!(
            metrics_command(&args(&["-h", "--bogus"]), &svc),
            Ok(Output::Text { .. })
        ));
    }
}
