//! Audio device service: reads, and writes that report a post-condition.
//!
//! Every write follows the same sequence (architecture §6.3): check the
//! precondition, write, evaluate the HAL status, read the property back from
//! the HAL (not from a cached snapshot). A readback that differs yields
//! `unconfirmed` and the report carries both the previous and the observed
//! state (Q01). Risky writes (format, aggregates) are split into a plan, which
//! captures the device identity, and an execution, which revalidates it.

use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use serde_json::{Value, json};
use symcockpit_contract::{Error, Outcome, Risk};

use super::hal::{
    AggregateSpec, AudioHal, DeviceKind, HalError, HalErrorKind, ObjectId, RawDevice, Scope,
    StreamFormat,
};
use super::registry::{Changes, DeviceHandle, DeviceRegistry};
use crate::plan::{Action, ItemResult};

/// Volume and mute are scalars the device may quantise; a readback within this
/// distance counts as the requested value.
pub const VOLUME_TOLERANCE: f32 = 0.02;

/// How long a write is allowed to take before its readback is judged. HAL
/// property changes can land asynchronously, so the readback polls.
#[derive(Clone, Copy, Debug)]
pub struct Readback {
    pub attempts: u32,
    pub delay: Duration,
}

impl Default for Readback {
    fn default() -> Self {
        Readback {
            attempts: 10,
            delay: Duration::from_millis(50),
        }
    }
}

/// Result of one write: a post-condition, not a call status.
#[derive(Clone, Debug)]
pub struct ActionReport {
    pub action: &'static str,
    pub uid: String,
    pub outcome: Outcome,
    pub requested: Value,
    pub before: Value,
    /// State observed by the readback; equals `before` when nothing changed.
    pub after: Value,
    pub detail: Option<String>,
    /// Set for `failed` and `unsupported`: the error the CLI turns into an exit code.
    pub error: Option<Error>,
}

impl ActionReport {
    pub fn to_json(&self) -> Value {
        let mut v = json!({
            "action": self.action,
            "uid": self.uid,
            "outcome": self.outcome,
            "requested": self.requested,
            "before": self.before,
            "after": self.after,
        });
        if let Some(d) = &self.detail {
            v["detail"] = json!(d);
        }
        v
    }

    /// Exit code a CLI should use for this report: only `confirmed` is 0.
    pub fn exit_code(&self) -> u8 {
        match (&self.error, self.outcome) {
            (Some(e), _) => e.exit_code(),
            (None, Outcome::Confirmed) => symcockpit_contract::exit::OK,
            (None, _) => symcockpit_contract::exit::ERROR,
        }
    }

    /// `Ok` with the report for every outcome that reached the device and read
    /// it back (`confirmed`, `unconfirmed`, `skipped_changed`), `Err` otherwise.
    pub fn into_json(self) -> Result<Value, Error> {
        match self.error {
            Some(e) => Err(e),
            None => Ok(self.to_json()),
        }
    }
}

/// What a plan will do, with the device identity it was made against.
#[derive(Clone, Debug, PartialEq)]
pub enum AudioAction {
    SetFormat {
        uid: String,
        scope: Scope,
        rate: f64,
        bits: Option<u32>,
    },
    CreateAggregate(AggregateSpec),
    DeleteAggregate {
        uid: String,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub struct AudioPlan {
    pub action: AudioAction,
    /// Identity of every device the action touches, as seen when planning.
    /// Execution compares it again and reports `skipped_changed` on any change.
    pub identity: Value,
}

impl AudioPlan {
    pub fn action_id(&self) -> &'static str {
        match self.action {
            AudioAction::SetFormat { .. } => "audio.format.set",
            AudioAction::CreateAggregate(_) => "audio.aggregate.create",
            AudioAction::DeleteAggregate { .. } => "audio.aggregate.delete",
        }
    }

    /// All audio device configuration is risky (decision D10).
    pub fn risk(&self) -> Risk {
        Risk::Risky
    }

    /// The plan item shown to the human and digested by the plan engine.
    pub fn item(&self) -> Value {
        let params = match &self.action {
            AudioAction::SetFormat {
                uid,
                scope,
                rate,
                bits,
            } => json!({"uid": uid, "direction": scope.name(), "rate": rate, "bits": bits}),
            AudioAction::CreateAggregate(s) => json!({
                "name": s.name, "uid": s.uid, "main": s.main_uid,
                "members": s.member_uids, "multi_output": s.stacked,
            }),
            AudioAction::DeleteAggregate { uid } => json!({"uid": uid}),
        };
        json!({"action": self.action_id(), "risk": self.risk(), "params": params, "identity": self.identity})
    }
}

impl AudioPlan {
    /// What the user sees as the target of the plan item.
    fn target(&self) -> &str {
        match &self.action {
            AudioAction::SetFormat { uid, .. } | AudioAction::DeleteAggregate { uid } => uid,
            AudioAction::CreateAggregate(spec) => &spec.name,
        }
    }

