//! The UI thread's view of NetworkTables (services/nt_service.gd and
//! nt_control_link.gd): a per-topic cache with live flags, the connection
//! state and diagnostics, fed by `pump` from the client thread's events.
//! Implements [`ControlLink`] for the robot controls.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, Sender, TryRecvError};

use super::client::{ClientEvent, Diagnostics, State, TopicValue};
use super::protocol::{self, NtValue};
use super::runner::{Command, Event};
use super::topics::SubscriptionGroup;
use crate::request_state::{ControlLink, Value};

#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    pub value: Option<NtValue>,
    pub type_str: Arc<str>,
    pub server_ts: i64,
    pub local_ts: i64,
    /// Delivered a value on the current connection.
    pub fresh: bool,
    pub updates: u64,
}

/// What one `pump` brought in, in arrival order.
#[derive(Debug, Default)]
pub struct Pumped {
    pub values: Vec<TopicValue>,
    /// Some(ready) when READY was entered or left.
    pub connection: Option<bool>,
    /// The client thread has exited.
    pub closed: bool,
}

impl Pumped {
    pub fn is_empty(&self) -> bool {
        self.values.is_empty() && self.connection.is_none()
    }
}

pub struct NtService {
    tx: Sender<Command>,
    rx: Receiver<Vec<Event>>,
    cache: HashMap<Arc<str>, Entry>,
    state: State,
    ready: bool,
    diagnostics: Diagnostics,
    desired: HashMap<String, NtValue>,
    /// Publishes are refused (a spectator dashboard).
    pub read_only: bool,
}

impl NtService {
    pub fn new(tx: Sender<Command>, rx: Receiver<Vec<Event>>) -> Self {
        Self {
            tx,
            rx,
            cache: HashMap::new(),
            state: State::Idle,
            ready: false,
            diagnostics: Diagnostics::default(),
            desired: HashMap::new(),
            read_only: false,
        }
    }

    fn send(&self, cmd: Command) {
        let _ = self.tx.send(cmd);
    }

    /// A host, port or timeout change drops the old socket and opens a new
    /// one at once.
    pub fn configure(&self, host: &str, port: u16, timeout_s: f64) {
        self.send(Command::Configure {
            host: host.into(),
            port,
            timeout_s,
        });
    }

    pub fn start(&self) {
        self.send(Command::Start);
    }

    pub fn stop(&self) {
        self.send(Command::Stop);
    }

    pub fn reconnect(&self) {
        self.send(Command::Reconnect);
    }

    pub fn set_subscriptions(&self, groups: Vec<SubscriptionGroup>) {
        self.send(Command::Subscribe(groups));
    }

    /// Applies everything the client thread has sent since the last call.
    pub fn pump(&mut self, now_us: i64) -> Pumped {
        let mut out = Pumped::default();
        loop {
            let batch = match self.rx.try_recv() {
                Ok(b) => b,
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    out.closed = true;
                    break;
                }
            };
            for ev in batch {
                match ev {
                    Event::Diagnostics(d) => self.diagnostics = *d,
                    Event::Client(ClientEvent::State { state, .. }) => {
                        self.state = state;
                        if !matches!(state, State::Ready | State::Syncing) {
                            self.cache.values_mut().for_each(|e| e.fresh = false);
                        }
                        let ready = state == State::Ready;
                        if ready != self.ready {
                            self.ready = ready;
                            out.connection = Some(ready);
                        }
                    }
                    Event::Client(ClientEvent::Announced { name, type_str }) => {
                        self.slot(&name).type_str = type_str;
                    }
                    Event::Client(ClientEvent::Values(values)) => {
                        for v in values {
                            let e = self.slot(&v.name);
                            e.value = Some(v.value.clone());
                            e.type_str = v.type_str.clone();
                            e.server_ts = v.server_ts;
                            e.local_ts = now_us;
                            e.updates += 1;
                            e.fresh = true;
                            out.values.push(v);
                        }
                    }
                    Event::Client(_) => {}
                }
            }
        }
        out
    }

    fn slot(&mut self, name: &Arc<str>) -> &mut Entry {
        self.cache.entry(name.clone()).or_insert_with(|| Entry {
            value: None,
            type_str: "".into(),
            server_ts: 0,
            local_ts: 0,
            fresh: false,
            updates: 0,
        })
    }

    pub fn is_ready(&self) -> bool {
        self.ready
    }

    pub fn state(&self) -> State {
        self.state
    }

    pub fn diagnostics(&self) -> &Diagnostics {
        &self.diagnostics
    }

    /// Latest value, kept (stale) while disconnected.
    pub fn get(&self, topic: &str) -> Option<&NtValue> {
        self.cache.get(topic).and_then(|e| e.value.as_ref())
    }

    pub fn has_value(&self, topic: &str) -> bool {
        self.get(topic).is_some()
    }

    /// Connected and the topic delivered a value on this connection.
    pub fn is_live(&self, topic: &str) -> bool {
        self.ready && self.cache.get(topic).is_some_and(|e| e.fresh)
    }

    pub fn entry(&self, topic: &str) -> Option<&Entry> {
        self.cache.get(topic)
    }

    pub fn topic_names(&self) -> impl Iterator<Item = &str> {
        self.cache.keys().map(|k| &**k)
    }

    /// Desired-state publish: sent now when connected and again after every
    /// reconnect. False when read-only or the value does not fit the type.
    pub fn publish_value(&mut self, topic: &str, type_str: &str, value: NtValue) -> bool {
        if self.read_only || !protocol::is_publishable(&value, type_str) {
            return false;
        }
        self.desired.insert(topic.into(), value.clone());
        self.send(Command::Publish {
            topic: topic.into(),
            type_str: type_str.into(),
            value,
        });
        true
    }

    pub fn desired(&self, topic: &str) -> Option<&NtValue> {
        self.desired.get(topic)
    }
}

