//! The values the screens show, as a plain struct seeded with demo values.
//! NetworkTables will replace `MockData::demo_tick` later; screens only read
//! these fields and write the user-facing settings back.

use std::time::Instant;

use dash_core::controls::Controls;
use dash_core::match_model::{Aim, Clock, Header, Hub, LANE_KEY, MatchEvent, Phase};
use dash_core::request_state::{RequestTopics, Value};
pub use dash_core::settings::{ConnectionSettings, MapMode, MapSettings, VisualSettings};

use crate::match_feed::MatchFeed;

/// `/matchhud/state/*` as the robot publishes it (MatchStatusCalculator.java),
/// less the pose ([`RobotPose`]) and auto-align ([`AutoAlign`]) keys.
#[derive(Clone, Debug)]
pub struct MatchState {
    pub seq: i64,
    pub robot_time_us: i64,
    /// The robot's own `connected` key (FMS/DS link), not the NT connection.
    pub robot_connected: bool,
    pub enabled: bool,
    pub autonomous: bool,
    pub game_specific_message: String,
    pub is_shooting: bool,
    pub phase: Phase,
    pub hub: Hub,
    pub header: Header,
    pub aim: Aim,
    pub is_red_alliance: Option<bool>,
    pub total_time_remaining_s: f64,
    pub period_time_remaining_s: f64,
    pub shift_time_remaining_s: f64,
    pub shift_time_with_buffer_s: f64,
    pub buffer_remaining_s: f64,
    pub show_shift_indicator: bool,
    pub show_buffer: bool,
    /// The robot publishes the table at all (false: the No Robot Data fixture).
    pub published: bool,
}

impl MatchState {
    /// The `/matchhud/state` values the HUD model reads, keyed as published.
    pub fn topics(&self) -> Vec<(&'static str, Value)> {
        if !self.published {
            return Vec::new();
        }
        let mut out = vec![
            ("seq", Value::Int(self.seq)),
            ("robot_time_us", Value::Int(self.robot_time_us)),
            ("connected", Value::Bool(self.robot_connected)),
            ("enabled", Value::Bool(self.enabled)),
            ("autonomous", Value::Bool(self.autonomous)),
            (
                "game_specific_message",
                Value::String(self.game_specific_message.clone()),
            ),
            ("match_phase", self.phase.to_value()),
            ("hub_status", self.hub.to_value()),
            ("header_color", self.header.to_value()),
            ("aim_mode", self.aim.to_value()),
            (
                "total_time_remaining_s",
                Value::Double(self.total_time_remaining_s),
            ),
            (
                "period_time_remaining_s",
                Value::Double(self.period_time_remaining_s),
            ),
            (
                "shift_time_remaining_s",
                Value::Double(self.shift_time_remaining_s),
            ),
            (
                "shift_time_with_buffer_s",
                Value::Double(self.shift_time_with_buffer_s),
            ),
            ("buffer_remaining_s", Value::Double(self.buffer_remaining_s)),
            ("is_shooting", Value::Bool(self.is_shooting)),
            (
                "show_shift_indicator",
                Value::Bool(self.show_shift_indicator),
            ),
            ("show_buffer", Value::Bool(self.show_buffer)),
        ];
        if let Some(red) = self.is_red_alliance {
            out.push(("is_red_alliance", Value::Bool(red)));
        }
        out
    }
}

#[derive(Clone, Debug)]
pub struct NtDiagnostics {
    pub state: &'static str,
    pub server: String,
    pub rtt_ms: Option<f32>,
    pub reconnects: u32,
    /// Connection attempts since the last successful connect.
    pub attempt: u32,
}

impl NtDiagnostics {
    pub fn seed() -> Self {
        Self {
            state: "READY",
            server: "10.47.65.2:5810".into(),
            rtt_ms: Some(3.2),
            reconnects: 0,
            attempt: 0,
        }
    }
}

/// `/matchhud/state/robot_pose_*` and `robot_heading_rad` (HUD minimap).
#[derive(Clone, Debug, PartialEq)]
pub struct RobotPose {
    pub x_m: f64,
    pub y_m: f64,
    pub heading_rad: f64,
    pub valid: bool,
}