    /// [`Self::item`] with the `target` the plan engine requires.
    pub fn engine_item(&self) -> Value {
        let mut item = self.item();
        item["target"] = json!(self.target());
        item
    }

    /// Inverse of [`Self::engine_item`]: the plan as it was recorded.
    pub fn from_item(item: &Value) -> Result<AudioPlan, String> {
        let params = &item["params"];
        let text = |key: &str| {
            params[key]
                .as_str()
                .map(str::to_owned)
                .ok_or_else(|| format!("plan item without {key}"))
        };
        let action = match item["action"].as_str() {
            Some("audio.format.set") => AudioAction::SetFormat {
                uid: text("uid")?,
                scope: Scope::parse(&text("direction")?).map_err(|e| e.to_string())?,
                rate: params["rate"].as_f64().ok_or("plan item without rate")?,
                bits: params["bits"].as_u64().and_then(|b| u32::try_from(b).ok()),
            },
            Some("audio.aggregate.create") => AudioAction::CreateAggregate(AggregateSpec {
                name: text("name")?,
                uid: text("uid")?,
                main_uid: text("main")?,
                member_uids: params["members"]
                    .as_array()
                    .ok_or("plan item without members")?
                    .iter()
                    .filter_map(|m| m.as_str().map(str::to_owned))
                    .collect(),
                stacked: params["multi_output"].as_bool().unwrap_or(false),
            }),
            Some("audio.aggregate.delete") => AudioAction::DeleteAggregate { uid: text("uid")? },
            other => return Err(format!("not an audio plan item: {other:?}")),
        };
        Ok(AudioPlan {
            action,
            identity: item["identity"].clone(),
        })
    }
}

/// Runs the audio items of a stored plan. The service is built on first use,
/// so confirming a cleanup plan never opens the audio HAL. The device identity
/// is revalidated inside [`AudioService::execute`] (`skipped_changed`).
pub struct AudioPlanAction<'a> {
    pub kind: &'static str,
    pub service: &'a dyn Fn() -> Result<Arc<AudioService>, Error>,
}

impl Action for AudioPlanAction<'_> {
    fn kind(&self) -> &'static str {
        self.kind
    }

    fn still_valid(&self, item: &Value) -> Result<(), String> {
        AudioPlan::from_item(item).map(|_| ())
    }

    fn execute(&self, item: &Value) -> ItemResult {
        let result = AudioPlan::from_item(item)
            .map_err(Error::Failed)
            .and_then(|plan| Ok((self.service)()?.execute(&plan)));
        match result {
            Ok(report) => {
                let detail = report
                    .error
                    .as_ref()
                    .map(ToString::to_string)
                    .or(report.detail);
                ItemResult::new(report.outcome, detail)
            }
            Err(e) => ItemResult::new(Outcome::Failed, e.to_string()),
        }
    }
}

pub struct AudioService {
    hal: Arc<dyn AudioHal>,
    registry: Mutex<DeviceRegistry>,
    readback: Readback,
}

