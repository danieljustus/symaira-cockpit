//! The BLE session (R51 to R53) as the agent hosts it: connections and subscriptions stay open
//! between commands, the log lives in this thread's memory, and `ble export` reads it.
//!
//! One thread owns the CoreBluetooth central (its objects are not `Send`; the adapter needs no
//! run loop) and everything built on it. Commands arrive over a channel, so a long scan does not
//! block the agent's other requests and samples. Rules:
//!
//! - A **filter** only changes what a scan shows; it never touches a connection.
//! - **Connections** are made by `ble.connect` or on first use and kept until `ble.disconnect`,
//!   a failure, or the agent ends. They are closed (and subscriptions ended) at the end.
//! - **Subscriptions** are live: while any exists the thread polls the link and logs each
//!   notification. `ble.subscribe` with `seconds` expires by itself.
//! - **Writes** report request, acknowledgement and readback separately and are logged so.
//! - The **log** is bounded, in memory only, and leaves the process only through an explicit
//!   `ble.export` (CSV after RFC 4180, or JSON with the raw bytes) (Q08).
//!
//! shortcut: live subscriptions on one device at a time, because the CoreBluetooth adapter's
//! value events carry no peripheral id (see `BleLink::begin_subscription`).

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};
use symcockpit_contract::Error;
use symcockpit_contract::Outcome;
use symcockpit_core::bluetooth::{
    BLE_WRITE_KIND, BleCentral, BleLink, BleLog, BleWriteAction, ExportFormat, LogKind, ScanFilter,
    WriteReport, WriteRequest, ble_export_json, ble_scan_json, ble_write_json, item_result,
    normalize_uuid, to_hex, write_on_link,
};
use symcockpit_core::plan::{Action, ItemResult};

use super::actor::{Actor, Service};

pub type MakeCentral = Arc<dyn Fn() -> Result<Box<dyn BleCentral>, Error> + Send + Sync>;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// Added to an operation's own limit when waiting for its answer.
const SLACK: Duration = Duration::from_secs(15);
const LOG_CAP: usize = 5000;
/// How long one poll of the live subscriptions waits for notifications.
pub const POLL: Duration = Duration::from_millis(100);

pub enum Req {
    Scan {
        timeout: Duration,
        filter: String,
    },
    Connect {
        id: String,
    },
    Disconnect {
        id: String,
    },
    Services {
        id: String,
    },
    Read {
        id: String,
        service: String,
        characteristic: String,
    },
    Subscribe {
        id: String,
        service: String,
        characteristic: String,
        seconds: Option<f64>,
    },
    Unsubscribe {
        id: String,
        service: String,
        characteristic: String,
    },
    Write(WriteRequest),
    Export(ExportFormat),
    Log {
        since: u64,
    },
    Session,
}

pub enum Reply {
    Json(Value),
    Report(WriteReport),
}

struct Sub {
    device: String,
    service: String,
    characteristic: String,
    until: Option<Instant>,
}

struct Ble {
    make: MakeCentral,
    central: Option<Box<dyn BleCentral>>,
    links: BTreeMap<String, Box<dyn BleLink>>,
    subs: Vec<Sub>,
    log: BleLog,
    poll: Duration,
}

/// Writes on a link that stays open, keeping the report for the plan engine.
struct OnLink<'a> {
    link: &'a dyn BleLink,
    last: RefCell<Option<WriteReport>>,
}

impl BleWriteAction for OnLink<'_> {
    fn execute(&self, request: &WriteRequest) -> Result<WriteReport, Error> {
        let report = write_on_link(self.link, request);
        *self.last.borrow_mut() = Some(report.clone());
        Ok(report)
    }
}

fn not_connected(id: &str) -> Error {
    Error::Usage(format!("{id} is not connected (ble connect <device_id>)"))
}

impl Ble {
    fn central(&mut self) -> Result<&dyn BleCentral, Error> {
        if self.central.is_none() {
            self.central = Some((self.make)()?);
        }
        Ok(self.central.as_deref().expect("created above"))
    }

