//! Live robot data: fills the `MockData` groups from NetworkTables instead of
//! the demo (`--nt-host` / `--nt-port`). Screens keep reading `MockData`.
//!
//! Optional fields follow Godot's readers: joints, readouts, alliance and the
//! PathPlanner topics are `None` unless live on the current connection; the
//! deploy hash and the pose keep their last value. The Request/State pairs
//! are not mirrored: the auto selection sync and the controls publish and
//! read them through [`NtLink`] directly.

use std::cell::{Ref, RefCell, RefMut};
use std::rc::Rc;

use dash_core::controls::intake_speed_topics;
use dash_core::match_model::{self, Aim, Header, Hub, LANE_KEY, Phase};
use dash_core::nt::protocol::NtValue;
use dash_core::nt::{self, Clock, NtService, topics};
use dash_core::request_state::Value;

use crate::match_feed::MatchFeed;
use crate::mock::{
    AutoAlign, Joints, LaneSignal, MatchState, MockData, PathPlannerTopics, RobotPose,
    ShooterReadouts,
};

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

fn robot_enum<T>(v: Option<&NtValue>, from_value: fn(&Value) -> T) -> T {
    from_value(&v.and_then(NtValue::to_control_value).unwrap_or(Value::Int(-1)))
}

/// Copies every topic-backed field from the cache. The HUD reads countdowns,
/// the banner and the lane toast from the match model, which [`NtSource`]
/// feeds separately.
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
    s.phase = robot_enum(v.get(&m("match_phase")), Phase::from_value);
    s.hub = robot_enum(v.get(&m("hub_status")), Hub::from_value);
    s.header = robot_enum(v.get(&m("header_color")), Header::from_value);
    s.aim = robot_enum(v.get(&m("aim_mode")), Aim::from_value);
    s.total_time_remaining_s = f("total_time_remaining_s", 0.0);
    s.period_time_remaining_s = f("period_time_remaining_s", 0.0);
    s.shift_time_remaining_s = f("shift_time_remaining_s", 0.0);
    s.shift_time_with_buffer_s = f("shift_time_with_buffer_s", 0.0);
    s.buffer_remaining_s = f("buffer_remaining_s", 0.0);
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
}

/// The topic-backed fields as they are before anything arrives.
fn blank(data: &mut MockData) {
    data.demo = false;
    data.nt_connected = false;
    data.match_feed = MatchFeed::new(match_model::Clock::new());
    data.matchs = MatchState {
        seq: 0,
        robot_time_us: 0,
        robot_connected: false,
        game_specific_message: String::new(),
        is_red_alliance: None,
        enabled: false,
        ..MatchState::seed()
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
    data.nt = nt::Diagnostics::default();
}

/// The live connection, shared by the services that talk to the robot: the
/// auto selection sync and the controls use it as their [`ControlLink`]
/// (`MockData::nt_link`), [`NtSource`] pumps it.
///
/// [`ControlLink`]: dash_core::request_state::ControlLink
#[derive(Clone)]
pub struct NtLink(Rc<RefCell<NtService>>);

impl NtLink {
    pub fn new(nt: NtService) -> Self {
        Self(Rc::new(RefCell::new(nt)))
    }

    pub fn borrow(&self) -> Ref<'_, NtService> {
        self.0.borrow()
    }

    pub fn borrow_mut(&self) -> RefMut<'_, NtService> {
        self.0.borrow_mut()
    }
}

impl std::fmt::Debug for NtLink {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("NtLink")
    }
}

pub struct NtSource {
    nt: NtLink,
    clock: Clock,
    host_override: Option<String>,
    port_override: Option<u16>,
    configured: Option<(String, u16, f64)>,
    subscribed: Option<(String, String)>,
}

impl NtSource {
    /// Clears the demo values and starts connecting. Overrides win over the
    /// saved connection settings, as Godot's `--nt-host` / `--nt-port` do.
    pub fn start(data: &mut MockData, host_override: Option<String>, port_override: Option<u16>) -> Self {
        Self::start_with(data, nt::spawn(Clock::real()), host_override, port_override)
    }

    fn start_with(
        data: &mut MockData,
        nt: NtService,
        host_override: Option<String>,
        port_override: Option<u16>,
    ) -> Self {
        blank(data);
        let nt = NtLink::new(nt);
        data.nt_link = Some(nt.clone());
        let mut src = Self {
            nt,
            clock: Clock::real(),
            host_override,
            port_override,
            configured: None,
            subscribed: None,
        };
        src.sync_settings(data);
        if let Some((host, port, _)) = &src.configured {
            data.nt.host = host.clone();
            data.nt.port = *port;
        }
        src.nt.borrow().start();
        src
    }

