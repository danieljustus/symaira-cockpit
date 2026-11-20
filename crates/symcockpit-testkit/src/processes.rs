//! Fakes and tests for `symcockpit_core::processes`. All data is synthetic.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use symcockpit_core::processes::*;

/// Replays scripted sweeps (the last repeats) and reports every name as freshly resolved.
#[derive(Clone)]
pub struct ScriptedProcessSource {
    pending: Arc<Mutex<Vec<ProcessSampleSet>>>,
    pub sample_count: Arc<AtomicUsize>,
}

impl ScriptedProcessSource {
    pub fn new(sets: Vec<ProcessSampleSet>) -> Self {
        Self {
            pending: Arc::new(Mutex::new(sets)),
            sample_count: Arc::new(AtomicUsize::new(0)),
        }
    }
}

impl ProcessSampleSource for ScriptedProcessSource {
    fn sample(&self, _known: &HashMap<i32, String>) -> (ProcessSampleSet, HashMap<i32, String>) {
        self.sample_count.fetch_add(1, Ordering::SeqCst);
        let mut pending = self.pending.lock().unwrap();
        let set = match pending.len() {
            0 => ProcessSampleSet {
                timestamp: 0.0,
                samples: vec![],
                unreadable_count: 0,
            },
            1 => pending[0].clone(),
            _ => pending.remove(0),
        };
        let resolved = set
            .samples
            .iter()
            .map(|s| (s.pid, s.name.clone()))
            .collect();
        (set, resolved)
    }
}

/// Resolves a name only for a PID absent from `known`, like the libproc source
/// skips `proc_pidpath` for cached PIDs; each table is one call's ground truth (last repeats).
#[derive(Clone)]
pub struct ResolutionCountingSource {
    tables: Arc<Mutex<Vec<HashMap<i32, String>>>>,
    tick: Arc<AtomicU64>,
    pub resolution_count: Arc<AtomicUsize>,
}

impl ResolutionCountingSource {
    pub fn new(tables: &[&[(i32, &str)]]) -> Self {
        Self {
            tables: Arc::new(Mutex::new(
                tables
                    .iter()
                    .map(|t| t.iter().map(|(p, n)| (*p, n.to_string())).collect())
                    .collect(),
            )),
            tick: Arc::new(AtomicU64::new(0)),
            resolution_count: Arc::new(AtomicUsize::new(0)),
        }
    }
}

impl ProcessSampleSource for ResolutionCountingSource {
    fn sample(&self, known: &HashMap<i32, String>) -> (ProcessSampleSet, HashMap<i32, String>) {
        let mut tables = self.tables.lock().unwrap();
        let tick = self.tick.fetch_add(1, Ordering::SeqCst) + 1;
        let table = if tables.len() > 1 {
            tables.remove(0)
        } else {
            tables[0].clone()
        };
        let mut pids: Vec<i32> = table.keys().copied().collect();
        pids.sort_unstable();
        let (mut samples, mut resolved) = (Vec::new(), HashMap::new());
        for pid in pids {
            let name = known.get(&pid).cloned().unwrap_or_else(|| {
                self.resolution_count.fetch_add(1, Ordering::SeqCst);
                resolved.insert(pid, table[&pid].clone());
                table[&pid].clone()
            });
            samples.push(ProcessSample {
                pid,
                name,
                cpu_time_nanoseconds: 0,
                memory_bytes: 0,
                thread_count: None,
                gpu_percent: None,
            });
        }
        (
            ProcessSampleSet {
                timestamp: tick as f64,
                samples,
                unreadable_count: 0,
            },
            resolved,
        )
    }
}

/// Records calls, so tests can prove `.gpu` bypasses the libproc pipeline.
#[derive(Clone)]
pub struct StubGpuSource {
    pub stubbed: ProcessUsageReport,
    pub calls: Arc<Mutex<Vec<usize>>>,
    pub resets: Arc<AtomicUsize>,
}

impl StubGpuSource {
    pub fn new(stubbed: ProcessUsageReport) -> Self {
        Self {
            stubbed,
            calls: Arc::default(),
            resets: Arc::default(),
        }
    }
}

impl GpuProcessReporting for StubGpuSource {
    fn report(&self, limit: usize) -> ProcessUsageReport {
        self.calls.lock().unwrap().push(limit);
        self.stubbed.clone()
    }
    fn reset_baseline(&self) {
        self.resets.fetch_add(1, Ordering::SeqCst);
    }
}