impl RobotPose {
    /// hud_base.json.
    pub fn seed() -> Self {
        Self {
            x_m: 4.2,
            y_m: 2.6,
            heading_rad: 0.6,
            valid: true,
        }
    }
}

/// `/matchhud/state/auto_align_*`, `driver_override`, `camera_topic`
/// (HUD CameraOverlay).
#[derive(Clone, Debug, PartialEq)]
pub struct AutoAlign {
    pub active: bool,
    pub distance_m: f64,
    pub ready: bool,
    pub driver_override: bool,
    /// Optional: the FIR robot never publishes it.
    pub camera_topic: Option<String>,
}

impl AutoAlign {
    /// hud_base.json.
    pub fn seed() -> Self {
        Self {
            active: false,
            distance_m: 0.0,
            ready: false,
            driver_override: false,
            camera_topic: None,
        }
    }
}

/// The three joint topics (Robot 3D tab, driver view). `None` is a topic
/// that has not arrived, which the UI shows as a manual fallback.
#[derive(Clone, Debug, PartialEq)]
pub struct Joints {
    /// /AdvantageKit/RealOutputs/IntakeSubsystem/WristPosition
    pub wrist: Option<f64>,
    /// /AdvantageKit/RealOutputs/Turret/PositionRot
    pub turret_rot: Option<f64>,
    /// /AdvantageKit/RealOutputs/Climber/CurrentHeightMeters
    pub climber_height_m: Option<f64>,
}

impl Joints {
    /// touch_base.json: turret and wrist live, climber on manual fallback.
    pub fn seed() -> Self {
        Self {
            wrist: Some(0.0),
            turret_rot: Some(0.0),
            climber_height_m: None,
        }
    }
}

/// Topics::READOUT_TOPICS, under /AdvantageKit/RealOutputs/ (Intake panel).
#[derive(Clone, Debug, PartialEq)]
pub struct ShooterReadouts {
    /// Turret/DistanceToTarget
    pub distance_to_target_m: Option<f64>,
    /// Shooter/RequestedVelocityRPM
    pub requested_rpm: Option<f64>,
    /// Shooter/VelocityRPM
    pub velocity_rpm: Option<f64>,
    /// Shooter/LeaderVelocityRPM
    pub leader_rpm: Option<f64>,
    /// Shooter/FollowerVelocityRPM
    pub follower_rpm: Option<f64>,
    /// Turret/PositionDeg
    pub turret_position_deg: Option<f64>,
    /// Turret/Angle
    pub turret_angle: Option<f64>,
    /// Shooter/IsSpunUp
    pub is_spun_up: Option<bool>,
    /// ShooterSubsystem/GPSAssistFeaturesEnabled
    pub gps_assist_enabled: Option<bool>,
    /// MatchStatus/isShooting
    pub is_shooting: Option<bool>,
}

impl ShooterReadouts {
    /// touch_m6_base.json.
    pub fn seed() -> Self {
        Self {
            distance_to_target_m: Some(3.456),
            requested_rpm: Some(3200.0),
            velocity_rpm: Some(3187.6),
            leader_rpm: Some(3190.2),
            follower_rpm: Some(3185.1),
            turret_position_deg: Some(-42.37),
            turret_angle: Some(-0.7401),
            is_spun_up: Some(true),
            gps_assist_enabled: Some(true),
            is_shooting: Some(false),
        }
    }
}

/// /AdvantageKit/RealOutputs/SwerveSubsystem/AdjustingVelocity, the raw
/// signal behind the lane toast.
#[derive(Clone, Debug, PartialEq)]
pub struct LaneSignal {
    pub adjusting_velocity: Option<bool>,
}

impl LaneSignal {
    /// hud_base.json.
    pub fn seed() -> Self {
        Self {
            adjusting_velocity: Some(false),
        }
    }
}

