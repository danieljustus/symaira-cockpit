//! The process table through `libproc`, and the root-only `powermetrics` runner.
//! Port of `LibprocProcessSampleSource` (`ProcessUsageService.swift`) and the
//! process-running part of `PowermetricsGPUProcessSource.swift`.
//!
//! No shelling out to `ps`/`top`: a sweep costs milliseconds, and `ps`'s `%cpu`
//! averages over the process's whole lifetime.

use std::collections::HashMap;
use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use symcockpit_contract::Error;
use symcockpit_core::kill::{ProcessControl, ProcessIdentity, SignalError};
use symcockpit_core::processes::{
    DefaultGpuProcessSource, GpuProcessReporting, IoRegistryGpuProcessSource,
    PowermetricsGpuProcessSource, PowermetricsRunner, ProcessSample, ProcessSampleSet,
    ProcessSampleSource, ProcessUsageService,
};

use crate::gpu::IoRegistryGpuReader;
use crate::host::{monotonic_nanoseconds, monotonic_seconds};

/// `PROC_PIDPATHINFO_MAXSIZE` (4 x `MAXPATHLEN`) is a C macro `libc` does not export.
const PATH_BUFFER_SIZE: usize = 4 * 1024;

/// Stop at the first NUL within the buffer; invalid UTF-8 becomes U+FFFD.
pub fn decode_name_buffer(buffer: &[libc::c_char]) -> String {
    let bytes: Vec<u8> = buffer
        .iter()
        .take_while(|c| **c != 0)
        .map(|c| *c as u8)
        .collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

fn all_pids() -> Vec<i32> {
    // SAFETY: a NULL buffer with size 0 asks only for the process count.
    let probe = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
    if probe <= 0 {
        return Vec::new();
    }
    // Head-room for processes spawned between the probe and the read.
    let mut pids = vec![0i32; probe as usize + 64];
    // SAFETY: the buffer holds `pids.len()` ints, and the byte count passed matches it.
    let written = unsafe {
        libc::proc_listallpids(
            pids.as_mut_ptr().cast(),
            (pids.len() * size_of::<i32>()) as libc::c_int,
        )
    };
    pids.truncate(written.max(0) as usize);
    pids.retain(|p| *p > 0);
    pids
}

/// Fails with EPERM for processes owned by another user: expected, reported as unreadable.
fn task_info(pid: i32) -> Option<libc::proc_taskinfo> {
    let mut info = std::mem::MaybeUninit::<libc::proc_taskinfo>::zeroed();
    let size = size_of::<libc::proc_taskinfo>() as libc::c_int;
    // SAFETY: `info` is a writable proc_taskinfo of `size` bytes.
    let got = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTASKINFO,
            0,
            info.as_mut_ptr().cast(),
            size,
        )
    };
    // SAFETY: fully written when the kernel returned exactly `size` bytes.
    (got == size).then(|| unsafe { info.assume_init() })
}

fn name_of(pid: i32) -> String {
    let mut path = vec![0 as libc::c_char; PATH_BUFFER_SIZE];
    // SAFETY: the buffer is writable for `path.len()` bytes.
    if unsafe { libc::proc_pidpath(pid, path.as_mut_ptr().cast(), path.len() as u32) } > 0 {
        let full = decode_name_buffer(&path);
        if let Some(last) = full.split('/').rfind(|part| !part.is_empty()) {
            return last.to_string();
        }
    }
    // The short name is truncated to 15 characters but always available.
    let mut short = vec![0 as libc::c_char; 256];
    // SAFETY: the buffer is writable for `short.len()` bytes.
    if unsafe { libc::proc_name(pid, short.as_mut_ptr().cast(), short.len() as u32) } > 0 {
        let name = decode_name_buffer(&short);
        if !name.is_empty() {
            return name;
        }
    }
    format!("pid {pid}")
}

pub struct LibprocProcessSampleSource;

impl ProcessSampleSource for LibprocProcessSampleSource {
    fn sample(
        &self,
        known_names: &HashMap<i32, String>,
    ) -> (ProcessSampleSet, HashMap<i32, String>) {
        let pids = all_pids();
        let (mut samples, mut resolved, mut unreadable) =
            (Vec::with_capacity(pids.len()), HashMap::new(), 0);
        for pid in pids {
            let Some(info) = task_info(pid) else {
                unreadable += 1;
                continue;
            };
            // Only a PID seen for the first time pays for proc_pidpath.
            let name = known_names.get(&pid).cloned().unwrap_or_else(|| {
                let name = name_of(pid);
                resolved.insert(pid, name.clone());
                name
            });
            samples.push(ProcessSample {
                pid,
                name,
                cpu_time_nanoseconds: info.pti_total_user.wrapping_add(info.pti_total_system),
                memory_bytes: info.pti_resident_size,
                thread_count: Some(i64::from(info.pti_threadnum)),
                gpu_percent: None,
            });
        }
        let set = ProcessSampleSet {
            timestamp: monotonic_seconds(),
            samples,
            unreadable_count: unreadable,
        };
        (set, resolved)
    }
}

