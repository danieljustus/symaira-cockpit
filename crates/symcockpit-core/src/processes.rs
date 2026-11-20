//! Process listing (`symcockpit processes|top`, MCP `get_top_processes`).
//!
//! Port of `ProcessUsage.swift`, `ProcessUsageService.swift` (service, not the
//! libproc adapter), `ProcessListingPresentation.swift`,
//! `IORegistryGPUProcessSource.swift` and `PowermetricsGPUProcessSource.swift`.
//! CPU and GPU shares are rates, so they exist only between two sweeps.

use std::collections::HashMap;
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

use serde::Serialize;
use serde_json::Value;
use symcockpit_contract::Error;

pub use crate::metrics::Output;

pub const DEFAULT_LIMIT: usize = 6;
/// Hard cap, so an agent asking for "all" cannot produce an unbounded reply.
pub const MAXIMUM_LIMIT: usize = 50;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ProcessSortKey {
    Cpu,
    Memory,
    Gpu,
}

impl ProcessSortKey {
    pub fn parse(raw: &str) -> Option<Self> {
        match raw.to_lowercase().as_str() {
            "cpu" => Some(Self::Cpu),
            "memory" => Some(Self::Memory),
            "gpu" => Some(Self::Gpu),
            _ => None,
        }
    }
}

/// One process's resource usage at a point in time.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct ProcessUsage {
    pub pid: i32,
    pub name: String,
    /// Share of one core in percent (200 = two cores busy); `None` until a second sweep.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cpu_percent: Option<f64>,
    pub memory_bytes: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thread_count: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gpu_percent: Option<f64>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct ProcessUsageReport {
    pub sorted_by: ProcessSortKey,
    pub processes: Vec<ProcessUsage>,
    pub sampled_process_count: usize,
    pub unreadable_process_count: usize,
    pub notes: Vec<String>,
}

impl ProcessUsageReport {
    fn empty(sorted_by: ProcessSortKey, notes: Vec<String>) -> Self {
        Self {
            sorted_by,
            processes: Vec::new(),
            sampled_process_count: 0,
            unreadable_process_count: 0,
            notes,
        }
    }
}

// MARK: - Sampling port

/// A raw per-process reading, before CPU percentages exist.
#[derive(Clone, Debug, PartialEq)]
pub struct ProcessSample {
    pub pid: i32,
    pub name: String,
    /// Cumulative CPU time (user + system) in nanoseconds.
    pub cpu_time_nanoseconds: u64,
    pub memory_bytes: u64,
    pub thread_count: Option<i64>,
    pub gpu_percent: Option<f64>,
}

/// One sweep over the process table; `timestamp` in seconds (monotonic).
#[derive(Clone, Debug, PartialEq)]
pub struct ProcessSampleSet {
    pub timestamp: f64,
    pub samples: Vec<ProcessSample>,
    /// Processes the kernel refused to describe (another user's, typically).
    pub unreadable_count: usize,
}

pub trait ProcessSampleSource: Send + Sync {
    /// Take a sweep. A PID in `known_names` must not be resolved again; the
    /// returned map holds the names resolved on this call.
    fn sample(
        &self,
        known_names: &HashMap<i32, String>,
    ) -> (ProcessSampleSet, HashMap<i32, String>);
}

/// Supplies a GPU-ranked report (a wholly different source than libproc).
pub trait GpuProcessReporting: Send + Sync {
    fn report(&self, limit: usize) -> ProcessUsageReport;
    /// Forget any sampling baseline so the next report starts a fresh one.
    fn reset_baseline(&self) {}
}

// MARK: - Ranking