/// /AdvantageKit/RealOutputs/PathPlanner/* as the robot reports it.
#[derive(Clone, Debug, PartialEq)]
pub struct PathPlannerTopics {
    pub current_selected_auto: Option<String>,
    pub selected_auto_valid: Option<bool>,
    /// ValidNames/Autos.
    pub valid_autos: Option<Vec<String>>,
    /// Optional: only robot code with the README snippet publishes it.
    pub deploy_hash: Option<String>,
}

impl PathPlannerTopics {
    /// touch_m6_base.json.
    pub fn seed() -> Self {
        Self {
            current_selected_auto: Some("Ball Shooter Left".into()),
            selected_auto_valid: Some(true),
            valid_autos: Some(
                [
                    "Ball Shooter Left",
                    "Ball Shooter Right",
                    "Climber Right Left",
                    "Climber Right Middle",
                    "Climber Right Right",
                    "Move Forward And Shoot Center",
                    "Move Forward And Shoot Left",
                    "Move Forward And Shoot Right",
                    "Stay And Shoot",
                ]
                .into_iter()
                .map(String::from)
                .collect(),
            ),
            deploy_hash: None,
        }
    }
}

/// One Request/State pair: what the dashboard last published and what the
/// robot echoes (see `dash_core::request_state`).
#[derive(Clone, Debug, PartialEq)]
pub struct RequestEcho<T> {
    pub topics: RequestTopics,
    pub request: Option<T>,
    pub state: Option<T>,
}

/// <shared>/PathPlanner/SelectedPath Request/State (Auto tab).
#[derive(Clone, Debug, PartialEq)]
pub struct AutoSelection {
    pub link: RequestEcho<String>,
    /// The dashboard's persisted choice: "" mirrors the robot, "NONE" is No Auto.
    pub stored: String,
}

impl AutoSelection {
    /// touch_m6_base.json.
    pub fn seed() -> Self {
        Self {
            link: RequestEcho {
                topics: RequestTopics::new("Shared", "PathPlanner/SelectedPath"),
                request: None,
                state: Some("Ball Shooter Left".into()),
            },
            stored: "Ball Shooter Left".into(),
        }
    }
}

/// <shared>/Intake/Speed Request/State and aim trim publish/readback
/// (Intake panel).
#[derive(Clone, Debug, PartialEq)]
pub struct ControlTopics {
    /// Persisted override; `None` uses the robot's compiled constant.
    pub intake_stored: Option<f64>,
    pub intake: RequestEcho<f64>,
    pub aim_trim: RequestEcho<f64>,
}

impl ControlTopics {
    /// touch_m6_base.json.
    pub fn seed() -> Self {
        Self {
            intake_stored: None,
            intake: RequestEcho {
                topics: RequestTopics::new("Shared", "Intake/Speed"),
                request: None,
                state: Some(0.5),
            },
            aim_trim: RequestEcho {
                topics: RequestTopics {
                    request: "/Tuning/Turret/AimTrimDeg".into(),
                    state: "/AdvantageKit/NetworkInputs/Tuning/Turret/AimTrimDeg".into(),
                },
                request: None,
                state: Some(0.0),
            },
        }
    }
}

