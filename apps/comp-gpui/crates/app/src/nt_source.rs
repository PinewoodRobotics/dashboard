//! Live robot data: fills the `MockData` groups from NetworkTables instead of
//! the demo (`--nt-host` / `--nt-port`). Screens keep reading `MockData`.
//!
//! Optional fields follow Godot's readers: joints, readouts, alliance, the
//! PathPlanner topics and the Request/State echoes are `None` unless live on
//! the current connection; the deploy hash and the pose keep their last value.
//! Screens that write a `RequestEcho::request` get it published as a
//! desired-state value (`None` stops re-sending it).

use std::collections::HashMap;
use std::time::Instant;

use dash_core::nt::protocol::NtValue;
use dash_core::nt::{self, Clock, NtService, topics};

use crate::mock::{
    AimMode, AutoAlign, HeaderColor, HubStatus, Joints, LaneSignal, LaneToast, LinkBanner,
    MatchPhase, MatchState, MockData, PathPlannerTopics, RobotPose, ShooterReadouts,
};

const STALE_AFTER_US: i64 = 1_000_000;
const EXTRAPOLATE_CAP_S: f64 = 0.1;
const HOLD_AFTER_SEQ: u32 = 2;
const COUNTDOWN_KEYS: [&str; 5] = [
    "total_time_remaining_s",
    "period_time_remaining_s",
    "shift_time_remaining_s",
    "shift_time_with_buffer_s",
    "buffer_remaining_s",
];

/// core/match/countdown.gd: re-anchors on every update, extrapolates at
/// most 0.1 s while the link is up, and shows a value the robot holds
/// (unchanged for two seq steps) exactly.
#[derive(Clone, Debug, Default)]
struct Countdown {
    value: f64,
    has_value: bool,
    anchor_us: i64,
    seq_since_anchor: u32,
    held_at_link_loss: bool,
}

impl Countdown {
    fn update(&mut self, v: f64, now_us: i64) {
        self.value = v;
        self.has_value = true;
        self.anchor_us = now_us;
        self.seq_since_anchor = 0;
    }

    fn on_seq(&mut self) {
        if self.has_value {
            self.seq_since_anchor += 1;
        }
    }

    fn held(&self) -> bool {
        self.seq_since_anchor >= HOLD_AFTER_SEQ
    }

    fn on_link_lost(&mut self) {
        self.held_at_link_loss = self.held();
    }

    fn running(&self, link_ok: bool) -> bool {
        self.has_value && !if link_ok { self.held() } else { self.held_at_link_loss }
    }

    fn display(&self, now_us: i64, link_ok: bool) -> f64 {
        if !self.has_value {
            return 0.0;
        }
        let elapsed = ((now_us - self.anchor_us) as f64 / 1e6).max(0.0);
        let shown = if link_ok {
            if self.held() {
                self.value
            } else {
                self.value - elapsed.min(EXTRAPOLATE_CAP_S)
            }
        } else if self.held_at_link_loss {
            self.value
        } else {
            self.value - elapsed
        };
        shown.max(0.0)
    }
}

/// The banner half of core/match/match_model.gd.
#[derive(Clone, Debug, Default)]
struct Link {
    nt_ready: bool,
    seq: i64,
    seq_fresh: bool,
    connected_flag: bool,
    connected_fresh: bool,
    last_seq_change_us: i64,
}

impl Link {
    fn set_nt_ready(&mut self, ready: bool, now_us: i64) {
        if ready == self.nt_ready {
            return;
        }
        self.nt_ready = ready;
        self.seq_fresh = false;
        self.connected_fresh = false;
        if ready {
            self.last_seq_change_us = now_us;
        }
    }

    /// Returns whether seq changed.
    fn on_seq(&mut self, s: i64, now_us: i64) -> bool {
        self.seq_fresh = true;
        if s == self.seq {
            return false;
        }
        self.seq = s;
        self.last_seq_change_us = now_us;
        true
    }

    fn on_connected(&mut self, c: bool) {
        self.connected_fresh = true;
        self.connected_flag = c;
    }