impl AudioService {
    pub fn new(hal: Arc<dyn AudioHal>) -> Self {
        AudioService {
            hal,
            registry: Mutex::new(DeviceRegistry::default()),
            readback: Readback::default(),
        }
    }

    pub fn with_readback(mut self, readback: Readback) -> Self {
        self.readback = readback;
        self
    }

    pub fn hal(&self) -> &Arc<dyn AudioHal> {
        &self.hal
    }

    pub fn registry(&self) -> MutexGuard<'_, DeviceRegistry> {
        self.registry.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Re-read the device list into the registry.
    pub fn refresh(&self) -> Result<Changes, Error> {
        let snapshot = self.hal.snapshot()?;
        Ok(self.registry().refresh(snapshot))
    }

    /// Refresh, then return the handle and state of an online device.
    pub(crate) fn resolve(&self, uid: &str) -> Result<(DeviceHandle, RawDevice), Error> {
        self.refresh()?;
        let reg = self.registry();
        let handle = reg.handle(uid)?;
        let raw = reg.validate(&handle)?.clone();
        Ok((handle, raw))
    }

    /// Poll `read` until `ok` accepts the value or the attempts run out; the
    /// last observation is returned either way.
    fn poll<T>(
        &self,
        mut read: impl FnMut() -> Result<T, HalError>,
        ok: impl Fn(&T) -> bool,
    ) -> Result<T, HalError> {
        let mut last = read()?;
        for _ in 1..self.readback.attempts.max(1) {
            if ok(&last) {
                break;
            }
            std::thread::sleep(self.readback.delay);
            last = read()?;
        }
        Ok(last)
    }

    fn uid_of(&self, object: Option<ObjectId>) -> Value {
        object
            .and_then(|o| self.hal.device_uid(o).ok())
            .map_or(Value::Null, Value::String)
    }

    fn report(
        &self,
        action: &'static str,
        uid: &str,
        outcome: Outcome,
        values: (Value, Value, Value),
        detail: Option<String>,
    ) -> ActionReport {
        ActionReport {
            action,
            uid: uid.to_owned(),
            outcome,
            requested: values.0,
            before: values.1,
            after: values.2,
            detail,
            error: None,
        }
    }

    /// A write that did not happen or was rejected: after == before. Also
    /// refreshes the registry so a vanished device shows up offline.
    fn failed(
        &self,
        action: &'static str,
        uid: &str,
        requested: Value,
        before: Value,
        err: &HalError,
    ) -> ActionReport {
        let _ = self.refresh();
        let outcome = if err.kind == HalErrorKind::NotSupported {
            Outcome::Unsupported
        } else {
            Outcome::Failed
        };
        let detail = if err.kind == HalErrorKind::NoSuchObject {
            format!("device disappeared during the change: {err}")
        } else {
            err.to_string()
        };
        let mut r = self.report(
            action,
            uid,
            outcome,
            (requested, before.clone(), before),
            Some(detail),
        );
        r.error = Some(err.clone().into());
        r
    }

    fn rejected(&self, action: &'static str, uid: &str, error: Error) -> ActionReport {
        let outcome = if matches!(error, Error::Unsupported(_)) {
            Outcome::Unsupported
        } else {
            Outcome::Failed
        };
        let mut r = self.report(
            action,
            uid,
            outcome,
            (Value::Null, Value::Null, Value::Null),
            Some(error.to_string()),
        );
        r.error = Some(error);
        r
    }

    // ---------------------------------------------------------------- default

    pub fn set_default(&self, scope: Scope, uid: &str) -> Result<ActionReport, Error> {
        const ACTION: &str = "audio.default.set";
        let (handle, dev) = self.resolve(uid)?;
        if dev.scope(scope).channels == 0 {
            return Err(Error::Unsupported(format!(
                "device has no {} streams",
                scope.name()
            )));
        }
        let before = self.uid_of(self.hal.default_device(scope)?);
        let requested = json!(uid);
        if let Err(e) = self.hal.set_default_device(scope, handle.object) {
            return Ok(self.failed(ACTION, uid, requested, before, &e));
        }
        let after = self.poll(
            || self.hal.default_device(scope),
            |o| *o == Some(handle.object),
        );
        let after = match after {
            Ok(o) => self.uid_of(o),
            Err(e) => return Ok(self.failed(ACTION, uid, requested, before, &e)),
        };
        let outcome = if after == requested {
            Outcome::Confirmed
        } else {
            Outcome::Unconfirmed
        };
        let _ = self.refresh();
        Ok(self.report(ACTION, uid, outcome, (requested, before, after), None))
    }