#[derive(Clone, Debug)]
pub struct MockData {
    pub nt_connected: bool,
    pub matchs: MatchState,
    /// The HUD's match model, fed from `matchs`, `pose` and `lane`.
    pub match_feed: MatchFeed,
    pub connection: ConnectionSettings,
    pub map: MapSettings,
    pub visual: VisualSettings,
    pub nt: NtDiagnostics,
    pub autos: Vec<String>,
    pub pose: RobotPose,
    pub align: AutoAlign,
    pub joints: Joints,
    pub readouts: ShooterReadouts,
    pub lane: LaneSignal,
    pub pathplanner: PathPlannerTopics,
    pub auto_selection: AutoSelection,
    pub controls: ControlTopics,
    /// The intake speed and aim trim controllers over `controls`
    /// (see `mock_link`).
    pub control: Controls,
    pub demo_started: Instant,
    pub demo: bool,
    /// Fed by the NT client (`--nt-host` / `--nt-port`); the mock robot
    /// must not answer requests.
    pub live_nt: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scenario {
    Demo,
    PreMatch,
    Autonomous,
    Transition,
    ShiftActive,
    ShiftWarning,
    ShiftInactive,
    Endgame,
    PostMatch,
    NtDisconnected,
    LaneToast,
    NoData,
    Stale,
    AutoAlign,
    AutoAlignReady,
}

impl Scenario {
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s.trim_start_matches("hud_") {
            "demo" => Self::Demo,
            "pre_match" => Self::PreMatch,
            "autonomous" => Self::Autonomous,
            "transition" => Self::Transition,
            "shift_active" => Self::ShiftActive,
            "shift_warning" => Self::ShiftWarning,
            "shift_inactive" => Self::ShiftInactive,
            "endgame" => Self::Endgame,
            "post_match" => Self::PostMatch,
            "nt_disconnected" => Self::NtDisconnected,
            "lane_toast" => Self::LaneToast,
            "no_data" => Self::NoData,
            "stale" => Self::Stale,
            "auto_align" => Self::AutoAlign,
            "auto_align_ready" => Self::AutoAlignReady,
            _ => return None,
        })
    }
}

impl MatchState {
    /// hud_base.json.
    pub fn seed() -> Self {
        Self {
            seq: 4242,
            robot_time_us: 100_000_000,
            robot_connected: true,
            enabled: true,
            autonomous: false,
            game_specific_message: "B".into(),
            is_shooting: false,
            phase: Phase::PreMatch,
            hub: Hub::None,
            header: Header::Hidden,
            aim: Aim::ShooterDisabled,
            is_red_alliance: Some(false),
            total_time_remaining_s: 0.0,
            period_time_remaining_s: 0.0,
            shift_time_remaining_s: 0.0,
            shift_time_with_buffer_s: 0.0,
            buffer_remaining_s: 0.0,
            show_shift_indicator: false,
            show_buffer: false,
            published: true,
        }
    }
}

impl MockData {
    pub fn new(scenario: Scenario) -> Self {
        let now = Instant::now();
        let controls = ControlTopics::seed();
        let control = Controls::with_topics(controls.intake.topics.clone(), controls.intake_stored);
        let mut data = Self {
            nt_connected: true,
            matchs: MatchState::seed(),
            match_feed: MatchFeed::new(if scenario == Scenario::Demo {
                Clock::new()
            } else {
                Clock::frozen(10_000_000)
            }),
            connection: ConnectionSettings::default(),
            map: MapSettings::default(),
            visual: VisualSettings::default(),
            nt: NtDiagnostics::seed(),
            autos: [
                "Center 3 Note",
                "Amp Side 4 Piece",
                "Source Sweep",
                "Leave Only",
                "Do Nothing",
            ]
            .into_iter()
            .map(String::from)
            .collect(),
            pose: RobotPose::seed(),
            align: AutoAlign::seed(),
            joints: Joints::seed(),
            readouts: ShooterReadouts::seed(),
            lane: LaneSignal::seed(),
            pathplanner: PathPlannerTopics::seed(),
            auto_selection: AutoSelection::seed(),
            controls,
            control,
            demo_started: now,
            demo: scenario == Scenario::Demo,
            live_nt: false,
        };
        data.apply(scenario);
        crate::mock_link::step(&mut data);
        data
    }

