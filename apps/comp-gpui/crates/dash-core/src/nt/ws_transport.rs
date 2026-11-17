//! WebSocket transport on a worker thread per connection (ws_transport.gd
//! plus threaded_transport.gd). The worker owns the socket: it resolves,
//! connects, does the handshake, writes queued frames, stamps receive times
//! and parses every packet, so the client thread only applies decoded values.
//!
//! `close` never joins the worker: it may sit in a hostname lookup or a
//! connect. The worker sees the request when that returns and drops its
//! socket; Rust threads need no reaping, so it is simply detached.

use std::io::ErrorKind;
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tungstenite::client::IntoClientRequest;
use tungstenite::handshake::HandshakeError;
use tungstenite::protocol::CloseFrame;
use tungstenite::protocol::frame::coding::CloseCode;
use tungstenite::{Message, WebSocket};

use super::clock::Clock;
use super::protocol;
use super::transport::{Packet, Transport, TransportState};

const IDLE_SLEEP: Duration = Duration::from_millis(1);

pub type Waker = Arc<dyn Fn() + Send + Sync>;

enum Out {
    Text(String),
    Binary(Vec<u8>),
    Probe,
}

struct Shared {
    running: bool,
    close_request: i32,
    outbox: Vec<Out>,
    inbox: Vec<Packet>,
    state: TransportState,
    selected: String,
    close_code: i32,
    close_reason: String,
}

pub struct WsTransport {
    clock: Clock,
    connect_timeout: Duration,
    waker: Option<Waker>,
    shared: Option<Arc<Mutex<Shared>>>,
    state_seen: TransportState,
    selected_seen: String,
    close_code_seen: i32,
    close_reason_seen: String,
}

impl WsTransport {
    /// `connect_timeout` bounds the worker's own connect and handshake so an
    /// attempt the client's watchdog gave up on stops sending SYNs too.
    /// `waker` is called whenever the worker has news for the client.
    pub fn new(clock: Clock, connect_timeout: Duration, waker: Option<Waker>) -> Self {
        Self {
            clock,
            connect_timeout,
            waker,
            shared: None,
            state_seen: TransportState::Closed,
            selected_seen: String::new(),
            close_code_seen: -1,
            close_reason_seen: String::new(),
        }
    }

    fn sync(&mut self, s: &Shared) {
        self.state_seen = s.state;
        self.selected_seen.clone_from(&s.selected);
        self.close_code_seen = s.close_code;
        self.close_reason_seen.clone_from(&s.close_reason);
    }

    fn enqueue(&mut self, item: Out) -> bool {
        if self.state_seen != TransportState::Open {
            return false;
        }
        let Some(shared) = &self.shared else { return false };
        shared.lock().unwrap().outbox.push(item);
        true
    }
}

fn host_port(url: &str) -> Option<(String, u16)> {
    let rest = url.strip_prefix("ws://")?;
    let authority = rest.split('/').next()?;
    let (host, port) = authority.rsplit_once(':')?;
    Some((host.trim_matches(['[', ']']).to_owned(), port.parse().ok()?))
}

impl Transport for WsTransport {
    fn open(&mut self, url: &str, protocols: &[String]) -> Result<(), String> {
        let (host, port) = host_port(url).ok_or_else(|| format!("bad url {url}"))?;
        let shared = Arc::new(Mutex::new(Shared {
            running: true,
            close_request: 1000,
            outbox: Vec::new(),
            inbox: Vec::new(),
            state: TransportState::Connecting,
            selected: String::new(),
            close_code: -1,
            close_reason: String::new(),
        }));
        let worker = Worker {
            shared: shared.clone(),
            clock: self.clock.clone(),
            waker: self.waker.clone(),
        };
        let url = url.to_owned();
        let protocols = protocols.to_vec();
        let timeout = self.connect_timeout;
        std::thread::Builder::new()
            .name("nt-ws".into())
            .spawn(move || worker.run(&url, &host, port, &protocols, timeout))
            .map_err(|e| e.to_string())?;
        self.shared = Some(shared);
        self.state_seen = TransportState::Connecting;
        Ok(())
    }

    fn poll(&mut self) {
        if let Some(shared) = self.shared.clone() {
            let s = shared.lock().unwrap();
            self.sync(&s);
        }
    }

