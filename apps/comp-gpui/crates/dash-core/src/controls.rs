//! The touchscreen's robot controls (L4): the intake speed override, the
//! turret aim trim and the shooter readouts under it. Ports comp-godot's
//! `core/controls/{intake_speed,aim_trim,shooter_readouts}.gd` and
//! `services/controls_service.gd` (the web's `useIntakeSpeedNetworkTable` and
//! `useShooterTuningNetworkTable`) onto [`RequestState`].

use std::f64::consts::PI;

use crate::request_state::{
    ControlLink, Policy, RequestState, RequestStatus, RequestTopics, Value, approx_eq,
};

pub const INTAKE_SPEED_ENTRY: &str = "Intake/Speed";
pub const AIM_TRIM_PUBLISH: &str = "/Tuning/Turret/AimTrimDeg";
/// The AdvantageKit mirror of the tuning input: the M1 sim run showed it
/// follows a held publisher within one robot loop.
pub const AIM_TRIM_READBACK: &str = "/AdvantageKit/NetworkInputs/Tuning/Turret/AimTrimDeg";

pub fn intake_speed_topics(shared_table: &str) -> RequestTopics {
    RequestTopics::new(shared_table, INTAKE_SPEED_ENTRY)
}

pub fn aim_trim_topics() -> RequestTopics {
    RequestTopics {
        request: AIM_TRIM_PUBLISH.into(),
        state: AIM_TRIM_READBACK.into(),
    }
}

/// The requested intake duty cycle, persisted and published to
/// `<shared>/Intake/Speed/Request` again on every reconnect so a robot reboot
/// keeps it. Reset publishes the -1 sentinel ("use the compiled constant").
#[derive(Clone, Debug)]
pub struct IntakeSpeed {
    pub req: RequestState<f64>,
}

impl IntakeSpeed {
    pub const RESET_SENTINEL: f64 = -1.0;
    pub const FALLBACK_SPEED: f64 = 0.15;

    pub const STATUS_DISCONNECTED: &str = "Robot not connected — value is sent when it reconnects";
    pub const STATUS_CONSTANT: &str = "Using the robot's compiled constant";
    pub const STATUS_CONFIRMED: &str = "Robot confirmed this speed";
    pub const STATUS_WAITING: &str = "Waiting for the robot to confirm";

    pub fn new(topics: RequestTopics, stored: Option<f64>) -> Self {
        let held = stored.filter(|v| v.is_finite()).map(Self::round_speed);
        Self {
            req: RequestState::new(topics, Policy::default(), approx_eq).with_held(held),
        }
    }

    pub fn round_speed(v: f64) -> f64 {
        (v.clamp(0.0, 1.0) * 100.0).round() / 100.0
    }

    /// The override, `None` when the robot's compiled constant applies.
    pub fn requested(&self) -> Option<f64> {
        self.req.held().copied()
    }

    /// Returns the new override, to persist.
    pub fn set_speed(&mut self, link: &mut dyn ControlLink, v: f64) -> f64 {
        let v = Self::round_speed(v);
        self.req.hold(link, 0, v);
        v
    }

    pub fn reset(&mut self, link: &mut dyn ControlLink) {
        self.req.clear(link, Some(Self::RESET_SENTINEL));
    }

    pub fn set_topics(&mut self, link: &mut dyn ControlLink, topics: RequestTopics) {
        self.req.set_topics(link, topics);
    }

    pub fn update(&mut self, link: &mut dyn ControlLink) {
        self.req.update(link, 0);
    }

    pub fn robot_speed(&self, link: &dyn ControlLink) -> Option<f64> {
        self.req.robot(link)
    }

    pub fn slider_value(&self, link: &dyn ControlLink) -> f64 {
        self.req.shown(link).unwrap_or(Self::FALLBACK_SPEED)
    }