    fn sync_settings(&mut self, data: &MockData) {
        let c = &data.connection;
        let host = self.host_override.clone().unwrap_or_else(|| c.nt.host.trim().to_owned());
        let port = self.port_override.unwrap_or(c.nt.port);
        let want = (host, port, f64::from(c.reconnect_timeout_s));
        let nt = self.nt.borrow();
        if self.configured.as_ref() != Some(&want) {
            nt.configure(&want.0, want.1, want.2);
            self.configured = Some(want);
        }
        let subs = (
            c.selected_path_topics().state,
            intake_speed_topics(&c.nt.shared_table).state,
        );
        if self.subscribed.as_ref() != Some(&subs) {
            nt.set_subscriptions(topics::subscription_groups(&subs.0, &subs.1));
            self.subscribed = Some(subs);
        }
    }

    /// Applies what arrived since the last call. Returns whether a screen
    /// needs to redraw.
    pub fn tick(&mut self, data: &mut MockData) -> bool {
        self.sync_settings(data);
        let pumped = self.nt.borrow_mut().pump(self.clock.now_us());
        let feed = &mut data.match_feed;
        let model_now = feed.now_us();
        let mut changed = !pumped.is_empty();
        if let Some(ready) = pumped.connection {
            changed |= feed.model.set_nt_ready(ready, model_now).is_some();
        }
        for v in &pumped.values {
            let key = match v.name.strip_prefix(topics::MATCH_STATE_PREFIX) {
                Some(key) => key,
                None if &*v.name == topics::LANE_ADJUSTING_VELOCITY => LANE_KEY,
                None => continue,
            };
            if let Some(value) = v.value.to_control_value() {
                changed |= feed.model.ingest(key, &value, model_now).is_some();
            }
        }
        changed |= feed.model.step(model_now).is_some();
        let nt = self.nt.borrow();
        if !pumped.is_empty() {
            refresh(data, &*nt);
        }
        let nt_connected = nt.is_ready();
        if nt_connected != data.nt_connected {
            data.nt_connected = nt_connected;
            changed = true;
        }
        changed |= write_diagnostics(data, nt.diagnostics());
        changed
    }
}