/// Build a report from the newest sweep and the one before it.
pub fn rank(
    current: &ProcessSampleSet,
    previous: Option<&ProcessSampleSet>,
    sorted_by: ProcessSortKey,
    limit: usize,
) -> ProcessUsageReport {
    let elapsed = previous.map_or(0.0, |p| current.timestamp - p.timestamp);
    let previous_cpu: HashMap<i32, u64> = match previous {
        Some(p) if elapsed > 0.0 => p
            .samples
            .iter()
            .map(|s| (s.pid, s.cpu_time_nanoseconds))
            .collect(),
        _ => HashMap::new(),
    };
    let mut usages: Vec<ProcessUsage> = current
        .samples
        .iter()
        .map(|s| {
            // A restarted PID can report less CPU time than last sweep: no usable delta.
            let cpu_percent = previous_cpu
                .get(&s.pid)
                .filter(|before| s.cpu_time_nanoseconds >= **before)
                .map(|before| {
                    ((s.cpu_time_nanoseconds - before) as f64 / 1e9 / elapsed * 100.0).max(0.0)
                });
            ProcessUsage {
                pid: s.pid,
                name: s.name.clone(),
                cpu_percent,
                memory_bytes: s.memory_bytes,
                thread_count: s.thread_count,
                gpu_percent: s.gpu_percent,
            }
        })
        .collect();

    // Memory breaks ties, so a first sweep without rates still has a meaningful order.
    let by_rate = |rate: fn(&ProcessUsage) -> Option<f64>| {
        move |a: &ProcessUsage, b: &ProcessUsage| {
            let (l, r) = (rate(a).unwrap_or(-1.0), rate(b).unwrap_or(-1.0));
            if l == r {
                b.memory_bytes.cmp(&a.memory_bytes)
            } else {
                r.total_cmp(&l)
            }
        }
    };
    match sorted_by {
        ProcessSortKey::Cpu => usages.sort_by(by_rate(|u| u.cpu_percent)),
        ProcessSortKey::Memory => usages.sort_by_key(|a| std::cmp::Reverse(a.memory_bytes)),
        // Unreachable through the service (it routes `.gpu` to the GPU source); kept exhaustive.
        ProcessSortKey::Gpu => usages.sort_by(by_rate(|u| u.gpu_percent)),
    }

    let mut notes = Vec::new();
    if elapsed <= 0.0 {
        notes.push(
            "CPU percentages need a second sample; only memory is ranked so far.".to_string(),
        );
    }
    if current.unreadable_count > 0 {
        notes.push(format!(
            "{} processes are owned by another user (usually root) and are not readable without elevation.",
            current.unreadable_count
        ));
    }
    usages.truncate(limit);
    ProcessUsageReport {
        sorted_by,
        processes: usages,
        sampled_process_count: current.samples.len(),
        unreadable_process_count: current.unreadable_count,
        notes,
    }
}

// MARK: - Service

#[derive(Default)]
struct ServiceState {
    previous: Option<ProcessSampleSet>,
    /// Names by PID, pruned to each sweep's PIDs so it cannot grow without
    /// bound and a recycled PID is re-resolved instead of keeping its predecessor's name.
    names: HashMap<i32, String>,
}

/// Keeps the previous sweep so CPU percentages can be differenced.
pub struct ProcessUsageService {
    source: Box<dyn ProcessSampleSource>,
    gpu: Box<dyn GpuProcessReporting>,
    state: Mutex<ServiceState>,
}

impl ProcessUsageService {
    pub fn new(source: Box<dyn ProcessSampleSource>, gpu: Box<dyn GpuProcessReporting>) -> Self {
        Self {
            source,
            gpu,
            state: Mutex::new(ServiceState::default()),
        }
    }

    fn state(&self) -> std::sync::MutexGuard<'_, ServiceState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Take a sweep and rank it against the previous one. `.gpu` bypasses the
    /// libproc sweep entirely and defers to the GPU source.
    pub fn report(&self, sorted_by: ProcessSortKey, limit: i64) -> ProcessUsageReport {
        let limit = limit.clamp(1, MAXIMUM_LIMIT as i64) as usize;
        if sorted_by == ProcessSortKey::Gpu {
            return self.gpu.report(limit);
        }
        let known = self.state().names.clone();
        let (set, resolved) = self.source.sample(&known);
        let last = {
            let mut state = self.state();
            state.names = set
                .samples
                .iter()
                .filter_map(|s| {
                    resolved
                        .get(&s.pid)
                        .or_else(|| known.get(&s.pid))
                        .map(|n| (s.pid, n.clone()))
                })
                .collect();
            state.previous.replace(set.clone())
        };
        rank(&set, last.as_ref(), sorted_by, limit)
    }

    /// Forget the previous sweep (the UI stopped sampling; a stale baseline
    /// would average over the whole gap).
    pub fn reset_baseline(&self) {
        self.state().previous = None;
        self.gpu.reset_baseline();
    }
}

// MARK: - GPU: IORegistry

/// One GPU user client (a process's connection to an accelerator).
#[derive(Clone, Debug, PartialEq)]
pub struct GpuRegistryClient {
    pub pid: i32,
    pub name: String,
    /// `accumulatedGPUTime` (ns) of every `AppUsage` entry; `None` when the
    /// client has no `AppUsage` key at all, empty when it is present but idle.
    pub accumulated_gpu_time_nanoseconds: Option<Vec<u64>>,
}

pub trait GpuClientReading: Send + Sync {
    fn read_clients(&self) -> Vec<GpuRegistryClient>;
}

struct Baseline {
    uptime_nanoseconds: u64,
    gpu_nanoseconds: HashMap<i32, u64>,
}