    pub fn status(&self, link: &dyn ControlLink) -> &'static str {
        match self.req.status(link) {
            RequestStatus::Disconnected => Self::STATUS_DISCONNECTED,
            RequestStatus::Idle { .. } => Self::STATUS_CONSTANT,
            RequestStatus::Confirmed => Self::STATUS_CONFIRMED,
            RequestStatus::Waiting => Self::STATUS_WAITING,
        }
    }

    /// The publish error if the last publish failed, else the status.
    pub fn status_line(&self, link: &dyn ControlLink) -> String {
        self.req
            .publish_error
            .clone()
            .unwrap_or_else(|| self.status(link).to_owned())
    }
}

/// Turret aim trim: writes the absolute trim (clamped to +-10 deg, rounded
/// to 0.01) and confirms against the AdvantageKit readback. Not persisted:
/// the trim lives in the robot, and a pending request is dropped and its
/// publisher forgotten when the connection drops, so a rebooted robot never
/// gets it again.
#[derive(Clone, Debug)]
pub struct AimTrim {
    pub req: RequestState<f64>,
}

impl Default for AimTrim {
    fn default() -> Self {
        Self::new()
    }
}

impl AimTrim {
    pub const LIMIT_DEG: f64 = 10.0;
    pub const STEP_DEG: f64 = 0.25;

    pub const STATUS_DISCONNECTED: &str = "Robot not connected";
    pub const STATUS_WAITING: &str = "Waiting for the robot to confirm";
    pub const STATUS_CONFIRMED: &str = "Robot confirmed this trim";
    pub const STATUS_UNKNOWN: &str = "No trim reported by the robot yet";

    pub fn new() -> Self {
        Self {
            req: RequestState::new(
                aim_trim_topics(),
                Policy {
                    forget_on_disconnect: true,
                    pending_timeout_us: None,
                },
                approx_eq,
            ),
        }
    }

    pub fn clamp_trim(deg: f64) -> f64 {
        (deg.clamp(-Self::LIMIT_DEG, Self::LIMIT_DEG) * 100.0).round() / 100.0
    }

    /// "0°", "2.5° L" (positive aims left, CCW), "1.25° R".
    pub fn format(deg: f64) -> String {
        let mag = (deg.abs() * 100.0).round() / 100.0;
        if mag == 0.0 {
            return "0°".into();
        }
        let s = format!("{mag:.2}");
        let s = s.trim_end_matches('0').trim_end_matches('.');
        format!("{s}° {}", if deg > 0.0 { "L" } else { "R" })
    }

    pub fn connected(&self, link: &dyn ControlLink) -> bool {
        link.connected()
    }

    pub fn robot_trim(&self, link: &dyn ControlLink) -> Option<f64> {
        self.req.robot(link)
    }

    /// The trim waiting for the robot's echo.
    pub fn requested(&self) -> Option<f64> {
        self.req.pending().map(|p| p.value)
    }

    /// Returns whether a value was published: nothing is sent while
    /// disconnected or when it matches the pending trim or, with none, the
    /// robot's.
    pub fn set_trim(&mut self, link: &mut dyn ControlLink, deg: f64) -> bool {
        if !link.connected() {
            return false;
        }
        let v = Self::clamp_trim(deg);
        if !self.req.would_change(link, &v) {
            return false;
        }
        self.req.send(link, 0, v);
        true
    }

    pub fn center(&mut self, link: &mut dyn ControlLink) -> bool {
        self.set_trim(link, 0.0)
    }

    pub fn update(&mut self, link: &mut dyn ControlLink) {
        self.req.update(link, 0);
    }

    pub fn slider_value(&self, link: &dyn ControlLink) -> f64 {
        self.req.shown(link).unwrap_or(0.0)
    }