/// Scripted registry snapshots (the last repeats); counts reads.
pub struct FakeGpuRegistry {
    snapshots: Mutex<Vec<Vec<GpuRegistryClient>>>,
}

impl FakeGpuRegistry {
    pub fn new(snapshots: Vec<Vec<GpuRegistryClient>>) -> Self {
        Self {
            snapshots: Mutex::new(snapshots),
        }
    }
}

impl GpuClientReading for FakeGpuRegistry {
    fn read_clients(&self) -> Vec<GpuRegistryClient> {
        let mut s = self.snapshots.lock().unwrap();
        if s.len() > 1 {
            s.remove(0)
        } else {
            s.first().cloned().unwrap_or_default()
        }
    }
}

/// A scripted monotonic clock in nanoseconds.
#[derive(Clone)]
pub struct FakeClock(Arc<AtomicU64>);

impl Default for FakeClock {
    fn default() -> Self {
        Self(Arc::new(AtomicU64::new(1_000_000_000)))
    }
}

impl FakeClock {
    pub fn advance_seconds(&self, seconds: f64) {
        self.0.fetch_add((seconds * 1e9) as u64, Ordering::SeqCst);
    }
    pub fn reader(&self) -> Box<dyn Fn() -> u64 + Send + Sync> {
        let c = self.0.clone();
        Box::new(move || c.load(Ordering::SeqCst))
    }
}

pub struct FakePowermetrics(pub Option<Vec<u8>>);

impl PowermetricsRunner for FakePowermetrics {
    fn sample(&self, _: u64) -> Option<Vec<u8>> {
        self.0.clone()
    }
}