    fn apply(&mut self, scenario: Scenario) {
        let m = &mut self.matchs;
        let shift_active = |m: &mut MatchState| {
            m.phase = Phase::Shift1;
            m.hub = Hub::Active;
            m.header = Header::Green;
            m.aim = Aim::GpsAuto;
            m.total_time_remaining_s = 110.42;
            m.period_time_remaining_s = 15.42;
            m.shift_time_remaining_s = 15.42;
            m.shift_time_with_buffer_s = 18.42;
            m.show_shift_indicator = true;
        };
        match scenario {
            Scenario::Demo => {
                self.demo_tick();
                return;
            }
            Scenario::PreMatch | Scenario::PostMatch => {
                m.phase = if scenario == Scenario::PreMatch {
                    Phase::PreMatch
                } else {
                    Phase::PostMatch
                };
            }
            Scenario::Autonomous => {
                m.phase = Phase::Autonomous;
                m.hub = Hub::Both;
                m.header = Header::Purple;
                m.aim = Aim::GpsAuto;
                m.total_time_remaining_s = 147.53;
                m.period_time_remaining_s = 7.53;
                m.show_shift_indicator = true;
            }
            Scenario::Transition => {
                m.phase = Phase::Transition;
                m.hub = Hub::Both;
                m.header = Header::Green;
                m.aim = Aim::ManualAiming;
                m.total_time_remaining_s = 134.81;
                m.period_time_remaining_s = 4.81;
                m.shift_time_remaining_s = 4.81;
                m.shift_time_with_buffer_s = 4.81;
                m.show_shift_indicator = true;
            }
            Scenario::ShiftActive | Scenario::Stale => shift_active(m),
            Scenario::NoData => m.published = false,
            Scenario::ShiftWarning => {
                m.phase = Phase::Shift2;
                m.hub = Hub::Warning;
                m.header = Header::Yellow;
                m.aim = Aim::GpsAuto;
                m.total_time_remaining_s = 83.74;
                m.period_time_remaining_s = 23.74;
                m.shift_time_remaining_s = 23.74;
                m.shift_time_with_buffer_s = 23.74;
                m.buffer_remaining_s = 1.74;
                m.show_shift_indicator = true;
                m.show_buffer = true;
            }
            Scenario::ShiftInactive => {
                m.phase = Phase::Shift2;
                m.hub = Hub::Inactive;
                m.total_time_remaining_s = 72.05;
                m.period_time_remaining_s = 12.05;
                m.shift_time_remaining_s = 12.05;
                m.shift_time_with_buffer_s = 12.05;
                m.show_shift_indicator = true;
            }
            Scenario::Endgame => {
                m.phase = Phase::Endgame;
                m.hub = Hub::Both;
                m.header = Header::Green;
                m.aim = Aim::ManualAiming;
                m.total_time_remaining_s = 21.37;
                m.period_time_remaining_s = 21.37;
            }
            Scenario::AutoAlign | Scenario::AutoAlignReady => {
                shift_active(m);
                let ready = scenario == Scenario::AutoAlignReady;
                self.align.active = true;
                self.align.ready = ready;
                self.align.distance_m = if ready { 0.42 } else { 1.26 };
            }
            Scenario::NtDisconnected => {
                shift_active(m);
                self.nt.state = "CONNECTING";
                self.nt.rtt_ms = None;
                self.nt.attempt = 3;
            }
            Scenario::LaneToast => shift_active(m),
        }
        self.sync_match();
        // The Godot fixtures' nt_link / nt_steps / match.advance_s, in order.
        match scenario {
            Scenario::NtDisconnected => {
                self.nt_connected = false;
                self.sync_match();
            }
            Scenario::LaneToast => {
                self.lane.adjusting_velocity = Some(true);
                self.sync_match();
                self.match_feed.clock.advance_s(0.6);
                self.match_feed.step();
            }
            Scenario::Stale => {
                self.match_feed.clock.advance_s(1.5);
                self.match_feed.step();
            }
            _ => {}
        }
    }

    /// Delivers the match topics to the HUD model as NT would, then steps it.
    pub fn sync_match(&mut self) -> Vec<MatchEvent> {
        let feed = &mut self.match_feed;
        let mut events: Vec<MatchEvent> = feed.set_link(self.nt_connected).into_iter().collect();
        let mut topics = self.matchs.topics();
        if self.matchs.published {
            topics.push(("robot_pose_valid", Value::Bool(self.pose.valid)));
        }
        if let Some(v) = self.lane.adjusting_velocity {
            topics.push((LANE_KEY, Value::Bool(v)));
        }
        events.extend(feed.publish(topics));
        events.extend(feed.step());
        events
    }