    fn has_data(&self) -> bool {
        (self.seq_fresh && self.seq > 0) || (self.connected_fresh && self.connected_flag)
    }

    fn stale(&self, now_us: i64) -> bool {
        self.nt_ready && self.has_data() && now_us - self.last_seq_change_us >= STALE_AFTER_US
    }

    fn banner(&self, now_us: i64) -> LinkBanner {
        if !self.nt_ready {
            LinkBanner::Disconnected
        } else if !self.has_data() {
            LinkBanner::NoData
        } else if self.stale(now_us) {
            LinkBanner::Stale
        } else {
            LinkBanner::None
        }
    }
}

/// core/match/lane_toast.gd: the first value after start, or after the
/// match returns to pre-match, is stored silently; every change after that
/// fires.
#[derive(Clone, Debug, Default)]
struct LaneEdge {
    last: Option<bool>,
}

impl LaneEdge {
    fn observe(&mut self, v: bool) -> bool {
        let fired = self.last.is_some_and(|l| l != v);
        self.last = Some(v);
        fired
    }

    fn reset(&mut self) {
        self.last = None;
    }
}

trait TopicView {
    fn get(&self, topic: &str) -> Option<&NtValue>;
    fn live(&self, topic: &str) -> bool;

    fn live_value(&self, topic: &str) -> Option<&NtValue> {
        self.live(topic).then(|| self.get(topic)).flatten()
    }
    fn live_f64(&self, topic: &str) -> Option<f64> {
        self.live_value(topic).and_then(NtValue::as_f64)
    }
    fn live_bool(&self, topic: &str) -> Option<bool> {
        self.live_value(topic).and_then(NtValue::as_bool)
    }
    fn live_string(&self, topic: &str) -> Option<String> {
        self.live_value(topic).and_then(|v| v.as_str().map(str::to_owned))
    }
}

impl TopicView for NtService {
    fn get(&self, topic: &str) -> Option<&NtValue> {
        NtService::get(self, topic)
    }
    fn live(&self, topic: &str) -> bool {
        self.is_live(topic)
    }
}

fn index<T: Copy>(v: Option<&NtValue>, all: &[T]) -> T {
    v.and_then(NtValue::as_i64)
        .and_then(|i| usize::try_from(i).ok())
        .and_then(|i| all.get(i).copied())
        .unwrap_or(all[0])
}

const PHASES: [MatchPhase; 9] = [
    MatchPhase::PreMatch,
    MatchPhase::Autonomous,
    MatchPhase::Transition,
    MatchPhase::Shift1,
    MatchPhase::Shift2,
    MatchPhase::Shift3,
    MatchPhase::Shift4,
    MatchPhase::Endgame,
    MatchPhase::PostMatch,
];
const HUBS: [HubStatus; 5] = [
    HubStatus::None,
    HubStatus::Both,
    HubStatus::Active,
    HubStatus::Warning,
    HubStatus::Inactive,
];
const HEADERS: [HeaderColor; 4] = [
    HeaderColor::Hidden,
    HeaderColor::Green,
    HeaderColor::Yellow,
    HeaderColor::Purple,
];
const AIMS: [AimMode; 3] = [AimMode::ShooterDisabled, AimMode::GpsAuto, AimMode::ManualAiming];