pub fn client(pid: i32, name: &str, times: Option<&[u64]>) -> GpuRegistryClient {
    GpuRegistryClient {
        pid,
        name: name.into(),
        accumulated_gpu_time_nanoseconds: times.map(<[u64]>::to_vec),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::metrics::{assert_matches_oracle_shape, oracle_text};
    use serde_json::json;
    use std::time::Duration;

    fn sample(pid: i32, name: &str, cpu_ns: u64, memory_mb: u64) -> ProcessSample {
        ProcessSample {
            pid,
            name: name.into(),
            cpu_time_nanoseconds: cpu_ns,
            memory_bytes: memory_mb * 1_048_576,
            thread_count: Some(4),
            gpu_percent: None,
        }
    }

    fn set(timestamp: f64, samples: Vec<ProcessSample>) -> ProcessSampleSet {
        ProcessSampleSet {
            timestamp,
            samples,
            unreadable_count: 0,
        }
    }

    fn stub_service(source: impl ProcessSampleSource + 'static) -> ProcessUsageService {
        let gpu = StubGpuSource::new(ProcessUsageReport {
            sorted_by: ProcessSortKey::Gpu,
            processes: vec![],
            sampled_process_count: 0,
            unreadable_process_count: 0,
            notes: vec![],
        });
        ProcessUsageService::new(Box::new(source), Box::new(gpu))
    }

    // Vectors: tuning/Tests/SymCockpitCoreTests/ProcessUsageTests.swift (ProcessUsageServiceTests)
    #[test]
    fn service_differences_consecutive_calls() {
        let s = stub_service(ScriptedProcessSource::new(vec![
            set(0.0, vec![sample(1, "busy", 0, 10)]),
            set(2.0, vec![sample(1, "busy", 1_000_000_000, 10)]),
        ]));
        assert_eq!(
            s.report(ProcessSortKey::Cpu, 6).processes[0].cpu_percent,
            None
        );
        assert!(
            (s.report(ProcessSortKey::Cpu, 6).processes[0]
                .cpu_percent
                .unwrap()
                - 50.0)
                .abs()
                < 1e-3
        );
    }

    #[test]
    fn reset_baseline_drops_the_previous_sweep() {
        let s = stub_service(ScriptedProcessSource::new(vec![
            set(0.0, vec![sample(1, "busy", 0, 10)]),
            set(1.0, vec![sample(1, "busy", 500_000_000, 10)]),
        ]));
        s.report(ProcessSortKey::Cpu, 6);
        s.reset_baseline();
        assert_eq!(
            s.report(ProcessSortKey::Cpu, 6).processes[0].cpu_percent,
            None
        );
    }

    #[test]
    fn limit_is_clamped_to_one_and_the_maximum() {
        let samples = (1..=80)
            .map(|i| sample(i, &format!("p{i}"), 0, i as u64))
            .collect();
        let s = stub_service(ScriptedProcessSource::new(vec![set(0.0, samples)]));
        assert_eq!(
            s.report(ProcessSortKey::Memory, 5_000).processes.len(),
            MAXIMUM_LIMIT
        );
        assert_eq!(s.report(ProcessSortKey::Memory, 0).processes.len(), 1);
        assert_eq!(s.report(ProcessSortKey::Memory, -3).processes.len(), 1);
    }

    #[test]
    fn repeat_sweeps_resolve_names_only_for_uncached_pids() {
        let table: &[(i32, &str)] = &[(1, "a"), (2, "b"), (3, "c")];
        let source = ResolutionCountingSource::new(&[table, table, table]);
        let s = stub_service(source.clone());
        for _ in 0..3 {
            s.report(ProcessSortKey::Cpu, 6);
        }
        assert_eq!(source.resolution_count.load(Ordering::SeqCst), 3);
        let mut names: Vec<String> = s
            .report(ProcessSortKey::Cpu, 6)
            .processes
            .into_iter()
            .map(|p| p.name)
            .collect();
        names.sort();
        assert_eq!(names, ["a", "b", "c"]);
    }

    #[test]
    fn recycled_pid_is_re_resolved_and_the_cache_is_pruned() {
        let source = ResolutionCountingSource::new(&[
            &[(1, "one"), (3, "old")],
            &[(1, "one"), (3, "old")],
            &[(1, "one")],
            &[(1, "one"), (3, "fresh")],
        ]);
        let s = stub_service(source.clone());
        let reports: Vec<_> = (0..4).map(|_| s.report(ProcessSortKey::Cpu, 6)).collect();
        let name_of = |r: &ProcessUsageReport| {
            r.processes
                .iter()
                .find(|p| p.pid == 3)
                .map(|p| p.name.clone())
        };
        assert_eq!(name_of(&reports[3]).as_deref(), Some("fresh"));
        // 2 + 0 (cached) + 0 + 1 (3 returns after pruning)
        assert_eq!(source.resolution_count.load(Ordering::SeqCst), 3);
    }

    #[test]
    fn gpu_sort_routes_to_the_gpu_source_instead_of_libproc() {
        let libproc =
            ScriptedProcessSource::new(vec![set(0.0, vec![sample(1, "cpu-bound", 0, 10)])]);
        let stubbed = ProcessUsageReport {
            sorted_by: ProcessSortKey::Gpu,
            processes: vec![ProcessUsage {
                pid: 99,
                name: "renderer".into(),
                cpu_percent: None,
                memory_bytes: 0,
                thread_count: None,
                gpu_percent: Some(42.0),
            }],
            sampled_process_count: 1,
            unreadable_process_count: 0,
            notes: vec![],
        };
        let gpu = StubGpuSource::new(stubbed);
        let s = ProcessUsageService::new(Box::new(libproc.clone()), Box::new(gpu.clone()));
        assert_eq!(
            s.report(ProcessSortKey::Gpu, 7).processes[0].gpu_percent,
            Some(42.0)
        );
        s.report(ProcessSortKey::Gpu, 5_000);
        assert_eq!(*gpu.calls.lock().unwrap(), [7, MAXIMUM_LIMIT]);
        assert_eq!(
            libproc.sample_count.load(Ordering::SeqCst),
            0,
            "GPU sampling never sweeps libproc"
        );
        s.reset_baseline();
        assert_eq!(gpu.resets.load(Ordering::SeqCst), 1);
    }

    // Vectors: GPURegistryTests.swift (IORegistryGPUProcessSourceTests)
    fn registry_source(
        snapshots: Vec<Vec<GpuRegistryClient>>,
        clock: &FakeClock,
        stale: u64,
    ) -> IoRegistryGpuProcessSource {
        IoRegistryGpuProcessSource::new(
            Box::new(FakeGpuRegistry::new(snapshots)),
            clock.reader(),
            Duration::from_secs(stale),
        )
    }
    const S: u64 = 1_000_000_000;

    #[test]
    fn first_gpu_sample_primes_the_baseline_and_reports_measuring_not_zero() {
        let source = registry_source(
            vec![vec![client(10, "Game", Some(&[5 * S]))]],
            &FakeClock::default(),
            30,
        );
        let r = source.report(5);
        assert_eq!((r.sorted_by, r.processes.len()), (ProcessSortKey::Gpu, 1));
        assert_eq!(r.processes[0].gpu_percent, None);
        assert!(r.notes.iter().any(|n| n.contains("Measuring")));
    }

    #[test]
    fn second_gpu_sample_computes_the_delta_over_wall_time() {
        let clock = FakeClock::default();
        let source = registry_source(
            vec![
                vec![
                    client(10, "Game", Some(&[5 * S])),
                    client(20, "Idle", Some(&[100])),
                ],
                vec![
                    client(10, "Game", Some(&[5 * S + S / 2])),
                    client(20, "Idle", Some(&[100])),
                ],
            ],
            &clock,
            30,
        );
        source.report(5);
        clock.advance_seconds(2.0);
        let r = source.report(5);
        assert_eq!(
            r.processes.iter().map(|p| p.pid).collect::<Vec<_>>(),
            [10, 20]
        );
        assert!((r.processes[0].gpu_percent.unwrap() - 25.0).abs() < 1e-4);
        assert!(r.processes[1].gpu_percent.unwrap().abs() < 1e-4);
        assert!(!r.notes.iter().any(|n| n.contains("Measuring")) && r.sampled_process_count == 2);
    }

    #[test]
    fn sums_every_app_usage_entry_and_every_client_of_a_pid() {
        let clock = FakeClock::default();
        let source = registry_source(
            vec![
                vec![
                    client(7, "WindowServer", Some(&[S, 10])),
                    client(7, "WindowServer", Some(&[2 * S])),
                ],
                vec![
                    client(7, "WindowServer", Some(&[S + S / 10, 10])),
                    client(7, "WindowServer", Some(&[2 * S + 3 * S / 10])),
                ],
            ],
            &clock,
            30,
        );
        source.report(5);
        clock.advance_seconds(1.0);
        let r = source.report(5);
        assert_eq!(r.processes.len(), 1);
        assert!((r.processes[0].gpu_percent.unwrap() - 40.0).abs() < 1e-4);
    }

    #[test]
    fn idle_client_with_empty_app_usage_is_not_listed() {
        let source = registry_source(
            vec![vec![
                client(1, "Idle", Some(&[])),
                client(2, "Busy", Some(&[10])),
            ]],
            &FakeClock::default(),
            30,
        );
        assert_eq!(
            source
                .report(5)
                .processes
                .iter()
                .map(|p| p.pid)
                .collect::<Vec<_>>(),
            [2]
        );
    }

    #[test]
    fn counter_reset_drops_the_stale_baseline_for_that_pid() {
        let clock = FakeClock::default();
        let source = registry_source(
            vec![
                vec![
                    client(10, "Game", Some(&[9 * S])),
                    client(20, "Other", Some(&[S])),
                ],
                vec![
                    client(10, "Game", Some(&[1_000])),
                    client(20, "Other", Some(&[S + S / 2])),
                ],
                vec![
                    client(10, "Game", Some(&[500_001_000])),
                    client(20, "Other", Some(&[S + S / 2])),
                ],
            ],
            &clock,
            30,
        );
        source.report(5);
        clock.advance_seconds(1.0);
        let reset = source.report(5);
        assert_eq!(
            reset.processes.iter().map(|p| p.pid).collect::<Vec<_>>(),
            [20, 10]
        );
        assert!((reset.processes[0].gpu_percent.unwrap() - 50.0).abs() < 1e-4);
        assert_eq!(
            reset.processes[1].gpu_percent, None,
            "a reset counter is dropped, never negative"
        );
        clock.advance_seconds(1.0);
        let recovered = source.report(5);
        let game = recovered.processes.iter().find(|p| p.pid == 10).unwrap();
        assert!((game.gpu_percent.unwrap() - 50.0).abs() < 1e-4);
    }

    #[test]
    fn pid_that_disappeared_loses_its_baseline() {
        let clock = FakeClock::default();
        let source = registry_source(
            vec![
                vec![
                    client(10, "Game", Some(&[S])),
                    client(99, "Idle", Some(&[])),
                ],
                vec![client(99, "Idle", Some(&[]))],
                vec![
                    client(10, "Game", Some(&[S + S / 5])),
                    client(99, "Idle", Some(&[])),
                ],
            ],
            &clock,
            30,
        );
        source.report(5);
        clock.advance_seconds(1.0);
        assert!(source.report(5).processes.is_empty());
        clock.advance_seconds(1.0);
        let back = source.report(5);
        assert_eq!(
            back.processes
                .iter()
                .find(|p| p.pid == 10)
                .unwrap()
                .gpu_percent,
            None
        );
    }

    #[test]
    fn baseline_older_than_the_stale_limit_is_re_primed_and_reset_starts_over() {
        let clock = FakeClock::default();
        let source = registry_source(
            vec![
                vec![client(10, "Game", Some(&[S]))],
                vec![client(10, "Game", Some(&[2 * S]))],
            ],
            &clock,
            5,
        );
        source.report(5);
        clock.advance_seconds(60.0);
        let r = source.report(5);
        assert_eq!(r.processes[0].gpu_percent, None);
        assert!(r.notes.iter().any(|n| n.contains("Measuring")));

        let clock = FakeClock::default();
        let source = registry_source(
            vec![
                vec![client(10, "Game", Some(&[S]))],
                vec![client(10, "Game", Some(&[2 * S]))],
            ],
            &clock,
            30,
        );
        source.report(5);
        source.reset_baseline();
        clock.advance_seconds(1.0);
        assert_eq!(source.report(5).processes[0].gpu_percent, None);
    }

    #[test]
    fn limit_keeps_the_busiest_processes() {
        let clock = FakeClock::default();
        let source = registry_source(
            vec![
                vec![
                    client(1, "A", Some(&[0])),
                    client(2, "B", Some(&[0])),
                    client(3, "C", Some(&[0])),
                ],
                vec![
                    client(1, "A", Some(&[S / 10])),
                    client(2, "B", Some(&[9 * S / 10])),
                    client(3, "C", Some(&[S / 2])),
                ],
            ],
            &clock,
            30,
        );
        source.report(2);
        clock.advance_seconds(1.0);
        let r = source.report(2);
        assert_eq!(
            r.processes.iter().map(|p| p.pid).collect::<Vec<_>>(),
            [2, 3]
        );
        assert_eq!(r.sampled_process_count, 3);
    }

    fn recording_fallback() -> StubGpuSource {
        StubGpuSource::new(ProcessUsageReport {
            sorted_by: ProcessSortKey::Gpu,
            processes: vec![],
            sampled_process_count: 0,
            unreadable_process_count: 0,
            notes: vec!["fallback".into()],
        })
    }

    #[test]
    fn fallback_is_chosen_only_when_the_registry_has_no_app_usage() {
        let clock = FakeClock::default();
        for (snapshot, falls_back) in [
            (vec![client(1, "NoUsage", None)], true),
            (vec![], true),
            (vec![client(1, "Game", Some(&[5]))], false),
        ] {
            let fallback = recording_fallback();
            let source = DefaultGpuProcessSource::new(
                registry_source(vec![snapshot], &clock, 30),
                Box::new(fallback.clone()),
            );
            let r = source.report(5);
            assert_eq!(
                fallback.calls.lock().unwrap().len(),
                usize::from(falls_back)
            );
            assert_eq!(r.notes == ["fallback"], falls_back);
        }
        let fallback = recording_fallback();
        DefaultGpuProcessSource::new(
            registry_source(vec![vec![]], &clock, 30),
            Box::new(fallback.clone()),
        )
        .reset_baseline();
        assert_eq!(fallback.resets.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn missing_app_usage_everywhere_reports_a_note_without_fallback() {
        let source = registry_source(vec![vec![]], &FakeClock::default(), 30);
        assert!(source.report(5).notes[0].contains("no per-process GPU usage"));
    }

    #[test]
    fn powermetrics_as_root_ranks_by_gpu_and_reports_failures_as_notes() {
        let plist = br#"<?xml version="1.0"?><plist version="1.0"><dict><key>tasks</key><array>
<dict><key>name</key><string>a</string><key>pid</key><integer>1</integer><key>gputime_ms_per_s</key><real>100</real></dict>
<dict><key>name</key><string>b</string><key>pid</key><integer>2</integer><key>gputime_ms_per_s</key><real>500</real></dict>
</array></dict></plist>"#;
        let source = |out: Option<Vec<u8>>| {
            PowermetricsGpuProcessSource::new(
                1000,
                Box::new(|| true),
                Box::new(FakePowermetrics(out)),
            )
        };
        let ok = source(Some(plist.to_vec())).report(1);
        assert_eq!(
            (
                ok.processes.len(),
                ok.processes[0].pid,
                ok.sampled_process_count
            ),
            (1, 2, 2)
        );
        assert_eq!(
            source(None).report(5).notes,
            ["powermetrics did not return a GPU sample."]
        );
        assert!(
            source(Some(b"junk".to_vec())).report(5).notes[0]
                .contains("Could not read GPU figures")
        );
    }

    // Commands. Oracle forms: processes-json, top-json, mcp-call-get_top_processes, processes-help.
    fn cpu_service() -> ProcessUsageService {
        stub_service(ScriptedProcessSource::new(vec![
            set(
                0.0,
                vec![sample(1, "alpha", 0, 100), sample(2, "beta", 0, 900)],
            ),
            set(
                1.0,
                vec![
                    sample(1, "alpha", 250_000_000, 100),
                    sample(2, "beta", 10_000_000, 900),
                ],
            ),
        ]))
    }

    fn args(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn json_matches_the_oracle_shapes() {
        let slept = Mutex::new(vec![]);
        let sleep = |d: Duration| slept.lock().unwrap().push(d);
        let Ok(Output::Json(v)) = processes_command(&args(&["--json"]), &cpu_service(), &sleep)
        else {
            panic!("json expected")
        };
        for fixture in ["processes-json.shape.json", "top-json.shape.json"] {
            assert_matches_oracle_shape(fixture, &v);
        }
        assert_eq!(*slept.lock().unwrap(), [Duration::from_secs(1)]);
        assert_eq!(v["sorted_by"], "cpu");
        assert_eq!(v["processes"][0]["name"], "alpha");
        let mcp = get_top_processes_json(&cpu_service(), &json!({}), &|_| {}).unwrap();
        assert_matches_oracle_shape("mcp-call-get_top_processes.shape.json", &mcp);
        assert_eq!(mcp, v, "CLI and MCP print the same JSON");
    }

    #[test]
    fn processes_text_prints_the_table_and_notes_on_stderr() {
        let sleeps = Mutex::new(vec![]);
        let out = processes_command(&args(&["--interval", "2.5"]), &cpu_service(), &|d| {
            sleeps.lock().unwrap().push(d)
        })
        .unwrap();
        let Output::Text { stdout, stderr } = out else {
            panic!("text expected")
        };
        assert_eq!(*sleeps.lock().unwrap(), [Duration::from_millis(2500)]);
        assert_eq!(stdout.len(), 4);
        assert!(stdout[2].starts_with("1       alpha") && stdout[2].contains("25.0"));
        assert!(stderr.is_empty());
    }

    #[test]
    fn help_is_the_oracle_text_and_bad_arguments_exit_2() {
        let Ok(Output::Text { stdout, .. }) =
            processes_command(&args(&["--help"]), &cpu_service(), &|_| {
                panic!("no sampling for help")
            })
        else {
            panic!()
        };
        assert_eq!(
            stdout.join("\n") + "\n",
            oracle_text("processes-help.stdout")
        );
        for bad in [&["--sort"][..], &["--limit", "0"], &["--bogus"]] {
            let err = processes_command(&args(bad), &cpu_service(), &|_| {
                panic!("must fail before sampling")
            })
            .unwrap_err();
            assert_eq!(err.exit_code(), 2, "{bad:?}");
        }
    }

    #[test]
    fn mcp_tool_validates_sort_by_and_honours_limit() {
        let err = get_top_processes_json(&cpu_service(), &json!({"sort_by": "disk"}), &|_| {})
            .unwrap_err();
        assert_eq!(err.to_string(), "sort_by must be 'cpu', 'memory' or 'gpu'.");
        assert_eq!(err.exit_code(), 2);
        let v = get_top_processes_json(
            &cpu_service(),
            &json!({"sort_by": "MEMORY", "limit": 1}),
            &|_| {},
        )
        .unwrap();
        assert_eq!(
            (
                v["sorted_by"].as_str(),
                v["processes"].as_array().map(Vec::len)
            ),
            (Some("memory"), Some(1))
        );
        assert_eq!(v["processes"][0]["name"], "beta");
    }
}