    // ----------------------------------------------------------------- volume

    /// `scope`: `None` picks output if the device has a settable output
    /// volume, else input.
    pub fn set_volume(
        &self,
        uid: &str,
        scope: Option<Scope>,
        value: f32,
    ) -> Result<ActionReport, Error> {
        const ACTION: &str = "audio.volume.set";
        if !(0.0..=1.0).contains(&value) {
            return Err(Error::Usage("volume must be between 0 and 1".into()));
        }
        let (handle, dev) = self.resolve(uid)?;
        let scope = self.pick_scope(&dev, scope, |s| s.volume.is_some(), "a volume control")?;
        let state = dev.scope(scope);
        if !state.volume_settable {
            return Err(Error::Unsupported(format!(
                "the {} volume of this device is not settable",
                scope.name()
            )));
        }
        let before = json!(state.volume);
        let requested = json!(value);
        if let Err(e) = self.hal.set_volume(handle.object, scope, value) {
            return Ok(self.failed(ACTION, uid, requested, before, &e));
        }
        let after = self.poll(
            || self.hal.volume(handle.object, scope),
            |v| v.is_some_and(|v| (v - value).abs() <= VOLUME_TOLERANCE),
        );
        Ok(match after {
            Ok(v) => {
                let hit = v.is_some_and(|v| (v - value).abs() <= VOLUME_TOLERANCE);
                let outcome = if hit {
                    Outcome::Confirmed
                } else {
                    Outcome::Unconfirmed
                };
                self.report(ACTION, uid, outcome, (requested, before, json!(v)), None)
            }
            Err(e) => self.failed(ACTION, uid, requested, before, &e),
        })
    }

    pub fn set_mute(
        &self,
        uid: &str,
        scope: Option<Scope>,
        muted: bool,
    ) -> Result<ActionReport, Error> {
        const ACTION: &str = "audio.mute.set";
        let (handle, dev) = self.resolve(uid)?;
        let scope = self.pick_scope(&dev, scope, |s| s.muted.is_some(), "a mute control")?;
        let state = dev.scope(scope);
        if !state.mute_settable {
            return Err(Error::Unsupported(format!(
                "the {} mute of this device is not settable",
                scope.name()
            )));
        }
        let before = json!(state.muted);
        let requested = json!(muted);
        if let Err(e) = self.hal.set_mute(handle.object, scope, muted) {
            return Ok(self.failed(ACTION, uid, requested, before, &e));
        }
        let after = self.poll(
            || self.hal.mute(handle.object, scope),
            |m| *m == Some(muted),
        );
        Ok(match after {
            Ok(m) => {
                let outcome = if m == Some(muted) {
                    Outcome::Confirmed
                } else {
                    Outcome::Unconfirmed
                };
                self.report(ACTION, uid, outcome, (requested, before, json!(m)), None)
            }
            Err(e) => self.failed(ACTION, uid, requested, before, &e),
        })
    }

    fn pick_scope(
        &self,
        dev: &RawDevice,
        wanted: Option<Scope>,
        has: impl Fn(&super::hal::ScopeState) -> bool,
        what: &str,
    ) -> Result<Scope, Error> {
        let candidates = match wanted {
            Some(s) => vec![s],
            None => vec![Scope::Output, Scope::Input],
        };
        candidates
            .into_iter()
            .find(|s| has(dev.scope(*s)))
            .ok_or_else(|| Error::Unsupported(format!("device has no {what}")))
    }

    // ----------------------------------------------------------------- format

