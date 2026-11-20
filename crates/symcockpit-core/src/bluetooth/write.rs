//! Characteristic writes (R52): request, acknowledgement and readback are
//! reported separately, and the result is a post-condition (Q01).
//!
//! The write is an *action behind a trait* so the plan engine can hold it:
//! `plan_ble_write_json` builds the plan item without touching a device, and
//! `BleWriteAction::execute` runs it after confirmation.

use std::time::Duration;

use serde::Serialize;
use serde_json::{Value, json};
use symcockpit_contract::{Error, Outcome};

use super::ble::{BleCentral, WriteAck, normalize_uuid};

/// ATT allows at most 512 bytes in one attribute value.
const MAX_VALUE_LEN: usize = 512;

pub fn to_hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    bytes.iter().fold(String::new(), |mut s, b| {
        let _ = write!(s, "{b:02x}");
        s
    })
}

pub fn from_hex(text: &str) -> Result<Vec<u8>, Error> {
    let t = text.trim();
    let bad = || Error::Usage(format!("not a hex byte string: {text:?}"));
    if !t.len().is_multiple_of(2) || !t.is_ascii() {
        return Err(bad());
    }
    (0..t.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&t[i..i + 2], 16).map_err(|_| bad()))
        .collect()
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WriteRequest {
    pub device_id: String,
    pub service: String,
    pub characteristic: String,
    pub value: Vec<u8>,
    pub with_response: bool,
}

impl WriteRequest {
    /// Validates and normalizes user input (trust boundary).
    pub fn new(
        device_id: &str,
        service: &str,
        characteristic: &str,
        value_hex: &str,
        with_response: bool,
    ) -> Result<WriteRequest, Error> {
        let value = from_hex(value_hex)?;
        if value.is_empty() || value.len() > MAX_VALUE_LEN {
            return Err(Error::Usage(format!(
                "value must be 1 to {MAX_VALUE_LEN} bytes, got {}",
                value.len()
            )));
        }
        if device_id.trim().is_empty() {
            return Err(Error::Usage("device id is empty".into()));
        }
        Ok(WriteRequest {
            device_id: device_id.trim().to_owned(),
            service: normalize_uuid(service)?,
            characteristic: normalize_uuid(characteristic)?,
            value,
            with_response,
        })
    }

    /// The plan item the plan engine stores (`contract::Plan::items`).
    pub fn to_plan_item(&self) -> Value {
        json!({
            "action": "ble_write",
            "device_id": self.device_id,
            "service": self.service,
            "characteristic": self.characteristic,
            "value_hex": to_hex(&self.value),
            "with_response": self.with_response,
        })
    }