/// Copies every topic-backed field from the cache. Countdowns, the banner
/// and the lane toast are left to the stateful parts of [`NtSource`].
fn refresh(data: &mut MockData, v: &impl TopicView) {
    let m = |k: &str| topics::match_topic(k);
    let b = |k: &str| v.get(&m(k)).and_then(NtValue::as_bool).unwrap_or(false);
    let f = |k: &str, old: f64| v.get(&m(k)).and_then(NtValue::as_f64).unwrap_or(old);
    let s = &mut data.matchs;
    s.seq = v.get(&m("seq")).and_then(NtValue::as_i64).unwrap_or(0);
    s.robot_time_us = v.get(&m("robot_time_us")).and_then(NtValue::as_i64).unwrap_or(0);
    s.robot_connected = b("connected");
    s.enabled = b("enabled");
    s.autonomous = b("autonomous");
    s.is_shooting = b("is_shooting");
    s.show_shift_indicator = b("show_shift_indicator");
    s.show_buffer = b("show_buffer");
    s.game_specific_message = v
        .get(&m("game_specific_message"))
        .and_then(NtValue::as_str)
        .unwrap_or_default()
        .to_owned();
    s.phase = index(v.get(&m("match_phase")), &PHASES);
    s.hub = index(v.get(&m("hub_status")), &HUBS);
    s.header = index(v.get(&m("header_color")), &HEADERS);
    s.aim = index(v.get(&m("aim_mode")), &AIMS);
    s.is_red_alliance = v.live_bool(&m("is_red_alliance"));

    let p = &data.pose;
    data.pose = RobotPose {
        x_m: f("robot_pose_x_m", p.x_m),
        y_m: f("robot_pose_y_m", p.y_m),
        heading_rad: f("robot_heading_rad", p.heading_rad),
        valid: v.get(&m("robot_pose_valid")).and_then(NtValue::as_bool) != Some(false)
            && v.get(&m("robot_pose_x_m")).is_some(),
    };
    data.align = AutoAlign {
        active: b("auto_align_active"),
        distance_m: f("auto_align_distance_m", 0.0),
        ready: b("auto_align_ready"),
        driver_override: b("driver_override"),
        camera_topic: v
            .get(&m("camera_topic"))
            .and_then(NtValue::as_str)
            .filter(|t| !t.is_empty())
            .map(str::to_owned),
    };
    data.joints = Joints {
        wrist: v.live_f64(topics::JOINT_WRIST),
        turret_rot: v.live_f64(topics::JOINT_TURRET),
        climber_height_m: v.live_f64(topics::JOINT_CLIMBER),
    };
    data.readouts = ShooterReadouts {
        distance_to_target_m: v.live_f64(topics::READOUT_DISTANCE),
        requested_rpm: v.live_f64(topics::READOUT_REQUESTED_RPM),
        velocity_rpm: v.live_f64(topics::READOUT_VELOCITY_RPM),
        leader_rpm: v.live_f64(topics::READOUT_LEADER_RPM),
        follower_rpm: v.live_f64(topics::READOUT_FOLLOWER_RPM),
        turret_position_deg: v.live_f64(topics::READOUT_TURRET_DEG),
        turret_angle: v.live_f64(topics::READOUT_TURRET_ANGLE),
        is_spun_up: v.live_bool(topics::READOUT_SPUN_UP),
        gps_assist_enabled: v.live_bool(topics::READOUT_GPS_ASSIST),
        is_shooting: v.live_bool(topics::READOUT_IS_SHOOTING),
    };
    data.lane = LaneSignal {
        adjusting_velocity: v.live_bool(topics::LANE_ADJUSTING_VELOCITY),
    };
    data.pathplanner = PathPlannerTopics {
        current_selected_auto: v.live_string(topics::PP_CURRENT_SELECTED_AUTO),
        selected_auto_valid: v.live_bool(topics::PP_SELECTED_AUTO_VALID),
        valid_autos: v
            .live_value(topics::PP_VALID_AUTOS)
            .and_then(|x| x.as_string_array().map(<[String]>::to_vec)),
        deploy_hash: v
            .get(topics::PP_DEPLOY_HASH)
            .and_then(NtValue::as_str)
            .map(str::to_owned),
    };
    let auto = &mut data.auto_selection.link;
    auto.state = v.live_string(&auto.topics.state);
    let intake = &mut data.controls.intake;
    intake.state = v.live_f64(&intake.topics.state);
    let trim = &mut data.controls.aim_trim;
    trim.state = v.live_f64(&trim.topics.state);
}

