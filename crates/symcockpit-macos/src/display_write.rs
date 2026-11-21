//! Live adapters for the display and power *writes*: `DisplayServices`
//! brightness, the CoreGraphics gamma table, the dim windows, the extended-brightness
//! trigger and the IOKit power assertion.
//!
//! No test in this workspace calls into this module: tests run on the fakes of
//! `symcockpit-testkit`, and these adapters are exercised on real hardware only
//! by an explicit, separately identified acceptance run (Q07). Every `unsafe`
//! block names the invariant it relies on (ADR 0004).

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::ffi::{CStr, c_int, c_void};

use core_foundation::base::TCFType;
use core_foundation::string::CFString;
use core_foundation_sys::string::CFStringRef;
use objc2::MainThreadMarker;
use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_app_kit::{
    NSApplication, NSApplicationActivationPolicy, NSBackingStoreType, NSColor, NSScreen, NSView,
    NSWindow, NSWindowAnimationBehavior, NSWindowCollectionBehavior, NSWindowStyleMask,
};
use objc2_core_graphics::{CGColorSpace, kCGColorSpaceExtendedLinearSRGB};
use objc2_foundation::{NSNumber, NSPoint, NSRect, NSSize, NSString};
use objc2_metal::{
    MTLClearColor, MTLCommandBuffer, MTLCommandEncoder, MTLCommandQueue,
    MTLCreateSystemDefaultDevice, MTLDevice, MTLDrawable, MTLLoadAction, MTLPixelFormat,
    MTLRenderPassDescriptor, MTLStoreAction,
};
use objc2_quartz_core::{CAMetalDrawable, CAMetalLayer};
use symcockpit_contract::Error;
use symcockpit_core::awake::{PowerAssertionPort, PowerAssertionType};
use symcockpit_core::display::DisplayEnumerator;
use symcockpit_core::display_write::{BrightnessSink, DimOverlayPort};
use symcockpit_core::edr::{EdrPlatform, EdrTrigger};
use symcockpit_core::gamma::{GammaIo, GammaRamp};

use crate::display::LiveDisplays;

const DISPLAY_SERVICES: &CStr =
    c"/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices";

/// `dlsym` from DisplayServices (ADR 0004: private symbols are probed one by
/// one; a missing one is a named error, never a crash).
fn display_services_symbol(name: &CStr) -> Option<*mut c_void> {
    // SAFETY: both arguments are NUL-terminated C strings. The handle is never
    // closed, so a resolved pointer stays valid for the process lifetime.
    unsafe {
        let handle = libc::dlopen(DISPLAY_SERVICES.as_ptr(), libc::RTLD_NOW);
        if handle.is_null() {
            return None;
        }
        let sym = libc::dlsym(handle, name.as_ptr());
        (!sym.is_null()).then_some(sym)
    }
}

type SetBrightnessFn = unsafe extern "C" fn(u32, f32) -> c_int;
type BrightnessChangedFn = unsafe extern "C" fn(u32, f64) -> c_int;

/// Private `DisplayServicesSetBrightness`, then `DisplayServicesBrightnessChanged`
/// so Control Center and the Displays pane (which are told, not polling) follow.
pub struct LiveBrightnessSink {
    set: Option<SetBrightnessFn>,
    changed: Option<BrightnessChangedFn>,
}

impl LiveBrightnessSink {
    pub fn new() -> Self {
        // SAFETY: the symbols are declared with the signatures Swift uses for them
        // (`(CGDirectDisplayID, Float) -> Int32`, `(CGDirectDisplayID, Double) -> Int32`).
        unsafe {
            Self {
                set: display_services_symbol(c"DisplayServicesSetBrightness")
                    .map(|p| std::mem::transmute::<*mut c_void, SetBrightnessFn>(p)),
                changed: display_services_symbol(c"DisplayServicesBrightnessChanged")
                    .map(|p| std::mem::transmute::<*mut c_void, BrightnessChangedFn>(p)),
            }
        }
    }
}

impl Default for LiveBrightnessSink {
    fn default() -> Self {
        Self::new()
    }
}