    pub fn plan_format(&self, uid: &str, rate: f64, bits: Option<u32>) -> Result<AudioPlan, Error> {
        if !rate.is_finite() || rate <= 0.0 {
            return Err(Error::Usage("rate must be a positive number of Hz".into()));
        }
        let (_, dev) = self.resolve(uid)?;
        let scope = if dev.output.channels > 0 {
            Scope::Output
        } else {
            Scope::Input
        };
        if !dev.offers_rate(rate) {
            return Err(Error::Unsupported(format!(
                "the device does not offer {rate} Hz"
            )));
        }
        if let Some(b) = bits {
            self.pick_format(&dev, scope, rate, b)?;
        }
        Ok(AudioPlan {
            action: AudioAction::SetFormat {
                uid: uid.to_owned(),
                scope,
                rate,
                bits,
            },
            identity: format_identity(&dev),
        })
    }

    fn pick_format(
        &self,
        dev: &RawDevice,
        scope: Scope,
        rate: f64,
        bits: u32,
    ) -> Result<StreamFormat, Error> {
        dev.scope(scope)
            .formats
            .iter()
            .find(|f| f.bits == bits && StreamFormat::same_rate(f.rate, rate))
            .copied()
            .ok_or_else(|| {
                Error::Unsupported(format!(
                    "the device offers no {bits}-bit format at {rate} Hz"
                ))
            })
    }

    fn exec_format(&self, uid: &str, scope: Scope, rate: f64, bits: Option<u32>) -> ActionReport {
        const ACTION: &str = "audio.format.set";
        let (handle, dev) = match self.resolve(uid) {
            Ok(x) => x,
            Err(e) => return self.changed(ACTION, uid, &e),
        };
        let before = current_format(&dev, scope);
        let requested = json!({"rate": rate, "bits": bits});
        let reached = |now: &Value| {
            now["rate"]
                .as_f64()
                .is_some_and(|r| StreamFormat::same_rate(r, rate))
                && bits.is_none_or(|b| now["bits"].as_u64() == Some(u64::from(b)))
        };
        if reached(&before) {
            return self.report(
                ACTION,
                uid,
                Outcome::Confirmed,
                (requested, before.clone(), before),
                Some("already set".into()),
            );
        }
        // With bits the stream's physical format carries rate and bits in one
        // write; without, only the nominal rate changes.
        let write = match bits {
            Some(b) => self
                .pick_format(&dev, scope, rate, b)
                .map_err(|e| {
                    HalError::new(HalErrorKind::NotSupported, "set_format", &e.to_string())
                })
                .and_then(|f| self.hal.set_format(handle.object, scope, f)),
            None => self.hal.set_sample_rate(handle.object, rate),
        };
        if let Err(e) = write {
            return self.failed(ACTION, uid, requested, before, &e);
        }
        let read = || -> Result<Value, HalError> {
            let rate = self.hal.sample_rate(handle.object)?;
            let format = self.hal.format(handle.object, scope)?;
            Ok(json!({"rate": rate, "bits": format.map(|f| f.bits)}))
        };
        match self.poll(read, reached) {
            Ok(after) => {
                let outcome = if reached(&after) {
                    Outcome::Confirmed
                } else {
                    Outcome::Unconfirmed
                };
                self.report(ACTION, uid, outcome, (requested, before, after), None)
            }
            Err(e) => self.failed(ACTION, uid, requested, before, &e),
        }
    }

    /// The plan no longer matches the world: report it, change nothing.
    fn changed(&self, action: &'static str, uid: &str, why: &Error) -> ActionReport {
        self.report(
            action,
            uid,
            Outcome::SkippedChanged,
            (Value::Null, Value::Null, Value::Null),
            Some(format!("device changed since the plan was made: {why}")),
        )
    }

    // -------------------------------------------------------------- aggregate