/// Copies the client's diagnostics; true when what the Settings tab shows
/// changed. Until the client thread first reports, the configured server
/// set by [`NtSource::start`] stays.
fn write_diagnostics(data: &mut MockData, d: &nt::Diagnostics) -> bool {
    if d.host.is_empty() {
        return false;
    }
    let changed = data.nt.rows() != d.rows();
    data.nt = d.clone();
    changed
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::mpsc::{self, Receiver, Sender};

    use dash_core::nt::client::ClientEvent;
    use dash_core::nt::runner::{Command, Event};
    use dash_core::nt::{Diagnostics, State};

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

    struct Live {
        data: MockData,
        src: NtSource,
        cmds: Receiver<Command>,
        events: Sender<Vec<Event>>,
    }

    impl Live {
        fn new() -> Self {
            let (tx, cmds) = mpsc::channel();
            let (events, ev_rx) = mpsc::channel();
            let mut data = MockData::new(crate::mock::Scenario::PreMatch);
            let src = NtSource::start_with(&mut data, NtService::new(tx, ev_rx), None, None);
            crate::mock_link::step(&mut data);
            Self { data, src, cmds, events }
        }

        fn sent(&self) -> Vec<Command> {
            self.cmds.try_iter().collect()
        }

        fn deliver(&mut self, events: Vec<Event>) -> bool {
            self.events.send(events).unwrap();
            self.src.tick(&mut self.data)
        }

        fn set_state(&mut self, state: State) {
            let previous = self.src.nt.borrow().state();
            self.deliver(vec![Event::Client(ClientEvent::State { state, previous })]);
        }
    }

    fn publish(topic: &str, value: f64) -> Command {
        Command::Publish {
            topic: topic.into(),
            type_str: "double".into(),
            value: NtValue::Double(value),
        }
    }

    fn requests(sent: Vec<Command>) -> Vec<Command> {
        sent.into_iter()
            .filter(|c| matches!(c, Command::Publish { .. } | Command::Forget { .. } | Command::Release { .. }))
            .collect()
    }

    #[test]
    fn live_controls_publish_through_the_nt_link() {
        let mut l = Live::new();
        l.sent();
        crate::mock_link::with_controls(&mut l.data, |c, link| {
            c.intake.set_speed(link, 0.42);
        });
        assert_eq!(requests(l.sent()), [publish("/Shared/Intake/Speed/Request", 0.42)]);
        assert_eq!(l.data.controls.intake.request, None, "the mock robot is not involved");
        assert_eq!(l.data.controls.intake_stored, Some(0.42));
        crate::mock_link::echo(&mut l.data);
        assert_eq!(l.data.controls.intake.state, None, "no mock echo in live mode");

        let sent = crate::mock_link::with_controls(&mut l.data, |c, link| c.trim.set_trim(link, 1.5));
        assert!(!sent, "the trim needs a connection");
        l.set_state(State::Ready);
        let sent = crate::mock_link::with_controls(&mut l.data, |c, link| c.trim.set_trim(link, 1.5));
        assert!(sent);
        assert_eq!(
            requests(l.sent()),
            [
                publish(dash_core::controls::AIM_TRIM_PUBLISH, 1.5),
                publish("/Shared/Intake/Speed/Request", 0.42),
            ],
            "the trim, then the held intake override again on the new connection"
        );
    }

    #[test]
    fn shared_table_moves_the_intake_topics_and_subscription() {
        let mut l = Live::new();
        crate::mock_link::with_controls(&mut l.data, |c, link| {
            c.intake.set_speed(link, 0.3);
        });
        l.sent();
        l.data.connection.nt.shared_table = "Other".into();
        crate::mock_link::set_shared_table(&mut l.data, "Other");
        assert_eq!(
            requests(l.sent()),
            [
                Command::Release { topic: "/Shared/Intake/Speed/Request".into() },
                publish("/Other/Intake/Speed/Request", 0.3),
            ]
        );
        assert_eq!(l.data.controls.intake.topics.state, "/Other/Intake/Speed/State");
        l.src.tick(&mut l.data);
        let subscribed: Vec<String> = l
            .sent()
            .into_iter()
            .filter_map(|c| match c {
                Command::Subscribe(groups) => Some(groups),
                _ => None,
            })
            .flatten()
            .flat_map(|g| g.topics)
            .collect();
        assert!(subscribed.contains(&"/Other/Intake/Speed/State".to_string()));
        assert!(subscribed.contains(&"/Other/PathPlanner/SelectedPath/State".to_string()));
        assert!(!subscribed.iter().any(|t| t.starts_with("/Shared/")));
    }

    #[test]
    fn reconnect_is_an_explicit_request() {
        let mut l = Live::new();
        l.sent();
        l.data.request_reconnect();
        assert_eq!(l.sent(), [Command::Reconnect]);
        l.src.tick(&mut l.data);
        assert!(!l.sent().contains(&Command::Reconnect), "sent once, not on later ticks");
    }

    #[test]
    fn diagnostics_follow_the_client() {
        let mut l = Live::new();
        assert_eq!(l.data.nt.rows()[2], ("Server", "10.47.65.2:5810".to_string()), "configured server before any report");
        let d = Diagnostics {
            state: State::Backoff,
            host: "127.0.0.1".into(),
            port: 5821,
            attempt: 2,
            backoff_left_s: 0.3,
            rtt_us: -1,
            reconnects: 1,
            manual_reconnects: 1,
            last_close: "server closed".into(),
            ..Default::default()
        };
        assert!(l.deliver(vec![Event::Diagnostics(Box::new(d.clone()))]));
        assert_eq!(
            l.data.nt.rows().into_iter().map(|(_, v)| v).collect::<Vec<_>>(),
            [
                "BACKOFF",
                "Attempt 2 failed, retrying in 0.3 s",
                "127.0.0.1:5821",
                "--",
                "1 (manual 1)",
                "server closed"
            ]
        );
        let busier = Diagnostics { values_total: 99, ..d };
        assert!(!l.deliver(vec![Event::Diagnostics(Box::new(busier))]), "no redraw for unshown fields");
    }


    #[test]
    fn refresh_maps_topics_and_gates_on_liveness() {
        let mut data = MockData::new(crate::mock::Scenario::PreMatch);
        blank(&mut data);
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
        refresh(&mut data, &v);
        assert_eq!(data.matchs.seq, 42);
        assert_eq!(data.matchs.phase, Phase::Shift2);
        assert_eq!(data.matchs.hub, Hub::Warning);
        assert_eq!(data.matchs.header, Header::Hidden, "out of range maps to the first entry");
        assert_eq!(data.matchs.aim, Aim::ManualAiming);
        assert_eq!(data.matchs.is_red_alliance, Some(true));
        assert!(data.pose.valid);
        assert_eq!(data.pose.x_m, 5.0);
        assert_eq!(data.joints.wrist, Some(0.25));
        assert_eq!(data.joints.turret_rot, None, "NaN is absent");
        assert_eq!(data.joints.climber_height_m, None);
        assert_eq!(data.readouts.is_spun_up, Some(true));
        assert_eq!(data.pathplanner.valid_autos, Some(vec!["A".to_string()]));

        v.live = false;
        refresh(&mut data, &v);
        assert_eq!(data.joints.wrist, None, "joints fall back to manual when not live");
        assert_eq!(data.matchs.is_red_alliance, None);
        assert_eq!(data.pathplanner.deploy_hash.as_deref(), Some("abc"), "deploy hash kept while stale");
        assert_eq!(data.pose.x_m, 5.0, "pose kept while stale");
        assert_eq!(data.matchs.seq, 42);
    }
}