impl BrightnessSink for LiveBrightnessSink {
    fn set_brightness(&self, display_id: u32, value: f32) -> Result<(), Error> {
        // shortcut: Swift falls back to IOKit's IODisplaySetFloatParameter here
        // (Intel Macs); not ported, upgrade when an Intel target needs it.
        let set = self.set.ok_or_else(|| {
            Error::Unsupported("DisplayServicesSetBrightness is not available".into())
        })?;
        // SAFETY: `set` is the DisplayServices function resolved above and takes
        // plain integers and floats.
        let status = unsafe { set(display_id, value) };
        if status != 0 {
            return Err(Error::Failed(format!(
                "DisplayServicesSetBrightness failed: {status}"
            )));
        }
        if let Some(changed) = self.changed {
            // SAFETY: as above; the announcement is optional and its result ignored.
            let _ = unsafe { changed(display_id, f64::from(value)) };
        }
        Ok(())
    }
}

// ------------------------------------------------------------------- gamma

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGGetDisplayTransferByTable(
        display: u32,
        capacity: u32,
        red: *mut f32,
        green: *mut f32,
        blue: *mut f32,
        sample_count: *mut u32,
    ) -> i32;
    fn CGSetDisplayTransferByTable(
        display: u32,
        table_size: u32,
        red: *const f32,
        green: *const f32,
        blue: *const f32,
    ) -> i32;
    fn CGDisplayRestoreColorSyncSettings();
}

/// The CoreGraphics gamma calls. Only `GammaController` may own one: the gamma
/// table has a single writer (tuning/AGENTS.md).
pub struct CoreGraphicsGamma;

impl GammaIo for CoreGraphicsGamma {
    fn read_ramp(&self, display_id: u32, sample_count: usize) -> Option<GammaRamp> {
        let mut red = vec![0.0_f32; sample_count];
        let mut green = red.clone();
        let mut blue = red.clone();
        let mut written: u32 = 0;
        // SAFETY: the three buffers hold `sample_count` floats each and stay
        // alive for the call; `written` is a valid out pointer. The capacity
        // passed is the buffer length.
        let status = unsafe {
            CGGetDisplayTransferByTable(
                display_id,
                u32::try_from(sample_count).ok()?,
                red.as_mut_ptr(),
                green.as_mut_ptr(),
                blue.as_mut_ptr(),
                &mut written,
            )
        };
        let count = usize::try_from(written).ok()?.min(sample_count);
        (status == 0 && count > 1).then(|| {
            red.truncate(count);
            green.truncate(count);
            blue.truncate(count);
            GammaRamp { red, green, blue }
        })
    }

    fn write_ramp(&self, ramp: &GammaRamp, display_id: u32) -> bool {
        let Ok(size) = u32::try_from(ramp.sample_count()) else {
            return false;
        };
        if !ramp.is_well_formed() {
            return false;
        }
        // SAFETY: the ramp is well formed, so each channel holds `size` floats,
        // alive for the call.
        unsafe {
            CGSetDisplayTransferByTable(
                display_id,
                size,
                ramp.red.as_ptr(),
                ramp.green.as_ptr(),
                ramp.blue.as_ptr(),
            ) == 0
        }
    }

    fn restore_system_ramps(&self) {
        // SAFETY: no arguments, no preconditions.
        unsafe { CGDisplayRestoreColorSyncSettings() }
    }
}

// ---------------------------------------------------------- screens (main thread)

fn screen_with_id(mtm: MainThreadMarker, display_id: u32) -> Option<Retained<NSScreen>> {
    let key = NSString::from_str("NSScreenNumber");
    NSScreen::screens(mtm).iter().find(|screen| {
        screen
            .deviceDescription()
            .objectForKey(&key)
            .and_then(|v| v.downcast_ref::<NSNumber>().map(NSNumber::unsignedIntValue))
            == Some(display_id)
    })
}

/// Windows need a connected `NSApplication`; an accessory policy keeps this
/// process out of the Dock and the app switcher.
fn connect_to_window_server(mtm: MainThreadMarker) {
    NSApplication::sharedApplication(mtm)
        .setActivationPolicy(NSApplicationActivationPolicy::Accessory);
}

