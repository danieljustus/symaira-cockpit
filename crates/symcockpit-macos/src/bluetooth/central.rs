//! CoreBluetooth central (R51 to R53), built for a long-lived process.
//!
//! CoreBluetooth reports through a delegate. Instead of the main run loop this
//! adapter gives the manager a private serial dispatch queue; the delegate turns
//! every callback into a plain `Event` on an mpsc channel and the blocking
//! `BleCentral`/`BleLink` methods wait on that channel with a timeout. No thread
//! has to spin a run loop, so the same code serves the CLI (foreground command,
//! limited by the timeout argument) and the app agent.
//!
//! The objects are not `Send`: create and use the central on one thread. The
//! agent keeps it on a worker thread and talks to it by channel.
//!
//! Not exercised live (scan and connect raise the Bluetooth permission dialog);
//! the delegate wiring is covered by compile-time protocol checks and the
//! pure logic by fakes in `symcockpit-testkit`.

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::rc::Rc;
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use dispatch2::{DispatchQueue, DispatchRetained};
use objc2::rc::Retained;
use objc2::runtime::{AnyObject, ProtocolObject};
use objc2::{AllocAnyThread, DefinedClass, Message, define_class, msg_send};
use objc2_core_bluetooth::{
    CBAdvertisementDataIsConnectable, CBAdvertisementDataLocalNameKey,
    CBAdvertisementDataServiceUUIDsKey, CBCentralManager, CBCentralManagerDelegate,
    CBCharacteristic, CBCharacteristicProperties, CBCharacteristicWriteType, CBManager,
    CBManagerAuthorization, CBManagerState, CBPeripheral, CBPeripheralDelegate, CBService, CBUUID,
};
use objc2_foundation::{
    NSArray, NSData, NSDictionary, NSError, NSNumber, NSObject, NSObjectProtocol, NSString, NSUUID,
};
use symcockpit_contract::Error;
use symcockpit_core::bluetooth::{
    Advertisement, BleAuthorization, BleCentral, BleLink, Characteristic, Notification, Service,
    WriteAck,
};

const STATE_TIMEOUT: Duration = Duration::from_secs(5);
const OP_TIMEOUT: Duration = Duration::from_secs(10);

/// What the delegate saw, reduced to plain data.
enum Event {
    State(CBManagerState),
    Discovered(Advertisement),
    Connected(String),
    ConnectFailed(String, String),
    Disconnected(String),
    Services(String, Option<String>),
    Characteristics(String, Option<String>),
    Value {
        service: String,
        characteristic: String,
        result: Result<Vec<u8>, String>,
    },
    Wrote {
        service: String,
        characteristic: String,
        error: Option<String>,
    },
    NotifyState {
        service: String,
        characteristic: String,
        error: Option<String>,
    },
}

struct Shared {
    tx: Mutex<Sender<Event>>,
    /// Peripherals seen during scans; connecting needs the object, not the id.
    peripherals: Mutex<HashMap<String, Retained<CBPeripheral>>>,
}

// SAFETY: `Shared` is touched from the delegate queue and from the calling
// thread, always under its mutexes. The retained peripherals are only cloned or
// passed back to CoreBluetooth, whose objects use atomic reference counting and
// are documented as usable from any thread.
unsafe impl Send for Shared {}
unsafe impl Sync for Shared {}

impl Shared {
    fn send(&self, event: Event) {
        if let Ok(tx) = self.tx.lock() {
            let _ = tx.send(event); // the receiver is gone only during teardown
        }
    }
}

fn error_text(error: Option<&NSError>) -> Option<String> {
    error.map(|e| e.localizedDescription().to_string())
}

fn uuid_text(uuid: &CBUUID) -> String {
    // SAFETY: plain getter on a live CBUUID.
    unsafe { uuid.UUIDString() }
        .to_string()
        .to_ascii_uppercase()
}

