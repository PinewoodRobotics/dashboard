//! NT4 client state machine (core/nt/nt4_client.gd): connect, RTT time sync,
//! subscriptions, desired-state publishers, and the reconnect timing in
//! apps/comp-godot/README.md "Robot connection". Deterministic: it only
//! moves when `poll` is called and reads time from its [`Clock`], so the
//! tests drive it with a manual clock and a [`FakeTransport`].
//!
//! Unlike Godot, the client runs on its own thread (see `runner`), so there
//! is no per-frame packet budget: every packet is handled on each poll.
//!
//! [`FakeTransport`]: super::transport::FakeTransport

use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;

use serde_json::{Map, Value as Json};

use super::clock::Clock;
use super::msgpack::{MsgValue, Writer};
use super::protocol::{self, NtValue, SubOptions};
use super::time_sync::TimeSync;
use super::transport::{Packet, PacketBody, Transport, TransportState};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum State {
    #[default]
    Idle,
    Connecting,
    Syncing,
    Ready,
    Backoff,
}

impl State {
    pub fn name(self) -> &'static str {
        match self {
            State::Idle => "IDLE",
            State::Connecting => "CONNECTING",
            State::Syncing => "SYNCING",
            State::Ready => "READY",
            State::Backoff => "BACKOFF",
        }
    }
}

/// Delay before the next attempt by consecutive failures. A refused connect
/// costs one SYN and one RST on the robot LAN, so retries stay at 2 Hz.
pub const BACKOFF_S: [f64; 3] = [0.1, 0.25, 0.5];
pub const RTT_PERIOD_US: i64 = 250_000;
/// Silence on an open socket before it is dropped. Probes go out every
/// RTT_PERIOD_US and ntcore answers them from its network thread, so robot
/// GC pauses do not count; a poll gap counts for at most one probe period,
/// so a stalled client thread (or a sleeping laptop) does not either.
pub const LIVENESS_TIMEOUT_US: i64 = 2_000_000;
pub const DEFAULT_CONNECT_TIMEOUT_S: f64 = 2.0;
pub const MIN_CONNECT_TIMEOUT_S: f64 = 1.0;
pub const MAX_CONNECT_TIMEOUT_S: f64 = 60.0;