/// Per-process GPU usage from the IORegistry's `AppUsage` counters, no root:
/// `percent = delta GPU time / delta wall time * 100`. The first call primes
/// the baseline (no fabricated 0 %); a vanished PID or a counter that went
/// backwards is re-primed instead of producing a bogus figure.
pub struct IoRegistryGpuProcessSource {
    reader: Box<dyn GpuClientReading>,
    uptime_nanoseconds: Box<dyn Fn() -> u64 + Send + Sync>,
    stale_after_nanoseconds: u64,
    baseline: Mutex<Option<Baseline>>,
}

impl IoRegistryGpuProcessSource {
    /// A baseline older than `stale_after` is discarded rather than averaged over the gap.
    pub fn new(
        reader: Box<dyn GpuClientReading>,
        uptime_nanoseconds: Box<dyn Fn() -> u64 + Send + Sync>,
        stale_after: Duration,
    ) -> Self {
        Self {
            reader,
            uptime_nanoseconds,
            stale_after_nanoseconds: stale_after.as_nanos() as u64,
            baseline: Mutex::new(None),
        }
    }

    /// One sample, or `None` when the registry exposes no `AppUsage` at all —
    /// the signal [`DefaultGpuProcessSource`] uses to fall back to powermetrics.
    pub fn sample(&self, limit: usize) -> Option<ProcessUsageReport> {
        let clients = self.reader.read_clients();
        if !clients
            .iter()
            .any(|c| c.accumulated_gpu_time_nanoseconds.is_some())
        {
            return None;
        }
        let now = (self.uptime_nanoseconds)();
        // Sum every AppUsage entry of every client per pid; keep the name.
        let mut totals: HashMap<i32, u64> = HashMap::new();
        let mut names: HashMap<i32, String> = HashMap::new();
        for client in &clients {
            let Some(times) = client
                .accumulated_gpu_time_nanoseconds
                .as_ref()
                .filter(|t| !t.is_empty())
            else {
                continue;
            };
            let total = totals.entry(client.pid).or_insert(0);
            *total = times.iter().fold(*total, |a, t| a.wrapping_add(*t));
            names.insert(client.pid, client.name.clone());
        }
        let previous = self
            .baseline
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .replace(Baseline {
                uptime_nanoseconds: now,
                gpu_nanoseconds: totals.clone(),
            });
        let elapsed = previous
            .as_ref()
            .filter(|p| now > p.uptime_nanoseconds)
            .map(|p| now - p.uptime_nanoseconds)
            .filter(|gap| *gap <= self.stale_after_nanoseconds);

        let mut usages: Vec<ProcessUsage> = totals
            .iter()
            .map(|(pid, total)| {
                let gpu_percent = elapsed.and_then(|elapsed| {
                    let before = previous.as_ref()?.gpu_nanoseconds.get(pid)?;
                    (total >= before).then(|| (total - before) as f64 / elapsed as f64 * 100.0)
                });
                ProcessUsage {
                    pid: *pid,
                    name: names
                        .get(pid)
                        .cloned()
                        .unwrap_or_else(|| format!("pid {pid}")),
                    cpu_percent: None,
                    memory_bytes: 0,
                    thread_count: None,
                    gpu_percent,
                }
            })
            .collect();
        usages.sort_by(|a, b| {
            let (l, r) = (a.gpu_percent.unwrap_or(-1.0), b.gpu_percent.unwrap_or(-1.0));
            r.total_cmp(&l).then(a.pid.cmp(&b.pid))
        });
        let sampled = usages.len();
        usages.truncate(limit);
        Some(ProcessUsageReport {
            sorted_by: ProcessSortKey::Gpu,
            processes: usages,
            sampled_process_count: sampled,
            unreadable_process_count: 0,
            notes: if elapsed.is_none() {
                vec!["Measuring — GPU percentages need a second sample; none is shown yet.".into()]
            } else {
                Vec::new()
            },
        })
    }
}

impl GpuProcessReporting for IoRegistryGpuProcessSource {
    fn report(&self, limit: usize) -> ProcessUsageReport {
        self.sample(limit).unwrap_or_else(|| {
            ProcessUsageReport::empty(
                ProcessSortKey::Gpu,
                vec![
                    "The IORegistry exposes no per-process GPU usage (AppUsage) on this Mac."
                        .into(),
                ],
            )
        })
    }

    fn reset_baseline(&self) {
        *self.baseline.lock().unwrap_or_else(PoisonError::into_inner) = None;
    }
}

/// The default GPU source: the unprivileged IORegistry reader, with
/// powermetrics (root only) as the fallback when the registry exposes no `AppUsage`.
pub struct DefaultGpuProcessSource {
    registry: IoRegistryGpuProcessSource,
    fallback: Box<dyn GpuProcessReporting>,
}

impl DefaultGpuProcessSource {
    pub fn new(
        registry: IoRegistryGpuProcessSource,
        fallback: Box<dyn GpuProcessReporting>,
    ) -> Self {
        Self { registry, fallback }
    }
}