impl Drop for NtService {
    fn drop(&mut self) {
        self.send(Command::Shutdown);
    }
}

impl ControlLink for NtService {
    fn connected(&self) -> bool {
        self.ready
    }

    fn live(&self, topic: &str) -> bool {
        self.is_live(topic)
    }

    fn value(&self, topic: &str) -> Option<Value> {
        self.get(topic).and_then(NtValue::to_control_value)
    }

    fn publish(&mut self, topic: &str, value: Value) -> bool {
        let type_str = value.nt_type();
        self.publish_value(topic, type_str, NtValue::from_control_value(&value))
    }

    fn forget(&mut self, topic: &str) {
        self.desired.remove(topic);
        self.send(Command::Forget { topic: topic.into() });
    }

    fn release(&mut self, topic: &str) {
        self.desired.remove(topic);
        self.send(Command::Release { topic: topic.into() });
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;
    use std::sync::mpsc;

    use serde_json::json;

    use super::super::client::Nt4Client;
    use super::super::clock::Clock;
    use super::super::msgpack::MsgValue as M;
    use super::super::runner::Driver;
    use super::super::transport::FakeTransport;
    use super::*;

    fn f(id: i64, ts: i64, t: i64, v: M) -> M {
        M::Array(vec![M::Int(id), M::Int(ts), M::Int(t), v])
    }

    struct H {
        clock: Clock,
        driver: Driver,
        cmd_rx: mpsc::Receiver<Command>,
        ev_tx: mpsc::Sender<Vec<Event>>,
        nt: NtService,
        transports: Rc<RefCell<Vec<FakeTransport>>>,
        seen: Vec<TopicValue>,
        connection: Vec<bool>,
    }

    impl H {
        fn new() -> Self {
            let clock = Clock::manual(1_000_000);
            let transports: Rc<RefCell<Vec<FakeTransport>>> = Rc::default();
            let made = transports.clone();
            let client = Nt4Client::new(
                clock.clone(),
                Box::new(move |_| {
                    let t = FakeTransport::default();
                    made.borrow_mut().push(t.clone());
                    Box::new(t)
                }),
            );
            let (cmd_tx, cmd_rx) = mpsc::channel();
            let (ev_tx, ev_rx) = mpsc::channel();
            let nt = NtService::new(cmd_tx, ev_rx);
            nt.configure("127.0.0.1", 5810, 10.0);
            Self {
                clock,
                driver: Driver::new(client),
                cmd_rx,
                ev_tx,
                nt,
                transports,
                seen: Vec::new(),
                connection: Vec::new(),
            }
        }

        fn t(&self) -> FakeTransport {
            self.transports.borrow().last().unwrap().clone()
        }

        fn poll(&mut self) {
            while let Ok(cmd) = self.cmd_rx.try_recv() {
                self.driver.apply(cmd);
            }
            self.ev_tx.send(self.driver.step()).unwrap();
            let p = self.nt.pump(self.clock.now_us());
            self.seen.extend(p.values);
            self.connection.extend(p.connection);
        }

        fn connect(&mut self) {
            self.nt.start();
            self.poll();
            self.t().server_accept();
            self.poll();
            let probe = self.t().sent_frames()[0].clone();
            self.clock.advance_us(1000);
            self.t().push_values(&[f(-1, 9_000_000, 2, probe[3].clone())]);
            self.t().push_messages(json!([
                {"method": "announce", "params": {"name": "/m/seq", "id": 1, "type": "int", "properties": {}}},
                {"method": "announce", "params": {"name": "/m/x", "id": 2, "type": "double", "properties": {}}},
            ]));
            self.poll();
        }
    }

    #[test]
    fn cache_and_live_flags() {
        let mut h = H::new();
        assert!(!h.nt.has_value("/m/x"));
        assert_eq!(h.nt.get("/m/x"), None, "nothing before any value");
        h.connect();
        assert!(h.nt.is_ready());
        h.t().push_values(&[f(1, 100, 2, M::Int(5)), f(2, 101, 1, M::Float(2.5)), f(2, 102, 2, M::Int(3))]);
        h.poll();
        assert_eq!(h.nt.get("/m/seq"), Some(&NtValue::Int(5)));
        assert_eq!(h.nt.get("/m/x"), Some(&NtValue::Double(3.0)), "latest value, coerced to double");
        assert!(h.nt.is_live("/m/x"));
        let xs: Vec<_> = h.seen.iter().filter(|v| &*v.name == "/m/x").map(|v| v.value.clone()).collect();
        assert_eq!(xs, vec![NtValue::Double(2.5), NtValue::Double(3.0)], "one update per value");
        let e = h.nt.entry("/m/x").unwrap();
        assert_eq!(e.server_ts, 102);
        assert_eq!(e.updates, 2);
        assert_eq!(&*e.type_str, "double");
        h.t().server_close();
        h.poll();
        assert!(!h.nt.is_ready());
        assert!(!h.nt.is_live("/m/x"), "stale after disconnect");
        assert_eq!(h.nt.get("/m/x"), Some(&NtValue::Double(3.0)), "last value kept while disconnected");
    }

    #[test]
    fn connection_signal() {
        let mut h = H::new();
        h.connect();
        h.t().server_close();
        h.poll();
        assert_eq!(h.connection, vec![true, false]);
    }

    #[test]
    fn publisher_handle() {
        let mut h = H::new();
        assert!(h.nt.publish_value("/Shared/Intake/Speed/Request", "double", NtValue::Double(0.42)));
        assert_eq!(h.nt.desired("/Shared/Intake/Speed/Request"), Some(&NtValue::Double(0.42)));
        assert!(
            !h.nt.publish_value("/Shared/Intake/Speed/Request", "double", NtValue::String("x".into())),
            "wrong type rejected"
        );
        h.connect();
        let sent: Vec<_> = h.t().sent_frames().into_iter().filter(|fr| fr[0] != M::Int(-1)).collect();
        assert_eq!(sent.len(), 1);
        assert_eq!(sent[0][3], M::Float(0.42));
        h.nt.forget("/Shared/Intake/Speed/Request");
        assert_eq!(h.nt.desired("/Shared/Intake/Speed/Request"), None);
    }

    #[test]
    fn control_link_round_trip() {
        let mut h = H::new();
        h.nt.set_subscriptions(vec![]);
        h.connect();
        let link: &mut dyn ControlLink = &mut h.nt;
        assert!(link.connected());
        assert!(link.publish("/Shared/PathPlanner/SelectedPath/Request", Value::String("Stay".into())));
        h.poll();
        let publishes: Vec<_> = h.t().sent_messages().into_iter().filter(|m| m.method == "publish").collect();
        assert_eq!(publishes.len(), 1);
        assert_eq!(publishes[0].str("type"), Some("string"));
        h.t().push_messages(json!([{"method": "announce", "params": {"name": "/s", "id": 9, "type": "string", "properties": {}}}]));
        h.t().push_values(&[f(9, 5, 4, M::Str("Stay".into()))]);
        h.poll();
        assert!(h.nt.live("/s"));
        assert_eq!(ControlLink::value(&h.nt, "/s"), Some(Value::String("Stay".into())));
        h.nt.release("/Shared/PathPlanner/SelectedPath/Request");
        h.poll();
        assert!(h.t().sent_messages().iter().any(|m| m.method == "unpublish"));
    }

    #[test]
    fn read_only_refuses_publishes() {
        let mut h = H::new();
        h.nt.read_only = true;
        assert!(!h.nt.publish(AIM, Value::Double(1.0)));
        assert_eq!(h.nt.desired(AIM), None);
    }

    const AIM: &str = "/Tuning/Turret/AimTrimDeg";
}
