//! XPC transport of the privileged helper: a Mach-service (or anonymous)
//! listener and a client, each moving one JSON string per message.
//!
//! The wire protocol itself (versioned, typed) lives in
//! `symcockpit-helper-proto`; this module only carries bytes. A message is an
//! XPC dictionary with the string key `request` (client to helper) or `reply`
//! (helper to client). Peer authentication is XPC's own: before a connection
//! is resumed, `xpc_connection_set_peer_code_signing_requirement` pins the
//! peer to a code-signing requirement, which the system then enforces on every
//! message from the peer's audit token (never a pid it claims).
//!
//! Handlers run on libdispatch threads, concurrently, and must not panic; a
//! panic is caught at the boundary and answered with an empty reply.

use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use block2::RcBlock;

type XpcObject = *mut c_void;
/// `XPC_CONNECTION_MACH_SERVICE_LISTENER`.
const LISTENER_FLAG: u64 = 1;

const KEY_REQUEST: &CStr = c"request";
const KEY_REPLY: &CStr = c"reply";

unsafe extern "C" {
    fn xpc_connection_create(name: *const c_char, queue: *mut c_void) -> XpcObject;
    fn xpc_connection_create_mach_service(
        name: *const c_char,
        queue: *mut c_void,
        flags: u64,
    ) -> XpcObject;
    fn xpc_connection_create_from_endpoint(endpoint: XpcObject) -> XpcObject;
    fn xpc_endpoint_create(connection: XpcObject) -> XpcObject;
    fn xpc_connection_set_event_handler(connection: XpcObject, handler: *mut c_void);
    fn xpc_connection_set_peer_code_signing_requirement(
        connection: XpcObject,
        requirement: *const c_char,
    ) -> c_int;
    fn xpc_connection_resume(connection: XpcObject);
    fn xpc_connection_cancel(connection: XpcObject);
    fn xpc_connection_send_message(connection: XpcObject, message: XpcObject);
    fn xpc_connection_send_message_with_reply(
        connection: XpcObject,
        message: XpcObject,
        queue: *mut c_void,
        handler: *mut c_void,
    );
    fn xpc_dictionary_create(
        keys: *const *const c_char,
        values: *const XpcObject,
        count: usize,
    ) -> XpcObject;
    fn xpc_dictionary_create_reply(original: XpcObject) -> XpcObject;
    fn xpc_dictionary_set_string(dict: XpcObject, key: *const c_char, value: *const c_char);
    fn xpc_dictionary_get_string(dict: XpcObject, key: *const c_char) -> *const c_char;
    fn xpc_get_type(object: XpcObject) -> *const c_void;
    fn xpc_retain(object: XpcObject) -> XpcObject;
    fn xpc_release(object: XpcObject);

    static _xpc_type_connection: [u8; 0];
    static _xpc_type_dictionary: [u8; 0];
}

fn is_type(object: XpcObject, kind: *const [u8; 0]) -> bool {
    // SAFETY: `xpc_get_type` accepts any XPC object; the type symbols are
    // process-lifetime statics exported by libxpc.
    !object.is_null() && unsafe { xpc_get_type(object) } == kind.cast()
}

fn is_connection(object: XpcObject) -> bool {
    is_type(object, &raw const _xpc_type_connection)
}

fn is_dictionary(object: XpcObject) -> bool {
    is_type(object, &raw const _xpc_type_dictionary)
}

/// The `request`/`reply` string of a message dictionary.
fn message_string(message: XpcObject, key: &CStr) -> Option<String> {
    if !is_dictionary(message) {
        return None;
    }
    // SAFETY: `message` is a dictionary and `key` a C string; the returned
    // pointer is owned by the dictionary and copied before it can go away.
    let ptr = unsafe { xpc_dictionary_get_string(message, key.as_ptr()) };
    // SAFETY: non-null NUL-terminated string (checked).
    (!ptr.is_null()).then(|| {
        unsafe { CStr::from_ptr(ptr) }
            .to_string_lossy()
            .into_owned()
    })
}

fn set_string(dict: XpcObject, key: &CStr, value: &str) {
    // A NUL inside a JSON text cannot occur (it is escaped); an empty reply is the safe fallback.
    let value = CString::new(value).unwrap_or_default();
    // SAFETY: `dict` is a dictionary we created; both strings are valid C strings
    // (XPC copies them).
    unsafe { xpc_dictionary_set_string(dict, key.as_ptr(), value.as_ptr()) };
}

