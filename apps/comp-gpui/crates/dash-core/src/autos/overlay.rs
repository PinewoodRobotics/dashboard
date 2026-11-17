//! One auto drawn on the field, as view-independent geometry in Godot world
//! space: the path centerline, start and end markers, a pin per timeline
//! event at the pose where it starts, and the turret's aim line, with the
//! colors every view uses. Port of Godot's `scenes3d/auto/auto_path_overlay.gd`
//! less the meshes, so the 2D minimap and the 3D views draw the same thing.

use super::field::{WorldPoint, to_world};
use super::ribbon::{self, Centerline};
use crate::playback::{Alliance, AutoMechanisms, ItemKind, TimelineItem};

/// sRGB color with straight alpha.
pub type Rgba = [f32; 4];

const fn rgb(hex: u32, a: f32) -> Rgba {
    [
        ((hex >> 16) & 0xff) as f32 / 255.0,
        ((hex >> 8) & 0xff) as f32 / 255.0,
        (hex & 0xff) as f32 / 255.0,
        a,
    ]
}

/// auto_path.gdshader: the travelled and the remaining part of the ribbon.
pub const DONE_COLOR: Rgba = [0.439, 0.804, 0.208, 1.0];
pub const TODO_COLOR: Rgba = [1.0, 1.0, 1.0, 0.6];
pub const START_COLOR: Rgba = rgb(0x70cd35, 1.0);
pub const END_COLOR: Rgba = rgb(0xffffff, 1.0);
pub const END_FILL_ALPHA: f32 = 0.35;
pub const AIM_COLOR: Rgba = [0.231, 0.51, 0.965, 0.85];
pub const PIN_ALPHA: f32 = 0.6;

/// Heights above the carpet that keep the 3D overlay layers apart.
pub const START_LIFT: f64 = 0.04;
pub const END_LIFT: f64 = 0.045;
pub const AIM_LIFT: f64 = 0.05;

pub const START_RING: (f64, f64) = (0.34, 0.46);
/// Arrow head ahead of the start ring: (back, tip) along forward, half width.
pub const START_ARROW: (f64, f64, f64) = (0.52, 0.85, 0.17);
pub const END_FILL_R: f64 = 0.3;
pub const END_RING: (f64, f64) = (0.3, 0.4);
pub const PIN_HEIGHT: f64 = 1.0;
/// Half the width of the pin's square stem.
pub const PIN_STEM: f64 = 0.018;
/// The pin head is an octahedron of this radius on top of the stem.
pub const PIN_HEAD: f64 = 0.075;
/// Pins of events starting at the same pose step along world +X.
pub const PIN_STACK_STEP: f64 = 0.1;
pub const AIM_HALF_WIDTH: f64 = 0.035;
pub const AIM_RING: (f64, f64) = (0.16, 0.24);
/// Shorter aim lines are not drawn.
pub const AIM_MIN_M: f64 = 0.05;

pub fn kind_color(kind: ItemKind, runs: bool) -> Rgba {
    if !runs {
        return rgb(0x71717a, 1.0);
    }
    match kind {
        ItemKind::Aim => rgb(0x3b82f6, 1.0),
        ItemKind::Shooter => rgb(0xff9d00, 1.0),
        ItemKind::Intake => rgb(0x70cd35, 1.0),
        ItemKind::Noop => rgb(0x71717a, 1.0),
        ItemKind::Other => rgb(0xa600ff, 1.0),
    }
}

/// Godot world direction of a field heading.
pub fn forward(heading: f64) -> (f64, f64) {
    (-heading.cos(), heading.sin())
}

#[derive(Clone, Debug, PartialEq)]
pub struct Pin {
    /// Base of the stem on the carpet, already moved aside by its stack.
    pub base: WorldPoint,
    pub kind: ItemKind,
    pub runs: bool,
}

impl Pin {
    pub fn color(&self) -> Rgba {
        let mut c = kind_color(self.kind, self.runs);
        c[3] = PIN_ALPHA;
        c
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct PathOverlay {
    pub auto: String,
    pub alliance: Alliance,
    /// Empty for an auto without a path.
    pub line: Centerline,
    pub start: WorldPoint,
    /// World (X, Z) direction the robot faces at the start.
    pub start_forward: (f64, f64),
    /// None for an auto without a path.
    pub end: Option<WorldPoint>,
    pub pins: Vec<Pin>,
}

impl PathOverlay {
    pub fn build(m: &AutoMechanisms, alliance: Alliance) -> Self {
        let line = if m.playback.has_path() {
            ribbon::centerline(&m.playback, alliance, ribbon::LIFT)
        } else {
            Centerline::default()
        };
        let start = m.pose_at(0.0, alliance);
        let end = m.playback.has_path().then(|| {
            let e = m.pose_at(m.duration, alliance);
            lifted(to_world(e.x, e.y), END_LIFT)
        });
        PathOverlay {
            auto: m.playback.name.clone(),
            alliance,
            line,
            start: lifted(to_world(start.x, start.y), START_LIFT),
            start_forward: forward(start.heading),
            end,
            pins: pins(m, alliance),
        }
    }

    /// The time at the end of the path: a progress that shows it all travelled.
    pub fn end_time(&self) -> f64 {
        self.line.times.last().copied().unwrap_or(0.0)
    }
}

fn lifted(mut p: WorldPoint, y: f64) -> WorldPoint {
    p.y = y;
    p
}

fn pins(m: &AutoMechanisms, alliance: Alliance) -> Vec<Pin> {
    let mut placed: Vec<((i64, i64), u32)> = Vec::new();
    m.items
        .iter()
        .map(|it: &TimelineItem| {
            let p = m.pose_at(it.t0, alliance);
            let mut base = to_world(p.x, p.y);
            let slot = (
                (base.x * 100.0).round() as i64,
                (base.z * 100.0).round() as i64,
            );
            let stack = match placed.iter_mut().find(|(s, _)| *s == slot) {
                Some((_, n)) => {
                    *n += 1;
                    *n - 1
                }
                None => {
                    placed.push((slot, 1));
                    0
                }
            };
            base.x += PIN_STACK_STEP * stack as f64;
            Pin {
                base,
                kind: it.kind,
                runs: it.runs,
            }
        })
        .collect()
}

/// The turret's aim line from the robot to its target at `AIM_LIFT`; None
/// while it does not aim or the two are too close to draw a line.
pub fn aim_line(from: WorldPoint, to: WorldPoint, on: bool) -> Option<(WorldPoint, WorldPoint)> {
    let len = (to.x - from.x).hypot(to.z - from.z);
    (on && len >= AIM_MIN_M).then(|| (lifted(from, AIM_LIFT), lifted(to, AIM_LIFT)))
}
