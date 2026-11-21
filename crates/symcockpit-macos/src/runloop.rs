//! The main run loop as the agent's wait point (architecture §10: the main thread
//! spins a CFRunLoop for platform callbacks, here the CGEvent tap).
//!
//! A [`RunLoopWaker`] is a manual run-loop source on the creating thread's loop.
//! Another thread calls [`RunLoopWaker::wake`] after queueing work; the owner's
//! [`RunLoopWaker::run_for`] then returns at once. The source stays signalled
//! until the loop has handled it, so a wake-up between "queue is empty" and
//! "loop entered" is not lost, and nobody has to poll.

use std::ffi::c_void;
use std::time::Duration;

#[repr(C)]
struct SourceContext {
    version: isize,
    info: *mut c_void,
    retain: Option<extern "C" fn(*const c_void) -> *const c_void>,
    release: Option<extern "C" fn(*const c_void)>,
    copy_description: Option<extern "C" fn(*const c_void) -> *const c_void>,
    equal: Option<extern "C" fn(*const c_void, *const c_void) -> u8>,
    hash: Option<extern "C" fn(*const c_void) -> usize>,
    schedule: Option<extern "C" fn(*mut c_void, *mut c_void, *const c_void)>,
    cancel: Option<extern "C" fn(*mut c_void, *mut c_void, *const c_void)>,
    perform: Option<extern "C" fn(*mut c_void)>,
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFRunLoopDefaultMode: *const c_void;
    static kCFRunLoopCommonModes: *const c_void;
    fn CFRunLoopGetCurrent() -> *mut c_void;
    fn CFRunLoopSourceCreate(
        alloc: *const c_void,
        order: isize,
        context: *mut SourceContext,
    ) -> *mut c_void;
    fn CFRunLoopAddSource(rl: *mut c_void, source: *mut c_void, mode: *const c_void);
    fn CFRunLoopRemoveSource(rl: *mut c_void, source: *mut c_void, mode: *const c_void);
    fn CFRunLoopSourceSignal(source: *mut c_void);
    fn CFRunLoopSourceInvalidate(source: *mut c_void);
    fn CFRunLoopWakeUp(rl: *mut c_void);
    fn CFRunLoopRunInMode(mode: *const c_void, seconds: f64, return_after_source: u8) -> i32;
    fn CFRelease(cf: *const c_void);
}

extern "C" fn nothing(_info: *mut c_void) {}

/// See the module docs. Create it on the thread that will call `run_for`.
pub struct RunLoopWaker {
    source: *mut c_void,
    run_loop: *mut c_void,
}

// SAFETY: `CFRunLoopSourceSignal` and `CFRunLoopWakeUp` are documented as
// thread-safe; `run_for` and `drop` are only meant for the owning thread and
// the owner keeps the waker alive for as long as any clone of the wake handle
// exists (the agent holds both for the whole session).
unsafe impl Send for RunLoopWaker {}
unsafe impl Sync for RunLoopWaker {}

impl RunLoopWaker {
    /// Adds the source to the current thread's run loop.
    pub fn new() -> Option<Self> {
        let mut context = SourceContext {
            version: 0,
            info: std::ptr::null_mut(),
            retain: None,
            release: None,
            copy_description: None,
            equal: None,
            hash: None,
            schedule: None,
            cancel: None,
            perform: Some(nothing),
        };
        // SAFETY: `context` is fully initialised and only read during the call
        // (CF copies it); the source and the run loop are released/removed in `drop`.
        unsafe {
            let source = CFRunLoopSourceCreate(std::ptr::null(), 0, &raw mut context);
            if source.is_null() {
                return None;
            }
            let run_loop = CFRunLoopGetCurrent();
            CFRunLoopAddSource(run_loop, source, kCFRunLoopCommonModes);
            Some(Self { source, run_loop })
        }
    }

    /// Makes a running or future `run_for` return. Callable from any thread.
    pub fn wake(&self) {
        // SAFETY: both handles are live until `drop`.
        unsafe {
            CFRunLoopSourceSignal(self.source);
            CFRunLoopWakeUp(self.run_loop);
        }
    }

    /// Runs the owning thread's loop (tap callbacks included) until `wake`, a
    /// handled source or `limit`, whichever comes first.
    pub fn run_for(&self, limit: Duration) {
        // SAFETY: runs the current thread's loop for a bounded time.
        unsafe { CFRunLoopRunInMode(kCFRunLoopDefaultMode, limit.as_secs_f64(), 1) };
    }
}

impl Drop for RunLoopWaker {
    fn drop(&mut self) {
        // SAFETY: created in `new`, released exactly once here.
        unsafe {
            CFRunLoopRemoveSource(self.run_loop, self.source, kCFRunLoopCommonModes);
            CFRunLoopSourceInvalidate(self.source);
            CFRelease(self.source);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::Instant;

    use super::*;

    #[test]
    fn a_wake_from_another_thread_ends_run_for_early() {
        let waker = Arc::new(RunLoopWaker::new().expect("a run loop source"));
        let other = Arc::clone(&waker);
        let started = Instant::now();
        let thread = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(50));
            other.wake();
        });
        waker.run_for(Duration::from_secs(30));
        thread.join().unwrap();
        assert!(started.elapsed() < Duration::from_secs(10));
    }

    #[test]
    fn a_wake_before_run_for_is_not_lost() {
        let waker = RunLoopWaker::new().expect("a run loop source");
        waker.wake();
        let started = Instant::now();
        waker.run_for(Duration::from_secs(30));
        assert!(started.elapsed() < Duration::from_secs(10));
    }

    #[test]
    fn run_for_honours_its_limit_without_a_wake() {
        let waker = RunLoopWaker::new().expect("a run loop source");
        let started = Instant::now();
        waker.run_for(Duration::from_millis(100));
        assert!(started.elapsed() >= Duration::from_millis(90));
    }
}