#[derive(Clone, Debug, PartialEq)]
pub struct TopicInfo {
    pub id: i64,
    pub name: Arc<str>,
    pub type_str: Arc<str>,
    pub properties: Map<String, Json>,
    pub pubuid: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TopicValue {
    pub name: Arc<str>,
    pub type_str: Arc<str>,
    pub value: NtValue,
    pub server_ts: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ClientEvent {
    State { state: State, previous: State },
    Announced { name: Arc<str>, type_str: Arc<str> },
    Unannounced { name: String, id: i64 },
    Properties { name: String, update: Map<String, Json> },
    /// One per binary packet, already coerced to each topic's type.
    Values(Vec<TopicValue>),
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Diagnostics {
    pub state: State,
    pub protocol: String,
    pub url: String,
    pub host: String,
    pub port: u16,
    pub rtt_us: i64,
    pub offset_us: i64,
    pub server_time_us: i64,
    pub announced: usize,
    pub subscriptions: usize,
    pub publishers: usize,
    /// Attempts opened since the last READY or manual reconnect.
    pub attempt: u32,
    /// Age of the current attempt, or -1 with none.
    pub attempt_age_s: f64,
    pub backoff_left_s: f64,
    pub connect_timeout_s: f64,
    pub values_total: u64,
    pub values_per_s: f64,
    pub unknown_id_drops: u64,
    pub decode_errors: u64,
    pub coerce_errors: u64,
    pub text_frames: u64,
    pub binary_frames: u64,
    pub rtt_samples: u64,
    pub connects: u32,
    /// Open connections that closed (server close, liveness, error).
    pub reconnects: u32,
    pub manual_reconnects: u32,
    pub connect_watchdog_fires: u32,
    pub liveness_fires: u32,
    pub send_errors: u32,
    pub last_close: String,
}

impl Diagnostics {
    /// The settings tab's attempt line (settings_tab.gd status_text):
    /// "Connected", or what the client is doing, such as
    /// "Connecting, attempt 3 (0.4 s)".
    pub fn status_text(&self) -> String {
        let attempt = self.attempt;
        match self.state {
            State::Ready => "Connected".into(),
            State::Connecting => {
                format!("Connecting, attempt {attempt} ({:.1} s)", self.attempt_age_s.max(0.0))
            }
            State::Syncing => format!("Syncing, attempt {attempt}"),
            State::Backoff if attempt == 0 => {
                format!("Link lost, retrying in {:.1} s", self.backoff_left_s)
            }
            State::Backoff => {
                format!("Attempt {attempt} failed, retrying in {:.1} s", self.backoff_left_s)
            }
            State::Idle => "Disconnected".into(),
        }
    }

    pub fn rtt_ms(&self) -> Option<f64> {
        (self.state == State::Ready && self.rtt_us >= 0).then(|| self.rtt_us as f64 / 1000.0)
    }

    /// The settings tab's Diagnostics box, in order.
    pub fn rows(&self) -> Vec<(&'static str, String)> {
        let dash = |s: String| if s.is_empty() { "--".into() } else { s };
        vec![
            ("State", self.state.name().into()),
            ("Attempt", self.status_text()),
            ("Server", format!("{}:{}", self.host, self.port)),
            ("Round trip", self.rtt_ms().map_or_else(|| "--".into(), |r| format!("{r:.1} ms"))),
            ("Reconnects", format!("{} (manual {})", self.reconnects, self.manual_reconnects)),
            ("Last close", dash(self.last_close.clone())),
        ]
    }
}

/// Called once per attempt with the connect timeout in seconds.
pub type TransportFactory = Box<dyn FnMut(f64) -> Box<dyn Transport>>;

struct Sub {
    topics: Vec<String>,
    options: SubOptions,
}

struct Pub {
    name: String,
    type_str: String,
    properties: Map<String, Json>,
    value: Option<NtValue>,
    last_ts: i64,
}

pub struct Nt4Client {
    pub clock: Clock,
    factory: TransportFactory,
    /// 4.0 only: keeps RTT time sync on the data socket and avoids 4.1's
    /// server pings, which drop a client that stalls.
    pub protocols: Vec<String>,
    pub client_name: String,
    host: String,
    port: u16,
    connect_timeout_s: f64,
    state: State,
    transport: Option<Box<dyn Transport>>,
    state_since_us: i64,
    attempt_started_us: i64,
    failures: usize,
    backoff_until_us: i64,
    last_rx_us: i64,
    last_poll_us: i64,
    next_rtt_us: i64,
    sync: TimeSync,
    subs: BTreeMap<i64, Sub>,
    next_subuid: i64,
    pubs: BTreeMap<i64, Pub>,
    next_pubuid: i64,
    topics: HashMap<i64, TopicInfo>,
    selected_protocol: String,
    rate_window_start_us: i64,
    rate_window_count: u64,
    events: Vec<ClientEvent>,
    stats: Diagnostics,
}

impl Nt4Client {
    pub fn new(clock: Clock, factory: TransportFactory) -> Self {
        let salt = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or(0)
            % 100_000;
        Self {
            clock,
            factory,
            protocols: vec![protocol::PROTOCOL_V40.into()],
            client_name: format!("pwrup-gpui-{}-{salt}", std::process::id()),
            host: String::new(),
            port: 5810,
            connect_timeout_s: DEFAULT_CONNECT_TIMEOUT_S,
            state: State::Idle,
            transport: None,
            state_since_us: 0,
            attempt_started_us: 0,
            failures: 0,
            backoff_until_us: 0,
            last_rx_us: 0,
            last_poll_us: 0,
            next_rtt_us: 0,
            sync: TimeSync::default(),
            subs: BTreeMap::new(),
            next_subuid: 1,
            pubs: BTreeMap::new(),
            next_pubuid: 1,
            topics: HashMap::new(),
            selected_protocol: String::new(),
            rate_window_start_us: 0,
            rate_window_count: 0,
            events: Vec::new(),
            stats: Diagnostics::default(),
        }
    }

    /// Any change reconnects at once unless the client is stopped.
    pub fn configure(&mut self, host: &str, port: u16, connect_timeout_s: f64) {
        let timeout = connect_timeout_s.clamp(MIN_CONNECT_TIMEOUT_S, MAX_CONNECT_TIMEOUT_S);
        let changed = host != self.host || port != self.port || timeout != self.connect_timeout_s;
        self.host = host.into();
        self.port = port;
        self.connect_timeout_s = timeout;
        if changed && self.state != State::Idle {
            self.reopen();
        }
    }

    pub fn connect_timeout_s(&self) -> f64 {
        self.connect_timeout_s
    }

    pub fn start(&mut self) {
        if self.state == State::Idle {
            self.reopen();
        }
    }

    pub fn stop(&mut self) {
        self.drop_transport(1000);
        self.reset_connection_state();
        self.set_state(State::Idle);
    }

    /// Drops whatever the client is doing (open socket, hung connect, pending
    /// backoff) and opens a new connection now, from any state.
    pub fn reconnect(&mut self) {
        self.stats.manual_reconnects += 1;
        self.reopen();
    }

    fn reopen(&mut self) {
        self.drop_transport(1000);
        self.reset_connection_state();
        self.stats.attempt = 0;
        self.failures = 0;
        self.open(self.clock.now_us());
    }

    pub fn state(&self) -> State {
        self.state
    }

    pub fn is_ready(&self) -> bool {
        self.state == State::Ready
    }

    pub fn is_open(&self) -> bool {
        matches!(self.state, State::Syncing | State::Ready)
    }

    pub fn url(&self) -> String {
        format!("ws://{}:{}/nt/{}", self.host, self.port, self.client_name)
    }

    pub fn selected_protocol(&self) -> &str {
        &self.selected_protocol
    }

    pub fn has_time_sync(&self) -> bool {
        self.sync.has_sync()
    }

    pub fn server_time_us(&self) -> i64 {
        if !self.sync.has_sync() {
            return -1;
        }
        self.sync.server_now_us(self.clock.now_us())
    }

    pub fn rtt_us(&self) -> i64 {
        self.sync.best_rtt_us
    }

    pub fn offset_us(&self) -> i64 {
        self.sync.offset_us
    }

    pub fn announced_topics(&self) -> impl Iterator<Item = &TopicInfo> {
        self.topics.values()
    }

    pub fn topic_id(&self, name: &str) -> Option<i64> {
        self.topics.values().find(|t| &*t.name == name).map(|t| t.id)
    }

    pub fn take_events(&mut self) -> Vec<ClientEvent> {
        std::mem::take(&mut self.events)
    }

    pub fn diagnostics(&self) -> Diagnostics {
        let now = self.clock.now_us();
        Diagnostics {
            state: self.state,
            protocol: self.selected_protocol.clone(),
            url: self.url(),
            host: self.host.clone(),
            port: self.port,
            rtt_us: self.sync.best_rtt_us,
            offset_us: self.sync.offset_us,
            server_time_us: self.server_time_us(),
            announced: self.topics.len(),
            subscriptions: self.subs.len(),
            publishers: self.pubs.len(),
            attempt_age_s: if self.stats.attempt > 0 {
                (now - self.attempt_started_us) as f64 / 1e6
            } else {
                -1.0
            },
            backoff_left_s: if self.state == State::Backoff {
                ((self.backoff_until_us - now) as f64 / 1e6).max(0.0)
            } else {
                0.0
            },
            connect_timeout_s: self.connect_timeout_s,
            ..self.stats.clone()
        }
    }

    pub fn subscribe(&mut self, topics: Vec<String>, options: SubOptions) -> i64 {
        let subuid = self.next_subuid;
        self.next_subuid += 1;
        if self.is_open() {
            self.send_text(&[protocol::subscribe_msg(subuid, &topics, &options)]);
        }
        self.subs.insert(subuid, Sub { topics, options });
        subuid
    }

    pub fn unsubscribe(&mut self, subuid: i64) {
        if self.subs.remove(&subuid).is_some() && self.is_open() {
            self.send_text(&[protocol::unsubscribe_msg(subuid)]);
        }
    }

    pub fn add_publisher(&mut self, name: &str, type_str: &str, properties: Map<String, Json>) -> i64 {
        let pubuid = self.next_pubuid;
        self.next_pubuid += 1;
        if self.state == State::Ready {
            self.send_text(&[protocol::publish_msg(pubuid, name, type_str, &properties)]);
        }
        self.pubs.insert(
            pubuid,
            Pub {
                name: name.into(),
                type_str: type_str.into(),
                properties,
                value: None,
                last_ts: 0,
            },
        );
        pubuid
    }

    pub fn remove_publisher(&mut self, pubuid: i64) {
        if self.pubs.remove(&pubuid).is_some() && self.state == State::Ready {
            self.send_text(&[protocol::unpublish_msg(pubuid)]);
        }
    }

    /// Stores the desired value and sends it now when READY. Returns false
    /// (and stores nothing) when the value is not representable as the
    /// publisher's type.
    pub fn set_value(&mut self, pubuid: i64, value: NtValue) -> bool {
        let Some(p) = self.pubs.get_mut(&pubuid) else {
            return false;
        };
        if !protocol::is_publishable(&value, &p.type_str) {
            return false;
        }
        p.value = Some(value);
        if self.state == State::Ready {
            let mut w = Writer::default();
            self.write_pub_value(&mut w, pubuid);
            self.send_binary(w.into_bytes());
        }
        true
    }

    /// Forgets the desired value so it is not re-sent on the next connection.
    pub fn clear_value(&mut self, pubuid: i64) {
        if let Some(p) = self.pubs.get_mut(&pubuid) {
            p.value = None;
        }
    }

    pub fn publisher_value(&self, pubuid: i64) -> Option<&NtValue> {
        self.pubs.get(&pubuid).and_then(|p| p.value.as_ref())
    }

    /// Test hook: sends a value with an explicit timestamp, bypassing time sync.
    pub fn debug_send_value_at(&mut self, pubuid: i64, value: &NtValue, ts_us: i64) -> bool {
        let Some(p) = self.pubs.get(&pubuid) else {
            return false;
        };
        if self.state != State::Ready {
            return false;
        }
        match protocol::value_frame(pubuid, ts_us, &p.type_str, value) {
            Some(frame) => self.send_binary(frame),
            None => false,
        }
    }

    fn write_pub_value(&mut self, w: &mut Writer, pubuid: i64) {
        let server_now = self.sync.server_now_us(self.clock.now_us());
        let p = self.pubs.get_mut(&pubuid).unwrap();
        let Some(value) = p.value.as_ref() else { return };
        let ts = server_now.max(p.last_ts + 1);
        p.last_ts = ts;
        protocol::write_value_frame(w, pubuid, ts, &p.type_str, value);
    }

    pub fn poll(&mut self) {
        let now = self.clock.now_us();
        let gap = now - self.last_poll_us;
        self.last_poll_us = now;
        if gap > RTT_PERIOD_US && self.is_open() {
            self.last_rx_us = (self.last_rx_us + gap - RTT_PERIOD_US).min(now);
        }
        match self.state {
            State::Idle => return,
            State::Backoff => {
                if now >= self.backoff_until_us {
                    self.open(now);
                }
                return;
            }
            State::Connecting => {
                let t = self.transport.as_mut().unwrap();
                t.poll();
                match t.state() {
                    TransportState::Open => self.on_open(now),
                    TransportState::Closed | TransportState::Closing => {
                        let code = t.close_code();
                        self.on_closed(now, format!("connect failed ({code})"), false);
                        return;
                    }
                    TransportState::Connecting => {
                        if now - self.state_since_us >= (self.connect_timeout_s * 1e6) as i64 {
                            self.stats.connect_watchdog_fires += 1;
                            // The watchdog already waited the full timeout, so retry at once.
                            self.on_closed(now, "connect timeout".into(), true);
                        }
                        return;
                    }
                }
            }
            State::Syncing | State::Ready => {}
        }
        self.poll_open(now);
    }

    fn poll_open(&mut self, now: i64) {
        let Some(t) = self.transport.as_mut() else { return };
        t.poll();
        self.drain(now);
        let Some(t) = self.transport.as_ref() else { return };
        if matches!(t.state(), TransportState::Closed | TransportState::Closing) {
            let reason = format!("closed by server ({} {})", t.close_code(), t.close_reason());
            self.on_closed(now, reason, false);
            return;
        }
        if now - self.last_rx_us > LIVENESS_TIMEOUT_US {
            self.stats.liveness_fires += 1;
            self.on_closed(now, "liveness timeout".into(), false);
            return;
        }
        if now >= self.next_rtt_us {
            self.send_rtt(now);
        }
        if now - self.rate_window_start_us >= 1_000_000 {
            self.stats.values_per_s =
                self.rate_window_count as f64 * 1e6 / (now - self.rate_window_start_us) as f64;
            self.rate_window_start_us = now;
            self.rate_window_count = 0;
        }
    }

    fn open(&mut self, now: i64) {
        self.reset_connection_state();
        self.stats.attempt += 1;
        self.attempt_started_us = now;
        if self.host.trim().is_empty() {
            self.stats.last_close = "no host".into();
            self.enter_backoff(now, false);
            return;
        }
        let mut t = (self.factory)(self.connect_timeout_s);
        let opened = t.open(&self.url(), &self.protocols);
        self.state_since_us = now;
        if let Err(e) = opened {
            self.stats.last_close = format!("open error {e}");
            self.enter_backoff(now, false);
            return;
        }
        self.transport = Some(t);
        self.set_state(State::Connecting);
    }

    fn on_open(&mut self, now: i64) {
        self.stats.connects += 1;
        self.selected_protocol = self.transport.as_ref().unwrap().selected_protocol();
        self.last_rx_us = now;
        self.rate_window_start_us = now;
        self.rate_window_count = 0;
        self.set_state(State::Syncing);
        self.send_rtt(now);
        if !self.subs.is_empty() {
            let msgs: Vec<Json> = self
                .subs
                .iter()
                .map(|(uid, s)| protocol::subscribe_msg(*uid, &s.topics, &s.options))
                .collect();
            self.send_text(&msgs);
        }
    }

    fn enter_ready(&mut self) {
        self.stats.attempt = 0;
        self.failures = 0;
        self.set_state(State::Ready);
        if self.pubs.is_empty() {
            return;
        }
        let msgs: Vec<Json> = self
            .pubs
            .iter()
            .map(|(uid, p)| protocol::publish_msg(*uid, &p.name, &p.type_str, &p.properties))
            .collect();
        self.send_text(&msgs);
        let mut w = Writer::default();
        let with_value: Vec<i64> = self
            .pubs
            .iter()
            .filter(|(_, p)| p.value.is_some())
            .map(|(uid, _)| *uid)
            .collect();
        for uid in &with_value {
            self.write_pub_value(&mut w, *uid);
        }
        if !with_value.is_empty() {
            self.send_binary(w.into_bytes());
        }
    }

    fn on_closed(&mut self, now: i64, reason: String, immediate: bool) {
        if self.is_open() {
            self.stats.reconnects += 1;
        }
        self.stats.last_close = reason;
        self.drop_transport(-1);
        self.reset_connection_state();
        self.enter_backoff(now, immediate);
    }

    fn enter_backoff(&mut self, now: i64, immediate: bool) {
        let delay_s = if immediate {
            0.0
        } else {
            BACKOFF_S[self.failures.min(BACKOFF_S.len() - 1)]
        };
        self.failures += 1;
        self.backoff_until_us = now + (delay_s * 1e6).round() as i64;
        self.set_state(State::Backoff);
    }

    fn drop_transport(&mut self, code: i32) {
        if let Some(mut t) = self.transport.take() {
            t.close(code);
        }
    }

    fn reset_connection_state(&mut self) {
        let old = std::mem::take(&mut self.topics);
        self.sync.reset();
        self.selected_protocol.clear();
        for p in self.pubs.values_mut() {
            p.last_ts = 0;
        }
        for (id, info) in old {
            self.events.push(ClientEvent::Unannounced {
                name: info.name.to_string(),
                id,
            });
        }
    }

    fn set_state(&mut self, s: State) {
        if s == self.state {
            return;
        }
        let previous = self.state;
        self.state = s;
        self.state_since_us = self.clock.now_us();
        self.events.push(ClientEvent::State { state: s, previous });
    }

    fn send_rtt(&mut self, now: i64) {
        self.next_rtt_us = now + RTT_PERIOD_US;
        let Some(t) = self.transport.as_mut() else { return };
        if t.state() != TransportState::Open {
            return;
        }
        if !t.send_rtt_probe(now) {
            self.stats.send_errors += 1;
        }
    }

    fn send_text(&mut self, msgs: &[Json]) -> bool {
        let Some(t) = self.transport.as_mut() else { return false };
        if t.state() != TransportState::Open {
            return false;
        }
        if !t.send_text(protocol::encode_text(msgs)) {
            self.stats.send_errors += 1;
            return false;
        }
        true
    }

    fn send_binary(&mut self, bytes: Vec<u8>) -> bool {
        let Some(t) = self.transport.as_mut() else { return false };
        if t.state() != TransportState::Open {
            return false;
        }
        if !t.send_binary(bytes) {
            self.stats.send_errors += 1;
            return false;
        }
        true
    }

    fn drain(&mut self, now: i64) {
        let packets = self.transport.as_mut().unwrap().take_packets();
        if packets.is_empty() {
            return;
        }
        self.last_rx_us = now;
        for pkt in packets {
            let Packet { rx_us, body } = pkt;
            match body {
                PacketBody::Text(res) => {
                    self.stats.text_frames += 1;
                    self.handle_text(res);
                }
                PacketBody::Binary { frames, error } => {
                    self.stats.binary_frames += 1;
                    if error.is_some() {
                        self.stats.decode_errors += 1;
                    }
                    self.handle_binary(frames, rx_us.unwrap_or(now));
                }
            }
            if self.transport.is_none() {
                return;
            }
        }
    }

    fn handle_text(&mut self, res: Result<Vec<protocol::Message>, String>) {
        let Ok(messages) = res else {
            self.stats.decode_errors += 1;
            return;
        };
        for m in messages {
            match m.method.as_str() {
                "announce" => {
                    let (Some(id), Some(name)) = (m.int("id"), m.str("name")) else {
                        self.stats.decode_errors += 1;
                        continue;
                    };
                    let info = TopicInfo {
                        id,
                        name: name.into(),
                        type_str: m.str("type").unwrap_or("raw").into(),
                        properties: m
                            .params
                            .get("properties")
                            .and_then(Json::as_object)
                            .cloned()
                            .unwrap_or_default(),
                        pubuid: m.int("pubuid").unwrap_or(-1),
                    };
                    self.events.push(ClientEvent::Announced {
                        name: info.name.clone(),
                        type_str: info.type_str.clone(),
                    });
                    self.topics.insert(id, info);
                }
                "unannounce" => {
                    if let Some(id) = m.int("id")
                        && self.topics.remove(&id).is_some()
                    {
                        self.events.push(ClientEvent::Unannounced {
                            name: m.str("name").unwrap_or_default().into(),
                            id,
                        });
                    }
                }
                "properties" => {
                    let update = m
                        .params
                        .get("update")
                        .and_then(Json::as_object)
                        .cloned()
                        .unwrap_or_default();
                    let name = m.str("name").unwrap_or_default().to_owned();
                    for info in self.topics.values_mut().filter(|t| *t.name == *name) {
                        for (k, v) in &update {
                            if v.is_null() {
                                info.properties.remove(k);
                            } else {
                                info.properties.insert(k.clone(), v.clone());
                            }
                        }
                    }
                    self.events.push(ClientEvent::Properties { name, update });
                }
                _ => {}
            }
        }
    }

    fn handle_binary(&mut self, frames: Vec<protocol::Frame>, now: i64) {
        let mut batch = Vec::new();
        for f in frames {
            if f.id == protocol::RTT_ID {
                if let MsgValue::Int(echoed) = f.value
                    && self.sync.add_sample(now, echoed, f.ts)
                {
                    self.stats.rtt_samples += 1;
                    if self.state == State::Syncing {
                        self.enter_ready();
                    }
                }
                continue;
            }
            let Some(info) = self.topics.get(&f.id) else {
                self.stats.unknown_id_drops += 1;
                continue;
            };
            let Some(value) = protocol::coerce(f.value, &info.type_str) else {
                self.stats.coerce_errors += 1;
                continue;
            };
            batch.push(TopicValue {
                name: info.name.clone(),
                type_str: info.type_str.clone(),
                value,
                server_ts: f.ts,
            });
        }
        let n = batch.len() as u64;
        self.stats.values_total += n;
        self.rate_window_count += n;
        if n > 0 {
            self.events.push(ClientEvent::Values(batch));
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;

    use serde_json::json;

    use super::super::msgpack::MsgValue as M;
    use super::super::transport::FakeTransport;
    use super::*;

    const SERVER_T0: i64 = 40_000_000;

    fn f(id: i64, ts: i64, t: i64, v: M) -> M {
        M::Array(vec![M::Int(id), M::Int(ts), M::Int(t), v])
    }

    struct H {
        clock: Clock,
        client: Nt4Client,
        transports: Rc<RefCell<Vec<FakeTransport>>>,
        values: Vec<(String, NtValue, i64, String)>,
        states: Vec<State>,
    }

    impl H {
        fn new() -> Self {
            let clock = Clock::manual(1_000_000);
            let transports: Rc<RefCell<Vec<FakeTransport>>> = Rc::default();
            let made = transports.clone();
            let mut client = Nt4Client::new(
                clock.clone(),
                Box::new(move |_| {
                    let t = FakeTransport::default();
                    made.borrow_mut().push(t.clone());
                    Box::new(t)
                }),
            );
            client.configure("127.0.0.1", 5810, 2.0);
            Self {
                clock,
                client,
                transports,
                values: Vec::new(),
                states: Vec::new(),
            }
        }

        fn t(&self) -> FakeTransport {
            self.transports.borrow().last().unwrap().clone()
        }

        fn tn(&self, i: usize) -> FakeTransport {
            self.transports.borrow()[i].clone()
        }

        fn count(&self) -> usize {
            self.transports.borrow().len()
        }

        fn poll(&mut self) {
            self.client.poll();
            for e in self.client.take_events() {
                match e {
                    ClientEvent::Values(batch) => {
                        for v in batch {
                            self.values.push((v.name.to_string(), v.value, v.server_ts, v.type_str.to_string()));
                        }
                    }
                    ClientEvent::State { state, .. } => self.states.push(state),
                    _ => {}
                }
            }
        }

        fn connect_ready(&mut self) {
            self.client.start();
            self.poll();
            self.t().server_accept();
            self.poll();
            let probe = self.t().sent_frames()[0].clone();
            self.clock.advance_us(2000);
            self.t().push_values(&[f(-1, SERVER_T0 + 1000, 2, probe[3].clone())]);
            self.poll();
        }

        fn run_for(&mut self, seconds: f64, step_s: f64) {
            for _ in 0..(seconds / step_s).round() as i64 {
                self.clock.advance_s(step_s);
                self.poll();
            }
        }

        fn reply_rtt(&mut self) {
            self.t().push_values(&[f(-1, SERVER_T0 + 3_000_000, 2, M::Int(0))]);
            self.poll();
        }

        fn diag(&self) -> Diagnostics {
            self.client.diagnostics()
        }

        fn sent_for(&self, pubuid: i64) -> Vec<Vec<M>> {
            self.t()
                .sent_frames()
                .into_iter()
                .filter(|fr| fr[0] == M::Int(pubuid))
                .collect()
        }
    }

    fn s(v: &str) -> NtValue {
        NtValue::String(v.into())
    }

    #[test]
    fn url_and_protocol_offer() {
        let mut h = H::new();
        h.client.start();
        assert_eq!(h.client.state(), State::Connecting);
        assert!(h.t().url().starts_with("ws://127.0.0.1:5810/nt/pwrup-gpui-"), "{}", h.t().url());
        assert_eq!(h.t().offered(), vec!["networktables.first.wpi.edu".to_string()]);
    }

    #[test]
    fn open_sends_rtt_then_batched_subscriptions() {
        let mut h = H::new();
        h.client.subscribe(
            vec!["/matchhud/state/".into()],
            SubOptions { prefix: true, periodic: Some(0.02), ..Default::default() },
        );
        h.client.subscribe(vec!["/a".into(), "/b".into()], SubOptions { periodic: Some(0.1), ..Default::default() });
        h.client.start();
        h.poll();
        h.t().server_accept();
        h.poll();
        assert_eq!(h.client.state(), State::Syncing);
        assert_eq!(h.client.selected_protocol(), "networktables.first.wpi.edu");
        let frames = h.t().sent_frames();
        assert_eq!(frames.len(), 1, "one RTT probe");
        assert_eq!(frames[0], vec![M::Int(-1), M::Int(0), M::Int(2), M::Int(h.clock.now_us())]);
        assert_eq!(h.t().sent_text_count(), 1, "subscriptions batched into one text frame");
        let msgs = h.t().sent_messages();
        assert_eq!(msgs.len(), 2);
        assert_eq!(msgs[0].method, "subscribe");
        assert_eq!(msgs[1].params["topics"], json!(["/a", "/b"]));
    }

    #[test]
    fn ready_on_first_rtt_reply_and_offset() {
        let mut h = H::new();
        h.connect_ready();
        assert_eq!(h.client.state(), State::Ready);
        assert_eq!(h.client.rtt_us(), 2000);
        assert_eq!(h.client.server_time_us(), SERVER_T0 + 2000);
        h.clock.advance_s(1.0);
        assert_eq!(h.client.server_time_us(), SERVER_T0 + 1_002_000);
    }

    #[test]
    fn rtt_probe_every_quarter_second() {
        let mut h = H::new();
        h.connect_ready();
        let n = h.t().sent_binary_count();
        h.clock.advance_us(240_000);
        h.poll();
        assert_eq!(h.t().sent_binary_count(), n, "no probe before 250 ms");
        h.clock.advance_us(10_000);
        h.t().push_values(&[f(-1, SERVER_T0 + 2_000_000, 2, M::Int(0))]);
        h.poll();
        assert_eq!(h.t().sent_binary_count(), n + 1, "probe after 250 ms");
        assert_eq!(h.t().sent_frames().last().unwrap()[0], M::Int(-1));
    }

    #[test]
    fn values_decode_with_announced_type() {
        let mut h = H::new();
        h.connect_ready();
        h.t().push_messages(json!([
            {"method": "announce", "params": {"name": "/matchhud/state/seq", "id": 3, "type": "int", "properties": {}}},
            {"method": "announce", "params": {"name": "/x/d", "id": 4, "type": "double", "properties": {}}},
            {"method": "announce", "params": {"name": "/x/s", "id": 5, "type": "struct:Pose2d", "properties": {}}},
        ]));
        h.t().push_values(&[
            f(3, 100, 2, M::Int(17)),
            f(4, 101, 2, M::Int(5)),
            f(5, 102, 5, M::Bin(vec![1, 2])),
            f(99, 103, 1, M::Float(1.0)),
        ]);
        h.poll();
        assert_eq!(h.values.len(), 3);
        assert_eq!(h.values[0], ("/matchhud/state/seq".into(), NtValue::Int(17), 100, "int".into()));
        assert_eq!(h.values[1].1, NtValue::Double(5.0), "int on a double topic is coerced");
        assert_eq!(h.values[2].1, NtValue::Raw(vec![1, 2]));
        assert_eq!(h.diag().unknown_id_drops, 1);
    }

    #[test]
    fn publishers_are_desired_state() {
        let mut h = H::new();
        let pubuid = h.client.add_publisher("/Shared/PathPlanner/SelectedPath/Request", "string", Map::new());
        assert!(h.client.set_value(pubuid, s("Auto A")));
        assert!(!h.client.set_value(pubuid, NtValue::Int(3)), "type mismatch is rejected");
        h.connect_ready();
        let msgs = h.t().sent_messages();
        let publish: Vec<_> = msgs.iter().filter(|m| m.method == "publish").collect();
        assert_eq!(publish.len(), 1);
        assert_eq!(publish[0].int("pubuid"), Some(pubuid));
        let vals = h.sent_for(pubuid);
        assert_eq!(vals.len(), 1, "desired value sent on READY");
        assert_eq!(vals[0][3], M::Str("Auto A".into()));
        assert_eq!(vals[0][1], M::Int(h.client.server_time_us()), "stamped with the server time estimate");
    }

    #[test]
    fn publish_stamps_monotonic_and_not_ahead() {
        let mut h = H::new();
        let pubuid = h.client.add_publisher("/Shared/Intake/Speed/Request", "double", Map::new());
        h.connect_ready();
        h.client.set_value(pubuid, NtValue::Double(0.1));
        h.client.set_value(pubuid, NtValue::Double(0.2));
        h.clock.advance_us(10);
        h.client.set_value(pubuid, NtValue::Double(0.3));
        let vals = h.sent_for(pubuid);
        assert_eq!(vals.len(), 3);
        let now_est = h.client.server_time_us();
        let ts = |i: usize| match vals[i][1] {
            M::Int(t) => t,
            _ => panic!(),
        };
        assert_eq!(ts(0), now_est - 10);
        assert_eq!(ts(1), ts(0) + 1, "same-instant publish gets last+1");
        assert_eq!(ts(2), now_est, "later publish uses the estimate again");
        assert_eq!(vals[2][3], M::Float(0.3));
    }

    #[test]
    fn reconnect_republishes_without_caller_action() {
        let mut h = H::new();
        let pubuid = h.client.add_publisher("/Shared/PathPlanner/SelectedPath/Request", "string", Map::new());
        h.client.subscribe(vec!["/Shared/PathPlanner/SelectedPath/State".into()], SubOptions::default());
        h.client.set_value(pubuid, s("First"));
        h.connect_ready();
        h.client.set_value(pubuid, s("Second"));
        h.t().push_messages(json!([{"method": "announce", "params": {"name": "/Shared/PathPlanner/SelectedPath/State", "id": 7, "type": "string", "properties": {}}}]));
        h.poll();
        assert_eq!(h.client.topic_id("/Shared/PathPlanner/SelectedPath/State"), Some(7));
        h.t().server_close();
        h.poll();
        assert_eq!(h.client.state(), State::Backoff);
        assert_eq!(h.client.topic_id("/Shared/PathPlanner/SelectedPath/State"), None, "ids cleared on close");
        h.clock.advance_s(0.1);
        h.poll();
        assert_eq!(h.count(), 2, "reconnect after 0.1 s backoff");
        assert_eq!(h.client.state(), State::Connecting);
        h.t().server_accept();
        h.poll();
        assert_eq!(h.t().sent_messages().len(), 1, "subscription re-sent on open");
        let probe = h.t().sent_frames()[0].clone();
        h.clock.advance_us(1000);
        h.t().push_values(&[f(-1, 5_000, 2, probe[3].clone())]);
        h.poll();
        assert_eq!(h.client.state(), State::Ready);
        let vals = h.sent_for(pubuid);
        assert_eq!(vals.len(), 1);
        assert_eq!(vals[0][3], M::Str("Second".into()), "latest desired value re-published");
        assert_eq!(vals[0][1], M::Int(5_500), "stamp follows the new server clock (robot reboot)");
    }

    #[test]
    fn cleared_value_not_republished() {
        let mut h = H::new();
        let pubuid = h.client.add_publisher("/x", "double", Map::new());
        h.client.set_value(pubuid, NtValue::Double(1.0));
        h.client.clear_value(pubuid);
        h.connect_ready();
        assert!(h.sent_for(pubuid).is_empty());
        let publishes = h.t().sent_messages().into_iter().filter(|m| m.method == "publish").count();
        assert_eq!(publishes, 1, "publisher still announced");
    }

    #[test]
    fn backoff_sequence() {
        let mut h = H::new();
        h.client.start();
        let mut delays = Vec::new();
        for _ in 0..6 {
            h.t().server_refuse();
            h.poll();
            assert_eq!(h.client.state(), State::Backoff);
            let n = h.count();
            let mut waited_steps = 0;
            while h.count() == n && waited_steps < 200 {
                h.clock.advance_us(50_000);
                waited_steps += 1;
                h.poll();
            }
            delays.push(waited_steps * 50);
        }
        assert_eq!(delays, vec![100, 250, 500, 500, 500, 500]);
        assert_eq!(h.diag().attempt, 7, "attempts counted since start");
    }

    #[test]
    fn backoff_resets_after_ready() {
        let mut h = H::new();
        h.client.start();
        h.t().server_refuse();
        h.poll();
        h.clock.advance_s(0.1);
        h.poll();
        h.t().server_refuse();
        h.poll();
        h.clock.advance_s(0.25);
        h.poll();
        h.t().server_accept();
        h.poll();
        let probe = h.t().sent_frames()[0].clone();
        h.t().push_values(&[f(-1, SERVER_T0, 2, probe[3].clone())]);
        h.poll();
        assert_eq!(h.client.state(), State::Ready);
        h.t().server_close();
        h.poll();
        assert_eq!(h.diag().attempt, 0, "attempt count reset by READY");
        let n = h.count();
        h.clock.advance_s(0.09);
        h.poll();
        assert_eq!(h.count(), n);
        h.clock.advance_s(0.01);
        h.poll();
        assert_eq!(h.count(), n + 1, "first retry after READY waits 0.1 s again");
    }

    #[test]
    fn connect_watchdog() {
        let mut h = H::new();
        h.client.start();
        h.poll();
        h.clock.advance_s(1.99);
        h.poll();
        assert_eq!(h.client.state(), State::Connecting);
        h.clock.advance_s(0.02);
        h.poll();
        assert!(h.tn(0).closed_by_client(), "stuck socket closed");
        assert_eq!(h.diag().connect_watchdog_fires, 1);
        h.poll();
        assert_eq!(h.count(), 2, "retried immediately");
        assert_eq!(h.client.state(), State::Connecting);
    }

    #[test]
    fn liveness_watchdog() {
        let mut h = H::new();
        h.connect_ready();
        h.run_for(1.95, 0.05);
        assert_eq!(h.client.state(), State::Ready);
        h.reply_rtt();
        h.run_for(1.95, 0.05);
        assert_eq!(h.client.state(), State::Ready, "inbound frame reset the watchdog");
        h.run_for(0.1, 0.05);
        assert_eq!(h.client.state(), State::Backoff);
        assert!(h.tn(0).closed_by_client());
        assert_eq!(h.diag().liveness_fires, 1);
    }

    #[test]
    fn stalled_frame_does_not_trip_liveness() {
        let mut h = H::new();
        h.connect_ready();
        h.run_for(1.0, 0.05);
        h.clock.advance_s(3.0);
        h.poll();
        assert_eq!(h.client.state(), State::Ready, "a 3 s stall counts as one probe period");
        assert_eq!(h.diag().liveness_fires, 0);
        h.run_for(0.7, 0.05);
        assert_eq!(h.client.state(), State::Ready);
        h.run_for(0.1, 0.05);
        assert_eq!(h.client.state(), State::Backoff, "silence after the stall still fires");
    }

    #[test]
    fn liveness_fires_at_two_polls_per_second() {
        let mut h = H::new();
        h.connect_ready();
        h.run_for(4.0, 0.5);
        assert_eq!(h.client.state(), State::Ready);
        h.run_for(0.5, 0.5);
        assert_eq!(h.diag().liveness_fires, 1, "each 0.5 s gap counts 0.25 s");
    }

    #[test]
    fn syncing_keeps_probing_without_reply() {
        let mut h = H::new();
        h.client.start();
        h.poll();
        h.t().server_accept();
        h.poll();
        h.t().push_text("[]");
        h.run_for(1.0, 0.05);
        assert_eq!(h.client.state(), State::Syncing);
        assert_eq!(h.t().sent_frames().len(), 5, "a probe every 250 ms");
    }

    #[test]
    fn host_change_closes_old_socket() {
        let mut h = H::new();
        h.connect_ready();
        let old = h.t();
        h.client.configure("10.47.65.2", 5810, 2.0);
        assert!(old.closed_by_client(), "old socket closed");
        assert_eq!(h.count(), 2);
        assert!(h.t().url().starts_with("ws://10.47.65.2:5810/"));
    }

    #[test]
    fn timeout_only_change_reconnects_and_applies() {
        let mut h = H::new();
        h.connect_ready();
        let old = h.t();
        h.client.configure("127.0.0.1", 5810, 2.0);
        assert_eq!(h.count(), 1, "unchanged settings keep the connection");
        h.client.configure("127.0.0.1", 5810, 1.0);
        assert!(old.closed_by_client(), "timeout change drops the old socket");
        assert_eq!(h.count(), 2);
        assert_eq!(h.client.state(), State::Connecting);
        h.run_for(0.95, 0.05);
        assert_eq!(h.count(), 2);
        h.run_for(0.1, 0.05);
        assert_eq!(h.diag().connect_watchdog_fires, 1, "watchdog uses the new 1 s timeout");
        assert_eq!(h.count(), 3);
    }

    #[test]
    fn timeout_clamped() {
        let mut h = H::new();
        h.client.configure("127.0.0.1", 5810, 0.2);
        assert_eq!(h.client.connect_timeout_s(), 1.0);
        h.client.configure("127.0.0.1", 5810, 600.0);
        assert_eq!(h.client.connect_timeout_s(), 60.0);
    }

    fn reach(h: &mut H, state: State) {
        match state {
            State::Idle => {}
            State::Ready => h.connect_ready(),
            State::Syncing => {
                h.client.start();
                h.poll();
                h.t().server_accept();
                h.poll();
            }
            State::Connecting => {
                h.client.start();
                h.run_for(1.0, 0.05);
            }
            State::Backoff => {
                h.client.start();
                for _ in 0..4 {
                    h.t().server_refuse();
                    h.run_for(0.5, 0.05);
                }
                h.t().server_refuse();
                h.poll();
            }
        }
    }

    #[test]
    fn manual_reconnect_from_every_state() {
        for state in [State::Idle, State::Connecting, State::Syncing, State::Ready, State::Backoff] {
            let mut h = H::new();
            reach(&mut h, state);
            let name = state.name();
            assert_eq!(h.client.state(), state, "reached {name}");
            let old = h.transports.borrow().last().cloned();
            let n = h.count();
            h.client.reconnect();
            assert_eq!(h.count(), n + 1, "{name}: new connection opened in the same call");
            assert_eq!(h.client.state(), State::Connecting, "{name}");
            assert_eq!(h.diag().attempt, 1, "{name}: attempt count reset");
            assert_eq!(h.diag().manual_reconnects, 1);
            if let Some(old) = old
                && state != State::Backoff
            {
                assert!(old.closed_by_client(), "{name}: old socket closed");
            }
            h.t().server_refuse();
            h.poll();
            assert!((h.diag().backoff_left_s - 0.1).abs() < 0.001, "{name}: backoff restarts from the first step");
        }
    }

    #[test]
    fn settings_status_text() {
        let d = |state, attempt, attempt_age_s, backoff_left_s| Diagnostics {
            state,
            attempt,
            attempt_age_s,
            backoff_left_s,
            ..Default::default()
        };
        assert_eq!(d(State::Ready, 0, -1.0, 0.0).status_text(), "Connected");
        assert_eq!(d(State::Connecting, 3, 0.42, 0.0).status_text(), "Connecting, attempt 3 (0.4 s)");
        assert_eq!(d(State::Syncing, 1, 0.1, 0.0).status_text(), "Syncing, attempt 1");
        assert_eq!(d(State::Backoff, 4, 1.0, 0.5).status_text(), "Attempt 4 failed, retrying in 0.5 s");
        assert_eq!(d(State::Backoff, 0, -1.0, 0.1).status_text(), "Link lost, retrying in 0.1 s");
        assert_eq!(d(State::Idle, 0, -1.0, 0.0).status_text(), "Disconnected");
    }

    #[test]
    fn settings_diagnostics_rows() {
        let mut d = Diagnostics {
            state: State::Ready,
            host: "10.47.65.2".into(),
            port: 5810,
            rtt_us: 1_540,
            reconnects: 2,
            manual_reconnects: 1,
            ..Default::default()
        };
        let rows = |d: &Diagnostics| d.rows().into_iter().map(|(_, v)| v).collect::<Vec<_>>();
        assert_eq!(
            rows(&d),
            ["READY", "Connected", "10.47.65.2:5810", "1.5 ms", "2 (manual 1)", "--"]
        );
        d.state = State::Backoff;
        d.attempt = 2;
        d.backoff_left_s = 0.25;
        d.last_close = "server closed".into();
        assert_eq!(
            rows(&d),
            [
                "BACKOFF",
                "Attempt 2 failed, retrying in 0.2 s",
                "10.47.65.2:5810",
                "--",
                "2 (manual 1)",
                "server closed"
            ]
        );
    }

    #[test]
    fn unannounce_and_properties() {
        let mut h = H::new();
        h.connect_ready();
        h.t().push_messages(json!([
            {"method": "announce", "params": {"name": "/p", "id": 1, "type": "double", "properties": {"retained": true}}},
            {"method": "properties", "params": {"name": "/p", "update": {"unit": "m", "retained": null}}},
        ]));
        h.poll();
        let info = h.client.announced_topics().next().unwrap().clone();
        assert_eq!(Json::Object(info.properties), json!({"unit": "m"}));
        h.t().push_messages(json!([{"method": "unannounce", "params": {"name": "/p", "id": 1}}]));
        h.t().push_values(&[f(1, 5, 1, M::Float(1.0))]);
        h.poll();
        assert_eq!(h.client.announced_topics().count(), 0);
        assert!(h.values.is_empty());
    }

    #[test]
    fn stop_goes_idle() {
        let mut h = H::new();
        h.connect_ready();
        h.client.stop();
        assert_eq!(h.client.state(), State::Idle);
        assert!(h.tn(0).closed_by_client());
        h.clock.advance_s(10.0);
        h.poll();
        assert_eq!(h.count(), 1);
        assert_eq!(h.states.last(), Some(&State::Idle));
    }
}