fn new_message(key: &CStr, value: &str) -> XpcObject {
    // SAFETY: an empty dictionary (no keys, no values, count 0).
    let dict = unsafe { xpc_dictionary_create(std::ptr::null(), std::ptr::null(), 0) };
    set_string(dict, key, value);
    dict
}

/// Pin `connection` to `requirement`. Must happen before `resume`.
fn pin(connection: XpcObject, requirement: &str) -> Result<(), String> {
    let requirement =
        CString::new(requirement).map_err(|_| "requirement contains NUL".to_string())?;
    // SAFETY: a connection that is not yet resumed and a valid C string.
    let status = unsafe {
        xpc_connection_set_peer_code_signing_requirement(connection, requirement.as_ptr())
    };
    if status == 0 {
        Ok(())
    } else {
        Err(format!(
            "the peer code-signing requirement was refused (status {status})"
        ))
    }
}

fn set_handler(connection: XpcObject, handler: impl Fn(XpcObject) + 'static) {
    let block = RcBlock::new(move |event: *mut c_void| handler(event));
    // SAFETY: XPC copies the block, so ours may drop right after; the block has
    // the `void (^)(xpc_object_t)` shape `xpc_handler_t` expects.
    unsafe {
        xpc_connection_set_event_handler(connection, (&*block as *const _ as *mut c_void).cast())
    };
}

/// Called with the request text, returns the reply text.
pub type Handler = Arc<dyn Fn(&str) -> String + Send + Sync>;

/// Hooks for the helper's idle rule: a peer connected or went away.
#[derive(Clone, Default)]
pub struct Hooks {
    pub on_connect: Option<Arc<dyn Fn() + Send + Sync>>,
    pub on_disconnect: Option<Arc<dyn Fn() + Send + Sync>>,
}

/// An XPC listener. Dropping it cancels the listener.
pub struct Server {
    listener: XpcObject,
}

// SAFETY: XPC connection objects are thread-safe (documented by libxpc); this
// type only calls xpc_* functions on it.
unsafe impl Send for Server {}
// SAFETY: as above.
unsafe impl Sync for Server {}

impl Server {
    /// Listen on the launchd Mach service `name` (the helper). Every accepted
    /// peer must satisfy `peer_requirement`, or is refused before it is resumed.
    pub fn mach_service(
        name: &str,
        peer_requirement: &str,
        handler: Handler,
        hooks: Hooks,
    ) -> Result<Self, String> {
        let name = CString::new(name).map_err(|_| "service name contains NUL".to_string())?;
        // SAFETY: a valid C string; NULL queue selects the default.
        let listener = unsafe {
            xpc_connection_create_mach_service(name.as_ptr(), std::ptr::null_mut(), LISTENER_FLAG)
        };
        Self::start(listener, Some(peer_requirement.to_owned()), handler, hooks)
    }

    /// An in-process listener without a Mach name, reachable through
    /// [`Server::endpoint`]. For tests: it has no peer requirement.
    pub fn anonymous(handler: Handler, hooks: Hooks) -> Result<Self, String> {
        // SAFETY: NULL name and queue create an anonymous listener.
        let listener = unsafe { xpc_connection_create(std::ptr::null(), std::ptr::null_mut()) };
        Self::start(listener, None, handler, hooks)
    }

    fn start(
        listener: XpcObject,
        requirement: Option<String>,
        handler: Handler,
        hooks: Hooks,
    ) -> Result<Self, String> {
        if listener.is_null() {
            return Err("could not create the XPC listener".into());
        }
        set_handler(listener, move |event| {
            // Only new peer connections arrive here; errors (listener invalid) are ignored.
            if !is_connection(event) {
                return;
            }
            accept(event, requirement.as_deref(), &handler, &hooks);
        });
        // SAFETY: a configured, not yet resumed connection.
        unsafe { xpc_connection_resume(listener) };
        Ok(Self { listener })
    }

    /// A handle a [`Client`] in this process can connect to (anonymous listeners only).
    pub fn endpoint(&self) -> Endpoint {
        // SAFETY: `listener` is a live connection.
        Endpoint(unsafe { xpc_endpoint_create(self.listener) })
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        // SAFETY: cancel then release the reference this value owns, once.
        unsafe {
            xpc_connection_cancel(self.listener);
            xpc_release(self.listener);
        }
    }
}

/// An endpoint object of an anonymous listener.
pub struct Endpoint(XpcObject);

// SAFETY: XPC objects are thread-safe.
unsafe impl Send for Endpoint {}

impl Drop for Endpoint {
    fn drop(&mut self) {
        // SAFETY: releases the reference this value owns, once.
        unsafe { xpc_release(self.0) };
    }
}

