//! An auto's path on the field: the sampled centerline in Godot world space
//! with the playback time of every point, and a flat strip whose UV.x carries
//! that time so a shader can split travelled from remaining without a rebuild.

use super::field::{WorldPoint, to_world};
use crate::playback::{Alliance, AutoPlayback};

pub const LIFT: f64 = 0.03;
pub const WIDTH: f64 = 0.14;
pub const MIN_STEP: f64 = 0.01;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Centerline {
    pub points: Vec<WorldPoint>,
    pub times: Vec<f64>,
}

/// Two vertices per centerline point, left then right; uv = (time, 0 left / 1 right).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct RibbonStrip {
    pub vertices: Vec<WorldPoint>,
    pub uvs: Vec<[f64; 2]>,
    pub indices: Vec<u32>,
}

/// Points closer than `MIN_STEP` to the previous one are skipped; the first
/// and last are kept.
pub fn centerline(p: &AutoPlayback, alliance: Alliance, lift: f64) -> Centerline {
    let mut out = Centerline::default();
    let n = p.sample_count;
    for i in 0..n {
        let s = p.sample_at(i, alliance);
        let mut w = to_world(s.x, s.y);
        w.y += lift;
        let t = i as f64 * p.dt;
        let too_close = out
            .points
            .last()
            .is_some_and(|last| w.distance_to(*last) < MIN_STEP);
        if i > 0 && i < n - 1 && too_close {
            continue;
        }
        if i == n - 1 && out.points.len() > 1 && too_close {
            *out.points.last_mut().unwrap() = w;
            *out.times.last_mut().unwrap() = t;
            continue;
        }
        out.points.push(w);
        out.times.push(t);
    }
    out
}

pub fn strip(line: &Centerline, width: f64) -> Option<RibbonStrip> {
    let pts = &line.points;
    let n = pts.len();
    if n < 2 {
        return None;
    }
    let mut out = RibbonStrip {
        vertices: Vec::with_capacity(n * 2),
        uvs: Vec::with_capacity(n * 2),
        indices: Vec::with_capacity((n - 1) * 6),
    };
    for i in 0..n {
        let a = pts[i.saturating_sub(1)];
        let b = pts[(i + 1).min(n - 1)];
        let (mut tx, mut tz) = (b.x - a.x, b.z - a.z);
        let len = (tx * tx + tz * tz).sqrt();
        if len * len < 1e-12 {
            (tx, tz) = (1.0, 0.0);
        } else {
            (tx, tz) = (tx / len, tz / len);
        }
        let (sx, sz) = (-tz * width * 0.5, tx * width * 0.5);
        let p = pts[i];
        out.vertices.push(WorldPoint {
            x: p.x - sx,
            y: p.y,
            z: p.z - sz,
        });
        out.vertices.push(WorldPoint {
            x: p.x + sx,
            y: p.y,
            z: p.z + sz,
        });
        out.uvs.push([line.times[i], 0.0]);
        out.uvs.push([line.times[i], 1.0]);
    }
    for i in 0..(n as u32 - 1) {
        let l0 = i * 2;
        out.indices
            .extend_from_slice(&[l0, l0 + 2, l0 + 1, l0 + 1, l0 + 2, l0 + 3]);
    }
    Some(out)
}
