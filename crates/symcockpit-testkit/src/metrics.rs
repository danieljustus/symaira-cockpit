//! Fakes and tests for `symcockpit_core::metrics`. All data is synthetic.

use std::path::Path;
use std::sync::Mutex;

use serde_json::Value;
use symcockpit_core::metrics::*;

/// Replays scripted snapshots; the last one repeats.
pub struct FakeSystemMetricsSource {
    snapshots: Mutex<Vec<SystemMetricsSnapshot>>,
}

impl FakeSystemMetricsSource {
    pub fn new(snapshots: Vec<SystemMetricsSnapshot>) -> Self {
        Self {
            snapshots: Mutex::new(snapshots),
        }
    }
}

impl SystemMetricsSource for FakeSystemMetricsSource {
    fn read_snapshot(&self) -> SystemMetricsSnapshot {
        let mut list = self.snapshots.lock().unwrap();
        if list.len() > 1 {
            list.remove(0)
        } else {
            list.first().cloned().unwrap_or_default()
        }
    }
}

pub struct FakeGpuUtilization(pub Option<f64>);

impl GpuUtilizationReading for FakeGpuUtilization {
    fn read_utilization_percent(&self) -> Option<f64> {
        self.0
    }
}

pub struct FakePower(pub Option<PowerReport>);

impl PowerReading for FakePower {
    fn read_power(&self) -> Option<PowerReport> {
        self.0.clone()
    }
}

type ValuesFn = dyn Fn(&str) -> Option<VolumeResourceValues> + Send + Sync;

/// Mounted paths plus a function answering each path's resource values.
pub struct FakeVolumeSource {
    paths: Vec<String>,
    values: Box<ValuesFn>,
}

impl FakeVolumeSource {
    pub fn new(
        paths: &[&str],
        values: impl Fn(&str) -> Option<VolumeResourceValues> + Send + Sync + 'static,
    ) -> Self {
        Self {
            paths: paths.iter().map(|p| p.to_string()).collect(),
            values: Box::new(values),
        }
    }
}

impl VolumeSource for FakeVolumeSource {
    fn mounted_volumes(&self) -> Vec<String> {
        self.paths.clone()
    }
    fn resource_values(&self, path: &str) -> Option<VolumeResourceValues> {
        (self.values)(path)
    }
}

/// A fully populated, entirely synthetic snapshot (every report key present).
pub fn synthetic_snapshot(timestamp: f64, cpu: [u64; 4], network: u64) -> SystemMetricsSnapshot {
    let space = DiskReport {
        capacity_bytes: 100,
        used_bytes: 40,
        free_bytes: 60,
    };
    SystemMetricsSnapshot {
        timestamp,
        cpu: CpuStatistics {
            total: cpu.to_vec(),
            per_core: vec![cpu.to_vec()],
        },
        memory: memory_statistics(100, 10, 20, 30, 16_384, 1 << 30),
        disk: Some(space.clone()),
        network: vec![NetworkInterfaceStatistics {
            name: "net0".into(),
            bytes_in: network,
            bytes_out: network,
        }],
        power: Some(PowerReport::new(
            Some(20.0),
            Some(3.0),
            Some(60.0),
            Some(AdapterPowerSource::SmcPdtr),
            Some(55.0),
            Some(SystemPowerSource::SmcPstr),
        )),
        gpu: Some(GpuReport {
            utilization_percent: 42.0,
        }),
        volumes: vec![StorageVolumeReport {
            name: "Vol".into(),
            mount_path: "/".into(),
            uuid: Some("u-1".into()),
            is_internal: Some(true),
            is_local: Some(true),
            is_read_only: Some(false),
            space: Some(space),
        }],
    }
}

/// Fail unless `value` has the shape recorded in `oracle/v0.12/cases/<fixture>`
/// (keys and types, see oracle/README.md).
pub fn assert_matches_oracle_shape(fixture: &str, value: &Value) {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../oracle/v0.12/cases")
        .join(fixture);
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let expected: Value = serde_json::from_str(&text).unwrap();
    let actual = symcockpit_oracle::shape::derive(value).unwrap();
    let diff = symcockpit_oracle::shape::compare(&expected, &actual);
    assert!(diff.errors.is_empty(), "{fixture}: {:?}", diff.errors);
}

