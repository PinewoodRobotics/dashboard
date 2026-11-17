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
        cpu_ms: f32,
        gpu_ms: f32,
        ready_us: u64,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ToProducer {
    Ack {
        view: u32,
        generation: u32,
        slot: u32,
        seq: u64,
    },
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