/// The topic-backed fields as they are before anything arrives.
fn blank(data: &mut MockData, now: Instant) {
    data.demo = false;
    data.nt_connected = false;
    data.banner = LinkBanner::Disconnected;
    data.lane_toast = None;
    data.matchs = MatchState {
        seq: 0,
        robot_time_us: 0,
        robot_connected: false,
        game_specific_message: String::new(),
        is_red_alliance: None,
        enabled: false,
        ..MatchState::seed(now)
    };
    data.pose = RobotPose {
        x_m: 0.0,
        y_m: 0.0,
        heading_rad: 0.0,
        valid: false,
    };
    data.align = AutoAlign::seed();
    data.joints = Joints {
        wrist: None,
        turret_rot: None,
        climber_height_m: None,
    };
    data.readouts = ShooterReadouts {
        distance_to_target_m: None,
        requested_rpm: None,
        velocity_rpm: None,
        leader_rpm: None,
        follower_rpm: None,
        turret_position_deg: None,
        turret_angle: None,
        is_spun_up: None,
        gps_assist_enabled: None,
        is_shooting: None,
    };
    data.lane = LaneSignal {
        adjusting_velocity: None,
    };
    data.pathplanner = PathPlannerTopics {
        current_selected_auto: None,
        selected_auto_valid: None,
        valid_autos: None,
        deploy_hash: None,
    };
    data.auto_selection.link.state = None;
    data.auto_selection.link.request = None;
    data.controls.intake.state = None;
    data.controls.intake.request = None;
    data.controls.aim_trim.state = None;
    data.controls.aim_trim.request = None;
    data.nt.state = "IDLE";
    data.nt.rtt_ms = None;
    data.nt.attempt = 0;
    data.nt.reconnects = 0;
}

/// One Request topic the screens drive through `RequestEcho::request`.
#[derive(Default)]
struct Outgoing {
    topic: String,
    value: Option<NtValue>,
}

impl Outgoing {
    fn sync(&mut self, nt: &mut NtService, topic: &str, type_str: &str, value: Option<NtValue>) {
        if topic != self.topic {
            if !self.topic.is_empty() {
                dash_core::request_state::ControlLink::release(nt, &self.topic);
            }
            self.topic = topic.into();
            self.value = None;
        }
        if value == self.value {
            return;
        }
        match &value {
            Some(v) => {
                nt.publish_value(topic, type_str, v.clone());
            }
            None => dash_core::request_state::ControlLink::forget(nt, topic),
        }
        self.value = value;
    }
}

pub struct NtSource {
    nt: NtService,
    clock: Clock,
    host_override: Option<String>,
    port_override: Option<u16>,
    configured: Option<(String, u16, f64)>,
    subscribed: Option<(String, String)>,
    link: Link,
    link_ok: bool,
    countdowns: HashMap<&'static str, Countdown>,
    lane: LaneEdge,
    reconnects_shown: u32,
    requests: [Outgoing; 3],
}

impl NtSource {
    /// Clears the demo values and starts connecting. Overrides win over the
    /// saved connection settings, as Godot's `--nt-host` / `--nt-port` do.
    pub fn start(data: &mut MockData, host_override: Option<String>, port_override: Option<u16>) -> Self {
        blank(data, Instant::now());
        let mut src = Self {
            nt: nt::spawn(Clock::real()),
            clock: Clock::real(),
            host_override,
            port_override,
            configured: None,
            subscribed: None,
            link: Link::default(),
            link_ok: false,
            countdowns: COUNTDOWN_KEYS.iter().map(|k| (*k, Countdown::default())).collect(),
            lane: LaneEdge::default(),
            reconnects_shown: 0,
            requests: Default::default(),
        };
        src.sync_settings(data);
        src.nt.start();
        src
    }