impl GpuProcessReporting for DefaultGpuProcessSource {
    fn report(&self, limit: usize) -> ProcessUsageReport {
        self.registry
            .sample(limit)
            .unwrap_or_else(|| self.fallback.report(limit))
    }

    fn reset_baseline(&self) {
        self.registry.reset_baseline();
        self.fallback.reset_baseline();
    }
}

// MARK: - GPU: powermetrics (root-only fallback)

/// Runs `powermetrics` once and returns its stdout; `None` on spawn failure,
/// timeout or non-zero exit. Never elevates: it only runs when already root.
pub trait PowermetricsRunner: Send + Sync {
    fn sample(&self, interval_milliseconds: u64) -> Option<Vec<u8>>;
}

pub struct PowermetricsGpuProcessSource {
    interval_milliseconds: u64,
    is_root: Box<dyn Fn() -> bool + Send + Sync>,
    runner: Box<dyn PowermetricsRunner>,
}

impl PowermetricsGpuProcessSource {
    pub fn new(
        interval_milliseconds: u64,
        is_root: Box<dyn Fn() -> bool + Send + Sync>,
        runner: Box<dyn PowermetricsRunner>,
    ) -> Self {
        Self {
            interval_milliseconds,
            is_root,
            runner,
        }
    }

    fn empty(note: &str) -> ProcessUsageReport {
        ProcessUsageReport::empty(ProcessSortKey::Gpu, vec![note.to_string()])
    }
}

impl GpuProcessReporting for PowermetricsGpuProcessSource {
    fn report(&self, limit: usize) -> ProcessUsageReport {
        if !(self.is_root)() {
            return Self::empty(
                "GPU sampling needs root — powermetrics refuses to run otherwise. Run \
                 `sudo symcockpit processes --sort gpu`, or use the app's \
                 \"Load GPU usage\" action, which prompts for your administrator password.",
            );
        }
        let Some(output) = self.runner.sample(self.interval_milliseconds) else {
            return Self::empty("powermetrics did not return a GPU sample.");
        };
        let Some(mut processes) = parse_powermetrics_gpu(&output) else {
            return Self::empty(
                "Could not read GPU figures from powermetrics's output — its format may have \
                 changed on this macOS version.",
            );
        };
        processes.sort_by(|a, b| {
            b.gpu_percent
                .unwrap_or(0.0)
                .total_cmp(&a.gpu_percent.unwrap_or(0.0))
        });
        let sampled = processes.len();
        processes.truncate(limit);
        ProcessUsageReport {
            sorted_by: ProcessSortKey::Gpu,
            processes,
            sampled_process_count: sampled,
            unreadable_process_count: 0,
            notes: Vec::new(),
        }
    }
}

/// powermetrics `-f plist` output: NUL-separated property lists (one per
/// sample). The per-process key names are undocumented and have shifted across
/// macOS releases, so several are tried in order; a miss yields `None`, never a made-up number.
pub fn parse_powermetrics_gpu(data: &[u8]) -> Option<Vec<ProcessUsage>> {
    let end = data.iter().position(|b| *b == 0).unwrap_or(data.len());
    let root = plist::Value::from_reader(std::io::Cursor::new(&data[..end])).ok()?;
    let root = root.as_dictionary()?;
    let tasks = ["tasks", "processes", "coalitions"]
        .iter()
        .find_map(|key| root.get(key)?.as_array())?;
    let number = |d: &plist::Dictionary, keys: &[&str]| {
        keys.iter().find_map(|k| match d.get(k)? {
            plist::Value::Integer(i) => i.as_signed().map(|v| v as f64),
            plist::Value::Real(r) => Some(*r),
            plist::Value::Boolean(b) => Some(f64::from(u8::from(*b))),
            _ => None,
        })
    };
    let usages: Vec<ProcessUsage> = tasks
        .iter()
        .filter_map(|task| {
            let task = task.as_dictionary()?;
            let name = ["name", "process", "pname"]
                .iter()
                .find_map(|k| task.get(k)?.as_string())?;
            let pid = i32::try_from(number(task, &["pid", "id"])? as i64).ok()?;
            let ms_per_second = number(
                task,
                &["gputime_ms_per_s", "gpu_ms_per_s", "gputime", "gpu_time_ms"],
            )?;
            Some(ProcessUsage {
                pid,
                name: name.to_string(),
                cpu_percent: None,
                memory_bytes: 0,
                thread_count: None,
                // ms of GPU time per second of wall clock = percent of one GPU's time.
                gpu_percent: Some(ms_per_second / 10.0),
            })
        })
        .collect();
    (!usages.is_empty()).then_some(usages)
}

// MARK: - Command: processes / top

