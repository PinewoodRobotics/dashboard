//! The socket under the NT4 client (core/nt/nt_transport.gd) and a scripted
//! fake for tests (fake_transport.gd).

use std::cell::RefCell;
use std::rc::Rc;

use super::msgpack::{self, MsgValue, Writer};
use super::protocol::{self, Frame, Message};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransportState {
    Connecting,
    Open,
    Closing,
    Closed,
}

#[derive(Clone, Debug, PartialEq)]
pub enum PacketBody {
    Text(Result<Vec<Message>, String>),
    Binary {
        frames: Vec<Frame>,
        error: Option<String>,
    },
}

/// An inbound WebSocket message, already parsed. `rx_us` is when it was read
/// off the socket; None means "now" to the client.
#[derive(Clone, Debug, PartialEq)]
pub struct Packet {
    pub rx_us: Option<i64>,
    pub body: PacketBody,
}

impl Packet {
    pub fn text(text: &str, rx_us: Option<i64>) -> Self {
        Self {
            rx_us,
            body: PacketBody::Text(protocol::parse_text(text)),
        }
    }

    pub fn binary(bytes: &[u8], rx_us: Option<i64>) -> Self {
        let mut frames = Vec::new();
        let error = protocol::decode_frames(bytes, &mut frames);
        Self {
            rx_us,
            body: PacketBody::Binary { frames, error },
        }
    }
}

pub trait Transport {
    fn open(&mut self, url: &str, protocols: &[String]) -> Result<(), String>;
    fn poll(&mut self) {}
    fn state(&self) -> TransportState;
    fn send_text(&mut self, text: String) -> bool;
    fn send_binary(&mut self, bytes: Vec<u8>) -> bool;
    /// Sends `[-1, 0, 2, local_now_us]`. Transports that queue re-stamp it at
    /// the moment it goes out, so queueing delay does not skew the offset.
    fn send_rtt_probe(&mut self, local_now_us: i64) -> bool {
        self.send_binary(protocol::rtt_frame(local_now_us))
    }
    fn take_packets(&mut self) -> Vec<Packet>;
    /// Code -1 drops the socket without a close handshake. Never blocks.
    fn close(&mut self, code: i32);
    fn selected_protocol(&self) -> String;
    fn close_code(&self) -> i32;
    fn close_reason(&self) -> String;
}

#[derive(Debug)]
pub struct FakeInner {
    pub state: TransportState,
    pub url: String,
    pub offered: Vec<String>,
    pub selected: String,
    pub open_result: Result<(), String>,
    pub sent_text: Vec<String>,
    pub sent_binary: Vec<Vec<u8>>,
    pub closed_by_client: bool,
    pub client_close_code: i32,
    inbound: Vec<Packet>,
}

/// A handle shared between the client (which owns a boxed copy) and the test.
#[derive(Clone, Debug)]
pub struct FakeTransport(pub Rc<RefCell<FakeInner>>);

impl Default for FakeTransport {
    fn default() -> Self {
        Self(Rc::new(RefCell::new(FakeInner {
            state: TransportState::Closed,
            url: String::new(),
            offered: Vec::new(),
            selected: String::new(),
            open_result: Ok(()),
            sent_text: Vec::new(),
            sent_binary: Vec::new(),
            closed_by_client: false,
            client_close_code: 0,
            inbound: Vec::new(),
        })))
    }
}

impl FakeTransport {
    pub fn url(&self) -> String {
        self.0.borrow().url.clone()
    }

    pub fn offered(&self) -> Vec<String> {
        self.0.borrow().offered.clone()
    }

    pub fn closed_by_client(&self) -> bool {
        self.0.borrow().closed_by_client
    }

    pub fn server_accept(&self) {
        let mut i = self.0.borrow_mut();
        i.state = TransportState::Open;
        i.selected = protocol::PROTOCOL_V40.into();
    }

    pub fn server_refuse(&self) {
        self.0.borrow_mut().state = TransportState::Closed;
    }

    pub fn server_close(&self) {
        self.0.borrow_mut().state = TransportState::Closed;
    }

    pub fn push_text(&self, text: &str) {
        self.0.borrow_mut().inbound.push(Packet::text(text, None));
    }

    pub fn push_messages(&self, messages: serde_json::Value) {
        self.push_text(&messages.to_string());
    }

    pub fn push_binary(&self, bytes: &[u8]) {
        self.0.borrow_mut().inbound.push(Packet::binary(bytes, None));
    }

    pub fn push_values(&self, frames: &[MsgValue]) {
        let mut w = Writer::default();
        frames.iter().for_each(|f| w.write_value(f));
        self.push_binary(w.bytes());
    }

    pub fn sent_text_count(&self) -> usize {
        self.0.borrow().sent_text.len()
    }

    pub fn sent_binary_count(&self) -> usize {
        self.0.borrow().sent_binary.len()
    }

    pub fn sent_messages(&self) -> Vec<Message> {
        self.0
            .borrow()
            .sent_text
            .iter()
            .flat_map(|t| protocol::parse_text(t).unwrap())
            .collect()
    }

    /// Every value frame sent, as `[id, ts, type, value]` arrays.
    pub fn sent_frames(&self) -> Vec<Vec<MsgValue>> {
        self.0
            .borrow()
            .sent_binary
            .iter()
            .flat_map(|b| msgpack::decode_all(b).values)
            .map(|v| match v {
                MsgValue::Array(a) => a,
                other => panic!("sent a non-frame {other:?}"),
            })
            .collect()
    }
}

impl Transport for FakeTransport {
    fn open(&mut self, url: &str, protocols: &[String]) -> Result<(), String> {
        let mut i = self.0.borrow_mut();
        i.url = url.into();
        i.offered = protocols.to_vec();
        i.open_result.clone()?;
        i.state = TransportState::Connecting;
        Ok(())
    }

    fn state(&self) -> TransportState {
        self.0.borrow().state
    }

    fn send_text(&mut self, text: String) -> bool {
        let mut i = self.0.borrow_mut();
        if i.state != TransportState::Open {
            return false;
        }
        i.sent_text.push(text);
        true
    }

    fn send_binary(&mut self, bytes: Vec<u8>) -> bool {
        let mut i = self.0.borrow_mut();
        if i.state != TransportState::Open {
            return false;
        }
        i.sent_binary.push(bytes);
        true
    }

    fn take_packets(&mut self) -> Vec<Packet> {
        std::mem::take(&mut self.0.borrow_mut().inbound)
    }

    fn close(&mut self, code: i32) {
        let mut i = self.0.borrow_mut();
        if i.state != TransportState::Closed {
            i.closed_by_client = true;
            i.client_close_code = code;
        }
        i.state = TransportState::Closed;
    }

    fn selected_protocol(&self) -> String {
        self.0.borrow().selected.clone()
    }

    fn close_code(&self) -> i32 {
        -1
    }

    fn close_reason(&self) -> String {
        String::new()
    }
}