/// `NSScreenSaverWindowLevel` (`kCGScreenSaverWindowLevel`).
const SCREEN_SAVER_LEVEL: isize = 1000;

fn overlay_window(mtm: MainThreadMarker, frame: NSRect) -> Retained<NSWindow> {
    // SAFETY: a borderless buffered window created on the main thread; AppKit
    // keeps it alive until `orderOut` and the `Retained` drop (we set
    // `releasedWhenClosed` to false so the two never both release it).
    let window = unsafe {
        NSWindow::initWithContentRect_styleMask_backing_defer(
            mtm.alloc(),
            frame,
            NSWindowStyleMask::Borderless,
            NSBackingStoreType::Buffered,
            false,
        )
    };
    // SAFETY: plain property setters on a window we own, on the main thread.
    unsafe { window.setReleasedWhenClosed(false) };
    window.setOpaque(false);
    window.setHasShadow(false);
    window.setLevel(SCREEN_SAVER_LEVEL);
    window.setIgnoresMouseEvents(true);
    window.setAnimationBehavior(NSWindowAnimationBehavior::None);
    window.setCollectionBehavior(
        NSWindowCollectionBehavior::CanJoinAllSpaces
            | NSWindowCollectionBehavior::Stationary
            | NSWindowCollectionBehavior::IgnoresCycle
            | NSWindowCollectionBehavior::FullScreenAuxiliary,
    );
    window
}

/// Software dim: one black, click-through window per screen at alpha `1 - opacity`.
pub struct LiveDim {
    mtm: MainThreadMarker,
    windows: RefCell<BTreeMap<u32, Retained<NSWindow>>>,
}

impl LiveDim {
    pub fn new() -> Result<Self, Error> {
        let mtm = MainThreadMarker::new()
            .ok_or_else(|| Error::Failed("the dim overlay must run on the main thread".into()))?;
        Ok(Self {
            mtm,
            windows: RefCell::default(),
        })
    }
}

impl DimOverlayPort for LiveDim {
    fn show(&self, opacity: f32) {
        connect_to_window_server(self.mtm);
        let alpha = f64::from(1.0 - opacity);
        for screen in NSScreen::screens(self.mtm).iter() {
            let key = NSString::from_str("NSScreenNumber");
            let Some(id) = screen
                .deviceDescription()
                .objectForKey(&key)
                .and_then(|v| v.downcast_ref::<NSNumber>().map(NSNumber::unsignedIntValue))
                .filter(|id| *id != 0)
            else {
                continue;
            };
            if let Some(existing) = self.windows.borrow().get(&id) {
                existing.setAlphaValue(alpha);
                continue;
            }
            let window = overlay_window(self.mtm, screen.frame());
            window.setBackgroundColor(Some(&NSColor::blackColor()));
            window.setAlphaValue(alpha);
            window.orderFront(None);
            self.windows.borrow_mut().insert(id, window);
        }
    }

    fn hide(&self) {
        for (_, window) in std::mem::take(&mut *self.windows.borrow_mut()) {
            window.orderOut(None);
        }
    }
}

// ----------------------------------------------------------------------- EDR

/// Extended brightness: the headroom the system grants comes from
/// [`LiveDisplays`], the trigger is a real, presented EDR layer.
pub struct LiveEdr {
    mtm: MainThreadMarker,
}

impl LiveEdr {
    pub fn new() -> Result<Self, Error> {
        let mtm = MainThreadMarker::new().ok_or_else(|| {
            Error::Failed("extended brightness must run on the main thread".into())
        })?;
        Ok(Self { mtm })
    }
}

impl EdrPlatform for LiveEdr {
    fn headroom(&self, display_id: u32) -> Option<f64> {
        LiveDisplays::new()
            .ok()?
            .enumerate_screens()
            .into_iter()
            .find(|s| s.display_id == display_id)
            .map(|s| s.max_edr_headroom)
    }

    fn create_trigger(&self, display_id: u32) -> Option<Box<dyn EdrTrigger>> {
        EdrTriggerWindow::new(self.mtm, display_id).map(|t| Box::new(t) as Box<dyn EdrTrigger>)
    }
}