    fn state(&self) -> TransportState {
        self.state_seen
    }

    fn send_text(&mut self, text: String) -> bool {
        self.enqueue(Out::Text(text))
    }

    fn send_binary(&mut self, bytes: Vec<u8>) -> bool {
        self.enqueue(Out::Binary(bytes))
    }

    fn send_rtt_probe(&mut self, _local_now_us: i64) -> bool {
        self.enqueue(Out::Probe)
    }

    fn take_packets(&mut self) -> Vec<Packet> {
        let Some(shared) = self.shared.clone() else {
            return Vec::new();
        };
        let mut s = shared.lock().unwrap();
        self.sync(&s);
        std::mem::take(&mut s.inbox)
    }

    fn close(&mut self, code: i32) {
        if let Some(shared) = self.shared.take() {
            let mut s = shared.lock().unwrap();
            s.running = false;
            s.close_request = code;
            s.outbox.clear();
        }
        self.state_seen = TransportState::Closed;
    }

    fn selected_protocol(&self) -> String {
        self.selected_seen.clone()
    }

    fn close_code(&self) -> i32 {
        self.close_code_seen
    }

    fn close_reason(&self) -> String {
        self.close_reason_seen.clone()
    }
}

impl Drop for WsTransport {
    fn drop(&mut self) {
        self.close(-1);
    }
}

struct Worker {
    shared: Arc<Mutex<Shared>>,
    clock: Clock,
    waker: Option<Waker>,
}

fn would_block(e: &tungstenite::Error) -> bool {
    matches!(e, tungstenite::Error::Io(io) if io.kind() == ErrorKind::WouldBlock)
}

impl Worker {
    fn wake(&self) {
        if let Some(w) = &self.waker {
            w();
        }
    }

    fn finish(&self, code: i32, reason: String) {
        {
            let mut s = self.shared.lock().unwrap();
            s.state = TransportState::Closed;
            s.close_code = code;
            s.close_reason = reason;
        }
        self.wake();
    }

    fn connect(
        &self,
        url: &str,
        host: &str,
        port: u16,
        protocols: &[String],
        timeout: Duration,
    ) -> Result<(WebSocket<TcpStream>, String), String> {
        let deadline = Instant::now() + timeout;
        let left = || deadline.saturating_duration_since(Instant::now());
        let addrs = (host, port)
            .to_socket_addrs()
            .map_err(|e| format!("resolve {host}: {e}"))?;
        let mut last = format!("no address for {host}");
        let mut stream = None;
        for addr in addrs {
            if left().is_zero() || !self.shared.lock().unwrap().running {
                break;
            }
            match TcpStream::connect_timeout(&addr, left()) {
                Ok(s) => {
                    stream = Some(s);
                    break;
                }
                Err(e) => last = e.to_string(),
            }
        }
        let stream = stream.ok_or(last)?;
        let io = |e: std::io::Error| e.to_string();
        stream.set_nodelay(true).map_err(io)?;
        let handshake_limit = Some(left().max(Duration::from_millis(1)));
        stream.set_read_timeout(handshake_limit).map_err(io)?;
        stream.set_write_timeout(handshake_limit).map_err(io)?;
        let mut req = url.into_client_request().map_err(|e| e.to_string())?;
        req.headers_mut().insert(
            "Sec-WebSocket-Protocol",
            protocols.join(", ").parse().map_err(|_| "bad protocol list")?,
        );
        let (ws, resp) = tungstenite::client::client(req, stream).map_err(|e| match e {
            HandshakeError::Failure(e) => e.to_string(),
            HandshakeError::Interrupted(_) => "handshake timeout".into(),
        })?;
        let selected = resp
            .headers()
            .get("sec-websocket-protocol")
            .and_then(|v| v.to_str().ok())
            .unwrap_or_default()
            .to_owned();
        let s = ws.get_ref();
        s.set_read_timeout(None).map_err(io)?;
        s.set_write_timeout(None).map_err(io)?;
        s.set_nonblocking(true).map_err(io)?;
        Ok((ws, selected))
    }