    /// Connects unless already connected; returns whether a new connection was made.
    fn ensure_connected(&mut self, id: &str) -> Result<bool, Error> {
        if self.links.contains_key(id) {
            return Ok(false);
        }
        let link = self.central()?.connect(id, CONNECT_TIMEOUT)?;
        self.log.record(LogKind::Connect, id, "", "", &[], "");
        self.links.insert(id.to_owned(), link);
        Ok(true)
    }

    fn link(&self, id: &str) -> Result<&dyn BleLink, Error> {
        self.links
            .get(id)
            .map(|l| &**l)
            .ok_or_else(|| not_connected(id))
    }

    fn drop_device(&mut self, id: &str, why: &str) {
        let (mine, rest): (Vec<_>, Vec<_>) = std::mem::take(&mut self.subs)
            .into_iter()
            .partition(|s| s.device == id);
        self.subs = rest;
        if let Some(link) = self.links.remove(id) {
            for sub in &mine {
                link.end_subscription(&sub.service, &sub.characteristic);
                self.log.record(
                    LogKind::Unsubscribe,
                    id,
                    &sub.service,
                    &sub.characteristic,
                    &[],
                    why,
                );
            }
            link.disconnect();
            self.log.record(LogKind::Disconnect, id, "", "", &[], why);
        }
    }

    fn connect(&mut self, id: &str) -> Result<Value, Error> {
        let new = self.ensure_connected(id)?;
        Ok(json!({"device_id": id, "connected": true, "new": new}))
    }

    fn disconnect(&mut self, id: &str) -> Value {
        let was = self.links.contains_key(id);
        self.drop_device(id, "requested");
        json!({"device_id": id, "connected": false, "was_connected": was})
    }

    fn services(&mut self, id: &str) -> Result<Value, Error> {
        self.ensure_connected(id)?;
        let services = self.link(id)?.services()?;
        Ok(json!({"device_id": id, "services": services}))
    }

    fn read(&mut self, id: &str, service: &str, characteristic: &str) -> Result<Value, Error> {
        let (service, characteristic) = (normalize_uuid(service)?, normalize_uuid(characteristic)?);
        self.ensure_connected(id)?;
        let value = self.link(id)?.read(&service, &characteristic);
        let value = match value {
            Ok(v) => v,
            Err(e) => {
                self.log.record(
                    LogKind::Error,
                    id,
                    &service,
                    &characteristic,
                    &[],
                    &e.to_string(),
                );
                return Err(e);
            }
        };
        self.log
            .record(LogKind::Read, id, &service, &characteristic, &value, "");
        Ok(json!({
            "device_id": id, "service": service, "characteristic": characteristic,
            "length": value.len(), "value_hex": to_hex(&value),
        }))
    }

    fn subscribe(
        &mut self,
        id: &str,
        service: &str,
        characteristic: &str,
        seconds: Option<f64>,
    ) -> Result<Value, Error> {
        let (service, characteristic) = (normalize_uuid(service)?, normalize_uuid(characteristic)?);
        if self.subs.iter().any(|s| s.device != id) {
            return Err(Error::Usage(
                "live subscriptions are limited to one connected device at a time; \
                 unsubscribe the other one first"
                    .into(),
            ));
        }
        self.ensure_connected(id)?;
        let until = seconds.map(|s| Instant::now() + Duration::from_secs_f64(s));
        let known = self
            .subs
            .iter_mut()
            .find(|s| s.service == service && s.characteristic == characteristic);
        if let Some(sub) = known {
            sub.until = until; // asking again only renews the expiry
        } else {
            self.link(id)?
                .begin_subscription(&service, &characteristic)?;
            self.subs.push(Sub {
                device: id.to_owned(),
                service: service.clone(),
                characteristic: characteristic.clone(),
                until,
            });
            self.log
                .record(LogKind::Subscribe, id, &service, &characteristic, &[], "");
        }
        Ok(json!({
            "device_id": id, "service": service, "characteristic": characteristic,
            "subscribed": true, "expires_in_s": seconds,
        }))
    }

