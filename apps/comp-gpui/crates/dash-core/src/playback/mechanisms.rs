//! Robot pose and mechanism state of one exported auto as a pure function of
//! t, so jumping to t and playing to t agree exactly. Joint values come out in
//! raw NT units, ready for the same rig solver as live data. Rules, from
//! `data/auto_commands.json` and the robot code:
//! - wrist: the most recently started running intake command holds the
//!   intake; with none, the intake's default command holds its location. The
//!   wrist eases to each new setpoint at the modeled travel rate.
//! - turret: aims at the AimPoint target while ContinuousAimCommand runs, and
//!   while the turret's default command aims (GPS assist on, the robot's
//!   default), easing in and out over `AIM_BLEND_S`.
//! - shooter and rollers: on while a running command has that effect.
//!
//! Events that never run on the robot (unregistered commands, markers nothing
//! is bound to) move nothing; their timeline items say why.

use std::f64::consts::TAU;
use std::sync::Arc;

use super::angle::{lerp, lerp_angle, smoothstep};
use super::auto::{Alliance, AutoEvent, AutoPlayback};
use crate::autos::aim_point;
use crate::autos::commands::{AutoCommands, CommandEffect};
use crate::autos::field::{FieldPoint, Pose};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ItemKind {
    Aim,
    Shooter,
    Intake,
    Noop,
    Other,
}

impl ItemKind {
    pub fn key(self) -> &'static str {
        match self {
            ItemKind::Aim => "aim",
            ItemKind::Shooter => "shooter",
            ItemKind::Intake => "intake",
            ItemKind::Noop => "noop",
            ItemKind::Other => "other",
        }
    }
}

/// One event on the scrub bar, pins and event feed, in export order.
#[derive(Clone, Debug, PartialEq)]
pub struct TimelineItem {
    pub name: String,
    pub t0: f64,
    pub t1: f64,
    pub kind: ItemKind,
    pub runs: bool,
    pub instant: bool,
    pub note: &'static str,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AimSource {
    None,
    Command,
    Default,
}

