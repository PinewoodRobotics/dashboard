//! NetworkTables 4 client (L7), ported from apps/comp-godot/core/nt.
//!
//! - [`client::Nt4Client`]: the protocol state machine (connect, time sync,
//!   subscriptions, desired-state publishers, backoff and watchdogs).
//! - [`runner::spawn`]: runs it on its own thread over [`ws_transport`].
//! - [`service::NtService`]: the UI thread's topic cache; implements
//!   [`crate::request_state::ControlLink`].

pub mod client;
pub mod clock;
pub mod msgpack;
pub mod protocol;
pub mod runner;
pub mod service;
pub mod time_sync;
pub mod topics;
pub mod transport;
pub mod ws_transport;

pub use client::{Diagnostics, State};
pub use clock::Clock;
pub use protocol::{NtValue, SubOptions};
pub use runner::spawn;
pub use service::NtService;