    fn unsubscribe(
        &mut self,
        id: &str,
        service: &str,
        characteristic: &str,
    ) -> Result<Value, Error> {
        let (service, characteristic) = (normalize_uuid(service)?, normalize_uuid(characteristic)?);
        let before = self.subs.len();
        self.subs.retain(|s| {
            !(s.device == id && s.service == service && s.characteristic == characteristic)
        });
        let was = self.subs.len() != before;
        if was && let Some(link) = self.links.get(id) {
            link.end_subscription(&service, &characteristic);
            self.log
                .record(LogKind::Unsubscribe, id, &service, &characteristic, &[], "");
        }
        Ok(
            json!({"device_id": id, "service": service, "characteristic": characteristic,
                  "subscribed": false, "was_subscribed": was}),
        )
    }

    fn write(&mut self, request: &WriteRequest) -> Result<WriteReport, Error> {
        self.ensure_connected(&request.device_id)?;
        let link = self.links.get(&request.device_id).expect("connected above");
        let action = OnLink {
            link: &**link,
            last: RefCell::new(None),
        };
        // Logs request, acknowledgement and readback as separate entries.
        ble_write_json(&action, &mut self.log, request)?;
        let report = action.last.take();
        report.ok_or_else(|| Error::Failed("the write produced no report".into()))
    }

    fn log_json(&self, since: u64) -> Value {
        let entries: Vec<Value> = self
            .log
            .since(since)
            .map(|(seq, e)| {
                json!({
                    "seq": seq, "t_ms": e.t_ms,
                    "kind": serde_json::to_value(e.kind).unwrap_or(Value::Null),
                    "device_id": e.device_id, "service": e.service,
                    "characteristic": e.characteristic, "bytes": e.bytes,
                    "value_hex": to_hex(&e.bytes), "detail": e.detail,
                })
            })
            .collect();
        json!({"seq": self.log.total(), "count": entries.len(), "entries": entries})
    }

    fn session_json(&self) -> Value {
        json!({
            "connections": self.links.keys().collect::<Vec<_>>(),
            "subscriptions": self.subs.iter().map(|s| json!({
                "device_id": s.device, "service": s.service, "characteristic": s.characteristic,
            })).collect::<Vec<_>>(),
            "log_entries": self.log.len(),
            "log_seq": self.log.total(),
        })
    }

    /// Ends every subscription and connection. The log stays until the process ends.
    fn close_all(&mut self) {
        let ids: Vec<String> = self.links.keys().cloned().collect();
        for id in ids {
            self.drop_device(&id, "agent ended");
        }
    }
}

impl Service for Ble {
    type Req = Req;
    type Resp = Result<Reply, Error>;

    fn handle(&mut self, req: Req) -> Self::Resp {
        let json = |v: Result<Value, Error>| v.map(Reply::Json);
        match req {
            Req::Scan { timeout, filter } => {
                let filter = ScanFilter::new(&filter);
                // Split borrow: the central and the log are different fields.
                self.central()?;
                let central = self.central.as_deref().expect("created above");
                json(ble_scan_json(central, &mut self.log, timeout, &filter))
            }
            Req::Connect { id } => json(self.connect(&id)),
            Req::Disconnect { id } => Ok(Reply::Json(self.disconnect(&id))),
            Req::Services { id } => json(self.services(&id)),
            Req::Read {
                id,
                service,
                characteristic,
            } => json(self.read(&id, &service, &characteristic)),
            Req::Subscribe {
                id,
                service,
                characteristic,
                seconds,
            } => json(self.subscribe(&id, &service, &characteristic, seconds)),
            Req::Unsubscribe {
                id,
                service,
                characteristic,
            } => json(self.unsubscribe(&id, &service, &characteristic)),
            Req::Write(request) => self.write(&request).map(Reply::Report),
            Req::Export(format) => json(ble_export_json(&self.log, format)),
            Req::Log { since } => Ok(Reply::Json(self.log_json(since))),
            Req::Session => Ok(Reply::Json(self.session_json())),
        }
    }