    pub fn from_plan_item(item: &Value) -> Result<WriteRequest, Error> {
        let text = |k: &str| {
            item.get(k)
                .and_then(Value::as_str)
                .ok_or_else(|| Error::Usage(format!("plan item lacks {k}")))
        };
        WriteRequest::new(
            text("device_id")?,
            text("service")?,
            text("characteristic")?,
            text("value_hex")?,
            item.get("with_response")
                .and_then(Value::as_bool)
                .unwrap_or(true),
        )
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum WriteStage {
    Requested,
    Sent,
    Acknowledged,
    Readback,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct StageRecord {
    pub stage: WriteStage,
    /// `ok`, `failed`, `not_applicable` or `unavailable`.
    pub status: &'static str,
    pub detail: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AckState {
    Acknowledged,
    NotApplicable,
    Failed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WriteReport {
    pub request: WriteRequest,
    pub stages: Vec<StageRecord>,
    pub ack: AckState,
    /// Bytes read back after the write, `None` if the read failed.
    pub readback: Option<Vec<u8>>,
    pub outcome: Outcome,
}

impl WriteReport {
    pub fn to_json(&self) -> Value {
        json!({
            "request": self.request.to_plan_item(),
            "stages": self.stages,
            "ack": self.ack,
            "readback_hex": self.readback.as_deref().map(to_hex),
            "outcome": self.outcome,
        })
    }
}

/// The write as an action the plan engine can run after confirmation.
pub trait BleWriteAction {
    /// `Err` only when the device could not be reached at all; a failed or
    /// unconfirmed write is a report with the matching `outcome`.
    fn execute(&self, request: &WriteRequest) -> Result<WriteReport, Error>;
}

/// Writes through a `BleCentral`: connect, write, read back, disconnect.
pub struct LinkWriteAction<'a> {
    pub central: &'a dyn BleCentral,
    pub connect_timeout: Duration,
}

impl BleWriteAction for LinkWriteAction<'_> {
    fn execute(&self, req: &WriteRequest) -> Result<WriteReport, Error> {
        let link = self.central.connect(&req.device_id, self.connect_timeout)?;
        let record = |stage, status, detail: &str| StageRecord {
            stage,
            status,
            detail: detail.to_owned(),
        };
        let mut stages = vec![record(WriteStage::Requested, "ok", "accepted locally")];
        let written = link.write(
            &req.service,
            &req.characteristic,
            &req.value,
            req.with_response,
        );
        let (ack, wrote) = match written {
            Ok(WriteAck::Acknowledged) => {
                stages.push(record(WriteStage::Sent, "ok", "handed to the transport"));
                stages.push(record(
                    WriteStage::Acknowledged,
                    "ok",
                    "peripheral confirmed",
                ));
                (AckState::Acknowledged, true)
            }
            Ok(WriteAck::NotRequested) => {
                stages.push(record(WriteStage::Sent, "ok", "handed to the transport"));
                stages.push(record(
                    WriteStage::Acknowledged,
                    "not_applicable",
                    "write without response",
                ));
                (AckState::NotApplicable, true)
            }
            Err(e) => {
                stages.push(record(WriteStage::Sent, "failed", &e.to_string()));
                stages.push(record(
                    WriteStage::Acknowledged,
                    "failed",
                    "no acknowledgement",
                ));
                (AckState::Failed, false)
            }
        };
        let mut readback = None;
        let outcome = if !wrote {
            stages.push(record(WriteStage::Readback, "unavailable", "write failed"));
            Outcome::Failed
        } else {
            match link.read(&req.service, &req.characteristic) {
                Ok(v) => {
                    let same = v == req.value;
                    stages.push(record(
                        WriteStage::Readback,
                        if same { "ok" } else { "failed" },
                        if same {
                            "value matches"
                        } else {
                            "value differs"
                        },
                    ));
                    readback = Some(v);
                    if same {
                        Outcome::Confirmed
                    } else {
                        Outcome::Unconfirmed
                    }
                }
                Err(e) => {
                    stages.push(record(WriteStage::Readback, "unavailable", &e.to_string()));
                    Outcome::Unconfirmed
                }
            }
        };
        link.disconnect();
        Ok(WriteReport {
            request: req.clone(),
            stages,
            ack,
            readback,
            outcome,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_round_trips_and_rejects_garbage() {
        assert_eq!(to_hex(&[0, 1, 0xab, 0xff]), "0001abff");
        assert_eq!(from_hex(" 0001ABff ").unwrap(), [0, 1, 0xab, 0xff]);
        for bad in ["0", "zz", "0x01", "é1"] {
            assert!(from_hex(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn request_validation_and_plan_item_round_trip() {
        let r = WriteRequest::new("dev", "180f", "2a19", "ff00", false).unwrap();
        assert_eq!(r.service, "180F");
        assert_eq!(WriteRequest::from_plan_item(&r.to_plan_item()).unwrap(), r);
        assert!(WriteRequest::new("dev", "180f", "2a19", "", true).is_err());
        assert!(WriteRequest::new("dev", "180f", "2a19", &"00".repeat(513), true).is_err());
        assert!(WriteRequest::new(" ", "180f", "2a19", "00", true).is_err());
        assert!(WriteRequest::new("d", "nope", "2a19", "00", true).is_err());
    }
}
