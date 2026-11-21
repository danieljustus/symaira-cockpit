//! A thread that owns something no other thread may touch (a SQLite connection, a
//! CoreBluetooth central whose objects are not `Send`) and serves requests over a channel
//! (architecture §10: threads for samplers, one writer per SQLite file, no async runtime).
//!
//! The owner is built *on* the thread by a `Send` factory, so only the factory has to cross.
//! Between requests the thread sleeps until the owner's next wake-up, or until a request when
//! the owner has nothing to do: an idle service costs no wake-ups (Q04).

use std::sync::Mutex;
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::thread::JoinHandle;
use std::time::Duration;

use symcockpit_contract::Error;

pub trait Service: 'static {
    type Req: Send + 'static;
    type Resp: Send + 'static;

    fn handle(&mut self, req: Self::Req) -> Self::Resp;

    /// How long the thread may sleep before `tick`; `None`: until the next request.
    fn wake_in(&self) -> Option<Duration> {
        None
    }

    fn tick(&mut self) {}

    /// Runs once on the thread, after the last request, before it ends.
    fn shutdown(&mut self) {}
}

enum Msg<S: Service> {
    Request(S::Req, Sender<S::Resp>),
    Stop,
}

pub struct Actor<S: Service> {
    tx: Sender<Msg<S>>,
    join: Mutex<Option<JoinHandle<()>>>,
}

impl<S: Service> Actor<S> {
    pub fn spawn(name: &str, make: impl FnOnce() -> S + Send + 'static) -> Self {
        let (tx, rx) = mpsc::channel::<Msg<S>>();
        let join = std::thread::Builder::new()
            .name(name.to_owned())
            .spawn(move || {
                let mut service = make();
                loop {
                    let msg = match service.wake_in() {
                        None => rx.recv().map_err(|_| RecvTimeoutError::Disconnected),
                        Some(wait) => rx.recv_timeout(wait),
                    };
                    match msg {
                        Ok(Msg::Request(req, reply)) => {
                            // The caller may have given up waiting; that is not our problem.
                            let _ = reply.send(service.handle(req));
                        }
                        Err(RecvTimeoutError::Timeout) => service.tick(),
                        Ok(Msg::Stop) | Err(RecvTimeoutError::Disconnected) => break,
                    }
                }
                service.shutdown();
            })
            .expect("the operating system can start a thread");
        Self {
            tx,
            join: Mutex::new(Some(join)),
        }
    }

    /// Sends `req` and waits for the answer. A service that died or does not answer in time
    /// is an error, never a made-up value.
    pub fn request(&self, req: S::Req, timeout: Duration) -> Result<S::Resp, Error> {
        let (reply, answer) = mpsc::channel();
        self.tx
            .send(Msg::Request(req, reply))
            .map_err(|_| Error::Failed("the service has stopped".into()))?;
        answer.recv_timeout(timeout).map_err(|e| match e {
            RecvTimeoutError::Timeout => Error::Failed("the service did not answer in time".into()),
            RecvTimeoutError::Disconnected => Error::Failed("the service has stopped".into()),
        })
    }

    /// Sends `req` without waiting for the answer (a click the caller must not wait for).
    pub fn post(&self, req: S::Req) {
        let (reply, _unwanted) = mpsc::channel();
        let _ = self.tx.send(Msg::Request(req, reply));
    }

    /// Ends the thread after its running request and joins it. Repeatable.
    pub fn stop(&self) {
        let _ = self.tx.send(Msg::Stop);
        let join = self.join.lock().unwrap_or_else(|e| e.into_inner()).take();
        if let Some(join) = join {
            let _ = join.join();
        }
    }
}

impl<S: Service> Drop for Actor<S> {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicU32, Ordering};

    use super::*;

    const WAIT: Duration = Duration::from_secs(10);

    /// Owns an `Rc`: it can only work if it was built on its own thread.
    struct Counter {
        n: Rc<RefCell<u32>>,
        ticks: Arc<AtomicU32>,
        ended: Arc<AtomicU32>,
        tick_every: Option<Duration>,
    }

    impl Service for Counter {
        type Req = u32;
        type Resp = u32;
        fn handle(&mut self, add: u32) -> u32 {
            *self.n.borrow_mut() += add;
            *self.n.borrow()
        }
        fn wake_in(&self) -> Option<Duration> {
            self.tick_every
        }
        fn tick(&mut self) {
            self.ticks.fetch_add(1, Ordering::SeqCst);
        }
        fn shutdown(&mut self) {
            self.ended.fetch_add(1, Ordering::SeqCst);
        }
    }

    fn spawn(tick_every: Option<Duration>) -> (Actor<Counter>, Arc<AtomicU32>, Arc<AtomicU32>) {
        let (ticks, ended) = (Arc::new(AtomicU32::new(0)), Arc::new(AtomicU32::new(0)));
        let (t, e) = (Arc::clone(&ticks), Arc::clone(&ended));
        let actor = Actor::spawn("test-counter", move || Counter {
            n: Rc::default(),
            ticks: t,
            ended: e,
            tick_every,
        });
        (actor, ticks, ended)
    }

    #[test]
    fn requests_run_in_order_on_the_owning_thread() {
        let (actor, ticks, _) = spawn(None);
        assert_eq!(actor.request(2, WAIT).unwrap(), 2);
        assert_eq!(actor.request(3, WAIT).unwrap(), 5);
        std::thread::sleep(Duration::from_millis(50));
        assert_eq!(
            ticks.load(Ordering::SeqCst),
            0,
            "an idle service never wakes"
        );
    }

    #[test]
    fn a_service_with_work_ticks_and_stop_runs_its_shutdown_once() {
        let (actor, ticks, ended) = spawn(Some(Duration::from_millis(5)));
        while ticks.load(Ordering::SeqCst) < 3 {
            std::thread::sleep(Duration::from_millis(5));
        }
        actor.stop();
        actor.stop();
        assert_eq!(ended.load(Ordering::SeqCst), 1);
        assert!(
            actor.request(1, WAIT).is_err(),
            "a stopped service answers with an error"
        );
    }

    #[test]
    fn dropping_the_actor_ends_the_thread() {
        let (actor, _, ended) = spawn(None);
        drop(actor);
        assert_eq!(ended.load(Ordering::SeqCst), 1);
    }
}
