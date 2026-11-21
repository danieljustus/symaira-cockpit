//! A wake source a test fires by hand.

use std::sync::{Arc, Mutex};

use symcockpit_contract::Error;
use symcockpit_core::wake::WakeSource;

type Callback = Arc<dyn Fn() + Send + Sync>;

#[derive(Clone, Default)]
pub struct FakeWake {
    callback: Arc<Mutex<Option<Callback>>>,
}

impl FakeWake {
    /// Whether anything is watching (the guard of `watch` still alive).
    pub fn watching(&self) -> bool {
        self.callback.lock().unwrap().is_some()
    }

    /// The system woke up: runs the callback on the caller's thread.
    pub fn fire(&self) {
        let callback = self.callback.lock().unwrap().clone();
        if let Some(callback) = callback {
            callback();
        }
    }
}

struct Guard(Arc<Mutex<Option<Callback>>>);

impl Drop for Guard {
    fn drop(&mut self) {
        *self.0.lock().unwrap() = None;
    }
}

impl WakeSource for FakeWake {
    fn watch(&self, on_wake: Box<dyn Fn() + Send + Sync>) -> Result<Box<dyn Send>, Error> {
        *self.callback.lock().unwrap() = Some(Arc::from(on_wake));
        Ok(Box::new(Guard(self.callback.clone())))
    }
}