    pub fn plan_aggregate_create(
        &self,
        name: &str,
        member_uids: &[String],
        main_uid: Option<&str>,
        stacked: bool,
    ) -> Result<AudioPlan, Error> {
        let name = name.trim();
        if name.is_empty() || name.chars().count() > 64 {
            return Err(Error::Usage("name must be 1 to 64 characters".into()));
        }
        if member_uids.len() < 2 {
            return Err(Error::Usage("need at least two member devices".into()));
        }
        let mut sorted = member_uids.to_vec();
        sorted.sort();
        sorted.dedup();
        if sorted.len() != member_uids.len() {
            return Err(Error::Usage("a device is listed twice".into()));
        }
        let main = main_uid.unwrap_or(&member_uids[0]);
        if !member_uids.iter().any(|m| m == main) {
            return Err(Error::Usage("the main device must be a member".into()));
        }
        let mut identity = Vec::new();
        for uid in member_uids {
            let (_, dev) = self.resolve(uid)?;
            if dev.kind == DeviceKind::Aggregate {
                return Err(Error::Usage(format!(
                    "'{uid}' is itself an aggregate; nesting is not supported"
                )));
            }
            if stacked && dev.output.channels == 0 {
                return Err(Error::Unsupported(format!(
                    "'{uid}' has no output streams; a multi-output device needs outputs"
                )));
            }
            identity.push(json!({"uid": uid, "sample_rate": dev.sample_rate}));
        }
        Ok(AudioPlan {
            action: AudioAction::CreateAggregate(AggregateSpec {
                name: name.to_owned(),
                uid: fresh_uid(name),
                main_uid: main.to_owned(),
                member_uids: member_uids.to_vec(),
                stacked,
            }),
            identity: json!({"members": identity}),
        })
    }

    fn exec_create(&self, spec: &AggregateSpec, identity: &Value) -> ActionReport {
        const ACTION: &str = "audio.aggregate.create";
        let requested =
            json!({"name": spec.name, "members": spec.member_uids, "multi_output": spec.stacked});
        let mut now = Vec::new();
        for uid in &spec.member_uids {
            match self.resolve(uid) {
                Ok((_, d)) => now.push(json!({"uid": uid, "sample_rate": d.sample_rate})),
                Err(e) => return self.changed(ACTION, &spec.uid, &e),
            }
        }
        if json!({"members": now}) != *identity {
            return self.changed(
                ACTION,
                &spec.uid,
                &Error::Failed("member state differs".into()),
            );
        }
        let object = match self.hal.create_aggregate(spec) {
            Ok(o) => o,
            Err(e) => return self.failed(ACTION, &spec.uid, requested, Value::Null, &e),
        };
        // Step 2: the new device must hold exactly the requested members.
        let mut want = spec.member_uids.clone();
        want.sort();
        let check = self
            .poll(|| self.hal.aggregate_members(object), |m| sorted(m) == want)
            .map_err(|e| e.to_string())
            .and_then(|m| {
                if sorted(&m) == want {
                    Ok(())
                } else {
                    Err(format!(
                        "created device holds {} of {} members",
                        m.len(),
                        want.len()
                    ))
                }
            });
        if let Err(why) = check {
            // Roll back: a half-built aggregate must not stay in the system.
            let cleanup = self.hal.destroy_aggregate(object);
            let _ = self.refresh();
            let note = match cleanup {
                Ok(()) => "the partial device was removed".to_owned(),
                Err(e) => format!(
                    "removing the partial device failed too ({e}); object {} is leaked",
                    object.0
                ),
            };
            let mut r = self.report(
                ACTION,
                &spec.uid,
                Outcome::Failed,
                (requested, Value::Null, Value::Null),
                Some(format!("{why}; {note}")),
            );
            r.error = Some(Error::Failed(r.detail.clone().unwrap_or_default()));
            return r;
        }
        let _ = self.refresh();
        let after = json!({"uid": spec.uid, "members": spec.member_uids});
        self.report(
            ACTION,
            &spec.uid,
            Outcome::Confirmed,
            (requested, Value::Null, after),
            None,
        )
    }