fn peripheral_id(p: &CBPeripheral) -> String {
    // SAFETY: `identifier` is a plain getter on a live CBPeer.
    unsafe { p.identifier() }.UUIDString().to_string()
}

fn characteristic_ids(c: &CBCharacteristic) -> (String, String) {
    // SAFETY: plain getters on live objects; the service back-pointer may be nil.
    unsafe {
        let service = c
            .service()
            .map(|s| uuid_text(&s.UUID()))
            .unwrap_or_default();
        (service, uuid_text(&c.UUID()))
    }
}

define_class!(
    #[unsafe(super(NSObject))]
    #[name = "SymCockpitBleBridge"]
    #[ivars = Arc<Shared>]
    struct Bridge;

    unsafe impl NSObjectProtocol for Bridge {}

    unsafe impl CBCentralManagerDelegate for Bridge {
        #[unsafe(method(centralManagerDidUpdateState:))]
        fn did_update_state(&self, central: &CBCentralManager) {
            // SAFETY: plain getter, called on the manager's own queue.
            let state = unsafe { central.state() };
            self.ivars().send(Event::State(state));
        }

        #[unsafe(method(centralManager:didDiscoverPeripheral:advertisementData:RSSI:))]
        fn did_discover(
            &self,
            _central: &CBCentralManager,
            peripheral: &CBPeripheral,
            data: &NSDictionary<NSString, AnyObject>,
            rssi: &NSNumber,
        ) {
            let id = peripheral_id(peripheral);
            if let Ok(mut map) = self.ivars().peripherals.lock() {
                map.insert(id.clone(), peripheral.retain());
            }
            self.ivars().send(Event::Discovered(advertisement(id, peripheral, data, rssi)));
        }

        #[unsafe(method(centralManager:didConnectPeripheral:))]
        fn did_connect(&self, _c: &CBCentralManager, peripheral: &CBPeripheral) {
            self.ivars().send(Event::Connected(peripheral_id(peripheral)));
        }

        #[unsafe(method(centralManager:didFailToConnectPeripheral:error:))]
        fn did_fail_to_connect(
            &self,
            _c: &CBCentralManager,
            peripheral: &CBPeripheral,
            error: Option<&NSError>,
        ) {
            let why = error_text(error).unwrap_or_else(|| "unknown error".into());
            self.ivars().send(Event::ConnectFailed(peripheral_id(peripheral), why));
        }

        #[unsafe(method(centralManager:didDisconnectPeripheral:error:))]
        fn did_disconnect(
            &self,
            _c: &CBCentralManager,
            peripheral: &CBPeripheral,
            _error: Option<&NSError>,
        ) {
            self.ivars().send(Event::Disconnected(peripheral_id(peripheral)));
        }
    }

    unsafe impl CBPeripheralDelegate for Bridge {
        #[unsafe(method(peripheral:didDiscoverServices:))]
        fn did_discover_services(&self, peripheral: &CBPeripheral, error: Option<&NSError>) {
            self.ivars().send(Event::Services(peripheral_id(peripheral), error_text(error)));
        }

        #[unsafe(method(peripheral:didDiscoverCharacteristicsForService:error:))]
        fn did_discover_characteristics(
            &self,
            peripheral: &CBPeripheral,
            _service: &CBService,
            error: Option<&NSError>,
        ) {
            self.ivars().send(Event::Characteristics(peripheral_id(peripheral), error_text(error)));
        }

        #[unsafe(method(peripheral:didUpdateValueForCharacteristic:error:))]
        fn did_update_value(
            &self,
            _peripheral: &CBPeripheral,
            characteristic: &CBCharacteristic,
            error: Option<&NSError>,
        ) {
            let (service, characteristic_id) = characteristic_ids(characteristic);
            let result = match error_text(error) {
                Some(e) => Err(e),
                // SAFETY: plain getter; `NSData::to_vec` copies the bytes.
                None => Ok(unsafe { characteristic.value() }.map(|d| d.to_vec()).unwrap_or_default()),
            };
            self.ivars().send(Event::Value { service, characteristic: characteristic_id, result });
        }

        #[unsafe(method(peripheral:didWriteValueForCharacteristic:error:))]
        fn did_write_value(
            &self,
            _peripheral: &CBPeripheral,
            characteristic: &CBCharacteristic,
            error: Option<&NSError>,
        ) {
            let (service, characteristic) = characteristic_ids(characteristic);
            self.ivars().send(Event::Wrote { service, characteristic, error: error_text(error) });
        }

        #[unsafe(method(peripheral:didUpdateNotificationStateForCharacteristic:error:))]
        fn did_update_notification_state(
            &self,
            _peripheral: &CBPeripheral,
            characteristic: &CBCharacteristic,
            error: Option<&NSError>,
        ) {
            let (service, characteristic) = characteristic_ids(characteristic);
            self.ivars().send(Event::NotifyState { service, characteristic, error: error_text(error) });
        }
    }
);