    pub fn status(&self, link: &dyn ControlLink) -> &'static str {
        match self.req.status(link) {
            RequestStatus::Disconnected => Self::STATUS_DISCONNECTED,
            RequestStatus::Waiting => Self::STATUS_WAITING,
            RequestStatus::Confirmed | RequestStatus::Idle { robot_known: true } => {
                Self::STATUS_CONFIRMED
            }
            RequestStatus::Idle { robot_known: false } => Self::STATUS_UNKNOWN,
        }
    }

    pub fn status_line(&self, link: &dyn ControlLink) -> String {
        self.req
            .publish_error
            .clone()
            .unwrap_or_else(|| self.status(link).to_owned())
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ReadoutKind {
    Bool {
        yes: &'static str,
        no: &'static str,
    },
    Num {
        decimals: usize,
        unit: &'static str,
    },
    /// Published in radians, shown in degrees.
    Rad {
        decimals: usize,
        unit: &'static str,
    },
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ReadoutRow {
    pub label: &'static str,
    pub topic: &'static str,
    pub kind: ReadoutKind,
}

macro_rules! out {
    ($t:literal) => {
        concat!("/AdvantageKit/RealOutputs", $t)
    };
}

const fn num(decimals: usize, unit: &'static str) -> ReadoutKind {
    ReadoutKind::Num { decimals, unit }
}

const YES_NO: ReadoutKind = ReadoutKind::Bool {
    yes: "Yes",
    no: "No",
};

/// The ten shooter rows under the aim trim (AimTrimSection.tsx).
pub const READOUT_ROWS: [ReadoutRow; 10] = [
    ReadoutRow {
        label: "Mode",
        topic: out!("/ShooterSubsystem/GPSAssistFeaturesEnabled"),
        kind: ReadoutKind::Bool {
            yes: "Auto shooter",
            no: "Manual shooter",
        },
    },
    ReadoutRow {
        label: "Distance",
        topic: out!("/Turret/DistanceToTarget"),
        kind: num(2, " m"),
    },
    ReadoutRow {
        label: "RPM target",
        topic: out!("/Shooter/RequestedVelocityRPM"),
        kind: num(0, ""),
    },
    ReadoutRow {
        label: "RPM actual",
        topic: out!("/Shooter/VelocityRPM"),
        kind: num(0, ""),
    },
    ReadoutRow {
        label: "Leader",
        topic: out!("/Shooter/LeaderVelocityRPM"),
        kind: num(0, ""),
    },
    ReadoutRow {
        label: "Follower",
        topic: out!("/Shooter/FollowerVelocityRPM"),
        kind: num(0, ""),
    },
    ReadoutRow {
        label: "Spun up",
        topic: out!("/Shooter/IsSpunUp"),
        kind: YES_NO,
    },
    ReadoutRow {
        label: "Shooting",
        topic: out!("/MatchStatus/isShooting"),
        kind: YES_NO,
    },
    ReadoutRow {
        label: "Turret",
        topic: out!("/Turret/PositionDeg"),
        kind: num(1, "°"),
    },
    ReadoutRow {
        label: "Turret cmd",
        topic: out!("/Turret/Angle"),
        kind: ReadoutKind::Rad {
            decimals: 1,
            unit: "°",
        },
    },
];

pub const MISSING: &str = "--";

/// JavaScript `Number.prototype.toFixed`: exact ties round away from zero
/// (Rust's formatter rounds them to even), and a negative value keeps its
/// sign even when it rounds to zero.
pub fn to_fixed(v: f64, decimals: usize) -> String {
    const EXTRA: usize = 30;
    let exact = format!("{:.*}", decimals + EXTRA, v.abs());
    let (head, tail) = exact.split_at(exact.len() - EXTRA);
    let head = head.strip_suffix('.').unwrap_or(head);
    let s = if tail.as_bytes()[0] >= b'5' {
        increment_decimal(head)
    } else {
        head.to_owned()
    };
    if v < 0.0 { format!("-{s}") } else { s }
}

fn increment_decimal(s: &str) -> String {
    let mut digits: Vec<u8> = s.bytes().collect();
    let mut i = digits.len();
    loop {
        if i == 0 {
            digits.insert(0, b'1');
            break;
        }
        i -= 1;
        match digits[i] {
            b'.' => continue,
            b'9' => digits[i] = b'0',
            d => {
                digits[i] = d + 1;
                break;
            }
        }
    }
    String::from_utf8(digits).unwrap_or_default()
}

/// A value shows only when it is a bool or a finite number of the row's
/// kind; anything else is "--".
pub fn format_row(row: &ReadoutRow, v: Option<&Value>) -> String {
    let Some(v) = v else {
        return MISSING.into();
    };
    match row.kind {
        ReadoutKind::Bool { yes, no } => match v.as_bool() {
            Some(b) => (if b { yes } else { no }).into(),
            None => MISSING.into(),
        },
        ReadoutKind::Num { decimals, unit } => match v.as_f64() {
            Some(x) => format!("{}{unit}", to_fixed(x, decimals)),
            None => MISSING.into(),
        },
        ReadoutKind::Rad { decimals, unit } => match v.as_f64() {
            Some(x) => format!("{}{unit}", to_fixed(x * 180.0 / PI, decimals)),
            None => MISSING.into(),
        },
    }
}

/// Every row as (label, text), from values that arrived on this connection.
pub fn readouts(link: &dyn ControlLink) -> Vec<(&'static str, String)> {
    READOUT_ROWS
        .iter()
        .map(|row| {
            let v = (link.connected() && link.live(row.topic))
                .then(|| link.value(row.topic))
                .flatten();
            (row.label, format_row(row, v.as_ref()))
        })
        .collect()
}

pub fn readout_topics() -> impl Iterator<Item = &'static str> {
    READOUT_ROWS.iter().map(|r| r.topic)
}

/// ControlsService: the intake speed and aim trim controllers, stepped once
/// per frame against the link. Auto selection (L3) lives in
/// `selection_sync`.
#[derive(Clone, Debug)]
pub struct Controls {
    pub intake: IntakeSpeed,
    pub trim: AimTrim,
}

impl Controls {
    pub fn new(shared_table: &str, stored_intake: Option<f64>) -> Self {
        Self::with_topics(intake_speed_topics(shared_table), stored_intake)
    }

    pub fn with_topics(intake: RequestTopics, stored_intake: Option<f64>) -> Self {
        Self {
            intake: IntakeSpeed::new(intake, stored_intake),
            trim: AimTrim::new(),
        }
    }

    pub fn step(&mut self, link: &mut dyn ControlLink) {
        self.intake.update(link);
        self.trim.update(link);
    }

    pub fn set_shared_table(&mut self, link: &mut dyn ControlLink, shared_table: &str) {
        self.intake
            .set_topics(link, intake_speed_topics(shared_table));
    }

    pub fn readouts(&self, link: &dyn ControlLink) -> Vec<(&'static str, String)> {
        readouts(link)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::request_state::FakeLink;

    const REQ: &str = "/Shared/Intake/Speed/Request";
    const STATE: &str = "/Shared/Intake/Speed/State";

    fn d(v: f64) -> Value {
        Value::Double(v)
    }

    fn up() -> FakeLink {
        FakeLink {
            up: true,
            ..Default::default()
        }
    }

    fn intake(stored: Option<f64>) -> IntakeSpeed {
        IntakeSpeed::new(intake_speed_topics("Shared"), stored)
    }

    #[test]
    fn intake_topics_follow_the_shared_table() {
        let t = intake_speed_topics("Other");
        assert_eq!(t.request, "/Other/Intake/Speed/Request");
        assert_eq!(t.state, "/Other/Intake/Speed/State");
        assert_eq!(intake_speed_topics(" /Shared/ ").request, REQ);
    }

    #[test]
    fn intake_slider_publishes_rounded_and_persists() {
        let mut link = FakeLink::default();
        let mut c = intake(None);
        let seen = [
            c.set_speed(&mut link, 0.4249),
            c.set_speed(&mut link, 1.7),
            c.set_speed(&mut link, -0.2),
        ];
        assert_eq!(seen, [0.42, 1.0, 0.0]);
        assert_eq!(link.count(REQ), 3, "every change publishes");
        assert_eq!(link.last(REQ), Some(&d(0.0)), "clamped to 0");
        assert_eq!(c.requested(), Some(0.0));
    }

    #[test]
    fn intake_stored_value_republished_on_every_connect() {
        let mut link = FakeLink::default();
        let mut c = intake(Some(0.37));
        c.update(&mut link);
        assert_eq!(link.count(REQ), 0);
        link.up = true;
        c.update(&mut link);
        c.update(&mut link);
        assert_eq!(link.count(REQ), 1);
        assert_eq!(link.last(REQ), Some(&d(0.37)));
        link.up = false;
        c.update(&mut link);
        link.up = true;
        c.update(&mut link);
        assert_eq!(link.count(REQ), 2, "re-published after a reconnect");
    }

    #[test]
    fn intake_stored_value_is_rounded_and_must_be_finite() {
        assert_eq!(intake(Some(0.456)).requested(), Some(0.46));
        assert_eq!(intake(Some(4.0)).requested(), Some(1.0));
        assert_eq!(intake(Some(f64::NAN)).requested(), None);
    }

    #[test]
    fn intake_no_override_publishes_nothing_on_connect() {
        let mut link = up();
        let mut c = intake(None);
        c.update(&mut link);
        assert_eq!(link.count(REQ), 0);
    }

    #[test]
    fn intake_reset_publishes_sentinel_and_clears() {
        let mut link = FakeLink::default();
        let mut c = intake(Some(0.6));
        c.reset(&mut link);
        assert_eq!(link.last(REQ), Some(&d(-1.0)));
        assert_eq!(c.requested(), None);
        link.up = true;
        c.update(&mut link);
        assert_eq!(
            link.count(REQ),
            1,
            "nothing stored to re-publish after a reset"
        );
    }

    #[test]
    fn intake_status_texts_and_slider_value() {
        let mut link = FakeLink::default();
        let mut c = intake(None);
        assert_eq!(
            c.status(&link),
            "Robot not connected — value is sent when it reconnects"
        );
        assert_eq!(
            c.slider_value(&link),
            0.15,
            "fallback before anything is known"
        );
        link.up = true;
        link.set(STATE, d(0.5));
        assert_eq!(c.status(&link), "Using the robot's compiled constant");
        assert_eq!(
            c.slider_value(&link),
            0.5,
            "robot value when nothing is requested"
        );
        c.set_speed(&mut link, 0.42);
        assert_eq!(c.status(&link), "Waiting for the robot to confirm");
        link.set(STATE, d(0.424));
        assert_eq!(
            c.status(&link),
            "Robot confirmed this speed",
            "within 0.005"
        );
        link.set(STATE, d(0.426));
        assert_eq!(
            c.status(&link),
            "Waiting for the robot to confirm",
            "outside 0.005"
        );
        link.set(STATE, d(f64::NAN));
        assert_eq!(c.robot_speed(&link), None, "non-finite State is unusable");
        assert_eq!(c.slider_value(&link), 0.42);
        link.up = false;
        assert_eq!(c.status(&link), IntakeSpeed::STATUS_DISCONNECTED);
    }

    #[test]
    fn intake_publish_error_until_a_publish_succeeds() {
        let mut link = up();
        link.fail_publish = true;
        let mut c = intake(None);
        c.set_speed(&mut link, 0.3);
        assert_eq!(
            c.status_line(&link),
            "Could not publish /Shared/Intake/Speed/Request"
        );
        link.fail_publish = false;
        c.set_speed(&mut link, 0.31);
        assert_eq!(c.req.publish_error, None);
        assert_eq!(c.status_line(&link), IntakeSpeed::STATUS_WAITING);
    }

    #[test]
    fn intake_new_topics_release_and_republish() {
        let mut link = up();
        let mut c = Controls::new("Shared", Some(0.4));
        c.step(&mut link);
        c.set_shared_table(&mut link, "Other");
        assert_eq!(link.released, vec![REQ.to_owned()]);
        assert_eq!(link.last("/Other/Intake/Speed/Request"), Some(&d(0.4)));
    }

    const PUB: &str = AIM_TRIM_PUBLISH;
    const READ: &str = AIM_TRIM_READBACK;

    #[test]
    fn trim_confirmation_topic_follows_the_m1_finding() {
        let t = AimTrim::new();
        assert_eq!(t.req.topics.request, "/Tuning/Turret/AimTrimDeg");
        assert_eq!(
            t.req.topics.state, "/AdvantageKit/NetworkInputs/Tuning/Turret/AimTrimDeg",
            "confirmed on the AdvantageKit NetworkInputs mirror"
        );
    }

    #[test]
    fn trim_disabled_when_not_connected() {
        let mut link = FakeLink::default();
        let mut t = AimTrim::new();
        assert!(!t.set_trim(&mut link, 2.0));
        assert!(!t.center(&mut link));
        assert!(link.published.is_empty());
        assert_eq!(t.status(&link), "Robot not connected");
        assert_eq!(t.slider_value(&link), 0.0);
    }

    #[test]
    fn trim_clamp_round_and_dedupe() {
        let mut link = up();
        let mut t = AimTrim::new();
        assert!(t.set_trim(&mut link, 12.0));
        assert_eq!(link.last(PUB), Some(&d(10.0)));
        assert!(t.set_trim(&mut link, -3.456));
        assert_eq!(link.last(PUB), Some(&d(-3.46)));
        assert!(
            !t.set_trim(&mut link, -3.458),
            "within 0.005 of the last sent value"
        );
        assert_eq!(link.count(PUB), 2);
        assert!(t.set_trim(&mut link, -3.45));
        assert_eq!(link.count(PUB), 3);
    }

    #[test]
    fn trim_dedupe_against_robot_readback_and_confirmation() {
        let mut link = up();
        let mut t = AimTrim::new();
        link.set(READ, d(1.5));
        assert_eq!(t.status(&link), "Robot confirmed this trim");
        assert_eq!(t.slider_value(&link), 1.5);
        assert!(
            !t.set_trim(&mut link, 1.5),
            "already what the robot reports"
        );
        assert_eq!(link.count(PUB), 0);
        assert!(t.set_trim(&mut link, 2.25));
        assert_eq!(t.status(&link), "Waiting for the robot to confirm");
        assert_eq!(t.slider_value(&link), 2.25);
        link.set(READ, d(2.25));
        t.update(&mut link);
        assert_eq!(
            t.requested(),
            None,
            "request cleared once the readback matches"
        );
        assert_eq!(t.status(&link), "Robot confirmed this trim");
        assert!(t.center(&mut link));
        assert_eq!(link.last(PUB), Some(&d(0.0)), "Center publishes 0");
    }

    #[test]
    fn trim_no_readback_yet() {
        let link = up();
        assert_eq!(
            AimTrim::new().status(&link),
            "No trim reported by the robot yet"
        );
    }

    #[test]
    fn trim_not_persisted_and_dropped_on_disconnect() {
        let mut link = up();
        let mut t = AimTrim::new();
        t.update(&mut link);
        t.set_trim(&mut link, 4.0);
        link.up = false;
        t.update(&mut link);
        assert_eq!(t.requested(), None);
        assert!(
            link.forgotten.iter().any(|f| f == PUB),
            "publisher stops re-sending after a reconnect"
        );
        assert!(!link.desired.contains_key(PUB));
        link.up = true;
        t.update(&mut link);
        assert_eq!(link.count(PUB), 1, "nothing re-sent on reconnect");
    }

    #[test]
    fn trim_format_labels() {
        assert_eq!(AimTrim::format(0.0), "0°");
        assert_eq!(AimTrim::format(0.001), "0°");
        assert_eq!(AimTrim::format(2.5), "2.5° L");
        assert_eq!(AimTrim::format(-1.25), "1.25° R");
        assert_eq!(AimTrim::format(10.0), "10° L");
        assert_eq!(AimTrim::format(-0.75), "0.75° R");
    }

    #[test]
    fn trim_publish_error_until_a_publish_succeeds() {
        let mut link = up();
        link.fail_publish = true;
        let mut t = AimTrim::new();
        assert!(t.set_trim(&mut link, 2.0));
        assert_eq!(
            t.req.publish_error.as_deref(),
            Some("Could not publish /Tuning/Turret/AimTrimDeg")
        );
        link.fail_publish = false;
        assert!(t.set_trim(&mut link, 3.0));
        assert_eq!(t.req.publish_error, None);
    }

    fn rows(link: &FakeLink) -> std::collections::HashMap<&'static str, String> {
        readouts(link).into_iter().collect()
    }

    #[test]
    fn readouts_ten_rows_in_web_order() {
        let labels: Vec<_> = readouts(&FakeLink::default())
            .into_iter()
            .map(|(l, _)| l)
            .collect();
        assert_eq!(
            labels,
            [
                "Mode",
                "Distance",
                "RPM target",
                "RPM actual",
                "Leader",
                "Follower",
                "Spun up",
                "Shooting",
                "Turret",
                "Turret cmd"
            ]
        );
        assert_eq!(readout_topics().count(), 10);
    }

    #[test]
    fn readouts_missing_values_are_dashes() {
        let mut link = FakeLink::default();
        assert!(rows(&link).values().all(|v| v == "--"));
        link.set(out!("/Turret/DistanceToTarget"), d(3.0));
        assert_eq!(
            rows(&link)["Distance"],
            "--",
            "not shown while disconnected"
        );
        link.up = true;
        link.set(out!("/Shooter/VelocityRPM"), d(f64::INFINITY));
        assert_eq!(rows(&link)["RPM actual"], "--", "non-finite");
        link.set(out!("/Shooter/IsSpunUp"), d(1.0));
        assert_eq!(rows(&link)["Spun up"], "--", "wrong type");
    }

    #[test]
    fn readouts_formats() {
        let mut link = up();
        link.set(
            out!("/ShooterSubsystem/GPSAssistFeaturesEnabled"),
            Value::Bool(false),
        );
        link.set(out!("/Turret/DistanceToTarget"), d(3.456));
        link.set(out!("/Shooter/RequestedVelocityRPM"), d(3200.0));
        link.set(out!("/Shooter/VelocityRPM"), d(3187.6));
        link.set(out!("/Shooter/LeaderVelocityRPM"), Value::Int(3190));
        link.set(out!("/Shooter/FollowerVelocityRPM"), d(0.4));
        link.set(out!("/Shooter/IsSpunUp"), Value::Bool(true));
        link.set(out!("/MatchStatus/isShooting"), Value::Bool(false));
        link.set(out!("/Turret/PositionDeg"), d(-42.37));
        link.set(out!("/Turret/Angle"), d(PI / 2.0));
        let got = rows(&link);
        let want = [
            ("Mode", "Manual shooter"),
            ("Distance", "3.46 m"),
            ("RPM target", "3200"),
            ("RPM actual", "3188"),
            ("Leader", "3190"),
            ("Follower", "0"),
            ("Spun up", "Yes"),
            ("Shooting", "No"),
            ("Turret", "-42.4°"),
            ("Turret cmd", "90.0°"),
        ];
        for (k, v) in want {
            assert_eq!(got[k], v, "{k}");
        }
        link.set(
            out!("/ShooterSubsystem/GPSAssistFeaturesEnabled"),
            Value::Bool(true),
        );
        link.set(out!("/Turret/DistanceToTarget"), d(2.0));
        assert_eq!(rows(&link)["Mode"], "Auto shooter");
        assert_eq!(rows(&link)["Distance"], "2.00 m", "toFixed pads");
    }

    #[test]
    fn to_fixed_matches_javascript() {
        assert_eq!(to_fixed(2.5, 0), "3");
        assert_eq!(to_fixed(0.5, 0), "1");
        assert_eq!(to_fixed(-2.5, 0), "-3");
        assert_eq!(to_fixed(0.25, 1), "0.3");
        assert_eq!(
            to_fixed(1.005, 2),
            "1.00",
            "1.005 is below the tie in binary"
        );
        assert_eq!(to_fixed(0.125, 2), "0.13");
        assert_eq!(to_fixed(9.95, 1), "9.9");
        assert_eq!(to_fixed(9.5, 0), "10");
        assert_eq!(to_fixed(99.75, 1), "99.8");
        assert_eq!(to_fixed(-0.04, 1), "-0.0");
        assert_eq!(to_fixed(-0.0, 1), "0.0");
        assert_eq!(to_fixed(3187.6, 0), "3188");
    }
}
