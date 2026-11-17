use std::io::{self, BufRead, Write};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ToHost {
    Surfaces {
        view: u32,
        generation: u32,
        width: u32,
        height: u32,
        ids: Vec<u32>,
    },
    Frame {
        view: u32,
        generation: u32,
        slot: u32,
        seq: u64,
        /// Wall time of Godot's tick: both force_draws and the copies, including waits on the
        /// GPU for earlier frames.
        tick_ms: f32,
        /// CPU time Godot's main thread spent in that tick (all views drawn in it).
        cpu_ms: f32,
        /// From the tick's submit to the fence that follows the copies.
        gpu_ms: f32,
        ready_us: u64,
        /// Stamp of the newest Pointer applied before this frame was drawn, 0 if none yet.
        input_stamp: u64,
    },
    Status {
        message: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Scene {
    Cube,
    Robot,
    Minimap,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ToProducer {
    /// Sizes are device pixels; `scale` is device pixels per logical pixel.
    OpenView {
        view: u32,
        scene: Scene,
        width: u32,
        height: u32,
        scale: f32,
        fps: u32,
        active: bool,
    },
    Resize {
        view: u32,
        width: u32,
        height: u32,
        scale: f32,
    },
    SetActive {
        view: u32,
        active: bool,
    },
    CloseView {
        view: u32,
    },
    Pointer(Pointer),
    Ack {
        view: u32,
        generation: u32,
        slot: u32,
        seq: u64,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PointerKind {
    Mouse,
    Touch,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PointerPhase {
    Down,
    Move,
    Up,
    Cancel,
    Wheel,
    Pinch,
}

pub mod buttons {
    pub const NONE: u8 = 0;
    pub const LEFT: u8 = 1;
    pub const RIGHT: u8 = 2;
    pub const MIDDLE: u8 = 3;
}

pub mod mods {
    pub const SHIFT: u8 = 1;
    pub const CTRL: u8 = 2;
    pub const ALT: u8 = 4;
    pub const META: u8 = 8;
}

/// One pointer event over a view. Positions are logical pixels from the view's top-left.
/// Mouse events use id 0; touches carry the platform touch id for their whole lifetime.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Pointer {
    pub view: u32,
    pub kind: PointerKind,
    pub id: u64,
    pub phase: PointerPhase,
    pub x: f32,
    pub y: f32,
    /// One of [`buttons`]; the button that changed for Down/Up.
    pub button: u8,
    /// Bitset of [`mods`].
    pub mods: u8,
    /// Wheel phase: WheelEvent.deltaX/deltaY as Chromium reports them (logical px, positive
    /// scrolls toward the end, 40 px per Cocoa line).
    pub wheel_x: f32,
    pub wheel_y: f32,
    /// Pinch phase: scale factor of this step (1.0 = no change).
    pub magnify: f32,
    /// Host wall-clock microseconds ([`now_us`]) when the event arrived.
    pub stamp: u64,
}

/// Wall-clock microseconds, comparable across the two processes on one machine.
pub fn now_us() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_micros() as u64)
        .unwrap_or(0)
}

pub fn write_message<T: Serialize>(writer: &mut impl Write, message: &T) -> io::Result<()> {
    let mut line = serde_json::to_vec(message)?;
    line.push(b'\n');
    writer.write_all(&line)?;
    writer.flush()
}

pub fn read_message<T: DeserializeOwned>(reader: &mut impl BufRead) -> io::Result<Option<T>> {
    let mut line = String::new();
    if reader.read_line(&mut line)? == 0 {
        return Ok(None);
    }
    serde_json::from_str(&line)
        .map(Some)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pointer_round_trips_as_a_tagged_line() {
        let message = ToProducer::Pointer(Pointer {
            view: 1,
            kind: PointerKind::Touch,
            id: 7,
            phase: PointerPhase::Move,
            x: 10.5,
            y: 20.0,
            button: buttons::NONE,
            mods: mods::SHIFT,
            wheel_x: 0.0,
            wheel_y: 0.0,
            magnify: 1.0,
            stamp: 1_763_000_000_000_000,
        });
        let mut bytes = Vec::new();
        write_message(&mut bytes, &message).unwrap();
        let text = String::from_utf8(bytes.clone()).unwrap();
        assert!(
            text.starts_with(r#"{"type":"Pointer","view":1,"kind":"Touch","id":7,"phase":"Move""#)
        );
        let back: ToProducer = read_message(&mut bytes.as_slice()).unwrap().unwrap();
        let ToProducer::Pointer(pointer) = back else {
            panic!("not a pointer");
        };
        assert_eq!(pointer.stamp, 1_763_000_000_000_000);
    }
}