    fn run(self, url: &str, host: &str, port: u16, protocols: &[String], timeout: Duration) {
        let (mut ws, selected) = match self.connect(url, host, port, protocols, timeout) {
            Ok(v) => v,
            Err(e) => return self.finish(-1, e),
        };
        {
            let mut s = self.shared.lock().unwrap();
            if !s.running {
                return;
            }
            s.state = TransportState::Open;
            s.selected = selected;
        }
        self.wake();
        loop {
            let (running, close_request, outgoing) = {
                let mut s = self.shared.lock().unwrap();
                (s.running, s.close_request, std::mem::take(&mut s.outbox))
            };
            if !running {
                if close_request >= 0 {
                    let frame = CloseFrame {
                        code: CloseCode::from(close_request as u16),
                        reason: "".into(),
                    };
                    let _ = ws.close(Some(frame));
                    let _ = ws.flush();
                }
                return;
            }
            let sent_any = !outgoing.is_empty();
            for item in outgoing {
                let msg = match item {
                    Out::Text(t) => Message::Text(t.into()),
                    Out::Binary(b) => Message::Binary(b.into()),
                    Out::Probe => Message::Binary(protocol::rtt_frame(self.clock.now_us()).into()),
                };
                if let Err(e) = ws.write(msg)
                    && !would_block(&e)
                {
                    return self.finish(-1, format!("write: {e}"));
                }
            }
            if let Err(e) = ws.flush()
                && !would_block(&e)
            {
                return self.finish(-1, format!("write: {e}"));
            }
            let mut packets = Vec::new();
            let mut closed: Option<(i32, String)> = None;
            loop {
                match ws.read() {
                    Ok(Message::Text(t)) => packets.push(Packet::text(t.as_str(), None)),
                    Ok(Message::Binary(b)) => packets.push(Packet::binary(&b, None)),
                    Ok(Message::Close(frame)) => {
                        closed = Some(match frame {
                            Some(f) => (i32::from(u16::from(f.code)), f.reason.to_string()),
                            None => (1005, String::new()),
                        });
                        break;
                    }
                    Ok(_) => {}
                    Err(e) if would_block(&e) => break,
                    Err(e) => {
                        closed = Some((-1, e.to_string()));
                        break;
                    }
                }
            }
            let got_any = !packets.is_empty();
            if got_any {
                let rx_us = self.clock.now_us();
                for p in &mut packets {
                    p.rx_us = Some(rx_us);
                }
                self.shared.lock().unwrap().inbox.append(&mut packets);
                self.wake();
            }
            if let Some((code, reason)) = closed {
                return self.finish(code, reason);
            }
            if !got_any && !sent_any {
                std::thread::sleep(IDLE_SLEEP);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_host_and_port() {
        assert_eq!(host_port("ws://10.47.65.2:5810/nt/x"), Some(("10.47.65.2".into(), 5810)));
        assert_eq!(host_port("ws://localhost:1/nt/x"), Some(("localhost".into(), 1)));
        assert_eq!(host_port("ws://[::1]:5810/nt/x"), Some(("::1".into(), 5810)));
        assert_eq!(host_port("http://x:1/"), None);
    }

    #[test]
    fn refused_connect_closes_without_blocking_the_caller() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);
        let mut t = WsTransport::new(Clock::real(), Duration::from_secs(2), None);
        t.open(&format!("ws://127.0.0.1:{port}/nt/test"), &[protocol::PROTOCOL_V40.into()])
            .unwrap();
        let start = Instant::now();
        while t.state() == TransportState::Connecting && start.elapsed() < Duration::from_secs(2) {
            std::thread::sleep(Duration::from_millis(5));
            t.poll();
        }
        assert_eq!(t.state(), TransportState::Closed);
        assert!(start.elapsed() < Duration::from_secs(1), "refusal is immediate");
    }

    #[test]
    fn close_does_not_wait_for_a_hung_connect() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let mut t = WsTransport::new(Clock::real(), Duration::from_secs(2), None);
        t.open(&format!("ws://127.0.0.1:{port}/nt/test"), &[protocol::PROTOCOL_V40.into()])
            .unwrap();
        std::thread::sleep(Duration::from_millis(50));
        t.poll();
        assert_eq!(t.state(), TransportState::Connecting, "the handshake is never answered");
        let start = Instant::now();
        t.close(1000);
        assert!(start.elapsed() < Duration::from_millis(5), "close returned in {:?}", start.elapsed());
        assert_eq!(t.state(), TransportState::Closed);
        drop(listener);
    }
}