/// Exact bytes of an oracle fixture (help texts hold no device data).
pub fn oracle_text(fixture: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../oracle/v0.12/cases")
        .join(fixture);
    std::fs::read_to_string(path).unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use symcockpit_contract::Error;

    fn service(snapshots: Vec<SystemMetricsSnapshot>) -> SystemMetricsService {
        SystemMetricsService::new(Box::new(FakeSystemMetricsSource::new(snapshots)))
    }

    // Vectors: tuning/Tests/SymCockpitCoreTests/SystemMetricsServiceTests.swift
    #[test]
    fn derives_utilization_and_throughput() {
        let s = service(vec![
            synthetic_snapshot(1.0, [10, 10, 10, 70], 100),
            synthetic_snapshot(3.0, [20, 20, 20, 80], 160),
        ]);
        s.read();
        let r = s.read();
        assert!((r.cpu.total_utilization.unwrap() - 0.75).abs() < 1e-4);
        assert_eq!(r.cpu.per_core_utilization, [0.75]);
        assert!((r.network.interfaces[0].bytes_in_per_second.unwrap() - 30.0).abs() < 1e-4);
        assert!((r.network.aggregate_bytes_out_per_second.unwrap() - 30.0).abs() < 1e-4);
    }

    #[test]
    fn decreasing_counter_skips_the_sample_instead_of_wrapping() {
        let s = service(vec![
            synthetic_snapshot(1.0, [0; 4], u64::MAX - 9),
            synthetic_snapshot(2.0, [0; 4], 10),
        ]);
        s.read();
        let r = s.read();
        assert_eq!(r.network.interfaces[0].bytes_in_per_second, None);
        assert_eq!(r.network.interfaces[0].bytes_out_per_second, None);
        assert_eq!(r.network.aggregate_bytes_in_per_second, None);
    }

    #[test]
    fn non_positive_time_does_not_derive_a_rate() {
        let s = service(vec![
            synthetic_snapshot(2.0, [0; 4], 1),
            synthetic_snapshot(2.0, [0; 4], 2),
            synthetic_snapshot(1.0, [0; 4], 3),
        ]);
        s.read();
        assert_eq!(s.read().network.interfaces[0].bytes_in_per_second, None);
        assert_eq!(s.read().network.interfaces[0].bytes_in_per_second, None);
    }

    #[test]
    fn unavailable_degrades_gracefully_with_notes() {
        let r = service(vec![SystemMetricsSnapshot::default()]).read();
        assert_eq!(r.cpu.total_utilization, None);
        assert_eq!(r.memory.used_bytes, None);
        assert!(r.disk.is_none() && r.network.interfaces.is_empty());
        assert_eq!(r.notes.len(), 7, "{:?}", r.notes);
        assert!(
            r.notes
                .iter()
                .any(|n| n.starts_with("GPU utilization unavailable"))
        );
        assert!(r.notes.iter().any(|n| n.starts_with("Power unavailable")));
    }

    #[test]
    fn first_read_has_no_rates_and_says_so_second_read_has_them() {
        let s = service(vec![
            synthetic_snapshot(1.0, [10, 10, 10, 70], 100),
            synthetic_snapshot(2.0, [20, 20, 20, 80], 150),
        ]);
        let first = metrics_json(&s).unwrap();
        assert!(first["cpu"].get("total_utilization").is_none());
        assert_eq!(first["cpu"]["per_core_utilization"], json!([]));
        assert!(
            first["network"]["interfaces"][0]
                .get("bytes_in_per_second")
                .is_none()
        );
        assert_eq!(
            first["notes"],
            json!(["Rates and CPU utilization require a previous sample."])
        );
        let second = metrics_json(&s).unwrap();
        assert_eq!(
            second["network"]["interfaces"][0]["bytes_in_per_second"].as_f64(),
            Some(50.0)
        );
        assert_eq!(second["notes"], json!([]));
    }

    // GPURegistryTests.swift GPUMetricsReportTests
    #[test]
    fn gpu_block_is_present_with_utilization_and_omitted_without() {
        let with = metrics_json(&service(vec![synthetic_snapshot(1.0, [0; 4], 0)])).unwrap();
        assert_eq!(with["gpu"]["utilization_percent"].as_f64(), Some(42.0));
        let mut snap = synthetic_snapshot(1.0, [0; 4], 0);
        snap.gpu = None;
        let without = metrics_json(&service(vec![snap])).unwrap();
        assert!(without.get("gpu").is_none());
        assert!(
            without["notes"]
                .to_string()
                .contains("GPU utilization unavailable")
        );
    }

    #[test]
    fn power_block_serializes_adapter_watts_and_sources() {
        let v = metrics_json(&service(vec![synthetic_snapshot(1.0, [0; 4], 0)])).unwrap();
        let p = &v["power"];
        assert_eq!(p["watts"], p["adapter_watts"]);
        assert_eq!(
            (p["adapter_source"].as_str(), p["system_source"].as_str()),
            (Some("smc_pdtr"), Some("smc_pstr"))
        );
        let sparse = serde_json::to_value(PowerReport::new(
            None,
            None,
            None,
            None,
            Some(7.0),
            Some(SystemPowerSource::BatterySystemLoad),
        ))
        .unwrap();
        assert_eq!(
            sparse,
            json!({"system_watts": 7.0, "system_source": "battery_system_load"})
        );
    }

    // StorageVolumeServiceTests.swift testDiscoveryAndCapacityFallbacks
    #[test]
    fn volume_discovery_filters_orders_and_prefers_the_data_volume() {
        let paths = [
            "/Volumes/USB 1",
            "/System/Volumes/Preboot",
            "/Volumes/.hidden",
            "/",
            "/Volumes/USB",
            "/Volumes/USB",
            "/Volumes/private",
            "/Volumes/unreadable",
            "/Volumes/Internal",
        ];
        let svc = StorageVolumeService::new(Box::new(FakeVolumeSource::new(&paths, |p| {
            (p != "/Volumes/unreadable").then(|| VolumeResourceValues {
                name: Some(
                    if p == "/" {
                        "Macintosh HD"
                    } else {
                        "Shared name"
                    }
                    .into(),
                ),
                uuid: Some(format!("demo-{p}")),
                is_internal: Some(p == "/" || p == "/Volumes/Internal"),
                is_local: Some(true),
                is_read_only: Some(p == "/Volumes/USB"),
                is_browsable: Some(p != "/Volumes/private"),
                total_capacity: Some(100),
                available_capacity: Some(if p == "/System/Volumes/Data" { 40 } else { 1 }),
                available_capacity_for_important_usage: Some(0),
            })
        })));
        let v = svc.read();
        let mounts: Vec<&str> = v.iter().map(|v| v.mount_path.as_str()).collect();
        assert_eq!(
            mounts,
            [
                "/",
                "/Volumes/Internal",
                "/Volumes/USB",
                "/Volumes/USB 1",
                "/Volumes/unreadable"
            ]
        );
        assert_eq!(
            v[0].space.as_ref().unwrap().free_bytes,
            40,
            "boot capacity comes from the Data volume"
        );
        assert_eq!(v[0].uuid.as_deref(), Some("demo-/System/Volumes/Data"));
        assert_eq!(
            (v[2].uuid.as_deref(), v[2].is_read_only),
            (Some("demo-/Volumes/USB"), Some(true))
        );
        let last = v.last().unwrap();
        assert!(last.space.is_none() && last.name == "unreadable" && last.uuid.is_none());
        assert!(
            StorageVolumeService::new(Box::new(FakeVolumeSource::new(&[], |_| None)))
                .read()
                .is_empty()
        );
    }

    #[test]
    fn volumes_flow_into_the_report_and_boot_disk_stays_separate() {
        let boot = synthetic_snapshot(1.0, [0; 4], 0).volumes;
        let mut renamed = boot.clone();
        renamed.push(StorageVolumeReport {
            name: "Backup".into(),
            mount_path: "/Volumes/Backup".into(),
            uuid: None,
            is_internal: Some(false),
            is_local: Some(true),
            is_read_only: None,
            space: None,
        });
        let s = service(vec![
            SystemMetricsSnapshot {
                volumes: boot.clone(),
                ..synthetic_snapshot(1.0, [0; 4], 0)
            },
            SystemMetricsSnapshot {
                volumes: renamed.clone(),
                ..synthetic_snapshot(2.0, [0; 4], 0)
            },
        ]);
        assert_eq!(s.read().volumes, boot);
        let r = s.read();
        assert_eq!(r.volumes, renamed);
        assert_eq!(r.disk.unwrap().capacity_bytes, 100);
        let v = serde_json::to_value(&r.volumes[1]).unwrap();
        assert_eq!(
            v,
            json!({"name": "Backup", "mount_path": "/Volumes/Backup", "is_internal": false, "is_local": true})
        );
    }

    // Oracle forms: metrics-json, mcp-call-get_system_metrics (both a first read).
    #[test]
    fn json_matches_the_oracle_shapes() {
        for fixture in [
            "metrics-json.shape.json",
            "mcp-call-get_system_metrics.shape.json",
        ] {
            let s = service(vec![synthetic_snapshot(1.0, [1, 2, 3, 4], 5)]);
            assert_matches_oracle_shape(fixture, &metrics_json(&s).unwrap());
        }
    }

    #[test]
    fn metrics_command_help_is_the_oracle_text_and_bad_args_exit_2() {
        let s = service(vec![SystemMetricsSnapshot::default()]);
        let help = metrics_command(&["--help".to_string()], &s).unwrap();
        let Output::Text { stdout, stderr } = help else {
            panic!("text expected")
        };
        assert!(stderr.is_empty());
        assert_eq!(stdout.join("\n") + "\n", oracle_text("metrics-help.stdout"));
        assert!(matches!(
            metrics_command(&["--json".to_string()], &s),
            Ok(Output::Json(_))
        ));
        let err = metrics_command(&["--bogus".to_string()], &s).unwrap_err();
        assert!(matches!(err, Error::Usage(_)));
        assert_eq!(err.exit_code(), 2);
    }
}
