//! System wake through `IORegisterForSystemPower` (the live [`WakeSource`]).
//!
//! The registration lives on a thread of its own with its own run loop; the notification arrives
//! there and only calls `on_wake`. The sleep messages are acknowledged at once, as the API
//! requires: unanswered, the system waits out a 30 s timeout before it sleeps.
//!
//! v0.12's `PowerWakeMonitor` compared against `0x0E00_0300`; the real value of
//! `kIOMessageSystemHasPoweredOn` is `0xE000_0300` (`iokit_common_msg`), so that monitor never
//! saw a wake. The values below were printed by a C program against the SDK headers.

use std::ffi::c_void;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc;
use std::thread::JoinHandle;
use std::time::Duration;

use core_foundation_sys::base::{CFRelease, CFRetain};
use core_foundation_sys::runloop::{
    CFRunLoopAddSource, CFRunLoopGetCurrent, CFRunLoopRef, CFRunLoopRemoveSource, CFRunLoopRun,
    CFRunLoopSourceRef, CFRunLoopStop, kCFRunLoopDefaultMode,
};
use symcockpit_contract::Error;
use symcockpit_core::wake::WakeSource;

const CAN_SYSTEM_SLEEP: u32 = 0xE000_0270;
const SYSTEM_WILL_SLEEP: u32 = 0xE000_0280;
const SYSTEM_HAS_POWERED_ON: u32 = 0xE000_0300;

type Callback =
    extern "C" fn(refcon: *mut c_void, service: u32, message: u32, argument: *mut c_void);

#[link(name = "IOKit", kind = "framework")]
unsafe extern "C" {
    fn IORegisterForSystemPower(
        refcon: *mut c_void,
        port: *mut *mut c_void,
        callback: Callback,
        notifier: *mut u32,
    ) -> u32;
    fn IODeregisterForSystemPower(notifier: *mut u32) -> i32;
    fn IOAllowPowerChange(kernel_port: u32, notification_id: isize) -> i32;
    fn IOServiceClose(connect: u32) -> i32;
    fn IONotificationPortGetRunLoopSource(port: *mut c_void) -> CFRunLoopSourceRef;
    fn IONotificationPortDestroy(port: *mut c_void);
}

struct Context {
    root_port: AtomicU32,
    on_wake: Box<dyn Fn() + Send + Sync>,
}

extern "C" fn notification(
    refcon: *mut c_void,
    _service: u32,
    message: u32,
    argument: *mut c_void,
) {
    // SAFETY: `refcon` is the `Context` of the thread that registered; it outlives the
    // registration (dropped after `IODeregisterForSystemPower`).
    let context = unsafe { &*refcon.cast::<Context>() };
    match message {
        CAN_SYSTEM_SLEEP | SYSTEM_WILL_SLEEP => {
            // SAFETY: the root port and the notification id are what the system handed us.
            unsafe {
                IOAllowPowerChange(context.root_port.load(Ordering::Acquire), argument as isize)
            };
        }
        SYSTEM_HAS_POWERED_ON => (context.on_wake)(),
        _ => {}
    }
}

pub struct LiveWake;

/// The registration thread; dropping it ends the run loop and joins.
struct Monitor {
    run_loop: CFRunLoopRef,
    thread: Option<JoinHandle<()>>,
}

// SAFETY: the run loop is retained for the life of the monitor and `CFRunLoopStop` is
// documented as callable from any thread.
unsafe impl Send for Monitor {}

impl Drop for Monitor {
    fn drop(&mut self) {
        if let Some(thread) = self.thread.take() {
            // A stop that arrives before the thread entered `CFRunLoopRun` is lost: repeat it.
            while !thread.is_finished() {
                // SAFETY: retained in `watch`, released below once the thread is gone.
                unsafe { CFRunLoopStop(self.run_loop) };
                std::thread::sleep(Duration::from_millis(5));
            }
            let _ = thread.join();
        }
        // SAFETY: the retain of `watch`, released exactly once.
        unsafe { CFRelease(self.run_loop.cast()) };
    }
}

struct Registered(usize);

fn register(on_wake: Box<dyn Fn() + Send + Sync>, ready: &mpsc::Sender<Result<Registered, Error>>) {
    let context = Box::new(Context {
        root_port: AtomicU32::new(0),
        on_wake,
    });
    let mut port: *mut c_void = std::ptr::null_mut();
    let mut notifier = 0_u32;
    let refcon = std::ptr::from_ref::<Context>(&context)
        .cast_mut()
        .cast::<c_void>();
    // SAFETY: `refcon` stays valid until after the deregistration below.
    let root =
        unsafe { IORegisterForSystemPower(refcon, &raw mut port, notification, &raw mut notifier) };
    if root == 0 || port.is_null() {
        let _ = ready.send(Err(Error::Failed(
            "could not register for system power notifications".into(),
        )));
        return;
    }
    context.root_port.store(root, Ordering::Release);
    // SAFETY: the port is live until destroyed below; the source belongs to it ("Get" rule).
    let (run_loop, source) = unsafe {
        let run_loop = CFRunLoopGetCurrent();
        CFRetain(run_loop.cast());
        let source = IONotificationPortGetRunLoopSource(port);
        CFRunLoopAddSource(run_loop, source, kCFRunLoopDefaultMode);
        (run_loop, source)
    };
    let _ = ready.send(Ok(Registered(run_loop as usize)));
    // SAFETY: runs this thread's loop until `CFRunLoopStop`; then everything is undone in
    // the order of the registration.
    unsafe {
        CFRunLoopRun();
        CFRunLoopRemoveSource(run_loop, source, kCFRunLoopDefaultMode);
        IODeregisterForSystemPower(&raw mut notifier);
        IOServiceClose(root);
        IONotificationPortDestroy(port);
    }
    drop(context);
}

impl WakeSource for LiveWake {
    fn watch(&self, on_wake: Box<dyn Fn() + Send + Sync>) -> Result<Box<dyn Send>, Error> {
        let (tx, rx) = mpsc::channel();
        let thread = std::thread::Builder::new()
            .name("symcockpit-wake".into())
            .spawn(move || register(on_wake, &tx))
            .map_err(|e| Error::Failed(format!("wake thread: {e}")))?;
        match rx.recv() {
            Ok(Ok(Registered(run_loop))) => Ok(Box::new(Monitor {
                run_loop: run_loop as CFRunLoopRef,
                thread: Some(thread),
            })),
            Ok(Err(e)) => {
                let _ = thread.join();
                Err(e)
            }
            Err(_) => Err(Error::Failed(
                "wake thread ended before it registered".into(),
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::AtomicUsize;

    use super::*;

    /// Registers and unregisters against the real system power service. The callback only
    /// counts; nothing here writes to hardware. A real wake is not provoked.
    #[test]
    fn registering_and_dropping_the_live_monitor_returns_promptly() {
        let wakes = Arc::new(AtomicUsize::new(0));
        let counter = Arc::clone(&wakes);
        let started = std::time::Instant::now();
        let guard = LiveWake
            .watch(Box::new(move || {
                counter.fetch_add(1, Ordering::SeqCst);
            }))
            .expect("system power registration");
        drop(guard);
        assert!(started.elapsed() < Duration::from_secs(5));
        assert_eq!(wakes.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn the_message_numbers_are_the_sdk_values() {
        // From a C program printing the SDK's `kIOMessage*` macros.
        assert_eq!(
            (CAN_SYSTEM_SLEEP, SYSTEM_WILL_SLEEP, SYSTEM_HAS_POWERED_ON),
            (0xe000_0270, 0xe000_0280, 0xe000_0300)
        );
    }
}
