//! Finder ⌘X / ⌘V through a CGEvent tap (R60).
//!
//! The decision lives in `symcockpit_core::input::FinderCut`; this file only
//! translates events, posts the replacement keys and owns the tap's lifetime.
//!
//! Threading: `FinderCutTap::start` adds the tap to the *calling thread's* run
//! loop, which must be the main run loop of the host process (the agent's main
//! thread), because NSWorkspace only tracks the frontmost app there. The host
//! keeps spinning that loop; `stop` (or drop) disables the tap and removes it.
//!
//! Not run live: creating the tap needs the Accessibility permission and
//! swallowing keys is Daniel's acceptance step.

use std::ffi::c_void;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::{class, msg_send};
use objc2_foundation::NSString;
use symcockpit_contract::Error;
use symcockpit_core::input::{
    Access, Action, DisabledReason, FinderCut, FinderEnv, InputProbe, Key, KeyEvent, Modifiers,
    Synthetic, TapEvent,
};

type TapCallback = extern "C" fn(*mut c_void, u32, *mut c_void, *mut c_void) -> *mut c_void;

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGEventTapCreate(
        tap: u32,
        place: u32,
        options: u32,
        events_of_interest: u64,
        callback: TapCallback,
        user_info: *mut c_void,
    ) -> *mut c_void;
    fn CGEventTapEnable(tap: *mut c_void, enable: bool);
    fn CGEventGetFlags(event: *mut c_void) -> u64;
    fn CGEventGetIntegerValueField(event: *mut c_void, field: u32) -> i64;
    fn CGEventSetIntegerValueField(event: *mut c_void, field: u32, value: i64);
    fn CGEventSetFlags(event: *mut c_void, flags: u64);
    fn CGEventCreateKeyboardEvent(source: *mut c_void, key: u16, down: bool) -> *mut c_void;
    fn CGEventPost(location: u32, event: *mut c_void);
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFRunLoopCommonModes: *const c_void;
    fn CFMachPortCreateRunLoopSource(
        alloc: *const c_void,
        port: *mut c_void,
        order: isize,
    ) -> *mut c_void;
    fn CFMachPortInvalidate(port: *mut c_void);
    fn CFRunLoopGetCurrent() -> *mut c_void;
    fn CFRunLoopAddSource(rl: *mut c_void, source: *mut c_void, mode: *const c_void);
    fn CFRunLoopRemoveSource(rl: *mut c_void, source: *mut c_void, mode: *const c_void);
    fn CFRunLoopRunInMode(mode: *const c_void, seconds: f64, return_after_source: u8) -> i32;
    static kCFRunLoopDefaultMode: *const c_void;
    fn CFRelease(cf: *const c_void);
}

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    fn AXIsProcessTrusted() -> bool;
}

#[link(name = "Carbon", kind = "framework")]
unsafe extern "C" {
    fn IsSecureEventInputEnabled() -> bool;
}

#[link(name = "AppKit", kind = "framework")]
unsafe extern "C" {}

const SESSION_TAP: u32 = 1;
const HEAD_INSERT: u32 = 0;
const TAP_DEFAULT: u32 = 0; // active tap: may swallow events
const EVENT_KEY_DOWN: u32 = 10;
const EVENT_TAP_DISABLED_BY_TIMEOUT: u32 = 0xFFFF_FFFE;
const EVENT_TAP_DISABLED_BY_USER_INPUT: u32 = 0xFFFF_FFFF;
const FIELD_KEYCODE: u32 = 9;
const FIELD_SOURCE_USER_DATA: u32 = 42;
/// Marks events this module posted so the tap lets them through.
const SYNTHETIC_MARK: i64 = 0x5359_4D43; // "SYMC"
const KEY_C: u16 = 8;
const KEY_V: u16 = 9;
const KEY_X: u16 = 7;
const FLAG_SHIFT: u64 = 0x0002_0000;
const FLAG_CONTROL: u64 = 0x0004_0000;
const FLAG_OPTION: u64 = 0x0008_0000;
const FLAG_COMMAND: u64 = 0x0010_0000;

