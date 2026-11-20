//! Finder ⌘X / ⌘V (R60): a pure decision engine for the event tap.
//!
//! Finder has no "cut" for files. ⌘X in Finder becomes ⌘C and remembers that
//! the clipboard holds a pending cut; ⌘V in Finder then becomes ⌘⌥V ("Move
//! Item Here"). In every other app, and whenever secure input is active, the
//! event passes through unchanged. The live tap in `symcockpit-macos` only
//! translates platform events to `TapEvent` and carries out the `Action`.

pub const FINDER_BUNDLE_ID: &str = "com.apple.finder";

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Modifiers {
    pub command: bool,
    pub shift: bool,
    pub option: bool,
    pub control: bool,
}

impl Modifiers {
    pub const COMMAND: Modifiers = Modifiers {
        command: true,
        shift: false,
        option: false,
        control: false,
    };
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Key {
    X,
    V,
    Other,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct KeyEvent {
    pub key: Key,
    pub modifiers: Modifiers,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DisabledReason {
    /// macOS disabled the tap because the callback was too slow.
    Timeout,
    /// macOS disabled the tap on user input (secure input started).
    UserInput,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TapEvent {
    Key(KeyEvent),
    Disabled(DisabledReason),
}

/// The key combination the adapter posts in place of the swallowed event.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Synthetic {
    /// ⌘C
    Copy,
    /// ⌘⌥V
    MoveHere,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Action {
    /// Deliver the original event untouched.
    PassThrough,
    /// Swallow the original event and post this one.
    Replace(Synthetic),
    /// Switch the disabled tap back on; nothing else.
    ReEnableTap,
}

/// Port: the system state the decision depends on.
pub trait FinderEnv {
    fn frontmost_bundle_id(&self) -> Option<String>;
    fn secure_input_active(&self) -> bool;
    /// `NSPasteboard.general.changeCount`.
    fn pasteboard_change_count(&self) -> i64;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Cut {
    Idle,
    /// ⌘C posted; the clipboard has not changed yet (`before` is its count then).
    Copying {
        before: i64,
    },
    /// The copy landed; the clipboard still holds exactly that copy.
    Armed {
        count: i64,
    },
}

#[derive(Debug)]
pub struct FinderCut {
    cut: Cut,
}

impl Default for FinderCut {
    fn default() -> Self {
        FinderCut { cut: Cut::Idle }
    }
}

impl FinderCut {
    pub fn handle(&mut self, event: TapEvent, env: &dyn FinderEnv) -> Action {
        let key = match event {
            TapEvent::Disabled(_) => {
                // Events may have been lost: forget any pending cut.
                self.cut = Cut::Idle;
                return Action::ReEnableTap;
            }
            TapEvent::Key(key) => key,
        };
        self.poll(env);
        let active = env.frontmost_bundle_id().as_deref() == Some(FINDER_BUNDLE_ID)
            && !env.secure_input_active();
        if !active || key.modifiers != Modifiers::COMMAND {
            return Action::PassThrough;
        }
        match (key.key, self.cut) {
            (Key::X, _) => {
                self.cut = Cut::Copying {
                    before: env.pasteboard_change_count(),
                };
                Action::Replace(Synthetic::Copy)
            }
            (Key::V, Cut::Armed { .. }) => {
                self.cut = Cut::Idle;
                Action::Replace(Synthetic::MoveHere)
            }
            _ => Action::PassThrough,
        }
    }

    /// Watches the clipboard: a cut is armed when its copy lands and dropped as
    /// soon as anything else changes the clipboard. `handle` calls this on every
    /// key event; the adapter also calls it every few milliseconds for a short
    /// while after a `Replace(Copy)` (until `is_waiting` is false), because a
    /// second copy that happens before the first is observed cannot be told apart.
    pub fn poll(&mut self, env: &dyn FinderEnv) {
        let now = env.pasteboard_change_count();
        self.cut = match self.cut {
            Cut::Copying { before } if now != before => Cut::Armed { count: now },
            Cut::Armed { count } if now != count => Cut::Idle,
            other => other,
        };
    }

    /// True between the posted ⌘C and the moment its copy is observed.
    pub fn is_waiting(&self) -> bool {
        matches!(self.cut, Cut::Copying { .. })
    }

    /// The copy never showed up (nothing was selected): forget the cut.
    pub fn abandon_waiting(&mut self) {
        if self.is_waiting() {
            self.cut = Cut::Idle;
        }
    }

    pub fn has_pending_cut(&self) -> bool {
        matches!(self.cut, Cut::Armed { .. })
    }
}
