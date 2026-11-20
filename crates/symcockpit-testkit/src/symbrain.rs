//! A fake `symbrain`: records every call and never touches a keychain.

use std::cell::RefCell;
use std::collections::BTreeMap;

use symcockpit_core::ai_usage::{CommandOutput, UsageError, UsageRunner};

/// One recorded call: arguments and child environment.
pub type Call = (Vec<String>, BTreeMap<String, String>);

pub struct FakeSymbrain {
    pub calls: RefCell<Vec<Call>>,
    pub answer: Result<(i32, String), UsageError>,
}

impl FakeSymbrain {
    /// Answers every call with this stdout and exit status 0.
    pub fn replying(stdout: &str) -> Self {
        Self {
            calls: RefCell::default(),
            answer: Ok((0, stdout.to_owned())),
        }
    }

    pub fn unavailable() -> Self {
        Self {
            calls: RefCell::default(),
            answer: Err(UsageError::BinaryUnavailable),
        }
    }
}

impl UsageRunner for FakeSymbrain {
    fn run(
        &self,
        args: &[String],
        env: &BTreeMap<String, String>,
    ) -> Result<CommandOutput, UsageError> {
        self.calls.borrow_mut().push((args.to_vec(), env.clone()));
        self.answer.clone().map(|(status, stdout)| CommandOutput {
            stdout: stdout.into_bytes(),
            stderr: Vec::new(),
            status,
        })
    }
}