fn key_event(keycode: i64, flags: u64) -> KeyEvent {
    KeyEvent {
        key: match keycode {
            k if k == i64::from(KEY_X) => Key::X,
            k if k == i64::from(KEY_V) => Key::V,
            _ => Key::Other,
        },
        modifiers: Modifiers {
            command: flags & FLAG_COMMAND != 0,
            shift: flags & FLAG_SHIFT != 0,
            option: flags & FLAG_OPTION != 0,
            control: flags & FLAG_CONTROL != 0,
        },
    }
}

/// Keycode and flags of the replacement key press.
fn synthetic_keys(s: Synthetic) -> (u16, u64) {
    match s {
        Synthetic::Copy => (KEY_C, FLAG_COMMAND),
        Synthetic::MoveHere => (KEY_V, FLAG_COMMAND | FLAG_OPTION),
    }
}

/// The live system state behind `FinderEnv`.
struct LiveEnv;

impl FinderEnv for LiveEnv {
    fn frontmost_bundle_id(&self) -> Option<String> {
        // SAFETY: plain Objective-C getters on AppKit singletons; each result is
        // optional and checked, and nothing is retained beyond this call.
        unsafe {
            let workspace: Retained<AnyObject> = msg_send![class!(NSWorkspace), sharedWorkspace];
            let app: Option<Retained<AnyObject>> = msg_send![&*workspace, frontmostApplication];
            let id: Option<Retained<NSString>> = msg_send![&*app?, bundleIdentifier];
            id.map(|s| s.to_string())
        }
    }

    fn secure_input_active(&self) -> bool {
        // SAFETY: no arguments, no side effects.
        unsafe { IsSecureEventInputEnabled() }
    }

    fn pasteboard_change_count(&self) -> i64 {
        // SAFETY: plain getters on the general pasteboard singleton.
        unsafe {
            let pasteboard: Retained<AnyObject> =
                msg_send![class!(NSPasteboard), generalPasteboard];
            let count: isize = msg_send![&*pasteboard, changeCount];
            count as i64
        }
    }
}

/// Reports permission and secure-input state without asking for anything.
pub struct LiveProbe;

impl InputProbe for LiveProbe {
    fn event_tap_access(&self) -> Access {
        // SAFETY: no arguments; the plain (non-prompting) variant.
        if unsafe { AXIsProcessTrusted() } {
            Access::Granted
        } else {
            Access::Denied
        }
    }

    fn secure_input_active(&self) -> bool {
        LiveEnv.secure_input_active()
    }
}

/// Called on the tap's thread after an event was replaced; must return quickly.
pub type OnAction = Arc<dyn Fn(Synthetic) + Send + Sync>;

struct TapState {
    engine: Mutex<FinderCut>,
    tap: Mutex<*mut c_void>,
    on_action: Option<OnAction>,
}

// SAFETY: the raw tap pointer is only used to re-enable the tap; CGEventTapEnable
// is thread-safe, and the pointer is cleared before the tap is released.
unsafe impl Send for TapState {}
unsafe impl Sync for TapState {}

fn post_key(keycode: u16, flags: u64, down: bool) {
    // SAFETY: creates, tags, posts and releases one event; a null event is skipped.
    unsafe {
        let event = CGEventCreateKeyboardEvent(std::ptr::null_mut(), keycode, down);
        if event.is_null() {
            return;
        }
        CGEventSetFlags(event, flags);
        CGEventSetIntegerValueField(event, FIELD_SOURCE_USER_DATA, SYNTHETIC_MARK);
        CGEventPost(SESSION_TAP, event);
        CFRelease(event);
    }
}

fn post_synthetic(s: Synthetic) {
    let (key, flags) = synthetic_keys(s);
    post_key(key, flags, true);
    post_key(key, flags, false);
}