/// Runs `/usr/bin/powermetrics` for one GPU/task sample. Only reached when this
/// process is already root (see `PowermetricsGpuProcessSource`); never elevates.
pub struct LivePowermetricsRunner;

impl PowermetricsRunner for LivePowermetricsRunner {
    fn sample(&self, interval_milliseconds: u64) -> Option<Vec<u8>> {
        let mut child = Command::new("/usr/bin/powermetrics")
            .args([
                "-i",
                &interval_milliseconds.to_string(),
                "-n",
                "1",
                "--samplers",
                "tasks",
                "--show-process-gpu",
                "-f",
                "plist",
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .ok()?;
        let mut stdout = child.stdout.take()?;
        let reader = std::thread::spawn(move || {
            let mut out = Vec::new();
            stdout.read_to_end(&mut out).map(|_| out)
        });
        let deadline =
            Instant::now() + Duration::from_millis(interval_milliseconds) + Duration::from_secs(10);
        let status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break Some(status),
                Ok(None) if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(50))
                }
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    break None;
                }
            }
        };
        let output = reader.join().ok()?.ok()?;
        status.filter(|s| s.success()).map(|_| output)
    }
}

/// The default GPU source: IORegistry `AppUsage`, powermetrics (root only) as the fallback.
pub fn live_gpu_source() -> Box<dyn GpuProcessReporting> {
    let registry = IoRegistryGpuProcessSource::new(
        Box::new(IoRegistryGpuReader),
        Box::new(monotonic_nanoseconds),
        Duration::from_secs(30),
    );
    let powermetrics = PowermetricsGpuProcessSource::new(
        1000,
        // SAFETY: geteuid has no preconditions.
        Box::new(|| unsafe { libc::geteuid() } == 0),
        Box::new(LivePowermetricsRunner),
    );
    Box::new(DefaultGpuProcessSource::new(
        registry,
        Box::new(powermetrics),
    ))
}

/// The process service of one process (keep it: CPU percentages need the previous sweep).
pub fn live_process_service() -> ProcessUsageService {
    ProcessUsageService::new(Box::new(LibprocProcessSampleSource), live_gpu_source())
}

/// The live process table for ending a process: identity from `proc_pidinfo`,
/// SIGTERM through `kill(2)`.
pub struct LiveProcessControl;