/// Resolved `processes [--sort cpu|memory|gpu] [--limit N] [--interval <seconds>] [--json]`.
#[derive(Clone, Debug, PartialEq)]
pub struct Options {
    pub sorted_by: ProcessSortKey,
    pub limit: i64,
    /// Seconds between the two sweeps that establish the CPU baseline.
    pub interval: f64,
    pub wants_json: bool,
    pub wants_help: bool,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            sorted_by: ProcessSortKey::Cpu,
            limit: DEFAULT_LIMIT as i64,
            interval: 1.0,
            wants_json: false,
            wants_help: false,
        }
    }
}

/// Usage text of `processes --help` (verbatim from Swift, which still says `symtune`).
pub const USAGE_LINES: [&str; 8] = [
    "Usage: symtune processes [--sort cpu|memory|gpu] [--limit N] [--interval <seconds>] [--json]",
    "",
    "Rank running processes by CPU, memory (RAM), or GPU usage. CPU is a rate,",
    "so the command samples twice --interval seconds apart (default 1.0) before",
    "reporting. Processes owned by another user are counted but not readable",
    "without elevation. GPU time is read from the IORegistry without root;",
    "only when the registry exposes no per-process GPU usage does the root-only",
    "powermetrics fallback apply (run this command with sudo then).",
];

/// An unknown flag is an error, so a typo does not quietly rank by CPU.
pub fn parse_options(args: &[String]) -> Result<Options, Error> {
    if args.iter().any(|a| a == "--help" || a == "-h") {
        return Ok(Options {
            wants_help: true,
            ..Options::default()
        });
    }
    let mut options = Options::default();
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        let usage = |m: &str| Error::Usage(format!("processes: {m}"));
        match arg.as_str() {
            "--json" => options.wants_json = true,
            "--sort" => {
                options.sorted_by = iter
                    .next()
                    .and_then(|v| ProcessSortKey::parse(v))
                    .ok_or_else(|| usage("--sort expects 'cpu', 'memory', or 'gpu'"))?;
            }
            "--limit" => {
                options.limit = iter
                    .next()
                    .and_then(|v| v.parse::<i64>().ok())
                    .filter(|v| *v > 0)
                    .ok_or_else(|| usage("--limit expects a positive integer"))?;
            }
            "--interval" => {
                // Swift accepts inf and then sleeps forever; a finite bound keeps `Duration` valid.
                options.interval = iter
                    .next()
                    .and_then(|v| v.parse::<f64>().ok())
                    .filter(|v| *v > 0.0 && v.is_finite())
                    .ok_or_else(|| usage("--interval expects a positive number of seconds"))?;
            }
            other => return Err(usage(&format!("unexpected argument '{other}'"))),
        }
    }
    Ok(options)
}

const PID_WIDTH: usize = 8;
const NAME_WIDTH: usize = 34;
const CPU_WIDTH: usize = 8;
const MEMORY_WIDTH: usize = 10;
const RULE_WIDTH: usize = PID_WIDTH + NAME_WIDTH + CPU_WIDTH + 1 + MEMORY_WIDTH;

/// Human-readable byte size ("1.8 GB", "482 MB", "96 KB").
pub fn format_bytes(value: u64) -> String {
    let bytes = value as f64;
    if bytes >= 1_073_741_824.0 {
        format!("{:.1} GB", bytes / 1_073_741_824.0)
    } else if bytes >= 1_048_576.0 {
        format!("{:.0} MB", bytes / 1_048_576.0)
    } else if bytes >= 1_024.0 {
        format!("{:.0} KB", bytes / 1_024.0)
    } else {
        format!("{value} B")
    }
}

/// Pad or clip to `width` characters.
// shortcut: counts `char`s, Swift counts grapheme clusters; differs only for combining marks.
fn column(text: &str, width: usize, align_right: bool) -> String {
    let clipped: String = text.chars().take(width).collect();
    let padding = " ".repeat(width.saturating_sub(clipped.chars().count()));
    if align_right {
        padding + &clipped
    } else {
        clipped + &padding
    }
}

/// `n/a` when there is no figure, so a missing rate never reads as idleness.
fn rate_text(value: Option<f64>) -> String {
    value.map_or_else(|| "n/a".into(), |v| format!("{v:.1}"))
}

/// The plain-text table, one string per line. A GPU report has no
/// CPU/memory figures, so its second column shows GPU % instead of memory.
pub fn table_lines(report: &ProcessUsageReport) -> Vec<String> {
    let gpu = report.sorted_by == ProcessSortKey::Gpu;
    let row = |pid: &str, name: &str, cpu: &str, second: &str| {
        format!(
            "{}{}{} {}",
            column(pid, PID_WIDTH, false),
            column(name, NAME_WIDTH, false),
            column(cpu, CPU_WIDTH, true),
            column(second, MEMORY_WIDTH, true)
        )
    };
    let mut lines = vec![
        row(
            "PID",
            "PROCESS",
            "CPU %",
            if gpu { "GPU %" } else { "MEMORY" },
        ),
        "-".repeat(RULE_WIDTH),
    ];
    for p in &report.processes {
        let second = if gpu {
            rate_text(p.gpu_percent)
        } else {
            format_bytes(p.memory_bytes)
        };
        lines.push(row(
            &p.pid.to_string(),
            &p.name,
            &rate_text(p.cpu_percent),
            &second,
        ));
    }
    lines
}