/// After a posted ⌘C, watches the clipboard briefly so the engine notices the
/// copy landing (see `FinderCut::poll`), then gives up.
fn watch_copy_landing(state: Arc<TapState>) {
    std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(1);
        while Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
            let Ok(mut engine) = state.engine.lock() else {
                return;
            };
            engine.poll(&LiveEnv);
            if !engine.is_waiting() {
                return;
            }
        }
        if let Ok(mut engine) = state.engine.lock() {
            engine.abandon_waiting();
        }
    });
}

extern "C" fn on_event(
    _proxy: *mut c_void,
    kind: u32,
    event: *mut c_void,
    user: *mut c_void,
) -> *mut c_void {
    // SAFETY: `user` is the `Arc<TapState>` raw pointer owned by the live
    // `FinderCutTap`, which outlives the tap (it removes the tap in `stop`).
    let state = unsafe { &*(user as *const TapState) };
    // A panic must not unwind through the C frame: let the event pass instead.
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        handle(state, kind, event, user as *const TapState)
    }));
    result.unwrap_or(event)
}

fn handle(state: &TapState, kind: u32, event: *mut c_void, raw: *const TapState) -> *mut c_void {
    let tap_event = match kind {
        EVENT_KEY_DOWN => {
            // SAFETY: `event` is the live event handed to the callback.
            let (code, flags, mark) = unsafe {
                (
                    CGEventGetIntegerValueField(event, FIELD_KEYCODE),
                    CGEventGetFlags(event),
                    CGEventGetIntegerValueField(event, FIELD_SOURCE_USER_DATA),
                )
            };
            if mark == SYNTHETIC_MARK {
                return event;
            }
            TapEvent::Key(key_event(code, flags))
        }
        EVENT_TAP_DISABLED_BY_TIMEOUT => TapEvent::Disabled(DisabledReason::Timeout),
        EVENT_TAP_DISABLED_BY_USER_INPUT => TapEvent::Disabled(DisabledReason::UserInput),
        _ => return event,
    };
    let Ok(mut engine) = state.engine.lock() else {
        return event;
    };
    match engine.handle(tap_event, &LiveEnv) {
        Action::PassThrough => event,
        Action::ReEnableTap => {
            if let Ok(tap) = state.tap.lock()
                && !tap.is_null()
            {
                // SAFETY: the tap is alive while its pointer is stored.
                unsafe { CGEventTapEnable(*tap, true) };
            }
            event
        }
        Action::Replace(synthetic) => {
            drop(engine);
            post_synthetic(synthetic);
            if let Some(on_action) = &state.on_action {
                on_action(synthetic);
            }
            if synthetic == Synthetic::Copy {
                // SAFETY: `raw` came from `Arc::into_raw`; the extra count is
                // released when the watcher thread ends.
                let arc = unsafe {
                    Arc::increment_strong_count(raw);
                    Arc::from_raw(raw)
                };
                watch_copy_landing(arc);
            }
            std::ptr::null_mut() // swallow the original key
        }
    }
}

/// The production [`symcockpit_core::input::TapHost`].
pub struct LiveTapHost;

impl symcockpit_core::input::RunningTap for FinderCutTap {}

impl symcockpit_core::input::TapHost for LiveTapHost {
    fn start(
        &self,
        on_action: OnAction,
    ) -> Result<Box<dyn symcockpit_core::input::RunningTap>, Error> {
        Ok(Box::new(FinderCutTap::start_with(Some(on_action))?))
    }
}

/// A running Finder-cut tap. Dropping it removes the tap.
pub struct FinderCutTap {
    tap: *mut c_void,
    source: *mut c_void,
    run_loop: *mut c_void,
    state: *const TapState,
}

impl FinderCutTap {
    /// Installs the tap on the current thread's run loop.
    /// `Error::Permission` without the Accessibility permission.
    pub fn start() -> Result<Self, Error> {
        Self::start_with(None)
    }