fn accept(peer: XpcObject, requirement: Option<&str>, handler: &Handler, hooks: &Hooks) {
    // A peer that cannot be pinned is refused: fail closed, never serve unauthenticated.
    if let Some(requirement) = requirement
        && pin(peer, requirement).is_err()
    {
        // SAFETY: the peer connection delivered to the listener's handler.
        unsafe { xpc_connection_cancel(peer) };
        return;
    }
    // SAFETY: keep the peer alive for as long as its handler can run (released on invalidation).
    unsafe { xpc_retain(peer) };
    if let Some(connect) = &hooks.on_connect {
        connect();
    }
    let handler = handler.clone();
    let hooks = hooks.clone();
    let peer_ptr = PeerPtr(peer);
    set_handler(peer, move |event| {
        let peer = peer_ptr.0;
        if is_dictionary(event) {
            let reply = match message_string(event, KEY_REQUEST) {
                Some(request) => {
                    catch_unwind(AssertUnwindSafe(|| handler(&request))).unwrap_or_default()
                }
                None => String::new(),
            };
            // SAFETY: `event` is the dictionary this handler was called with.
            let message = unsafe { xpc_dictionary_create_reply(event) };
            if !message.is_null() {
                set_string(message, KEY_REPLY, &reply);
                // SAFETY: `peer` is retained above; the reply is ours to release after sending.
                unsafe {
                    xpc_connection_send_message(peer, message);
                    xpc_release(message);
                }
            }
        } else {
            // An error object: the connection went away (invalid) or was interrupted.
            if let Some(disconnect) = &hooks.on_disconnect {
                disconnect();
            }
            // SAFETY: balances the retain in `accept`; an invalid connection delivers
            // exactly one terminal error.
            unsafe { xpc_release(peer) };
        }
    });
    // SAFETY: configured and pinned, not yet resumed.
    unsafe { xpc_connection_resume(peer) };
}

struct PeerPtr(XpcObject);
// SAFETY: XPC connections are thread-safe.
unsafe impl Send for PeerPtr {}
// SAFETY: as above.
unsafe impl Sync for PeerPtr {}

/// A client connection. Dropping it cancels the connection (the helper sees it
/// go away, which ends a governor that connection owned).
pub struct Client {
    connection: XpcObject,
}

// SAFETY: XPC connections are thread-safe.
unsafe impl Send for Client {}
// SAFETY: as above.
unsafe impl Sync for Client {}

impl Client {
    /// Connect to the helper's Mach service, requiring the helper to satisfy
    /// `peer_requirement` (the system enforces it on every reply).
    pub fn mach_service(name: &str, peer_requirement: &str) -> Result<Self, String> {
        let name = CString::new(name).map_err(|_| "service name contains NUL".to_string())?;
        // SAFETY: a valid C string; NULL queue selects the default; flags 0 = client.
        let connection =
            unsafe { xpc_connection_create_mach_service(name.as_ptr(), std::ptr::null_mut(), 0) };
        Self::start(connection, Some(peer_requirement))
    }

    /// Connect to an in-process anonymous listener.
    pub fn endpoint(endpoint: &Endpoint) -> Result<Self, String> {
        // SAFETY: a live endpoint object.
        let connection = unsafe { xpc_connection_create_from_endpoint(endpoint.0) };
        Self::start(connection, None)
    }

    fn start(connection: XpcObject, requirement: Option<&str>) -> Result<Self, String> {
        if connection.is_null() {
            return Err("could not create the XPC connection".into());
        }
        if let Some(requirement) = requirement {
            pin(connection, requirement)?;
        }
        // Errors surface through the reply of the next request; nothing to do here.
        set_handler(connection, |_| {});
        // SAFETY: configured, not yet resumed.
        unsafe { xpc_connection_resume(connection) };
        Ok(Self { connection })
    }