impl Bridge {
    fn new(shared: Arc<Shared>) -> Retained<Self> {
        let this = Self::alloc().set_ivars(shared);
        // SAFETY: `init` on an allocated NSObject subclass with initialized ivars.
        unsafe { msg_send![super(this), init] }
    }
}

fn advertisement(
    id: String,
    peripheral: &CBPeripheral,
    data: &NSDictionary<NSString, AnyObject>,
    rssi: &NSNumber,
) -> Advertisement {
    // SAFETY: the advertisement keys are framework constants; the values are
    // downcast before use, so a surprising type yields `None`, not UB.
    unsafe {
        let name = data
            .objectForKey(CBAdvertisementDataLocalNameKey)
            .and_then(|o| o.downcast::<NSString>().ok())
            .map(|s| s.to_string())
            .or_else(|| peripheral.name().map(|n| n.to_string()));
        let service_uuids = data
            .objectForKey(CBAdvertisementDataServiceUUIDsKey)
            .and_then(|o| o.downcast::<NSArray>().ok())
            .map(|a| {
                a.iter()
                    .filter_map(|u| u.downcast::<CBUUID>().ok())
                    .map(|u| uuid_text(&u))
                    .collect()
            })
            .unwrap_or_default();
        let connectable = data
            .objectForKey(CBAdvertisementDataIsConnectable)
            .and_then(|o| o.downcast::<NSNumber>().ok())
            .map(|n| n.as_bool());
        // 127 is CoreBluetooth's "RSSI not available".
        let rssi = i16::try_from(rssi.as_i64()).ok().filter(|r| *r != 127);
        Advertisement {
            id,
            name,
            rssi,
            service_uuids,
            connectable,
        }
    }
}

/// The local radio as BLE central. See the module docs for threading.
pub struct CoreBluetoothCentral {
    central: Retained<CBCentralManager>,
    bridge: Retained<Bridge>,
    shared: Arc<Shared>,
    rx: Rc<Receiver<Event>>,
    _queue: DispatchRetained<DispatchQueue>,
}

impl CoreBluetoothCentral {
    /// Creates the manager and waits until the radio state is known. This is
    /// the call that raises the Bluetooth permission dialog on first use.
    pub fn new() -> Result<Self, Error> {
        if matches!(
            authorization(),
            Some(BleAuthorization::Denied | BleAuthorization::Restricted)
        ) {
            return Err(Error::Permission(
                "Bluetooth access is denied for this process (System Settings > Privacy & Security > Bluetooth)"
                    .into(),
            ));
        }
        let (tx, rx) = channel();
        let shared = Arc::new(Shared {
            tx: Mutex::new(tx),
            peripherals: Mutex::default(),
        });
        let bridge = Bridge::new(shared.clone());
        let queue = DispatchQueue::new("com.symaira.symcockpit.ble", None);
        // SAFETY: the delegate and queue outlive the manager (all three are
        // fields of `Self`); callbacks only touch `Shared`, which is thread-safe.
        let central = unsafe {
            CBCentralManager::initWithDelegate_queue(
                CBCentralManager::alloc(),
                Some(ProtocolObject::from_ref(&*bridge)),
                Some(&queue),
            )
        };
        let this = CoreBluetoothCentral {
            central,
            bridge,
            shared,
            rx: Rc::new(rx),
            _queue: queue,
        };
        this.wait_for_power()?;
        Ok(this)
    }