    fn wake_in(&self) -> Option<Duration> {
        // With a live subscription the poll itself waits; without one the thread sleeps.
        (!self.subs.is_empty()).then_some(Duration::ZERO)
    }

    fn tick(&mut self) {
        let started = Instant::now();
        let now = started;
        let expired: Vec<(String, String, String)> = self
            .subs
            .iter()
            .filter(|s| s.until.is_some_and(|t| t <= now))
            .map(|s| {
                (
                    s.device.clone(),
                    s.service.clone(),
                    s.characteristic.clone(),
                )
            })
            .collect();
        for (device, service, characteristic) in expired {
            let _ = self.unsubscribe(&device, &service, &characteristic);
        }
        let devices: Vec<String> = {
            let mut d: Vec<String> = self.subs.iter().map(|s| s.device.clone()).collect();
            d.dedup();
            d
        };
        for device in devices {
            let Self {
                links, log, poll, ..
            } = self;
            let Some(link) = links.get(&device) else {
                continue;
            };
            let polled = link.poll_subscriptions(*poll, &mut |service, characteristic, n| {
                log.record(
                    LogKind::Notify,
                    &device,
                    service,
                    characteristic,
                    &n.value,
                    &format!("+{} ms", n.elapsed_ms),
                );
            });
            if let Err(e) = polled {
                self.log
                    .record(LogKind::Error, &device, "", "", &[], &e.to_string());
                self.drop_device(&device, "connection failed");
            }
        }
        // A link whose poll returns at once must not turn this into a busy loop.
        if let Some(rest) = self.poll.checked_sub(started.elapsed()) {
            std::thread::sleep(rest);
        }
    }

    fn shutdown(&mut self) {
        self.close_all();
    }
}

pub struct BleHandle {
    actor: Actor<Ble>,
}

fn arg<'a>(args: &'a Map<String, Value>, key: &str) -> Result<&'a str, Error> {
    args.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| Error::Usage(format!("missing argument '{key}'")))
}

impl BleHandle {
    pub fn spawn(make: MakeCentral, poll: Duration) -> Self {
        Self {
            actor: Actor::spawn("symcockpit-ble", move || Ble {
                make,
                central: None,
                links: BTreeMap::new(),
                subs: Vec::new(),
                log: BleLog::new(LOG_CAP),
                poll,
            }),
        }
    }

    fn ask(&self, req: Req, limit: Duration) -> Result<Reply, Error> {
        self.actor.request(req, limit + SLACK)?
    }

    fn json(&self, req: Req, limit: Duration) -> Result<Value, Error> {
        match self.ask(req, limit)? {
            Reply::Json(v) => Ok(v),
            Reply::Report(r) => Ok(r.to_json()),
        }
    }

    /// The register command `command` (`ble.scan`, `ble.connect`, ...) on the live session.
    pub fn run(&self, command: &str, args: &Map<String, Value>) -> Result<Value, Error> {
        let id = || arg(args, "device_id").map(str::to_owned);
        let gatt = || -> Result<_, Error> {
            Ok((
                id()?,
                arg(args, "service")?.to_owned(),
                arg(args, "characteristic")?.to_owned(),
            ))
        };
        let quick = Duration::from_secs(1);
        match command {
            "ble.scan" => {
                let seconds = args
                    .get("timeout_seconds")
                    .and_then(Value::as_f64)
                    .unwrap_or(5.0);
                let timeout = Duration::from_secs_f64(seconds);
                let filter = args.get("filter").and_then(Value::as_str).unwrap_or("");
                self.json(
                    Req::Scan {
                        timeout,
                        filter: filter.to_owned(),
                    },
                    timeout,
                )
            }
            "ble.connect" => self.json(Req::Connect { id: id()? }, CONNECT_TIMEOUT),
            "ble.disconnect" => self.json(Req::Disconnect { id: id()? }, CONNECT_TIMEOUT),
            "ble.services" => self.json(Req::Services { id: id()? }, CONNECT_TIMEOUT * 2),
            "ble.read" => {
                let (id, service, characteristic) = gatt()?;
                self.json(
                    Req::Read {
                        id,
                        service,
                        characteristic,
                    },
                    CONNECT_TIMEOUT * 2,
                )
            }
            "ble.subscribe" => {
                let (id, service, characteristic) = gatt()?;
                let seconds = args.get("seconds").and_then(Value::as_f64);
                self.json(
                    Req::Subscribe {
                        id,
                        service,
                        characteristic,
                        seconds,
                    },
                    CONNECT_TIMEOUT * 2,
                )
            }
            "ble.unsubscribe" => {
                let (id, service, characteristic) = gatt()?;
                self.json(
                    Req::Unsubscribe {
                        id,
                        service,
                        characteristic,
                    },
                    quick,
                )
            }
            "ble.export" => {
                let format = ExportFormat::parse(
                    args.get("format").and_then(Value::as_str).unwrap_or("json"),
                )?;
                self.json(Req::Export(format), quick)
            }
            "ble.log" => {
                let since = args.get("since").and_then(Value::as_u64).unwrap_or(0);
                self.json(Req::Log { since }, quick)
            }
            "ble.session" => self.json(Req::Session, quick),
            other => Err(Error::Failed(format!("{other}: no handler"))),
        }
    }