    /// [`Self::start`], telling `on_action` about every replaced key (the
    /// agent plays haptics and sound from there).
    pub fn start_with(on_action: Option<OnAction>) -> Result<Self, Error> {
        let state = Arc::into_raw(Arc::new(TapState {
            engine: Mutex::new(FinderCut::default()),
            tap: Mutex::new(std::ptr::null_mut()),
            on_action,
        }));
        // SAFETY: `state` stays valid until `stop` reclaims it; the callback is
        // an `extern "C"` function with the signature CGEventTapCreate expects.
        let tap = unsafe {
            CGEventTapCreate(
                SESSION_TAP,
                HEAD_INSERT,
                TAP_DEFAULT,
                1u64 << EVENT_KEY_DOWN,
                on_event,
                state as *mut c_void,
            )
        };
        if tap.is_null() {
            // SAFETY: reclaims the pointer created above; nothing else holds it.
            drop(unsafe { Arc::from_raw(state) });
            return Err(Error::Permission(
                "cannot create the event tap: grant Accessibility access (System Settings > Privacy & Security)".into(),
            ));
        }
        // SAFETY: `tap` is a live mach port; the source and run loop are used only until `stop`.
        let (source, run_loop) = unsafe {
            let source = CFMachPortCreateRunLoopSource(std::ptr::null(), tap, 0);
            let run_loop = CFRunLoopGetCurrent();
            CFRunLoopAddSource(run_loop, source, kCFRunLoopCommonModes);
            CGEventTapEnable(tap, true);
            (source, run_loop)
        };
        if let Ok(mut slot) = unsafe { &*state }.tap.lock() {
            *slot = tap;
        }
        Ok(FinderCutTap {
            tap,
            source,
            run_loop,
            state,
        })
    }

    /// Foreground helper: spins the current run loop for `duration`.
    pub fn spin(duration: Duration) {
        let end = Instant::now() + duration;
        while Instant::now() < end {
            let left = end
                .saturating_duration_since(Instant::now())
                .as_secs_f64()
                .min(0.25);
            // SAFETY: runs the current thread's run loop for a bounded time.
            unsafe { CFRunLoopRunInMode(kCFRunLoopDefaultMode, left, 0) };
        }
    }
}

impl Drop for FinderCutTap {
    fn drop(&mut self) {
        // SAFETY: every handle was created in `start` and is released exactly once
        // here: disable first so no callback starts, clear the stored pointer,
        // then remove, invalidate and release.
        unsafe {
            CGEventTapEnable(self.tap, false);
            if let Ok(mut slot) = (*self.state).tap.lock() {
                *slot = std::ptr::null_mut();
            }
            CFRunLoopRemoveSource(self.run_loop, self.source, kCFRunLoopCommonModes);
            CFMachPortInvalidate(self.tap);
            CFRelease(self.source);
            CFRelease(self.tap);
            drop(Arc::from_raw(self.state));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keycodes_and_flags_translate() {
        let e = key_event(7, FLAG_COMMAND);
        assert_eq!((e.key, e.modifiers), (Key::X, Modifiers::COMMAND));
        let e = key_event(9, FLAG_COMMAND | FLAG_SHIFT);
        assert_eq!(e.key, Key::V);
        assert!(e.modifiers.shift && e.modifiers.command && !e.modifiers.option);
        assert_eq!(key_event(0, 0).key, Key::Other);
        let all = key_event(7, FLAG_SHIFT | FLAG_CONTROL | FLAG_OPTION | FLAG_COMMAND);
        assert!(all.modifiers.shift && all.modifiers.control && all.modifiers.option);
    }

    #[test]
    fn replacement_keys_are_copy_and_move_here() {
        assert_eq!(synthetic_keys(Synthetic::Copy), (8, FLAG_COMMAND));
        assert_eq!(
            synthetic_keys(Synthetic::MoveHere),
            (9, FLAG_COMMAND | FLAG_OPTION)
        );
    }

    #[test]
    fn modifier_flags_match_the_core_graphics_header_values() {
        // kCGEventFlagMask{Shift,Control,Alternate,Command} from CGEventTypes.h.
        assert_eq!(FLAG_SHIFT, 1 << 17);
        assert_eq!(FLAG_CONTROL, 1 << 18);
        assert_eq!(FLAG_OPTION, 1 << 19);
        assert_eq!(FLAG_COMMAND, 1 << 20);
    }
}