    fn wait_for_power(&self) -> Result<(), Error> {
        let deadline = Instant::now() + STATE_TIMEOUT;
        loop {
            match recv_until(&self.rx, deadline)? {
                Some(Event::State(s)) => match s {
                    CBManagerState::PoweredOn => return Ok(()),
                    CBManagerState::Unauthorized => {
                        return Err(Error::Permission("Bluetooth access was not granted".into()));
                    }
                    CBManagerState::PoweredOff => {
                        return Err(Error::Unsupported("Bluetooth is turned off".into()));
                    }
                    CBManagerState::Unsupported => {
                        return Err(Error::Unsupported("this Mac has no BLE radio".into()));
                    }
                    _ => {} // unknown or resetting: wait for the next update
                },
                Some(_) => {}
                None => return Err(Error::Failed("Bluetooth state did not settle".into())),
            }
        }
    }

    fn find(&self, id: &str) -> Result<Retained<CBPeripheral>, Error> {
        if let Some(p) = self
            .shared
            .peripherals
            .lock()
            .ok()
            .and_then(|m| m.get(id).cloned())
        {
            return Ok(p);
        }
        let uuid = NSUUID::from_string(&NSString::from_str(id))
            .ok_or_else(|| Error::Usage(format!("not a peripheral id: {id:?}")))?;
        // SAFETY: documented lookup of peripherals known to the system by UUID.
        let known = unsafe {
            self.central
                .retrievePeripheralsWithIdentifiers(&NSArray::from_retained_slice(&[uuid]))
        };
        known
            .firstObject()
            .ok_or_else(|| Error::Failed("unknown device: scan first, or check the id".into()))
    }
}

pub(super) fn authorization() -> Option<BleAuthorization> {
    // SAFETY: class getter. No manager is instantiated, so this cannot request permission.
    match unsafe { CBManager::authorization_class() } {
        CBManagerAuthorization::NotDetermined => Some(BleAuthorization::NotDetermined),
        CBManagerAuthorization::Restricted => Some(BleAuthorization::Restricted),
        CBManagerAuthorization::Denied => Some(BleAuthorization::Denied),
        CBManagerAuthorization::AllowedAlways => Some(BleAuthorization::Allowed),
        _ => None,
    }
}

/// Next event before `deadline`; `None` when the deadline passed.
fn recv_until(rx: &Receiver<Event>, deadline: Instant) -> Result<Option<Event>, Error> {
    let left = deadline.saturating_duration_since(Instant::now());
    match rx.recv_timeout(left) {
        Ok(e) => Ok(Some(e)),
        Err(RecvTimeoutError::Timeout) => Ok(None),
        Err(RecvTimeoutError::Disconnected) => Err(Error::Failed("Bluetooth bridge closed".into())),
    }
}

impl BleCentral for CoreBluetoothCentral {
    fn scan(&self, timeout: Duration) -> Result<Vec<Advertisement>, Error> {
        while self.rx.try_recv().is_ok() {} // drop stale events
        // SAFETY: plain scan request; no service filter, no options.
        unsafe {
            self.central
                .scanForPeripheralsWithServices_options(None, None)
        };
        let deadline = Instant::now() + timeout;
        let mut seen = BTreeMap::new();
        while let Some(event) = recv_until(&self.rx, deadline)? {
            if let Event::Discovered(ad) = event {
                seen.insert(ad.id.clone(), ad);
            }
        }
        // SAFETY: stops the scan started above.
        unsafe { self.central.stopScan() };
        let mut all: Vec<_> = seen.into_values().collect();
        all.sort_by_key(|a| std::cmp::Reverse(a.rssi));
        Ok(all)
    }

