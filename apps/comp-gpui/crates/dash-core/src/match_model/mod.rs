//! Typed view of `/matchhud/state/*` plus the lane-alignment signal, fed one
//! value at a time ([`MatchModel::ingest`]) and stepped once per frame. No
//! NT access, so it runs under a fake clock in tests. Ports Godot's
//! `core/match/*`.

mod clock;
mod countdown;
mod enums;
mod lane_toast;
pub mod time_format;

pub use clock::Clock;
pub use countdown::{Countdown, EXTRAPOLATE_CAP_S, HOLD_AFTER_SEQ};
pub use enums::{Aim, Header, Hub, Phase};
pub use lane_toast::{DURATION_S as TOAST_DURATION_S, LaneToast};

use crate::request_state::Value;

pub const MATCH_STATE_PREFIX: &str = "/matchhud/state/";
pub const LANE_TOPIC: &str = "/AdvantageKit/RealOutputs/SwerveSubsystem/AdjustingVelocity";
/// The key [`MatchModel::ingest`] takes for [`LANE_TOPIC`].
pub const LANE_KEY: &str = "lane_alignment";

/// Every `/matchhud/state/*` topic the robot publishes
/// (MatchStatusSubsystem.java) with its NT type.
pub const MATCH_STATE_KEYS: &[(&str, &str)] = &[
    ("seq", "int"),
    ("robot_time_us", "int"),
    ("connected", "boolean"),
    ("is_red_alliance", "boolean"),
    ("enabled", "boolean"),
    ("autonomous", "boolean"),
    ("game_specific_message", "string"),
    ("match_phase", "int"),
    ("hub_status", "int"),
    ("header_color", "int"),
    ("total_time_remaining_s", "double"),
    ("period_time_remaining_s", "double"),
    ("shift_time_remaining_s", "double"),
    ("shift_time_with_buffer_s", "double"),
    ("buffer_remaining_s", "double"),
    ("is_shooting", "boolean"),
    ("show_shift_indicator", "boolean"),
    ("show_buffer", "boolean"),
    ("robot_pose_x_m", "double"),
    ("robot_pose_y_m", "double"),
    ("robot_heading_rad", "double"),
    ("robot_pose_valid", "boolean"),
    ("auto_align_active", "boolean"),
    ("auto_align_distance_m", "double"),
    ("auto_align_ready", "boolean"),
    ("driver_override", "boolean"),
    ("aim_mode", "int"),
    ("camera_topic", "string"),
];

pub fn match_topic(key: &str) -> String {
    format!("{MATCH_STATE_PREFIX}{key}")
}

pub const STALE_AFTER_US: i64 = 1_000_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CountdownKey {
    Total,
    Period,
    Shift,
    ShiftWithBuffer,
    Buffer,
}

impl CountdownKey {
    pub const ALL: [CountdownKey; 5] = [
        CountdownKey::Total,
        CountdownKey::Period,
        CountdownKey::Shift,
        CountdownKey::ShiftWithBuffer,
        CountdownKey::Buffer,
    ];

    pub fn key(self) -> &'static str {
        match self {
            CountdownKey::Total => "total_time_remaining_s",
            CountdownKey::Period => "period_time_remaining_s",
            CountdownKey::Shift => "shift_time_remaining_s",
            CountdownKey::ShiftWithBuffer => "shift_time_with_buffer_s",
            CountdownKey::Buffer => "buffer_remaining_s",
        }
    }

    pub fn from_key(key: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|k| k.key() == key)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Banner {
    None,
    Disconnected,
    NoData,
    Stale,
}

impl Banner {
    /// ConnectionLost.tsx's texts.
    pub fn text(self) -> &'static str {
        match self {
            Banner::None => "",
            Banner::Disconnected => "NT Disconnected",
            Banner::NoData => "No Robot Data",
            Banner::Stale => "Robot Data Stale",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum MatchEvent {
    PhaseChanged(Phase),
    LinkChanged(bool),
    ToastFired(bool),
}

/// The shift indicator's numbers as ShiftIndicator.tsx picks them.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ShiftDisplay {
    pub main: f64,
    /// The "with buffer" line, when shown.
    pub buffer: Option<f64>,
}

#[derive(Clone, Debug)]
pub struct MatchModel {
    pub nt_ready: bool,
    pub seq: i64,
    pub connected_flag: bool,
    pub phase: Phase,
    pub hub: Hub,
    pub header: Header,
    pub aim: Aim,
    pub show_shift_indicator: bool,
    pub show_buffer: bool,
    /// None until the robot publishes it.
    pub is_red_alliance: Option<bool>,
    /// None until the robot publishes it; only an explicit false is invalid.
    pub pose_valid: Option<bool>,
    countdowns: [Countdown; 5],
    pub toast: LaneToast,
    fresh_seq: bool,
    fresh_connected: bool,
    last_seq_change_us: i64,
    link_ok: bool,
    now_us: i64,
}

impl Default for MatchModel {
    fn default() -> Self {
        Self::new()
    }
}

impl MatchModel {
    pub fn new() -> Self {
        Self {
            nt_ready: false,
            seq: 0,
            connected_flag: false,
            phase: Phase::PreMatch,
            hub: Hub::None,
            header: Header::Hidden,
            aim: Aim::ShooterDisabled,
            show_shift_indicator: false,
            show_buffer: false,
            is_red_alliance: None,
            pose_valid: None,
            countdowns: Default::default(),
            toast: LaneToast::default(),
            fresh_seq: false,
            fresh_connected: false,
            last_seq_change_us: 0,
            link_ok: false,
            now_us: 0,
        }
    }

