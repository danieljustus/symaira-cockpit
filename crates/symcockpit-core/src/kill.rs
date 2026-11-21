//! Ending a process through a plan (R12, D10).
//!
//! The plan records the process id *and* its identity (start time, path,
//! owner). Confirming compares the identity again, so an id the system has
//! reused for another process is skipped (`skipped_changed`). The action sends
//! SIGTERM only and then looks again: gone is `confirmed`, still running is
//! `unconfirmed`, refused is `failed` with the reason. Never SIGKILL.

use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use symcockpit_contract::{Error, Outcome};

use crate::plan::{Action, Engine, ItemResult};

pub const KIND: &str = "kill_process";
/// How long the post-condition waits for the process to leave.
pub const GRACE: Duration = Duration::from_secs(3);
const POLL: Duration = Duration::from_millis(100);

/// What makes a process this process and not a later one with the same id.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ProcessIdentity {
    pub pid: i32,
    pub name: String,
    pub path: Option<String>,
    pub started_s: i64,
    pub started_us: i64,
    pub uid: u32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SignalError {
    NotFound,
    Denied(String),
    Other(String),
}

/// Port to the process table. Live adapter: `symcockpit-macos::process`.
pub trait ProcessControl {
    /// `None` when there is no such process; a zombie counts as gone.
    fn identity(&self, pid: i32) -> Result<Option<ProcessIdentity>, Error>;
    /// Sends SIGTERM.
    fn terminate(&self, pid: i32) -> Result<(), SignalError>;
    fn current_pid(&self) -> i32;
    fn current_uid(&self) -> u32;
}

/// `plan_kill_process` / `processes kill`: records the plan, touches nothing.
pub fn plan_kill_json(
    engine: &Engine,
    control: &dyn ProcessControl,
    pid: i64,
) -> Result<Value, Error> {
    let pid = i32::try_from(pid)
        .ok()
        .filter(|p| *p > 1)
        .ok_or_else(|| Error::Usage("pid must be 2 or greater".into()))?;
    if pid == control.current_pid() {
        return Err(Error::Usage("refusing to end symcockpit itself".into()));
    }
    let identity = control
        .identity(pid)?
        .ok_or_else(|| Error::Usage(format!("no process with id {pid}")))?;
    if identity.uid != control.current_uid() {
        return Err(Error::Permission(format!(
            "{} (pid {pid}) belongs to another user",
            identity.name
        )));
    }
    let item = json!({
        "action": KIND,
        "target": format!("{} (pid {pid})", identity.name),
        "pid": pid,
        "identity": identity,
    });
    let plan = engine.create(KIND, vec![item])?;
    Ok(engine.plan_json(&plan))
}

pub struct KillAction<'a> {
    pub control: &'a dyn ProcessControl,
    pub grace: Duration,
    pub sleep: &'a dyn Fn(Duration),
}

fn planned(item: &Value) -> Result<(i32, ProcessIdentity), String> {
    let pid = item["pid"]
        .as_i64()
        .and_then(|p| i32::try_from(p).ok())
        .ok_or("plan item without pid")?;
    let identity = serde_json::from_value(item["identity"].clone())
        .map_err(|e| format!("plan item without identity: {e}"))?;
    Ok((pid, identity))
}

impl Action for KillAction<'_> {
    fn kind(&self) -> &'static str {
        KIND
    }

    fn still_valid(&self, item: &Value) -> Result<(), String> {
        let (pid, expected) = planned(item)?;
        match self.control.identity(pid) {
            Ok(Some(now)) if now == expected => Ok(()),
            Ok(Some(now)) => Err(format!(
                "pid {pid} now belongs to another process ({})",
                now.name
            )),
            Ok(None) => Err("no longer running".into()),
            Err(e) => Err(format!("cannot verify: {e}")),
        }
    }

    fn execute(&self, item: &Value) -> ItemResult {
        let (pid, expected) = match planned(item) {
            Ok(p) => p,
            Err(e) => return ItemResult::new(Outcome::Failed, e),
        };
        match self.control.terminate(pid) {
            Ok(()) | Err(SignalError::NotFound) => {}
            Err(SignalError::Denied(why)) => {
                return ItemResult::new(Outcome::Failed, format!("not permitted: {why}"));
            }
            Err(SignalError::Other(why)) => return ItemResult::new(Outcome::Failed, why),
        }
        let mut waited = Duration::ZERO;
        loop {
            match self.control.identity(pid) {
                // Gone, or the id already belongs to someone else.
                Ok(None) => return ItemResult::new(Outcome::Confirmed, None),
                Ok(Some(now)) if now != expected => {
                    return ItemResult::new(Outcome::Confirmed, None);
                }
                Ok(Some(_)) if waited >= self.grace => {
                    return ItemResult::new(
                        Outcome::Unconfirmed,
                        format!(
                            "still running {} s after SIGTERM",
                            self.grace.as_secs_f64().round()
                        ),
                    );
                }
                Ok(Some(_)) => {
                    (self.sleep)(POLL);
                    waited += POLL;
                }
                Err(e) => {
                    return ItemResult::new(
                        Outcome::Unconfirmed,
                        format!("SIGTERM sent, cannot verify: {e}"),
                    );
                }
            }
        }
    }
}
