//! When a Godot frame actually reaches the display. The patched renderer reports which surface
//! buffers each presented drawable carried and when it was presented; views record which frame
//! each buffer held when they painted it.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use crate::stats::{FpsCounter, Smoothed};

#[derive(Clone, Copy)]
pub struct Painted {
    pub view: u32,
    pub seq: u64,
    pub ready_us: u64,
    pub input_stamp: u64,
}

#[derive(Default, Clone, Copy)]
pub struct PresentStats {
    pub age_ms: Smoothed,
    pub input_ms: Smoothed,
    pub fps: FpsCounter,
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    last_seq: u64,
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    last_input: u64,
}

#[derive(Default)]
struct Tracker {
    buffers: HashMap<usize, Painted>,
    views: HashMap<u32, PresentStats>,
    observed: bool,
}

fn tracker() -> &'static Mutex<Tracker> {
    static TRACKER: OnceLock<Mutex<Tracker>> = OnceLock::new();
    TRACKER.get_or_init(Default::default)
}

pub fn install() {
    #[cfg(target_os = "macos")]
    gpui_apple::metal_renderer::set_surface_present_observer(|buffers, presented_s| {
        let present_us = host_time_to_wall_us(presented_s);
        let mut tracker = tracker().lock().unwrap();
        tracker.observed = true;
        for address in buffers {
            let Some(painted) = tracker.buffers.get(address).copied() else {
                continue;
            };
            let stats = tracker.views.entry(painted.view).or_default();
            if painted.seq > stats.last_seq {
                stats.last_seq = painted.seq;
                stats.fps.tick();
                stats
                    .age_ms
                    .push(present_us.saturating_sub(painted.ready_us) as f32 / 1000.0);
            }
            if painted.input_stamp > stats.last_input {
                stats.last_input = painted.input_stamp;
                stats
                    .input_ms
                    .push(present_us.saturating_sub(painted.input_stamp) as f32 / 1000.0);
            }
        }
    });
}

/// Whether the renderer has reported any presentation; until then views fall back to paint time.
pub fn is_observed() -> bool {
    tracker().lock().unwrap().observed
}

pub fn painted(buffer_address: usize, frame: Painted) {
    tracker()
        .lock()
        .unwrap()
        .buffers
        .insert(buffer_address, frame);
}

pub fn forget(buffer_address: usize) {
    tracker().lock().unwrap().buffers.remove(&buffer_address);
}

pub fn stats(view: u32) -> PresentStats {
    tracker()
        .lock()
        .unwrap()
        .views
        .get(&view)
        .copied()
        .unwrap_or_default()
}

/// `presentedTime` is on the CACurrentMediaTime clock (mach_absolute_time in seconds).
#[cfg(target_os = "macos")]
#[allow(deprecated)]
fn host_time_to_wall_us(host_s: f64) -> u64 {
    let mut timebase = libc::mach_timebase_info { numer: 0, denom: 0 };
    let now_ticks = unsafe {
        libc::mach_timebase_info(&mut timebase);
        libc::mach_absolute_time()
    };
    let now_s = now_ticks as f64 * f64::from(timebase.numer) / f64::from(timebase.denom) / 1e9;
    let behind_us = ((now_s - host_s) * 1e6).max(0.0) as u64;
    protocol::now_us().saturating_sub(behind_us)
}