/// Two sweeps `interval` apart (the first only sets the CPU baseline), then the ranked report.
pub fn sample_twice(
    service: &ProcessUsageService,
    sorted_by: ProcessSortKey,
    limit: i64,
    interval: Duration,
    sleep: &dyn Fn(Duration),
) -> ProcessUsageReport {
    service.report(sorted_by, limit);
    sleep(interval);
    service.report(sorted_by, limit)
}

fn to_value(report: &ProcessUsageReport) -> Result<Value, Error> {
    serde_json::to_value(report).map_err(|e| Error::Failed(e.to_string()))
}

/// `symcockpit processes|top ...`. `sleep` waits between the two sweeps (injectable for tests).
pub fn processes_command(
    args: &[String],
    service: &ProcessUsageService,
    sleep: &dyn Fn(Duration),
) -> Result<Output, Error> {
    let options = parse_options(args)?;
    if options.wants_help {
        return Ok(Output::Text {
            stdout: USAGE_LINES.iter().map(|l| l.to_string()).collect(),
            stderr: Vec::new(),
        });
    }
    let report = sample_twice(
        service,
        options.sorted_by,
        options.limit,
        Duration::from_secs_f64(options.interval),
        sleep,
    );
    processes_output(&report, options.wants_json)
}

/// The JSON document, or the table on stdout with the notes on stderr.
pub fn processes_output(report: &ProcessUsageReport, json: bool) -> Result<Output, Error> {
    if json {
        return to_value(report).map(Output::Json);
    }
    Ok(Output::Text {
        stdout: table_lines(report),
        stderr: report.notes.iter().map(|n| format!("note: {n}")).collect(),
    })
}