/// A 1x1 borderless window whose `CAMetalLayer` renders extended-range white.
/// One pixel is enough: the system grants headroom as soon as *any* EDR content
/// is composited on the display.
pub struct EdrTriggerWindow {
    window: RefCell<Option<Retained<NSWindow>>>,
    layer: Retained<CAMetalLayer>,
    queue: Retained<ProtocolObject<dyn MTLCommandQueue>>,
}

/// Rendered into the trigger; it only has to be extended-range (the visible
/// brightening comes from the gamma boost, not from this pixel).
const TRIGGER_VALUE: f64 = 1.6;

impl EdrTriggerWindow {
    fn new(mtm: MainThreadMarker, display_id: u32) -> Option<Self> {
        let device = MTLCreateSystemDefaultDevice()?;
        let queue = device.newCommandQueue()?;
        let screen = screen_with_id(mtm, display_id)?;
        connect_to_window_server(mtm);

        let layer = CAMetalLayer::new();
        // EDR needs all three together: the flag, a float pixel format and an
        // extended-range colour space. Miss one and the content is downgraded to
        // SDR, which asks the system for no headroom at all.
        layer.setDevice(Some(&device));
        layer.setPixelFormat(MTLPixelFormat::RGBA16Float);
        // SAFETY: the constant is a valid CFString name for `CGColorSpace::with_name`.
        let space = unsafe { CGColorSpace::with_name(Some(kCGColorSpaceExtendedLinearSRGB)) };
        layer.setColorspace(space.as_deref());
        layer.setWantsExtendedDynamicRangeContent(true);
        layer.setOpaque(false);
        layer.setFramebufferOnly(true);
        let one = NSSize::new(1.0, 1.0);
        layer.setFrame(NSRect::new(NSPoint::new(0.0, 0.0), one));
        layer.setDrawableSize(one);
        layer.setContentsScale(1.0);

        // Top-left corner: on a built-in display the rounded corner mask covers
        // it. The trigger has to be *composited* to count, so it cannot be moved
        // off screen or made fully transparent.
        let screen_frame = screen.frame();
        let frame = NSRect::new(
            NSPoint::new(
                screen_frame.origin.x,
                screen_frame.origin.y + screen_frame.size.height - 1.0,
            ),
            one,
        );
        let window = overlay_window(mtm, frame);
        // Layer-*hosting* view: the layer must be assigned before `wantsLayer`,
        // otherwise AppKit owns the layer tree and swaps in its own backing
        // layer, which is not EDR-capable.
        let view = NSView::initWithFrame(mtm.alloc(), NSRect::new(NSPoint::new(0.0, 0.0), one));
        view.setLayer(Some(&layer));
        view.setWantsLayer(true);
        window.setContentView(Some(&view));
        window.setBackgroundColor(Some(&NSColor::clearColor()));
        window.orderFrontRegardless();

        let trigger = Self {
            window: RefCell::new(Some(window)),
            layer,
            queue,
        };
        trigger.present_frame();
        Some(trigger)
    }

    fn present_frame(&self) {
        let Some(drawable) = self.layer.nextDrawable() else {
            return;
        };
        let pass = MTLRenderPassDescriptor::renderPassDescriptor();
        // SAFETY: attachment 0 always exists on a render pass descriptor.
        let attachment = unsafe { pass.colorAttachments().objectAtIndexedSubscript(0) };
        attachment.setTexture(Some(&drawable.texture()));
        attachment.setLoadAction(MTLLoadAction::Clear);
        attachment.setStoreAction(MTLStoreAction::Store);
        attachment.setClearColor(MTLClearColor {
            red: TRIGGER_VALUE,
            green: TRIGGER_VALUE,
            blue: TRIGGER_VALUE,
            alpha: 1.0,
        });
        let Some(buffer) = self.queue.commandBuffer() else {
            return;
        };
        let Some(encoder) = buffer.renderCommandEncoderWithDescriptor(&pass) else {
            return;
        };
        encoder.endEncoding();
        let drawable: &ProtocolObject<dyn MTLDrawable> = ProtocolObject::from_ref(&*drawable);
        buffer.presentDrawable(drawable);
        buffer.commit();
    }
}