    pub fn plan_aggregate_delete(&self, uid: &str) -> Result<AudioPlan, Error> {
        let (_, dev) = self.resolve(uid)?;
        if dev.kind != DeviceKind::Aggregate {
            return Err(Error::Unsupported(format!(
                "'{uid}' is not an aggregate or multi-output device"
            )));
        }
        Ok(AudioPlan {
            action: AudioAction::DeleteAggregate {
                uid: uid.to_owned(),
            },
            identity: json!({"uid": uid, "members": dev.members}),
        })
    }

    fn exec_delete(&self, uid: &str, identity: &Value) -> ActionReport {
        const ACTION: &str = "audio.aggregate.delete";
        let (handle, dev) = match self.resolve(uid) {
            Ok(x) => x,
            Err(e) => return self.changed(ACTION, uid, &e),
        };
        if json!({"uid": uid, "members": dev.members}) != *identity {
            return self.changed(ACTION, uid, &Error::Failed("members differ".into()));
        }
        let before = json!({"present": true, "members": dev.members});
        let requested = json!({"present": false});
        if let Err(e) = self.hal.destroy_aggregate(handle.object) {
            return self.failed(ACTION, uid, requested, before, &e);
        }
        // Destruction is asynchronous in the HAL: poll until the device is gone.
        let gone = || -> Result<bool, HalError> {
            Ok(!self.hal.snapshot()?.devices.iter().any(|d| d.uid == uid))
        };
        let outcome = match self.poll(gone, |g| *g) {
            Ok(true) => Outcome::Confirmed,
            Ok(false) => Outcome::Unconfirmed,
            Err(e) => return self.failed(ACTION, uid, requested, before, &e),
        };
        let _ = self.refresh();
        let after = json!({"present": outcome != Outcome::Confirmed});
        self.report(ACTION, uid, outcome, (requested, before, after), None)
    }

    // ---------------------------------------------------------------- execute

    /// Run a plan. Revalidates the device identity first (`skipped_changed`).
    pub fn execute(&self, plan: &AudioPlan) -> ActionReport {
        match &plan.action {
            AudioAction::SetFormat {
                uid,
                scope,
                rate,
                bits,
            } => {
                // Identity: the format the plan was made against must still hold.
                match self.resolve(uid) {
                    Ok((_, dev)) if format_identity(&dev) != plan.identity => self.changed(
                        "audio.format.set",
                        uid,
                        &Error::Failed("format differs".into()),
                    ),
                    Ok(_) => self.exec_format(uid, *scope, *rate, *bits),
                    Err(e) => self.changed("audio.format.set", uid, &e),
                }
            }
            AudioAction::CreateAggregate(spec) => self.exec_create(spec, &plan.identity),
            AudioAction::DeleteAggregate { uid } => self.exec_delete(uid, &plan.identity),
        }
    }

    /// Error report for a request that failed before it became a plan.
    pub fn rejected_report(&self, action: &'static str, uid: &str, error: Error) -> ActionReport {
        self.rejected(action, uid, error)
    }
}

fn sorted(v: &[String]) -> Vec<String> {
    let mut v = v.to_vec();
    v.sort();
    v
}

fn current_format(dev: &RawDevice, scope: Scope) -> Value {
    json!({
        "rate": dev.sample_rate,
        "bits": dev.scope(scope).format.map(|f| f.bits),
    })
}

fn format_identity(dev: &RawDevice) -> Value {
    let scope = if dev.output.channels > 0 {
        Scope::Output
    } else {
        Scope::Input
    };
    json!({"uid": dev.uid, "format": current_format(dev, scope)})
}

/// A UID for a device we create: unique per call, recognisable as ours.
fn fresh_uid(name: &str) -> String {
    use std::hash::{DefaultHasher, Hash, Hasher};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let mut h = DefaultHasher::new();
    name.hash(&mut h);
    std::process::id().hash(&mut h);
    COUNTER.fetch_add(1, Ordering::Relaxed).hash(&mut h);
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos())
        .hash(&mut h);
    format!("com.symaira.cockpit.aggregate.{:016x}", h.finish())
}