    /// A confirmed write plan: the write on the session's connection, with its report.
    pub fn write(&self, request: WriteRequest) -> Result<WriteReport, Error> {
        match self.ask(Req::Write(request), CONNECT_TIMEOUT * 2)? {
            Reply::Report(report) => Ok(report),
            Reply::Json(_) => Err(Error::Failed("the write produced no report".into())),
        }
    }

    /// Closes every connection and subscription and ends the thread.
    pub fn stop(&self) {
        self.actor.stop();
    }
}

/// The plan action of a confirmed `ble.write` inside the agent: it writes on the session's
/// connection (reusing it, logging every stage) instead of connecting afresh.
pub struct HostedWrite(pub Arc<BleHandle>);

impl Action for HostedWrite {
    fn kind(&self) -> &'static str {
        BLE_WRITE_KIND
    }

    fn still_valid(&self, item: &Value) -> Result<(), String> {
        WriteRequest::from_plan_item(item)
            .map(|_| ())
            .map_err(|e| e.to_string())
    }

    fn execute(&self, item: &Value) -> ItemResult {
        match WriteRequest::from_plan_item(item).and_then(|request| self.0.write(request)) {
            Ok(report) => item_result(&report),
            Err(e) => ItemResult::new(Outcome::Failed, e.to_string()),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use symcockpit_core::bluetooth::{Advertisement, Characteristic, Notification, Service};
    use symcockpit_testkit::bluetooth::{FakeDevice, SyncCentral, WriteBehavior};

    use super::*;

    const SVC: &str = "180F";
    const CHR: &str = "2A19";

    fn ad(id: &str, name: &str) -> Advertisement {
        Advertisement {
            id: id.into(),
            name: Some(name.into()),
            rssi: Some(-60),
            service_uuids: vec![SVC.into()],
            connectable: Some(true),
        }
    }

    fn central() -> SyncCentral {
        SyncCentral::new(
            vec![ad("id-a", "Heart Strap"), ad("id-b", "Lamp")],
            FakeDevice {
                services: vec![Service {
                    uuid: SVC.into(),
                    characteristics: vec![Characteristic {
                        uuid: CHR.into(),
                        properties: vec!["read".into(), "write".into(), "notify".into()],
                    }],
                }],
                values: BTreeMap::from([((SVC.to_owned(), CHR.to_owned()), vec![0x01])]),
                write: WriteBehavior::Accept,
                notifications: Vec::<Notification>::new(),
            },
        )
    }

    fn session(c: &SyncCentral) -> BleHandle {
        let c = c.clone();
        BleHandle::spawn(
            Arc::new(move || Ok(Box::new(c.clone()) as Box<dyn BleCentral>)),
            Duration::from_millis(5),
        )
    }

    fn call(h: &BleHandle, command: &str, args: Value) -> Result<Value, Error> {
        h.run(command, args.as_object().unwrap())
    }

    fn gatt(id: &str) -> Value {
        json!({"device_id": id, "service": SVC, "characteristic": CHR})
    }

    fn eventually(what: &str, check: impl Fn() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !check() {
            assert!(Instant::now() < deadline, "timed out waiting for: {what}");
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn a_connection_outlives_the_command_that_made_it() {
        let c = central();
        let h = session(&c);
        let r = call(&h, "ble.connect", json!({"device_id": "id-a"})).unwrap();
        assert_eq!(
            (r["connected"].as_bool(), r["new"].as_bool()),
            (Some(true), Some(true))
        );
        // Reading uses the open connection: no second connect, no disconnect.
        let v = call(&h, "ble.read", gatt("id-a")).unwrap();
        assert_eq!(v["value_hex"], "01");
        assert_eq!(c.counters(), (0, 1, 0));
        assert_eq!(c.open_links(), 1);
        let s = call(&h, "ble.session", json!({})).unwrap();
        assert_eq!(s["connections"], json!(["id-a"]));
        let r = call(&h, "ble.disconnect", json!({"device_id": "id-a"})).unwrap();
        assert_eq!(r["was_connected"], true);
        assert_eq!((c.open_links(), c.counters().2), (0, 1));
        let r = call(&h, "ble.disconnect", json!({"device_id": "id-a"})).unwrap();
        assert_eq!(r["was_connected"], false, "disconnecting twice is harmless");
        h.stop();
    }

    #[test]
    fn a_filter_changes_the_display_and_never_a_connection() {
        let c = central();
        let h = session(&c);
        call(&h, "ble.connect", json!({"device_id": "id-a"})).unwrap();
        let shown = call(
            &h,
            "ble.scan",
            json!({"timeout_seconds": 1, "filter": "lamp"}),
        )
        .unwrap();
        assert_eq!(
            (shown["total_seen"].as_u64(), shown["shown"].as_u64()),
            (Some(2), Some(1))
        );
        let none = call(
            &h,
            "ble.scan",
            json!({"timeout_seconds": 1, "filter": "nothing"}),
        )
        .unwrap();
        assert_eq!(none["shown"], 0);
        assert_eq!(c.open_links(), 1, "the connection survived both filters");
        assert_eq!(c.counters().2, 0);
        h.stop();
    }

    #[test]
    fn a_live_subscription_logs_notifications_until_it_is_ended() {
        let c = central();
        let h = session(&c);
        call(&h, "ble.subscribe", gatt("id-a")).unwrap();
        assert_eq!(c.subscribed(), 1);
        c.notify(SVC, CHR, &[0x10, 0x20]);
        c.notify(SVC, CHR, &[0xff]);
        eventually("both notifications are logged", || {
            call(&h, "ble.session", json!({})).unwrap()["log_entries"]
                .as_u64()
                .unwrap()
                >= 4
        });
        let log = call(&h, "ble.log", json!({})).unwrap();
        let kinds: Vec<&str> = log["entries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["kind"].as_str().unwrap())
            .collect();
        assert_eq!(kinds, ["connect", "subscribe", "notify", "notify"]);
        assert_eq!(log["entries"][2]["bytes"], json!([0x10, 0x20]));
        // `since` returns only what is new.
        let seq = log["seq"].as_u64().unwrap();
        assert_eq!(
            call(&h, "ble.log", json!({"since": seq})).unwrap()["count"],
            0
        );
        let end = call(&h, "ble.unsubscribe", gatt("id-a")).unwrap();
        assert_eq!(end["was_subscribed"], true);
        assert_eq!(c.subscribed(), 0);
        // After that, a notification is not logged any more.
        c.notify(SVC, CHR, &[0x01]);
        std::thread::sleep(Duration::from_millis(50));
        let again = call(&h, "ble.log", json!({"since": seq})).unwrap();
        let later: Vec<&str> = again["entries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["kind"].as_str().unwrap())
            .collect();
        assert_eq!(later, ["unsubscribe"]);
        h.stop();
    }

    #[test]
    fn a_timed_subscription_ends_by_itself() {
        let c = central();
        let h = session(&c);
        let r = call(
            &h,
            "ble.subscribe",
            json!({"device_id": "id-a", "service": SVC, "characteristic": CHR, "seconds": 0.05}),
        )
        .unwrap();
        assert_eq!(r["expires_in_s"], 0.05);
        eventually("the subscription expired", || c.subscribed() == 0);
        assert_eq!(
            call(&h, "ble.session", json!({})).unwrap()["subscriptions"],
            json!([])
        );
        h.stop();
    }

    #[test]
    fn a_second_device_cannot_subscribe_while_the_first_is_live() {
        let c = central();
        let h = session(&c);
        call(&h, "ble.subscribe", gatt("id-a")).unwrap();
        let e = call(&h, "ble.subscribe", gatt("id-b")).unwrap_err();
        assert!(matches!(e, Error::Usage(_)), "{e:?}");
        h.stop();
    }

    #[test]
    fn a_write_keeps_request_acknowledgement_and_readback_apart_and_logs_them() {
        let c = central();
        let h = session(&c);
        let request = WriteRequest::new("id-a", SVC, CHR, "ff00", true).unwrap();
        let report = h.write(request).unwrap();
        assert_eq!(report.outcome, symcockpit_contract::Outcome::Confirmed);
        assert_eq!(c.stored_value(SVC, CHR), Some(vec![0xff, 0x00]));
        assert_eq!(c.open_links(), 1, "the write left the connection open");
        let log = call(&h, "ble.log", json!({})).unwrap();
        let kinds: Vec<&str> = log["entries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["kind"].as_str().unwrap())
            .collect();
        assert_eq!(
            kinds,
            [
                "connect",
                "write_requested",
                "write_acknowledged",
                "write_readback"
            ]
        );
        h.stop();
    }

    #[test]
    fn export_gives_csv_after_rfc_4180_and_json_with_raw_bytes() {
        let c = central();
        let h = session(&c);
        call(&h, "ble.read", gatt("id-a")).unwrap();
        let csv = call(&h, "ble.export", json!({"format": "csv"})).unwrap();
        assert_eq!(csv["count"], 2);
        let text = csv["content"].as_str().unwrap();
        assert!(
            text.starts_with(
                "t_ms,kind,device_id,service,characteristic,value_hex,length,detail\r\n"
            )
        );
        assert!(text.contains(",read,id-a,180F,2A19,01,1,"));
        let doc = call(&h, "ble.export", json!({"format": "json"})).unwrap();
        assert_eq!(doc["schema"], 1);
        assert_eq!(doc["entries"][1]["bytes"], json!([1]));
        assert!(call(&h, "ble.export", json!({"format": "xml"})).is_err());
        h.stop();
    }

    #[test]
    fn ending_the_session_closes_every_connection_and_subscription() {
        let c = central();
        let h = session(&c);
        call(&h, "ble.subscribe", gatt("id-a")).unwrap();
        assert_eq!((c.open_links(), c.subscribed()), (1, 1));
        h.stop();
        assert_eq!((c.open_links(), c.subscribed()), (0, 0));
    }

    #[test]
    fn failures_keep_their_class_and_a_missing_central_is_reported() {
        let c = central();
        c.refuse_connect(Some(Error::Permission(
            "Bluetooth access was not granted".into(),
        )));
        let h = session(&c);
        let e = call(&h, "ble.connect", json!({"device_id": "id-a"})).unwrap_err();
        assert!(matches!(e, Error::Permission(_)), "{e:?}");
        h.stop();
        let h = BleHandle::spawn(
            Arc::new(|| Err(Error::Unsupported("Bluetooth is off".into()))),
            Duration::from_millis(5),
        );
        let e = call(&h, "ble.scan", json!({})).unwrap_err();
        assert!(matches!(e, Error::Unsupported(_)), "{e:?}");
        h.stop();
    }
}