    /// The demo match: 5 s of pre-match, then the 2026 timeline (20 s auto,
    /// 10 s transition, four 25 s shifts, 30 s endgame), looping, with the
    /// hub alternating per shift and a lane-alignment toggle every 12 s,
    /// published like the robot's 20 ms loop. Returns whether the match model
    /// raised an event; the HUD redraws every frame regardless.
    pub fn demo_tick(&mut self) -> bool {
        if !self.demo {
            return false;
        }
        let now = Instant::now();
        const PRE: f64 = 5.0;
        const AUTO: f64 = 20.0;
        const TELEOP: f64 = 140.0;
        const POST: f64 = 5.0;
        let cycle = PRE + AUTO + TELEOP + POST;
        let t = now.duration_since(self.demo_started).as_secs_f64() % cycle;
        let mut m = MatchState::seed();
        m.seq = self.matchs.seq + 1;
        if t < PRE {
            m.phase = Phase::PreMatch;
        } else if t < PRE + AUTO {
            let left = PRE + AUTO - t;
            m.phase = Phase::Autonomous;
            m.hub = Hub::Both;
            m.header = Header::Purple;
            m.aim = Aim::GpsAuto;
            m.total_time_remaining_s = left + TELEOP;
            m.period_time_remaining_s = left;
            m.show_shift_indicator = true;
        } else if t < PRE + AUTO + TELEOP {
            let left = PRE + AUTO + TELEOP - t;
            m.total_time_remaining_s = left;
            m.period_time_remaining_s = left;
            m.show_shift_indicator = true;
            if left > 130.0 {
                m.phase = Phase::Transition;
                m.hub = Hub::Both;
                m.header = Header::Green;
                m.aim = Aim::ManualAiming;
                m.period_time_remaining_s = left - 130.0;
                m.shift_time_remaining_s = left - 130.0;
                m.shift_time_with_buffer_s = left - 130.0;
            } else if left > 30.0 {
                let into = 130.0 - left;
                let shift = (into / 25.0) as usize;
                let shift_left = 25.0 - (into - shift as f64 * 25.0);
                m.phase =
                    [Phase::Shift1, Phase::Shift2, Phase::Shift3, Phase::Shift4][shift.min(3)];
                let ours = shift % 2 == 0;
                let in_buffer = !ours && shift_left > 22.0;
                m.period_time_remaining_s = shift_left;
                m.shift_time_remaining_s = shift_left;
                m.aim = Aim::GpsAuto;
                if ours {
                    m.hub = Hub::Active;
                    m.header = Header::Green;
                    m.shift_time_with_buffer_s = shift_left + 3.0;
                } else if in_buffer {
                    m.hub = Hub::Warning;
                    m.header = Header::Yellow;
                    m.show_buffer = true;
                    m.buffer_remaining_s = shift_left - 22.0;
                } else {
                    m.hub = Hub::Inactive;
                    m.aim = Aim::ShooterDisabled;
                }
            } else {
                m.phase = Phase::Endgame;
                m.hub = Hub::Both;
                m.header = Header::Green;
                m.aim = Aim::ManualAiming;
                m.show_shift_indicator = false;
            }
        } else {
            m.phase = Phase::PostMatch;
        }
        m.enabled = !matches!(m.phase, Phase::PreMatch | Phase::PostMatch);
        self.lane.adjusting_velocity = Some(((t / 12.0) as u32) % 2 == 1);
        self.matchs = m;
        self.demo_drive(t);
        !self.sync_match().is_empty()
    }

    /// The demo robot laps an oval on the blue half and auto-aligns for the
    /// last 7 s of every 25 s.
    fn demo_drive(&mut self, t: f64) {
        let a = std::f64::consts::TAU / 20.0 * t;
        self.pose.x_m = 4.5 + 2.4 * a.cos();
        self.pose.y_m = 4.03 + 2.2 * a.sin();
        self.pose.heading_rad = (2.2 * a.cos()).atan2(-2.4 * a.sin());
        let phase = t.rem_euclid(25.0);
        self.align.active = phase > 18.0;
        self.align.distance_m = ((25.0 - phase) / 7.0 * 2.0).max(0.0);
        self.align.ready = self.align.distance_m < 0.5;
    }
}