    fn sync_settings(&mut self, data: &mut MockData) {
        let c = &data.connection;
        let host = self.host_override.clone().unwrap_or_else(|| c.nt_host.trim().to_owned());
        let port = self
            .port_override
            .or_else(|| c.nt_port.trim().parse().ok())
            .unwrap_or(5810);
        let want = (host, port, f64::from(c.reconnect_timeout_s));
        if self.configured.as_ref() != Some(&want) {
            self.nt.configure(&want.0, want.1, want.2);
            self.configured = Some(want);
        }
        let subs = (
            data.auto_selection.link.topics.state.clone(),
            data.controls.intake.topics.state.clone(),
        );
        if self.subscribed.as_ref() != Some(&subs) {
            self.nt.set_subscriptions(topics::subscription_groups(&subs.0, &subs.1));
            self.subscribed = Some(subs);
        }
        // The Settings tab's Reconnect button bumps the shown count; any
        // difference from what was last written here is a manual press.
        if data.nt.reconnects != self.reconnects_shown {
            self.nt.reconnect();
            data.nt.reconnects = self.reconnects_shown;
        }
    }

    fn sync_requests(&mut self, data: &MockData) {
        let a = &data.auto_selection.link;
        let i = &data.controls.intake;
        let t = &data.controls.aim_trim;
        let [ra, ri, rt] = &mut self.requests;
        ra.sync(&mut self.nt, &a.topics.request, "string", a.request.clone().map(NtValue::String));
        ri.sync(&mut self.nt, &i.topics.request, "double", i.request.map(NtValue::Double));
        rt.sync(&mut self.nt, &t.topics.request, "double", t.request.map(NtValue::Double));
    }

    /// Applies what arrived since the last call. Returns whether a screen
    /// needs to redraw.
    pub fn tick(&mut self, data: &mut MockData) -> bool {
        self.sync_settings(data);
        self.sync_requests(data);
        let now = Instant::now();
        let now_us = self.clock.now_us();
        let pumped = self.nt.pump(now_us);
        let mut changed = !pumped.is_empty();
        if let Some(ready) = pumped.connection {
            self.link.set_nt_ready(ready, now_us);
        }
        let mut toast = None;
        for v in &pumped.values {
            let Some(key) = v.name.strip_prefix(topics::MATCH_STATE_PREFIX) else {
                if &*v.name == topics::LANE_ADJUSTING_VELOCITY
                    && let Some(on) = v.value.as_bool()
                    && self.lane.observe(on)
                {
                    toast = Some(on);
                }
                continue;
            };
            match key {
                "seq" => {
                    if let Some(s) = v.value.as_i64()
                        && self.link.on_seq(s, now_us)
                    {
                        self.countdowns.values_mut().for_each(Countdown::on_seq);
                    }
                }
                "connected" => self.link.on_connected(v.value.as_bool() == Some(true)),
                "match_phase" => {
                    let p = index(Some(&v.value), &PHASES);
                    if p != data.matchs.phase && p == MatchPhase::PreMatch {
                        self.lane.reset();
                    }
                    data.matchs.phase = p;
                }
                _ => {
                    if let Some(c) = self.countdowns.get_mut(key)
                        && let Some(x) = v.value.as_f64()
                    {
                        c.update(x, now_us);
                    }
                }
            }
        }
        if changed {
            refresh(data, &self.nt);
        }
        if let Some(on) = toast {
            data.lane_toast = Some(LaneToast { on, shown_at: now });
        }

        let banner = self.link.banner(now_us);
        let link_ok = banner == LinkBanner::None;
        if link_ok != self.link_ok {
            self.link_ok = link_ok;
            if !link_ok {
                self.countdowns.values_mut().for_each(Countdown::on_link_lost);
            }
            changed = true;
        }
        let nt_connected = self.nt.is_ready();
        if banner != data.banner || nt_connected != data.nt_connected {
            data.banner = banner;
            data.nt_connected = nt_connected;
            changed = true;
        }
        if changed {
            self.write_countdowns(&mut data.matchs, now, now_us);
        }
        changed |= self.write_diagnostics(data);
        changed
    }

    fn write_countdowns(&self, m: &mut MatchState, now: Instant, now_us: i64) {
        let show = |k: &str| self.countdowns[k].display(now_us, self.link_ok);
        m.total_time_remaining_s = show("total_time_remaining_s");
        m.period_time_remaining_s = show("period_time_remaining_s");
        m.shift_time_remaining_s = show("shift_time_remaining_s");
        m.shift_time_with_buffer_s = show("shift_time_with_buffer_s");
        m.buffer_remaining_s = show("buffer_remaining_s");
        m.sampled_at = now;
        m.frozen = !self.countdowns.values().any(|c| c.running(self.link_ok));
    }