    fn connect(&self, id: &str, timeout: Duration) -> Result<Box<dyn BleLink>, Error> {
        let peripheral = self.find(id)?;
        // SAFETY: the bridge outlives the peripheral connection (both owned by the link).
        unsafe {
            peripheral.setDelegate(Some(ProtocolObject::from_ref(&*self.bridge)));
            self.central.connectPeripheral_options(&peripheral, None);
        }
        let deadline = Instant::now() + timeout;
        loop {
            match recv_until(&self.rx, deadline)? {
                Some(Event::Connected(got)) if got == id => break,
                Some(Event::ConnectFailed(got, why)) if got == id => {
                    return Err(Error::Failed(format!("connection failed: {why}")));
                }
                Some(_) => {}
                None => {
                    // SAFETY: gives up the pending connection.
                    unsafe { self.central.cancelPeripheralConnection(&peripheral) };
                    return Err(Error::Failed("connection timed out".into()));
                }
            }
        }
        Ok(Box::new(Link {
            central: self.central.clone(),
            peripheral,
            _bridge: self.bridge.clone(),
            rx: self.rx.clone(),
            id: id.to_owned(),
            started: RefCell::default(),
        }))
    }
}

struct Link {
    central: Retained<CBCentralManager>,
    peripheral: Retained<CBPeripheral>,
    _bridge: Retained<Bridge>,
    rx: Rc<Receiver<Event>>,
    id: String,
    /// When each persistent subscription (`begin_subscription`) started.
    started: RefCell<HashMap<(String, String), Instant>>,
}

fn property_names(p: CBCharacteristicProperties) -> Vec<String> {
    [
        (CBCharacteristicProperties::Read, "read"),
        (CBCharacteristicProperties::Write, "write"),
        (
            CBCharacteristicProperties::WriteWithoutResponse,
            "write_without_response",
        ),
        (CBCharacteristicProperties::Notify, "notify"),
        (CBCharacteristicProperties::Indicate, "indicate"),
        (CBCharacteristicProperties::Broadcast, "broadcast"),
        (
            CBCharacteristicProperties::AuthenticatedSignedWrites,
            "signed_write",
        ),
    ]
    .into_iter()
    .filter(|(flag, _)| p.contains(*flag))
    .map(|(_, name)| name.to_owned())
    .collect()
}

impl Link {
    fn services_list(&self) -> Vec<Retained<CBService>> {
        // SAFETY: plain getter on a connected peripheral.
        unsafe { self.peripheral.services() }
            .map(|a| a.to_vec())
            .unwrap_or_default()
    }

    /// Discovers services, then the characteristics of each.
    fn discover(&self) -> Result<(), Error> {
        let deadline = Instant::now() + OP_TIMEOUT;
        // SAFETY: documented discovery request; `None` means all services.
        unsafe { self.peripheral.discoverServices(None) };
        loop {
            match recv_until(&self.rx, deadline)? {
                Some(Event::Services(id, err)) if id == self.id => {
                    if let Some(e) = err {
                        return Err(Error::Failed(format!("service discovery failed: {e}")));
                    }
                    break;
                }
                Some(_) => {}
                None => return Err(Error::Failed("service discovery timed out".into())),
            }
        }
        let services = self.services_list();
        for service in &services {
            // SAFETY: documented discovery request for a service of this peripheral.
            unsafe {
                self.peripheral
                    .discoverCharacteristics_forService(None, service)
            };
        }
        let mut pending = services.len();
        while pending > 0 {
            match recv_until(&self.rx, deadline)? {
                Some(Event::Characteristics(id, err)) if id == self.id => {
                    if let Some(e) = err {
                        return Err(Error::Failed(format!(
                            "characteristic discovery failed: {e}"
                        )));
                    }
                    pending -= 1;
                }
                Some(_) => {}
                None => return Err(Error::Failed("characteristic discovery timed out".into())),
            }
        }
        Ok(())
    }