impl EdrTrigger for EdrTriggerWindow {
    fn render(&self) {
        self.present_frame();
    }

    fn remove(&self) {
        if let Some(window) = self.window.borrow_mut().take() {
            window.orderOut(None);
        }
    }
}

// --------------------------------------------------------------------- power

#[link(name = "IOKit", kind = "framework")]
unsafe extern "C" {
    fn IOPMAssertionCreateWithName(
        assertion_type: CFStringRef,
        level: u32,
        name: CFStringRef,
        assertion_id: *mut u32,
    ) -> i32;
    fn IOPMAssertionRelease(assertion_id: u32) -> i32;
}

/// `kIOPMAssertionLevelOn`.
const ASSERTION_LEVEL_ON: u32 = 255;

/// `IOPMAssertionCreateWithName`: the analog of `/usr/bin/caffeinate`, fully
/// unprivileged. macOS releases the assertion when its process ends.
pub struct LivePowerAssertions;

impl PowerAssertionPort for LivePowerAssertions {
    fn create(&self, kind: PowerAssertionType, reason: &str) -> Result<u32, Error> {
        let name = match kind {
            PowerAssertionType::PreventSystemSleep => "PreventUserIdleSystemSleep",
            PowerAssertionType::PreventDisplaySleep => "PreventUserIdleDisplaySleep",
        };
        let (name, reason) = (CFString::new(name), CFString::new(reason));
        let mut id: u32 = 0;
        // SAFETY: both CFStrings outlive the call and `id` is a valid out pointer.
        let status = unsafe {
            IOPMAssertionCreateWithName(
                name.as_concrete_TypeRef(),
                ASSERTION_LEVEL_ON,
                reason.as_concrete_TypeRef(),
                &mut id,
            )
        };
        if status == 0 {
            Ok(id)
        } else {
            Err(Error::Failed(format!(
                "Failed to create power assertion (IOReturn {status})."
            )))
        }
    }

    fn release(&self, assertion_id: u32) {
        // SAFETY: releasing an id this process created; a stale id is a no-op error.
        let _ = unsafe { IOPMAssertionRelease(assertion_id) };
    }
}

// ----------------------------------------------------------- process helpers

/// Lets the main run loop turn for at most `seconds` (windows and the EDR
/// layer are only composited while it runs). Main thread only.
pub fn pump_run_loop(seconds: f64) {
    // SAFETY: `kCFRunLoopDefaultMode` is a valid mode constant; running the
    // current thread's run loop for a bounded time has no other preconditions.
    unsafe {
        core_foundation_sys::runloop::CFRunLoopRunInMode(
            core_foundation_sys::runloop::kCFRunLoopDefaultMode,
            seconds,
            1,
        );
    }
}