    fn write_diagnostics(&mut self, data: &mut MockData) -> bool {
        let d = self.nt.diagnostics();
        let n = &mut data.nt;
        let server = format!("{}:{}", d.host, d.port);
        let rtt_ms = (d.state == nt::State::Ready && d.rtt_us >= 0).then(|| d.rtt_us as f32 / 1000.0);
        let changed = n.state != d.state.name()
            || n.server != server
            || n.rtt_ms != rtt_ms
            || n.reconnects != d.reconnects
            || n.attempt != d.attempt;
        n.state = d.state.name();
        n.server = server;
        n.rtt_ms = rtt_ms;
        n.reconnects = d.reconnects;
        n.attempt = d.attempt;
        self.reconnects_shown = d.reconnects;
        changed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct View {
        values: HashMap<String, NtValue>,
        live: bool,
    }

    impl TopicView for View {
        fn get(&self, topic: &str) -> Option<&NtValue> {
            self.values.get(topic)
        }
        fn live(&self, topic: &str) -> bool {
            self.live && self.values.contains_key(topic)
        }
    }

    #[test]
    fn countdown_extrapolates_then_holds() {
        let mut c = Countdown::default();
        assert_eq!(c.display(0, true), 0.0);
        c.update(10.0, 1_000_000);
        assert!((c.display(1_050_000, true) - 9.95).abs() < 1e-9);
        assert!((c.display(2_000_000, true) - 9.9).abs() < 1e-9, "capped at 0.1 s while linked");
        assert!(c.running(true));
        c.on_seq();
        c.on_seq();
        assert_eq!(c.display(5_000_000, true), 10.0, "held after two seq steps");
        assert!(!c.running(true));
        c.on_link_lost();
        assert_eq!(c.display(9_000_000, false), 10.0, "held value stays put without a link");
        c.update(10.0, 1_000_000);
        c.on_link_lost();
        assert!((c.display(4_000_000, false) - 7.0).abs() < 1e-9, "running value dead-reckons uncapped");
    }

    #[test]
    fn banner_follows_link_data_and_staleness() {
        let mut l = Link::default();
        assert_eq!(l.banner(0), LinkBanner::Disconnected);
        l.set_nt_ready(true, 0);
        assert_eq!(l.banner(0), LinkBanner::NoData);
        l.on_seq(5, 100);
        assert_eq!(l.banner(500_000), LinkBanner::None);
        assert_eq!(l.banner(1_000_100), LinkBanner::Stale);
        l.on_seq(6, 1_000_200);
        assert_eq!(l.banner(1_000_300), LinkBanner::None);
        l.set_nt_ready(false, 2_000_000);
        assert_eq!(l.banner(2_000_000), LinkBanner::Disconnected);
        l.set_nt_ready(true, 3_000_000);
        assert_eq!(l.banner(3_000_000), LinkBanner::NoData, "data must arrive on this connection");
        l.on_connected(true);
        assert_eq!(l.banner(3_000_000), LinkBanner::None, "the DS-attached flag counts as data");
    }

    #[test]
    fn lane_edge_skips_first_value() {
        let mut e = LaneEdge::default();
        assert!(!e.observe(true));
        assert!(!e.observe(true));
        assert!(e.observe(false));
        assert!(e.observe(true));
        e.reset();
        assert!(!e.observe(false));
    }

    #[test]
    fn request_writes_become_desired_state_publishes() {
        use dash_core::nt::runner::Command;
        let (tx, rx) = std::sync::mpsc::channel();
        let (_ev_tx, ev_rx) = std::sync::mpsc::channel();
        let mut nt = NtService::new(tx, ev_rx);
        let mut out = Outgoing::default();
        out.sync(&mut nt, "/a/Request", "double", None);
        out.sync(&mut nt, "/a/Request", "double", Some(NtValue::Double(0.4)));
        out.sync(&mut nt, "/a/Request", "double", Some(NtValue::Double(0.4)));
        out.sync(&mut nt, "/a/Request", "double", None);
        out.sync(&mut nt, "/b/Request", "double", Some(NtValue::Double(0.6)));
        let sent: Vec<Command> = rx.try_iter().collect();
        assert_eq!(
            sent,
            vec![
                Command::Publish {
                    topic: "/a/Request".into(),
                    type_str: "double".into(),
                    value: NtValue::Double(0.4)
                },
                Command::Forget { topic: "/a/Request".into() },
                Command::Release { topic: "/a/Request".into() },
                Command::Publish {
                    topic: "/b/Request".into(),
                    type_str: "double".into(),
                    value: NtValue::Double(0.6)
                },
            ]
        );
    }

    #[test]
    fn refresh_maps_topics_and_gates_on_liveness() {
        let mut data = MockData::new(crate::mock::Scenario::PreMatch);
        blank(&mut data, Instant::now());
        let mut v = View { live: true, ..Default::default() };
        let mut put = |k: &str, x: NtValue| {
            v.values.insert(k.into(), x);
        };
        put("/matchhud/state/seq", NtValue::Int(42));
        put("/matchhud/state/match_phase", NtValue::Int(4));
        put("/matchhud/state/hub_status", NtValue::Int(3));
        put("/matchhud/state/header_color", NtValue::Int(9));
        put("/matchhud/state/aim_mode", NtValue::Int(2));
        put("/matchhud/state/is_red_alliance", NtValue::Bool(true));
        put("/matchhud/state/robot_pose_x_m", NtValue::Double(5.0));
        put("/matchhud/state/robot_pose_valid", NtValue::Bool(true));
        put(topics::JOINT_WRIST, NtValue::Double(0.25));
        put(topics::JOINT_TURRET, NtValue::Double(f64::NAN));
        put(topics::READOUT_SPUN_UP, NtValue::Bool(true));
        put(topics::PP_VALID_AUTOS, NtValue::StringArray(vec!["A".into()]));
        put(topics::PP_DEPLOY_HASH, NtValue::String("abc".into()));
        put("/Shared/PathPlanner/SelectedPath/State", NtValue::String("A".into()));
        put("/Shared/Intake/Speed/State", NtValue::Double(0.5));
        refresh(&mut data, &v);
        assert_eq!(data.matchs.seq, 42);
        assert_eq!(data.matchs.phase, MatchPhase::Shift2);
        assert_eq!(data.matchs.hub, HubStatus::Warning);
        assert_eq!(data.matchs.header, HeaderColor::Hidden, "out of range maps to the first entry");
        assert_eq!(data.matchs.aim, AimMode::ManualAiming);
        assert_eq!(data.matchs.is_red_alliance, Some(true));
        assert!(data.pose.valid);
        assert_eq!(data.pose.x_m, 5.0);
        assert_eq!(data.joints.wrist, Some(0.25));
        assert_eq!(data.joints.turret_rot, None, "NaN is absent");
        assert_eq!(data.joints.climber_height_m, None);
        assert_eq!(data.readouts.is_spun_up, Some(true));
        assert_eq!(data.pathplanner.valid_autos, Some(vec!["A".to_string()]));
        assert_eq!(data.auto_selection.link.state.as_deref(), Some("A"));
        assert_eq!(data.controls.intake.state, Some(0.5));
        assert_eq!(data.controls.aim_trim.state, None);

        v.live = false;
        refresh(&mut data, &v);
        assert_eq!(data.joints.wrist, None, "joints fall back to manual when not live");
        assert_eq!(data.matchs.is_red_alliance, None);
        assert_eq!(data.auto_selection.link.state, None);
        assert_eq!(data.pathplanner.deploy_hash.as_deref(), Some("abc"), "deploy hash kept while stale");
        assert_eq!(data.pose.x_m, 5.0, "pose kept while stale");
        assert_eq!(data.matchs.seq, 42);
    }
}