    /// Send one request text and wait for the reply text.
    pub fn request(&self, request: &str, timeout: Duration) -> Result<String, String> {
        let message = new_message(KEY_REQUEST, request);
        let (tx, rx) = mpsc::channel::<Result<String, String>>();
        let tx = Mutex::new(Some(tx));
        let block = RcBlock::new(move |reply: *mut c_void| {
            let result = match message_string(reply, KEY_REPLY) {
                Some(text) => Ok(text),
                None if is_dictionary(reply) => Err("the helper sent no reply".to_string()),
                None => Err("the connection to the helper is invalid or was refused".to_string()),
            };
            if let Some(tx) = tx.lock().ok().and_then(|mut t| t.take()) {
                let _ = tx.send(result);
            }
        });
        // SAFETY: a live connection and message; XPC copies the block and retains
        // the message while the call is in flight.
        unsafe {
            xpc_connection_send_message_with_reply(
                self.connection,
                message,
                std::ptr::null_mut(),
                (&*block as *const _ as *mut c_void).cast(),
            );
            xpc_release(message);
        }
        rx.recv_timeout(timeout)
            .map_err(|_| format!("no reply from the helper within {} ms", timeout.as_millis()))?
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        // SAFETY: cancel then release the reference this value owns, once.
        unsafe {
            xpc_connection_cancel(self.connection);
            xpc_release(self.connection);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    const WAIT: Duration = Duration::from_secs(5);

    fn echo() -> Handler {
        Arc::new(|request| format!("echo:{request}"))
    }

    /// A real XPC round trip in this process, without root, without launchd,
    /// without a Mach name: an anonymous listener and a client built from its endpoint.
    #[test]
    fn a_request_makes_the_round_trip_through_xpc() {
        let server = Server::anonymous(echo(), Hooks::default()).unwrap();
        let client = Client::endpoint(&server.endpoint()).unwrap();
        assert_eq!(
            client.request("{\"version\":1}", WAIT).unwrap(),
            "echo:{\"version\":1}"
        );
        // Several requests on one connection, in order.
        for i in 0..5 {
            assert_eq!(
                client.request(&format!("r{i}"), WAIT).unwrap(),
                format!("echo:r{i}")
            );
        }
        // Non-ASCII survives.
        assert_eq!(client.request("é ✓", WAIT).unwrap(), "echo:é ✓");
    }

    #[test]
    fn concurrent_clients_are_served_independently() {
        let server = Server::anonymous(echo(), Hooks::default()).unwrap();
        let endpoint = server.endpoint();
        let clients: Vec<Client> = (0..3)
            .map(|_| Client::endpoint(&endpoint).unwrap())
            .collect();
        std::thread::scope(|scope| {
            for (i, client) in clients.iter().enumerate() {
                scope.spawn(move || {
                    for n in 0..10 {
                        let text = format!("c{i}-{n}");
                        assert_eq!(client.request(&text, WAIT).unwrap(), format!("echo:{text}"));
                    }
                });
            }
        });
    }

    #[test]
    fn connect_and_disconnect_hooks_fire() {
        let connected = Arc::new(AtomicUsize::new(0));
        let gone = Arc::new(AtomicUsize::new(0));
        let hooks = Hooks {
            on_connect: Some({
                let c = connected.clone();
                Arc::new(move || {
                    c.fetch_add(1, Ordering::SeqCst);
                })
            }),
            on_disconnect: Some({
                let g = gone.clone();
                Arc::new(move || {
                    g.fetch_add(1, Ordering::SeqCst);
                })
            }),
        };
        let server = Server::anonymous(echo(), hooks).unwrap();
        let client = Client::endpoint(&server.endpoint()).unwrap();
        client.request("x", WAIT).unwrap();
        assert_eq!(connected.load(Ordering::SeqCst), 1);
        assert_eq!(gone.load(Ordering::SeqCst), 0);
        drop(client);
        let deadline = std::time::Instant::now() + WAIT;
        while gone.load(Ordering::SeqCst) == 0 && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(
            gone.load(Ordering::SeqCst),
            1,
            "the owner going away is seen"
        );
    }

    #[test]
    fn a_slow_handler_times_out_and_a_panicking_one_does_not_abort() {
        let slow: Handler = Arc::new(|_| {
            std::thread::sleep(Duration::from_millis(400));
            "late".into()
        });
        let server = Server::anonymous(slow, Hooks::default()).unwrap();
        let client = Client::endpoint(&server.endpoint()).unwrap();
        let err = client.request("x", Duration::from_millis(50)).unwrap_err();
        assert!(err.contains("no reply"), "{err}");

        let boom: Handler = Arc::new(|_| panic!("handler bug"));
        let server = Server::anonymous(boom, Hooks::default()).unwrap();
        let client = Client::endpoint(&server.endpoint()).unwrap();
        assert_eq!(
            client.request("x", WAIT).unwrap(),
            "",
            "an empty reply, not an abort"
        );
    }

    #[test]
    fn a_connection_to_a_missing_mach_service_fails_fast_not_forever() {
        // No such service is registered: the connection becomes invalid and the
        // request answers with an error (no root, no launchd involvement).
        let client = Client::mach_service(
            "com.symaira.symcockpit-test-no-such-service",
            "anchor apple",
        )
        .unwrap();
        assert!(client.request("x", WAIT).is_err());
    }
}