/// Whether a process is still running (`kill(pid, 0)`): `EPERM` means it exists.
pub fn process_alive(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else {
        return false;
    };
    // SAFETY: signal 0 only checks existence and permission.
    let status = unsafe { libc::kill(pid, 0) };
    status == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// Write end of the self-pipe the signal handler feeds (`-1` until armed).
static SIGNAL_PIPE: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(-1);

extern "C" fn on_interrupt(_: c_int) {
    use std::sync::atomic::Ordering;
    let fd = SIGNAL_PIPE.load(Ordering::Relaxed);
    if fd >= 0 {
        // SAFETY: `write` is async-signal-safe; the byte lives on this stack frame.
        unsafe { libc::write(fd, [1_u8].as_ptr().cast(), 1) };
    }
}

/// Restore-on-interrupt, as `OverrideTracker.registerSignalHandlers`: on SIGINT
/// or SIGTERM a dedicated thread runs `restore`, then ends the process with
/// status 0. The handler only writes a byte to a self-pipe (async-signal-safe),
/// so it does not matter which thread receives the signal, and `exec` resets the
/// handlers, so nothing leaks into a forwarded Swift core. `restore` runs off the
/// main thread, so it may only do what is safe there (the brightness write from
/// the restore record); windows, gamma tables and assertions die with the process.
/// Arm once; a second call is ignored.
pub fn restore_on_signal(restore: impl FnOnce() + Send + 'static) {
    use std::sync::atomic::Ordering;
    if SIGNAL_PIPE.load(Ordering::Relaxed) >= 0 {
        return;
    }
    let mut fds: [c_int; 2] = [-1, -1];
    // SAFETY: `fds` has room for the two descriptors `pipe` writes.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return;
    }
    let [read_fd, write_fd] = fds;
    SIGNAL_PIPE.store(write_fd, Ordering::Relaxed);
    for signal in [libc::SIGINT, libc::SIGTERM] {
        // SAFETY: `action` is fully initialised (zeroed, empty mask, handler and
        // flags set) before it is handed to `sigaction`, and the handler is async-signal-safe.
        unsafe {
            let mut action: libc::sigaction = std::mem::zeroed();
            action.sa_sigaction = on_interrupt as extern "C" fn(c_int) as usize;
            action.sa_flags = libc::SA_RESTART;
            libc::sigemptyset(&mut action.sa_mask);
            libc::sigaction(signal, &action, std::ptr::null_mut());
        }
    }
    std::thread::spawn(move || {
        let mut byte = 0_u8;
        loop {
            // SAFETY: reads one byte into a valid local; retried on EINTR.
            let n = unsafe { libc::read(read_fd, (&raw mut byte).cast(), 1) };
            if n == 1 {
                break;
            }
            if n < 0 && std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
                return;
            }
        }
        restore();
        // SAFETY: `_exit` skips destructors on purpose: the main thread may be
        // mid-call, and everything that matters was restored from the record.
        unsafe { libc::_exit(0) }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn this_process_is_alive_and_an_absurd_pid_is_not() {
        assert!(process_alive(std::process::id()));
        assert!(!process_alive(u32::MAX));
        assert!(!process_alive(4_000_000));
    }

    #[test]
    fn the_overlay_adapters_refuse_off_the_main_thread_instead_of_crashing() {
        // The test harness never runs on the main thread; nothing is shown.
        assert!(LiveDim::new().is_err());
        assert!(LiveEdr::new().is_err());
    }

    /// Child half of `interrupts_restore_and_exit_with_status_zero`: only acts
    /// when the parent test re-executes this binary with the marker variable.
    #[test]
    fn signal_child() {
        let Some(marker) = std::env::var_os("SYMCOCKPIT_SIGNAL_CHILD_MARKER") else {
            return;
        };
        restore_on_signal(move || std::fs::write(marker, "restored").unwrap());
        std::fs::write(
            std::env::var_os("SYMCOCKPIT_SIGNAL_CHILD_READY").unwrap(),
            "up",
        )
        .unwrap();
        std::thread::sleep(std::time::Duration::from_secs(30));
    }

    /// Real signals, no hardware: SIGTERM and SIGINT both run the restore
    /// closure once and end the process with status 0 (like the Swift handlers).
    #[test]
    fn interrupts_restore_and_exit_with_status_zero() {
        for (signal, name) in [(libc::SIGTERM, "TERM"), (libc::SIGINT, "INT")] {
            let tmp = tempfile::tempdir().unwrap();
            let (marker, ready) = (tmp.path().join("marker"), tmp.path().join("ready"));
            let mut child = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "display_write::tests::signal_child",
                    "--nocapture",
                ])
                .env("SYMCOCKPIT_SIGNAL_CHILD_MARKER", &marker)
                .env("SYMCOCKPIT_SIGNAL_CHILD_READY", &ready)
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()
                .unwrap();
            for _ in 0..500 {
                if ready.exists() {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            assert!(
                ready.exists(),
                "SIG{name}: the child never armed its handler"
            );
            // SAFETY: signals a child process this test just spawned.
            unsafe { libc::kill(libc::pid_t::try_from(child.id()).unwrap(), signal) };
            let status = child.wait().unwrap();
            assert_eq!(status.code(), Some(0), "SIG{name}");
            assert_eq!(
                std::fs::read_to_string(&marker).unwrap(),
                "restored",
                "SIG{name}"
            );
        }
    }
}