    /// The NT connection came up or went down. Values from a previous
    /// connection no longer count as robot data.
    pub fn set_nt_ready(&mut self, ready: bool, now_us: i64) -> Option<MatchEvent> {
        if ready == self.nt_ready {
            return None;
        }
        self.nt_ready = ready;
        self.fresh_seq = false;
        self.fresh_connected = false;
        if ready {
            self.last_seq_change_us = now_us;
        }
        self.step(now_us)
    }

    /// One value for a `/matchhud/state` key, or [`LANE_KEY`].
    pub fn ingest(&mut self, key: &str, v: &Value, now_us: i64) -> Option<MatchEvent> {
        let on = matches!(v, Value::Bool(true));
        match key {
            "seq" => {
                self.fresh_seq = true;
                let s = match *v {
                    Value::Int(i) => i,
                    Value::Double(d) if d.is_finite() => d as i64,
                    _ => 0,
                };
                if s != self.seq {
                    self.seq = s;
                    self.last_seq_change_us = now_us;
                    for c in &mut self.countdowns {
                        c.on_seq();
                    }
                }
            }
            "connected" => {
                self.fresh_connected = true;
                self.connected_flag = on;
            }
            "match_phase" => {
                let p = Phase::from_value(v);
                if p != self.phase {
                    self.phase = p;
                    if p == Phase::PreMatch {
                        self.toast.reset();
                    }
                    return Some(MatchEvent::PhaseChanged(p));
                }
            }
            "hub_status" => self.hub = Hub::from_value(v),
            "header_color" => self.header = Header::from_value(v),
            "aim_mode" => self.aim = Aim::from_value(v),
            "show_shift_indicator" => self.show_shift_indicator = on,
            "show_buffer" => self.show_buffer = on,
            "is_red_alliance" => self.is_red_alliance = Some(on),
            "robot_pose_valid" => self.pose_valid = Some(on),
            LANE_KEY => {
                if self.toast.observe(on, now_us) {
                    return Some(MatchEvent::ToastFired(on));
                }
            }
            _ => {
                let f = match *v {
                    Value::Int(i) => i as f64,
                    Value::Double(d) => d,
                    _ => return None,
                };
                if let Some(k) = CountdownKey::from_key(key) {
                    self.countdowns[k as usize].update(f, now_us);
                }
            }
        }
        None
    }

    /// Robot data arrived on this connection: seq > 0 or the DS-attached flag.
    pub fn has_data(&self) -> bool {
        (self.fresh_seq && self.seq > 0) || (self.fresh_connected && self.connected_flag)
    }

    pub fn connected(&self) -> bool {
        self.nt_ready && self.has_data()
    }

    /// As of the last [`step`](Self::step).
    pub fn stale(&self) -> bool {
        self.stale_at(self.now_us)
    }

    pub fn stale_at(&self, now_us: i64) -> bool {
        self.connected() && now_us - self.last_seq_change_us >= STALE_AFTER_US
    }

    pub fn last_seq_change_us(&self) -> i64 {
        self.last_seq_change_us
    }

    pub fn link_ok(&self) -> bool {
        self.link_ok
    }

    pub fn banner(&self) -> Banner {
        if !self.nt_ready {
            Banner::Disconnected
        } else if !self.has_data() {
            Banner::NoData
        } else if self.stale() {
            Banner::Stale
        } else {
            Banner::None
        }
    }

    pub fn step(&mut self, now_us: i64) -> Option<MatchEvent> {
        self.now_us = now_us;
        let ok = self.connected() && !self.stale_at(now_us);
        if ok == self.link_ok {
            return None;
        }
        self.link_ok = ok;
        if !ok {
            for c in &mut self.countdowns {
                c.on_link_lost();
            }
        }
        Some(MatchEvent::LinkChanged(ok))
    }

    pub fn countdown(&self, key: CountdownKey, now_us: i64) -> f64 {
        self.countdowns[key as usize].display(now_us, self.link_ok)
    }

    pub fn countdown_state(&self, key: CountdownKey) -> &Countdown {
        &self.countdowns[key as usize]
    }

    pub fn total_display(&self, now_us: i64) -> f64 {
        self.countdown(CountdownKey::Total, now_us)
    }

    pub fn select_shift(
        p: Phase,
        h: Hub,
        period: f64,
        shift: f64,
        with_buffer: f64,
        buffer_rem: f64,
        buffer_shown: bool,
    ) -> ShiftDisplay {
        let main = if p.is_both_hub_period() {
            period.max(0.0)
        } else if h == Hub::Warning {
            0.0
        } else {
            shift.max(0.0)
        };
        let buffer = buffer_shown.then(|| {
            if h == Hub::Warning {
                buffer_rem
            } else {
                with_buffer
            }
            .max(0.0)
        });
        ShiftDisplay { main, buffer }
    }

    pub fn shift_display(&self, now_us: i64) -> ShiftDisplay {
        let c = |k| self.countdown(k, now_us);
        Self::select_shift(
            self.phase,
            self.hub,
            c(CountdownKey::Period),
            c(CountdownKey::Shift),
            c(CountdownKey::ShiftWithBuffer),
            c(CountdownKey::Buffer),
            self.show_buffer,
        )
    }

    /// Dim the robot when its pose is not current: the robot says so, or no
    /// live data.
    pub fn pose_trusted(&self) -> bool {
        self.pose_valid != Some(false) && self.link_ok
    }
}

#[cfg(test)]
mod tests;