/// Raw NT joint values as the robot publishes them (wrist and turret in rotations).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct RawJoints {
    pub wrist: f64,
    pub turret: f64,
    pub climber: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MechanismState {
    pub t: f64,
    pub pose: Pose,
    pub raw: RawJoints,
    pub turret_rad: f64,
    pub wrist_target_raw: f64,
    pub aim: bool,
    pub aim_source: AimSource,
    pub aim_target: FieldPoint,
    pub shooter: bool,
    pub rollers: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct WristSegment {
    t: f64,
    target: f64,
    rollers: bool,
    from: f64,
}

struct IntakeHold {
    t0: f64,
    t1: f64,
    target: f64,
    rollers: bool,
}

#[derive(Clone, Debug)]
pub struct AutoMechanisms {
    pub playback: Arc<AutoPlayback>,
    pub duration: f64,
    pub items: Vec<TimelineItem>,
    pub wrist_default: f64,
    pub wrist_rate: f64,
    pub rollers_default: bool,
    whole: [(f64, f64); 1],
    wrist: Vec<WristSegment>,
    aim_cmd: Vec<(f64, f64)>,
    shooter: Vec<(f64, f64)>,
}

impl AutoMechanisms {
    pub const INSTANT_S: f64 = 0.021;
    pub const AIM_BLEND_S: f64 = 0.4;
    /// Shown for an auto without a path: the Move Forward And Shoot Center start.
    pub const NO_PATH_POSE_BLUE: Pose = Pose::new(3.3705284, 4.0264605, 2.3561945);
    pub const CLIMBER_STOWED_RAW: f64 = 0.0;
    pub const WRIST_JOINT: &'static str = "index_wrist";
    pub const TURRET_JOINT: &'static str = "turret";
    pub const CLIMBER_JOINT: &'static str = "climber_inner";

    pub fn new(playback: Arc<AutoPlayback>, config: &AutoCommands) -> Self {
        let duration = playback.timeline_s();
        let setpoints = &config.wrist.setpoints_rot;
        let defaults = &config.intake_default_command;
        let wrist_default = setpoints.get(&defaults.wrist).copied().unwrap_or(0.0);
        let mut wrist_rate = f64::INFINITY;
        if !setpoints.is_empty() {
            let hi = setpoints
                .values()
                .copied()
                .fold(f64::NEG_INFINITY, f64::max);
            let lo = setpoints.values().copied().fold(f64::INFINITY, f64::min);
            let span = hi - lo;
            if span > 0.0 {
                wrist_rate = span / config.wrist.travel_s.max(1e-3);
            }
        }
        let mut m = AutoMechanisms {
            playback: playback.clone(),
            duration,
            items: Vec::new(),
            wrist_default,
            wrist_rate,
            rollers_default: defaults.rollers,
            whole: [(0.0, duration)],
            wrist: Vec::new(),
            aim_cmd: Vec::new(),
            shooter: Vec::new(),
        };
        let mut intake = Vec::new();
        for e in &playback.events {
            let effect = config.effect(&e.name);
            let t0 = e.t0.clamp(0.0, duration);
            let t1 = e.t1.clamp(t0, duration);
            let runs = runs(e);
            m.items.push(TimelineItem {
                name: e.name.clone(),
                t0,
                t1,
                kind: kind(e, &effect),
                runs,
                instant: e.t1 - e.t0 <= Self::INSTANT_S,
                note: note(e, runs),
            });
            if !runs {
                continue;
            }
            if effect.aim {
                m.aim_cmd.push((t0, t1));
            }
            if effect.shooter {
                m.shooter.push((t0, t1));
            }
            if let Some(w) = &effect.wrist {
                intake.push(IntakeHold {
                    t0,
                    t1,
                    target: setpoints.get(w).copied().unwrap_or(wrist_default),
                    rollers: effect.rollers.unwrap_or(false),
                });
            }
        }
        m.aim_cmd = merge(std::mem::take(&mut m.aim_cmd));
        m.shooter = merge(std::mem::take(&mut m.shooter));
        m.build_wrist(&intake);
        m
    }

    fn build_wrist(&mut self, intake: &[IntakeHold]) {
        let mut cuts = vec![0.0];
        for e in intake {
            cuts.push(e.t0);
            cuts.push(e.t1);
        }
        cuts.sort_by(f64::total_cmp);
        for c in cuts {
            let mut holder: Option<&IntakeHold> = None;
            for e in intake {
                if e.t0 <= c && c < e.t1 && holder.is_none_or(|h| e.t0 >= h.t0) {
                    holder = Some(e);
                }
            }
            let target = holder.map_or(self.wrist_default, |h| h.target);
            let rollers = holder.map_or(self.rollers_default, |h| h.rollers);
            if self
                .wrist
                .last()
                .is_some_and(|b| b.target == target && b.rollers == rollers)
            {
                continue;
            }
            if self.wrist.last().is_some_and(|b| b.t == c) {
                self.wrist.pop();
            }
            let from = self
                .wrist
                .last()
                .map_or(self.wrist_default, |b| self.ease_wrist(b, c));
            self.wrist.push(WristSegment {
                t: c,
                target,
                rollers,
                from,
            });
        }
    }

    fn ease_wrist(&self, seg: &WristSegment, t: f64) -> f64 {
        let travel = (seg.target - seg.from).abs() / self.wrist_rate;
        if travel <= 0.0 {
            return seg.target;
        }
        lerp(
            seg.from,
            seg.target,
            smoothstep(0.0, 1.0, (t - seg.t) / travel),
        )
    }

    fn wrist_segment(&self, t: f64) -> &WristSegment {
        let mut seg = &self.wrist[0];
        for s in &self.wrist {
            if s.t > t {
                break;
            }
            seg = s;
        }
        seg
    }

    pub fn wrist_raw(&self, t: f64) -> f64 {
        self.ease_wrist(self.wrist_segment(t), t)
    }

    pub fn wrist_target_raw(&self, t: f64) -> f64 {
        self.wrist_segment(t).target
    }

    pub fn rollers_on(&self, t: f64) -> bool {
        self.wrist_segment(t).rollers
    }

    pub fn shooter_on(&self, t: f64) -> bool {
        inside(&self.shooter, t, self.duration)
    }

    pub fn aim_command_on(&self, t: f64) -> bool {
        inside(&self.aim_cmd, t, self.duration)
    }

    fn aim_intervals(&self, gps_assist: bool) -> &[(f64, f64)] {
        if gps_assist {
            &self.whole
        } else {
            &self.aim_cmd
        }
    }

    pub fn no_path_pose(alliance: Alliance) -> Pose {
        match alliance {
            Alliance::Red => Self::NO_PATH_POSE_BLUE.flipped(),
            Alliance::Blue => Self::NO_PATH_POSE_BLUE,
        }
    }

    pub fn pose_at(&self, t: f64, alliance: Alliance) -> Pose {
        self.playback
            .sample_pose(t, alliance)
            .unwrap_or_else(|| Self::no_path_pose(alliance))
    }

    pub fn aim_target(&self, t: f64, alliance: Alliance) -> FieldPoint {
        aim_point::target(self.pose_at(t, alliance).point(), alliance.is_red())
    }

    pub fn aim_angle(&self, t: f64, alliance: Alliance) -> f64 {
        aim_point::turret_angle(self.pose_at(t, alliance), self.aim_target(t, alliance))
    }

    /// Chassis-relative CCW radians.
    pub fn turret_angle(&self, t: f64, alliance: Alliance, gps_assist: bool) -> f64 {
        let mut last_end: Option<f64> = None;
        for &(a, b) in self.aim_intervals(gps_assist) {
            if t >= a && (t < b || (b >= self.duration && t <= self.duration)) {
                let th = self.aim_angle(t, alliance);
                if a <= 0.0 {
                    return th;
                }
                return lerp_angle(0.0, th, smoothstep(0.0, Self::AIM_BLEND_S, t - a));
            }
            if b <= t {
                last_end = Some(b);
            }
        }
        match last_end {
            None => 0.0,
            Some(end) => lerp_angle(
                self.aim_angle(end, alliance),
                0.0,
                smoothstep(0.0, Self::AIM_BLEND_S, t - end),
            ),
        }
    }

    pub fn state_at(&self, t: f64, alliance: Alliance, gps_assist: bool) -> MechanismState {
        let t = t.clamp(0.0, self.duration);
        let turret = self.turret_angle(t, alliance, gps_assist);
        let aim = inside(self.aim_intervals(gps_assist), t, self.duration);
        let aim_source = match (aim, self.aim_command_on(t)) {
            (false, _) => AimSource::None,
            (true, true) => AimSource::Command,
            (true, false) => AimSource::Default,
        };
        MechanismState {
            t,
            pose: self.pose_at(t, alliance),
            raw: RawJoints {
                wrist: self.wrist_raw(t),
                turret: turret / TAU,
                climber: Self::CLIMBER_STOWED_RAW,
            },
            turret_rad: turret,
            wrist_target_raw: self.wrist_target_raw(t),
            aim,
            aim_source,
            aim_target: self.aim_target(t, alliance),
            shooter: self.shooter_on(t),
            rollers: self.rollers_on(t),
        }
    }

    /// Items whose start lies in (t_from, t_to], for the event feed.
    pub fn items_started(&self, t_from: f64, t_to: f64) -> Vec<&TimelineItem> {
        self.items
            .iter()
            .filter(|it| it.t0 > t_from && it.t0 <= t_to)
            .collect()
    }
}

fn runs(e: &AutoEvent) -> bool {
    match e.kind.as_str() {
        "command" => e.registered,
        "marker" | "zone_marker" => e.trigger_bound && e.registered,
        _ => false,
    }
}

fn kind(e: &AutoEvent, effect: &CommandEffect) -> ItemKind {
    if e.kind == "noop" || !e.registered {
        ItemKind::Noop
    } else if effect.aim {
        ItemKind::Aim
    } else if effect.shooter {
        ItemKind::Shooter
    } else if effect.wrist.is_some() || effect.rollers.is_some() {
        ItemKind::Intake
    } else {
        ItemKind::Other
    }
}

fn note(e: &AutoEvent, runs: bool) -> &'static str {
    if runs {
        ""
    } else if e.kind.ends_with("marker") {
        "marker only, nothing bound on robot"
    } else {
        "no-op on robot"
    }
}

fn merge(mut intervals: Vec<(f64, f64)>) -> Vec<(f64, f64)> {
    intervals.sort_by(|a, b| a.0.total_cmp(&b.0));
    let mut out: Vec<(f64, f64)> = Vec::new();
    for (a, b) in intervals {
        match out.last_mut() {
            Some(last) if a <= last.1 => last.1 = last.1.max(b),
            _ => out.push((a, b)),
        }
    }
    out
}

fn inside(intervals: &[(f64, f64)], t: f64, end: f64) -> bool {
    intervals
        .iter()
        .any(|&(a, b)| t >= a && (t < b || (b >= end && t <= end)))
}