impl ProcessControl for LiveProcessControl {
    fn identity(&self, pid: i32) -> Result<Option<ProcessIdentity>, Error> {
        let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::zeroed();
        let size = size_of::<libc::proc_bsdinfo>() as libc::c_int;
        // SAFETY: `info` is a writable proc_bsdinfo of `size` bytes.
        let got = unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDTBSDINFO,
                0,
                info.as_mut_ptr().cast(),
                size,
            )
        };
        if got != size {
            let errno = std::io::Error::last_os_error();
            return match errno.raw_os_error() {
                Some(libc::ESRCH) | Some(0) | None => Ok(None),
                _ => Err(Error::Failed(format!("process {pid}: {errno}"))),
            };
        }
        // SAFETY: fully written when the kernel returned exactly `size` bytes.
        let info = unsafe { info.assume_init() };
        // A killed child that nobody has waited for yet: already gone.
        if info.pbi_status == libc::SZOMB {
            return Ok(None);
        }
        let mut path = vec![0 as libc::c_char; PATH_BUFFER_SIZE];
        // SAFETY: the buffer is writable for `path.len()` bytes.
        let len = unsafe { libc::proc_pidpath(pid, path.as_mut_ptr().cast(), path.len() as u32) };
        Ok(Some(ProcessIdentity {
            pid,
            name: name_of(pid),
            path: (len > 0).then(|| decode_name_buffer(&path)),
            started_s: info.pbi_start_tvsec as i64,
            started_us: info.pbi_start_tvusec as i64,
            uid: info.pbi_uid,
        }))
    }

    fn terminate(&self, pid: i32) -> Result<(), SignalError> {
        // SAFETY: kill(2) takes two plain integers.
        if unsafe { libc::kill(pid, libc::SIGTERM) } == 0 {
            return Ok(());
        }
        let errno = std::io::Error::last_os_error();
        Err(match errno.raw_os_error() {
            Some(libc::ESRCH) => SignalError::NotFound,
            Some(libc::EPERM) => SignalError::Denied(errno.to_string()),
            _ => SignalError::Other(errno.to_string()),
        })
    }

    fn current_pid(&self) -> i32 {
        std::process::id() as i32
    }

    fn current_uid(&self) -> u32 {
        // SAFETY: geteuid has no preconditions.
        unsafe { libc::geteuid() }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Vectors: tuning/Tests/SymCockpitCoreTests/ProcessNameDecodingTests.swift
    fn buffer(bytes: &[u8]) -> Vec<libc::c_char> {
        bytes.iter().map(|b| *b as libc::c_char).collect()
    }

    #[test]
    fn decoding_stops_at_the_first_nul_and_is_bounded() {
        assert_eq!(decode_name_buffer(&buffer(&[65, 0, 66])), "A");
        assert_eq!(decode_name_buffer(&buffer(&[65, 66])), "AB");
        assert_eq!(decode_name_buffer(&[]), "");
        assert_eq!(decode_name_buffer(&buffer(&[0])), "");
        assert_eq!(
            decode_name_buffer(
                &buffer("プロセス".as_bytes())
                    .iter()
                    .copied()
                    .chain([0, 65])
                    .collect::<Vec<_>>()
            ),
            "プロセス"
        );
        assert_eq!(decode_name_buffer(&buffer(&[65, 255, 0])), "A\u{FFFD}");
    }

    #[test]
    fn libproc_source_reads_this_process() {
        let (set, resolved) = LibprocProcessSampleSource.sample(&HashMap::new());
        let own = set
            .samples
            .iter()
            .find(|s| s.pid == std::process::id() as i32)
            .expect("own pid readable");
        assert!(own.memory_bytes > 0 && own.thread_count.unwrap_or(0) > 0);
        assert!(
            resolved.contains_key(&own.pid),
            "first sweep resolves names"
        );
        // A cached PID is not resolved again.
        let known = HashMap::from([(own.pid, "cached".to_string())]);
        let (again, resolved_again) = LibprocProcessSampleSource.sample(&known);
        assert!(!resolved_again.contains_key(&own.pid));
        assert_eq!(
            again
                .samples
                .iter()
                .find(|s| s.pid == own.pid)
                .unwrap()
                .name,
            "cached"
        );
    }

    /// Live read-only check, run once by hand: `cargo test -p symcockpit-macos -- --ignored live`.
    #[test]
    #[ignore = "reads the real process table and IORegistry"]
    fn live_processes_match_the_oracle_shapes() {
        use symcockpit_core::processes::{Output, processes_command};
        use symcockpit_testkit::metrics::assert_matches_oracle_shape;
        let service = live_process_service();
        let sleep = |d: Duration| std::thread::sleep(d);
        let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        let Ok(Output::Json(v)) =
            processes_command(&args(&["--json", "--limit", "5"]), &service, &sleep)
        else {
            panic!("json expected")
        };
        for fixture in [
            "processes-json.shape.json",
            "top-json.shape.json",
            "mcp-call-get_top_processes.shape.json",
        ] {
            assert_matches_oracle_shape(fixture, &v);
        }
        assert!(
            v["processes"][0]["cpu_percent"].is_number(),
            "second sweep has CPU rates"
        );
        assert!(v["sampled_process_count"].as_u64().unwrap() > 0);
        let Ok(Output::Json(gpu)) =
            processes_command(&args(&["--json", "--sort", "gpu"]), &service, &sleep)
        else {
            panic!()
        };
        let Ok(Output::Json(by_memory)) = processes_command(
            &args(&["--json", "--sort", "memory", "--limit", "3"]),
            &service,
            &sleep,
        ) else {
            panic!()
        };
        let top: Vec<_> = by_memory["processes"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|p| (&p["pid"], &p["memory_bytes"], &p["thread_count"]))
            .collect();
        println!("live: top by memory (pid, bytes, threads) {top:?}");
        println!(
            "live: sampled={} unreadable={} gpu_clients={} gpu_notes={:?}",
            v["sampled_process_count"],
            v["unreadable_process_count"],
            gpu["sampled_process_count"],
            gpu["notes"]
        );
    }
}