    fn characteristic(
        &self,
        service: &str,
        uuid: &str,
    ) -> Result<Retained<CBCharacteristic>, Error> {
        if self.services_list().is_empty() {
            self.discover()?;
        }
        for s in self.services_list() {
            // SAFETY: plain getters on discovered objects.
            if unsafe { uuid_text(&s.UUID()) } != service {
                continue;
            }
            for c in unsafe { s.characteristics() }
                .map(|a| a.to_vec())
                .unwrap_or_default()
            {
                if unsafe { uuid_text(&c.UUID()) } == uuid {
                    return Ok(c);
                }
            }
        }
        Err(Error::Failed(format!(
            "no characteristic {uuid} in service {service} on this device"
        )))
    }

    /// Checks that the characteristic notifies, turns notifications on and waits for the
    /// confirmation. Shared by the timed and the persistent subscription.
    fn enable_notifications(
        &self,
        service: &str,
        characteristic: &str,
    ) -> Result<Retained<CBCharacteristic>, Error> {
        let c = self.characteristic(service, characteristic)?;
        // SAFETY: plain getter.
        let props = unsafe { c.properties() };
        if !props
            .intersects(CBCharacteristicProperties::Notify | CBCharacteristicProperties::Indicate)
        {
            return Err(Error::Unsupported("characteristic does not notify".into()));
        }
        // SAFETY: documented subscription request.
        unsafe { self.peripheral.setNotifyValue_forCharacteristic(true, &c) };
        self.wait("subscribe", |e| match e {
            Event::NotifyState {
                service: s,
                characteristic: ch,
                error,
            } if s == service && ch == characteristic => Some(match error {
                Some(e) => Err(Error::Failed(format!("subscribe failed: {e}"))),
                None => Ok(()),
            }),
            _ => None,
        })?;
        Ok(c)
    }

    fn wait<T>(
        &self,
        what: &str,
        mut pick: impl FnMut(Event) -> Option<Result<T, Error>>,
    ) -> Result<T, Error> {
        let deadline = Instant::now() + OP_TIMEOUT;
        loop {
            match recv_until(&self.rx, deadline)? {
                Some(event) => {
                    if let Some(done) = pick(event) {
                        return done;
                    }
                }
                None => return Err(Error::Failed(format!("{what} timed out"))),
            }
        }
    }
}

impl BleLink for Link {
    fn services(&self) -> Result<Vec<Service>, Error> {
        self.discover()?;
        let mut out = Vec::new();
        for s in self.services_list() {
            // SAFETY: plain getters on discovered objects.
            let characteristics = unsafe { s.characteristics() }
                .map(|a| a.to_vec())
                .unwrap_or_default()
                .into_iter()
                .map(|c| Characteristic {
                    uuid: unsafe { uuid_text(&c.UUID()) },
                    properties: property_names(unsafe { c.properties() }),
                })
                .collect();
            out.push(Service {
                uuid: unsafe { uuid_text(&s.UUID()) },
                characteristics,
            });
        }
        Ok(out)
    }

    fn read(&self, service: &str, characteristic: &str) -> Result<Vec<u8>, Error> {
        let c = self.characteristic(service, characteristic)?;
        // SAFETY: documented read request for a discovered characteristic.
        unsafe { self.peripheral.readValueForCharacteristic(&c) };
        self.wait("read", |e| match e {
            Event::Value {
                service: s,
                characteristic: ch,
                result,
            } if s == service && ch == characteristic => {
                Some(result.map_err(|e| Error::Failed(format!("read failed: {e}"))))
            }
            _ => None,
        })
    }