/// MCP `get_top_processes` (`sort_by`: cpu|memory|gpu, `limit`): two sweeps one second apart.
pub fn get_top_processes_json(
    service: &ProcessUsageService,
    arguments: &Value,
    sleep: &dyn Fn(Duration),
) -> Result<Value, Error> {
    let sort = match arguments.get("sort_by").and_then(Value::as_str) {
        None => ProcessSortKey::Cpu,
        Some(raw) => ProcessSortKey::parse(raw)
            .ok_or_else(|| Error::Usage("sort_by must be 'cpu', 'memory' or 'gpu'.".into()))?,
    };
    let limit = arguments
        .get("limit")
        .and_then(|v| {
            v.as_i64()
                .or_else(|| v.as_f64().filter(|f| f.fract() == 0.0).map(|f| f as i64))
        })
        .unwrap_or(DEFAULT_LIMIT as i64);
    to_value(&sample_twice(
        service,
        sort,
        limit,
        Duration::from_secs(1),
        sleep,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

    fn sample(
        pid: i32,
        name: &str,
        cpu_ns: u64,
        memory_mb: u64,
        gpu: Option<f64>,
    ) -> ProcessSample {
        ProcessSample {
            pid,
            name: name.into(),
            cpu_time_nanoseconds: cpu_ns,
            memory_bytes: memory_mb * 1_048_576,
            thread_count: Some(4),
            gpu_percent: gpu,
        }
    }

    fn set(timestamp: f64, samples: Vec<ProcessSample>, unreadable: usize) -> ProcessSampleSet {
        ProcessSampleSet {
            timestamp,
            samples,
            unreadable_count: unreadable,
        }
    }

    // Vectors: tuning/Tests/SymCockpitCoreTests/ProcessUsageTests.swift (ProcessUsageRankingTests)
    #[test]
    fn cpu_percent_is_the_rate_between_two_sweeps() {
        let first = set(100.0, vec![sample(1, "busy", 0, 10, None)], 0);
        let second = set(101.0, vec![sample(1, "busy", 500_000_000, 10, None)], 0);
        let r = rank(&second, Some(&first), ProcessSortKey::Cpu, 5);
        assert!((r.processes[0].cpu_percent.unwrap() - 50.0).abs() < 1e-3);
        let third = set(1.0, vec![sample(1, "render", 3_000_000_000, 10, None)], 0);
        let base = set(0.0, vec![sample(1, "render", 0, 10, None)], 0);
        let r = rank(&third, Some(&base), ProcessSortKey::Cpu, 5);
        assert!((r.processes[0].cpu_percent.unwrap() - 300.0).abs() < 1e-3);
    }

    #[test]
    fn first_sweep_reports_memory_but_no_cpu_and_says_so() {
        let only = set(
            10.0,
            vec![
                sample(1, "small", 5_000, 10, None),
                sample(2, "large", 1_000, 900, None),
            ],
            0,
        );
        let r = rank(&only, None, ProcessSortKey::Cpu, 5);
        assert!(r.processes.iter().all(|p| p.cpu_percent.is_none()));
        assert_eq!(r.processes[0].pid, 2);
        assert!(r.notes.iter().any(|n| n.contains("second sample")));
    }

    #[test]
    fn restarted_pid_does_not_underflow() {
        let first = set(0.0, vec![sample(7, "old", 9_000_000_000, 50, None)], 0);
        let second = set(1.0, vec![sample(7, "new", 1_000_000, 50, None)], 0);
        assert_eq!(
            rank(&second, Some(&first), ProcessSortKey::Cpu, 5).processes[0].cpu_percent,
            None
        );
    }

    #[test]
    fn memory_sort_limit_and_unreadable_counts() {
        let samples = (1..=20)
            .map(|i| sample(i, &format!("p{i}"), 0, i as u64, None))
            .collect();
        let r = rank(&set(0.0, samples, 212), None, ProcessSortKey::Memory, 3);
        assert_eq!(
            r.processes.iter().map(|p| p.pid).collect::<Vec<_>>(),
            [20, 19, 18]
        );
        assert_eq!(
            (r.sampled_process_count, r.unreadable_process_count),
            (20, 212)
        );
        assert!(r.notes.iter().any(|n| n.contains("another user")));
    }

    #[test]
    fn gpu_ranking_orders_known_values_and_falls_back_to_memory() {
        let known = set(
            0.0,
            vec![
                sample(1, "light", 0, 700, Some(5.0)),
                sample(2, "heavy", 0, 100, Some(45.0)),
            ],
            0,
        );
        let r = rank(&known, None, ProcessSortKey::Gpu, 5);
        assert_eq!(
            r.processes
                .iter()
                .map(|p| p.gpu_percent)
                .collect::<Vec<_>>(),
            [Some(45.0), Some(5.0)]
        );
        let unknown = set(
            0.0,
            vec![
                sample(1, "small", 0, 100, None),
                sample(2, "large", 0, 700, None),
            ],
            0,
        );
        assert_eq!(
            rank(&unknown, None, ProcessSortKey::Gpu, 5).processes[0].pid,
            2
        );
    }

    // Vectors: ProcessListingPresentationTests.swift
    #[test]
    fn parses_defaults_and_flags() {
        let d = parse_options(&[]).unwrap();
        assert_eq!(
            (d.sorted_by, d.limit, d.interval),
            (ProcessSortKey::Cpu, 6, 1.0)
        );
        let o = parse_options(&args(&[
            "--sort",
            "MEMORY",
            "--limit",
            "12",
            "--json",
            "--interval",
            "2.5",
        ]))
        .unwrap();
        assert_eq!(
            (o.sorted_by, o.limit, o.interval, o.wants_json),
            (ProcessSortKey::Memory, 12, 2.5, true)
        );
        assert!(
            parse_options(&args(&["--bogus", "--help"]))
                .unwrap()
                .wants_help
        );
    }

    #[test]
    fn rejects_bad_arguments_with_usage_errors() {
        for (bad, fragment) in [
            (vec!["--top"], "unexpected argument '--top'"),
            (vec!["memory"], "unexpected argument 'memory'"),
            (vec!["--sort"], "--sort"),
            (vec!["--sort", "disk"], "--sort"),
            (vec!["--limit"], "--limit"),
            (vec!["--limit", "0"], "--limit"),
            (vec!["--limit", "-3"], "--limit"),
            (vec!["--limit", "many"], "--limit"),
            (vec!["--interval"], "--interval"),
            (vec!["--interval", "0"], "--interval"),
            (vec!["--interval", "-1"], "--interval"),
            (vec!["--interval", "abc"], "--interval"),
            (vec!["--interval", "inf"], "--interval"),
        ] {
            let err = parse_options(&args(&bad)).unwrap_err();
            assert_eq!(err.exit_code(), 2, "{bad:?}");
            assert!(
                err.to_string().starts_with("processes: ") && err.to_string().contains(fragment),
                "{bad:?}: {err}"
            );
        }
    }

    fn listing(sorted_by: ProcessSortKey, processes: Vec<ProcessUsage>) -> ProcessUsageReport {
        ProcessUsageReport {
            sorted_by,
            sampled_process_count: processes.len(),
            processes,
            unreadable_process_count: 0,
            notes: vec![],
        }
    }

    fn usage(pid: i32, name: &str, cpu: Option<f64>, mem: u64, gpu: Option<f64>) -> ProcessUsage {
        ProcessUsage {
            pid,
            name: name.into(),
            cpu_percent: cpu,
            memory_bytes: mem,
            thread_count: None,
            gpu_percent: gpu,
        }
    }

    /// Format rule derived from ProcessListingPresentation.swift: PID(8) NAME(34)
    /// CPU(8, right) space MEMORY(10, right); rule of RULE_WIDTH dashes; `n/a` for a missing rate.
    #[test]
    fn table_layout_follows_the_swift_format_rule() {
        let lines = table_lines(&listing(
            ProcessSortKey::Cpu,
            vec![
                usage(42, "safari", Some(12.34), 2_147_483_648, None),
                usage(7, "fresh", None, 1_048_576, None),
                usage(1, &"x".repeat(80), Some(1.0), 1024, None),
            ],
        ));
        assert_eq!(
            lines[0],
            format!(
                "{:<8}{:<34}{:>8} {:>10}",
                "PID", "PROCESS", "CPU %", "MEMORY"
            )
        );
        assert_eq!(lines[1], "-".repeat(61));
        assert_eq!(
            lines[2],
            format!("{:<8}{:<34}{:>8} {:>10}", "42", "safari", "12.3", "2.0 GB")
        );
        assert_eq!(
            lines[3],
            format!("{:<8}{:<34}{:>8} {:>10}", "7", "fresh", "n/a", "1 MB")
        );
        assert_eq!(
            lines[4],
            format!("{:<8}{}{:>8} {:>10}", "1", "x".repeat(34), "1.0", "1 KB")
        );
        assert!(lines.iter().skip(2).all(|l| l.chars().count() == 61));
        assert_eq!(table_lines(&listing(ProcessSortKey::Cpu, vec![])).len(), 2);
    }

    #[test]
    fn gpu_table_shows_gpu_percent_in_the_second_column() {
        let lines = table_lines(&listing(
            ProcessSortKey::Gpu,
            vec![
                usage(2, "renderer", None, 0, Some(12.34)),
                usage(1, "idle", None, 0, None),
            ],
        ));
        assert!(lines[0].ends_with("     GPU %"));
        assert!(lines[2].ends_with("      12.3") && lines[3].ends_with("       n/a"));
    }

    #[test]
    fn byte_formatting_thresholds() {
        assert_eq!(format_bytes(512), "512 B");
        assert_eq!(format_bytes(1024), "1 KB");
        assert_eq!(format_bytes(1_048_576), "1 MB");
        assert_eq!(format_bytes(1_932_735_283), "1.8 GB");
    }

    // Vectors: PowermetricsGPUProcessSourceTests.swift (the schema is the parser's assumption).
    fn tasks_plist(extra: &[u8]) -> Vec<u8> {
        let mut data = br#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>tasks</key><array>
<dict><key>name</key><string>renderer</string><key>pid</key><integer>111</integer><key>gputime_ms_per_s</key><real>250.0</real></dict>
<dict><key>name</key><string>idle-app</string><key>pid</key><integer>222</integer><key>gputime_ms_per_s</key><real>0.0</real></dict>
</array></dict></plist>"#
            .to_vec();
        data.extend_from_slice(extra);
        data
    }

    #[test]
    fn parses_gpu_time_from_the_tasks_schema_with_nul_terminator() {
        for extra in [&b""[..], &b"\0"[..], &b"\0trailing sample"[..]] {
            let p = parse_powermetrics_gpu(&tasks_plist(extra)).unwrap();
            assert_eq!(p.len(), 2);
            let renderer = p.iter().find(|p| p.pid == 111).unwrap();
            assert_eq!(renderer.name, "renderer");
            assert!((renderer.gpu_percent.unwrap() - 25.0).abs() < 1e-3);
        }
    }

    #[test]
    fn unrecognized_or_invalid_plist_yields_none() {
        let other = br#"<?xml version="1.0"?><plist version="1.0"><dict><key>something_else</key><dict/></dict></plist>"#;
        assert!(parse_powermetrics_gpu(other).is_none());
        assert!(parse_powermetrics_gpu(b"not a plist").is_none());
    }

    #[test]
    fn unprivileged_powermetrics_never_runs_and_explains() {
        struct Boom;
        impl PowermetricsRunner for Boom {
            fn sample(&self, _: u64) -> Option<Vec<u8>> {
                panic!("must not run without root");
            }
        }
        let source = PowermetricsGpuProcessSource::new(1000, Box::new(|| false), Box::new(Boom));
        let r = source.report(5);
        assert_eq!(r.sorted_by, ProcessSortKey::Gpu);
        assert!(r.processes.is_empty() && r.notes[0].contains("root"));
    }
}
