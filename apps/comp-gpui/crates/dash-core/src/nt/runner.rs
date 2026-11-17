//! Runs an [`Nt4Client`] on its own thread. The UI talks to it through an
//! [`NtService`]: commands go in over one channel, batches of client events
//! and periodic diagnostics come back over another.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender, TryRecvError};
use std::time::Duration;

use serde_json::Map;

use super::client::{ClientEvent, Diagnostics, Nt4Client, RTT_PERIOD_US, State, TransportFactory};
use super::clock::Clock;
use super::protocol::NtValue;
use super::service::NtService;
use super::topics::SubscriptionGroup;
use super::ws_transport::{Waker, WsTransport};

/// Longest the client thread sleeps without a command or socket news;
/// bounds the timing error of backoff, watchdogs and RTT probes.
const TICK: Duration = Duration::from_millis(5);

#[derive(Clone, Debug, PartialEq)]
pub enum Command {
    Configure { host: String, port: u16, timeout_s: f64 },
    Start,
    Stop,
    Reconnect,
    /// Replaces every subscription.
    Subscribe(Vec<SubscriptionGroup>),
    /// Desired-state publish; a publisher of another type on the same topic
    /// is replaced.
    Publish { topic: String, type_str: String, value: NtValue },
    Forget { topic: String },
    Release { topic: String },
    Wake,
    Shutdown,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    Client(ClientEvent),
    Diagnostics(Box<Diagnostics>),
}

/// The client plus the topic-keyed publishers and subscription groups the
/// commands refer to (nt_control_link.gd and NtService.apply_connection).
pub struct Driver {
    pub client: Nt4Client,
    pubs: HashMap<String, (i64, String)>,
    subs: Vec<i64>,
    next_diag_us: i64,
}

impl Driver {
    pub fn new(client: Nt4Client) -> Self {
        Self {
            client,
            pubs: HashMap::new(),
            subs: Vec::new(),
            next_diag_us: 0,
        }
    }

    pub fn apply(&mut self, cmd: Command) {
        let c = &mut self.client;
        match cmd {
            Command::Configure { host, port, timeout_s } => c.configure(&host, port, timeout_s),
            Command::Start => c.start(),
            Command::Stop => c.stop(),
            Command::Reconnect => c.reconnect(),
            Command::Subscribe(groups) => {
                for uid in self.subs.drain(..) {
                    c.unsubscribe(uid);
                }
                self.subs = groups
                    .into_iter()
                    .map(|g| c.subscribe(g.topics, g.options))
                    .collect();
            }
            Command::Publish { topic, type_str, value } => {
                let uid = match self.pubs.get(&topic) {
                    Some((uid, t)) if *t == type_str => *uid,
                    old => {
                        if let Some((uid, _)) = old {
                            c.remove_publisher(*uid);
                        }
                        let uid = c.add_publisher(&topic, &type_str, Map::new());
                        self.pubs.insert(topic, (uid, type_str));
                        uid
                    }
                };
                c.set_value(uid, value);
            }
            Command::Forget { topic } => {
                if let Some((uid, _)) = self.pubs.get(&topic) {
                    c.clear_value(*uid);
                }
            }
            Command::Release { topic } => {
                if let Some((uid, _)) = self.pubs.remove(&topic) {
                    c.remove_publisher(uid);
                }
            }
            Command::Wake | Command::Shutdown => {}
        }
    }

    /// Polls the client once. Diagnostics ride along on every state change
    /// and at least every RTT period.
    pub fn step(&mut self) -> Vec<Event> {
        self.client.poll();
        let mut out: Vec<Event> = self.client.take_events().into_iter().map(Event::Client).collect();
        let now = self.client.clock.now_us();
        let state_changed = out
            .iter()
            .any(|e| matches!(e, Event::Client(ClientEvent::State { .. })));
        if state_changed || now >= self.next_diag_us {
            self.next_diag_us = now + RTT_PERIOD_US;
            out.push(Event::Diagnostics(Box::new(self.client.diagnostics())));
        }
        out
    }

    pub fn state(&self) -> State {
        self.client.state()
    }
}

/// Starts the client thread with the WebSocket transport. Nothing connects
/// until `configure` and `start` are sent.
pub fn spawn(clock: Clock) -> NtService {
    spawn_with(clock, |clock, waker| {
        let clock = clock.clone();
        Box::new(move |timeout_s| {
            Box::new(WsTransport::new(
                clock.clone(),
                Duration::from_secs_f64(timeout_s),
                Some(waker.clone()),
            ))
        })
    })
}

/// `make_factory` runs on the client thread, so the transports it builds
/// need not be `Send`. The waker it gets nudges the thread out of its sleep.
pub fn spawn_with<F>(clock: Clock, make_factory: F) -> NtService
where
    F: FnOnce(&Clock, Waker) -> TransportFactory + Send + 'static,
{
    let (cmd_tx, cmd_rx) = mpsc::channel::<Command>();
    let (ev_tx, ev_rx) = mpsc::channel::<Vec<Event>>();
    let wake_tx = cmd_tx.clone();
    let waker: Waker = Arc::new(move || {
        let _ = wake_tx.send(Command::Wake);
    });
    std::thread::Builder::new()
        .name("nt-client".into())
        .spawn(move || {
            let factory = make_factory(&clock, waker);
            run(Driver::new(Nt4Client::new(clock, factory)), cmd_rx, ev_tx);
        })
        .expect("spawn nt-client thread");
    NtService::new(cmd_tx, ev_rx)
}

fn run(mut driver: Driver, cmd_rx: Receiver<Command>, ev_tx: Sender<Vec<Event>>) {
    'outer: loop {
        let mut next = match cmd_rx.recv_timeout(TICK) {
            Ok(cmd) => Some(cmd),
            Err(RecvTimeoutError::Timeout) => None,
            Err(RecvTimeoutError::Disconnected) => break,
        };
        while let Some(cmd) = next.take() {
            if cmd == Command::Shutdown {
                break 'outer;
            }
            driver.apply(cmd);
            next = match cmd_rx.try_recv() {
                Ok(cmd) => Some(cmd),
                Err(TryRecvError::Empty) => None,
                Err(TryRecvError::Disconnected) => break 'outer,
            };
        }
        let events = driver.step();
        if !events.is_empty() && ev_tx.send(events).is_err() {
            break;
        }
    }
    driver.client.stop();
}