    fn write(
        &self,
        service: &str,
        characteristic: &str,
        value: &[u8],
        with_response: bool,
    ) -> Result<WriteAck, Error> {
        let c = self.characteristic(service, characteristic)?;
        // SAFETY: plain getter.
        let props = unsafe { c.properties() };
        let needed = if with_response {
            CBCharacteristicProperties::Write
        } else {
            CBCharacteristicProperties::WriteWithoutResponse
        };
        if !props.contains(needed) {
            return Err(Error::Unsupported(format!(
                "characteristic does not support {}",
                if with_response {
                    "write with response"
                } else {
                    "write without response"
                }
            )));
        }
        let data = NSData::with_bytes(value);
        let kind = if with_response {
            CBCharacteristicWriteType::WithResponse
        } else {
            CBCharacteristicWriteType::WithoutResponse
        };
        // SAFETY: documented write request; `data` is copied by CoreBluetooth.
        unsafe {
            self.peripheral
                .writeValue_forCharacteristic_type(&data, &c, kind)
        };
        if !with_response {
            return Ok(WriteAck::NotRequested);
        }
        self.wait("write", |e| match e {
            Event::Wrote {
                service: s,
                characteristic: ch,
                error,
            } if s == service && ch == characteristic => Some(match error {
                Some(e) => Err(Error::Failed(format!("write rejected: {e}"))),
                None => Ok(WriteAck::Acknowledged),
            }),
            _ => None,
        })
    }

    fn subscribe(
        &self,
        service: &str,
        characteristic: &str,
        window: Duration,
        on_value: &mut dyn FnMut(Notification),
    ) -> Result<(), Error> {
        let c = self.enable_notifications(service, characteristic)?;
        let started = Instant::now();
        let deadline = started + window;
        while let Some(event) = recv_until(&self.rx, deadline)? {
            if let Event::Value {
                service: s,
                characteristic: ch,
                result: Ok(value),
            } = event
                && s == service
                && ch == characteristic
            {
                on_value(Notification {
                    elapsed_ms: started.elapsed().as_millis() as u64,
                    value,
                });
            }
        }
        // SAFETY: ends the subscription started above.
        unsafe { self.peripheral.setNotifyValue_forCharacteristic(false, &c) };
        Ok(())
    }

    fn begin_subscription(&self, service: &str, characteristic: &str) -> Result<(), Error> {
        self.enable_notifications(service, characteristic)?;
        self.started.borrow_mut().insert(
            (service.to_owned(), characteristic.to_owned()),
            Instant::now(),
        );
        Ok(())
    }

    fn poll_subscriptions(
        &self,
        wait: Duration,
        on_value: &mut dyn FnMut(&str, &str, Notification),
    ) -> Result<(), Error> {
        let deadline = Instant::now() + wait;
        while let Some(event) = recv_until(&self.rx, deadline)? {
            if let Event::Value {
                service,
                characteristic,
                result: Ok(value),
            } = event
                && let Some(started) = self
                    .started
                    .borrow()
                    .get(&(service.clone(), characteristic.clone()))
            {
                on_value(
                    &service,
                    &characteristic,
                    Notification {
                        elapsed_ms: started.elapsed().as_millis() as u64,
                        value,
                    },
                );
            }
        }
        Ok(())
    }

    fn end_subscription(&self, service: &str, characteristic: &str) {
        let key = (service.to_owned(), characteristic.to_owned());
        if self.started.borrow_mut().remove(&key).is_none() {
            return;
        }
        if let Ok(c) = self.characteristic(service, characteristic) {
            // SAFETY: ends the subscription started in `begin_subscription`.
            unsafe { self.peripheral.setNotifyValue_forCharacteristic(false, &c) };
        }
    }

    fn disconnect(&self) {
        // SAFETY: documented request to drop the connection.
        unsafe { self.central.cancelPeripheralConnection(&self.peripheral) };
        // Wait briefly so an immediate reconnect does not race the teardown.
        let deadline = Instant::now() + Duration::from_secs(2);
        while let Ok(Some(event)) = recv_until(&self.rx, deadline) {
            if matches!(event, Event::Disconnected(ref id) if *id == self.id) {
                break;
            }
        }
    }
}
