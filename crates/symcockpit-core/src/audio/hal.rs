//! The audio port: everything the core needs from CoreAudio, as plain data and
//! one trait. `symcockpit-macos` implements it live, `symcockpit-testkit` as a fake.

use std::fmt;

use serde_json::{Value, json};
use symcockpit_contract::Error;

/// Volatile HAL object id. Valid for one appearance of a device only; never
/// store it across a disappearance (see `registry`).
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, PartialOrd, Ord)]
pub struct ObjectId(pub u32);

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, PartialOrd, Ord)]
pub enum Scope {
    Input,
    Output,
}

impl Scope {
    pub fn name(self) -> &'static str {
        match self {
            Scope::Input => "input",
            Scope::Output => "output",
        }
    }

    pub fn parse(text: &str) -> Result<Scope, Error> {
        match text {
            "input" => Ok(Scope::Input),
            "output" => Ok(Scope::Output),
            other => Err(Error::Usage(format!(
                "direction must be input or output, got '{other}'"
            ))),
        }
    }
}

/// Why a HAL call failed, coarse enough to pick an outcome and an exit code.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HalErrorKind {
    /// The object is gone (device unplugged between listing and use).
    NoSuchObject,
    /// The property does not exist or cannot be written on this object.
    NotSupported,
    /// macOS refused (privacy permission, illegal operation).
    Permission,
    Other,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HalError {
    pub kind: HalErrorKind,
    /// The call that failed, e.g. `AudioObjectSetPropertyData(volume)`.
    pub op: String,
    pub status: Option<i32>,
    pub message: String,
}

impl HalError {
    pub fn new(kind: HalErrorKind, op: &str, message: &str) -> Self {
        HalError {
            kind,
            op: op.to_owned(),
            status: None,
            message: message.to_owned(),
        }
    }
}

impl fmt::Display for HalError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.op, self.message)?;
        if let Some(s) = self.status {
            write!(f, " (OSStatus {s})")?;
        }
        Ok(())
    }
}

impl std::error::Error for HalError {}

impl From<HalError> for Error {
    fn from(e: HalError) -> Error {
        match e.kind {
            HalErrorKind::NotSupported => Error::Unsupported(e.to_string()),
            HalErrorKind::Permission => Error::Permission(e.to_string()),
            HalErrorKind::NoSuchObject | HalErrorKind::Other => Error::Failed(e.to_string()),
        }
    }
}

/// One concrete stream format (the HAL's physical format).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StreamFormat {
    pub rate: f64,
    /// Valid bits per sample.
    pub bits: u32,
    pub channels: u32,
}

impl StreamFormat {
    pub fn same_rate(a: f64, b: f64) -> bool {
        (a - b).abs() < 0.5
    }

    pub fn to_json(self) -> Value {
        json!({"rate": self.rate, "bits": self.bits, "channels": self.channels})
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RateRange {
    pub min: f64,
    pub max: f64,
}

/// What one direction of a device offers and currently holds.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ScopeState {
    pub channels: u32,
    pub volume: Option<f32>,
    pub volume_settable: bool,
    pub muted: Option<bool>,
    pub mute_settable: bool,
    pub format: Option<StreamFormat>,
    /// Physical formats the stream accepts.
    pub formats: Vec<StreamFormat>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeviceKind {
    Physical,
    Aggregate,
    Virtual,
}

impl DeviceKind {
    pub fn name(self) -> &'static str {
        match self {
            DeviceKind::Physical => "physical",
            DeviceKind::Aggregate => "aggregate",
            DeviceKind::Virtual => "virtual",
        }
    }
}

/// A device as read from the HAL at one moment.
#[derive(Clone, Debug, PartialEq)]
pub struct RawDevice {
    pub object: ObjectId,
    /// Stable across plug cycles and reboots: the identity for recognition.
    pub uid: String,
    pub name: String,
    pub manufacturer: Option<String>,
    /// `builtin`, `usb`, `bluetooth`, ... or the four-character code.
    pub transport: String,
    pub kind: DeviceKind,
    pub input: ScopeState,
    pub output: ScopeState,
    pub sample_rate: Option<f64>,
    pub sample_rates: Vec<RateRange>,
    /// Sub-device UIDs; empty unless `kind` is `Aggregate`.
    pub members: Vec<String>,
}

impl RawDevice {
    pub fn scope(&self, scope: Scope) -> &ScopeState {
        match scope {
            Scope::Input => &self.input,
            Scope::Output => &self.output,
        }
    }

    pub fn offers_rate(&self, hz: f64) -> bool {
        self.sample_rates
            .iter()
            .any(|r| hz >= r.min - 0.5 && hz <= r.max + 0.5)
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct HalSnapshot {
    pub devices: Vec<RawDevice>,
    pub default_input: Option<ObjectId>,
    pub default_output: Option<ObjectId>,
}

/// Request for a new aggregate or multi-output device.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AggregateSpec {
    pub name: String,
    /// UID of the new device; chosen by the caller so a plan can name it.
    pub uid: String,
    pub main_uid: String,
    pub member_uids: Vec<String>,
    /// `true` builds a multi-output device (every member plays the same audio).
    pub stacked: bool,
}

pub trait AudioHal: Send + Sync {
    fn snapshot(&self) -> Result<HalSnapshot, HalError>;
    fn device_uid(&self, object: ObjectId) -> Result<String, HalError>;
    fn default_device(&self, scope: Scope) -> Result<Option<ObjectId>, HalError>;
    fn set_default_device(&self, scope: Scope, object: ObjectId) -> Result<(), HalError>;
    fn volume(&self, object: ObjectId, scope: Scope) -> Result<Option<f32>, HalError>;
    fn set_volume(&self, object: ObjectId, scope: Scope, value: f32) -> Result<(), HalError>;
    fn mute(&self, object: ObjectId, scope: Scope) -> Result<Option<bool>, HalError>;
    fn set_mute(&self, object: ObjectId, scope: Scope, muted: bool) -> Result<(), HalError>;
    fn sample_rate(&self, object: ObjectId) -> Result<f64, HalError>;
    fn set_sample_rate(&self, object: ObjectId, hz: f64) -> Result<(), HalError>;
    fn format(&self, object: ObjectId, scope: Scope) -> Result<Option<StreamFormat>, HalError>;
    fn set_format(
        &self,
        object: ObjectId,
        scope: Scope,
        format: StreamFormat,
    ) -> Result<(), HalError>;
    fn create_aggregate(&self, spec: &AggregateSpec) -> Result<ObjectId, HalError>;
    fn aggregate_members(&self, object: ObjectId) -> Result<Vec<String>, HalError>;
    fn destroy_aggregate(&self, object: ObjectId) -> Result<(), HalError>;
    /// Bumped by the platform's device-list and default-device notifications.
    /// A consumer that sees a new value refreshes its registry.
    fn change_epoch(&self) -> u64;
}
