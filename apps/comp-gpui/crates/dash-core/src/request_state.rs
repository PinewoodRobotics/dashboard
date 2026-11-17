//! The robot-control handshake shared by auto selection (L3) and the intake
//! speed and aim trim controls (L4): the dashboard publishes a Request, the
//! value stays pending until the robot echoes it on State, then it is
//! confirmed. Ports the common core of Godot's `control_link.gd`,
//! `intake_speed.gd`, `aim_trim.gd` and `auto_selection_sync.gd`, and of the
//! web's `usePathNetworkTable` / `useIntakeSpeedNetworkTable`.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Bool(bool),
    Int(i64),
    Double(f64),
    String(String),
    StringArray(Vec<String>),
}

impl Value {
    pub fn nt_type(&self) -> &'static str {
        match self {
            Value::Bool(_) => "boolean",
            Value::Int(_) => "int",
            Value::Double(_) => "double",
            Value::String(_) => "string",
            Value::StringArray(_) => "string[]",
        }
    }

    /// Finite numbers only: a NaN or infinite State is treated as absent.
    pub fn as_f64(&self) -> Option<f64> {
        let v = match *self {
            Value::Double(v) => v,
            Value::Int(v) => v as f64,
            _ => return None,
        };
        v.is_finite().then_some(v)
    }

    pub fn as_bool(&self) -> Option<bool> {
        match *self {
            Value::Bool(b) => Some(b),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::String(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_string_array(&self) -> Option<&[String]> {
        match self {
            Value::StringArray(v) => Some(v),
            _ => None,
        }
    }

    /// A fixture's JSON value. Integers stay `Int` unless they carry a
    /// fraction; arrays must hold only strings.
    pub fn from_json(v: &serde_json::Value) -> Option<Value> {
        use serde_json::Value as J;
        Some(match v {
            J::Bool(b) => Value::Bool(*b),
            J::Number(n) => match n.as_i64() {
                Some(i) => Value::Int(i),
                None => Value::Double(n.as_f64()?),
            },
            J::String(s) => Value::String(s.clone()),
            J::Array(a) => Value::StringArray(
                a.iter()
                    .map(|x| x.as_str().map(str::to_owned))
                    .collect::<Option<_>>()?,
            ),
            J::Null | J::Object(_) => return None,
        })
    }
}

/// The slice of NetworkTables the robot controls need. The NT client (L7)
/// implements it; tests use [`FakeLink`].
pub trait ControlLink {
    fn connected(&self) -> bool;
    /// The topic delivered a value on the current connection.
    fn live(&self, topic: &str) -> bool;
    fn value(&self, topic: &str) -> Option<Value>;
    /// A desired-state publish: sent now when connected and again after every
    /// reconnect until `forget` or `release`. Returns false when it failed.
    fn publish(&mut self, topic: &str, value: Value) -> bool;
    fn forget(&mut self, topic: &str);
    /// Stops publishing the topic altogether (its name changed).
    fn release(&mut self, topic: &str);
}

fn trim_slashes(s: &str) -> &str {
    s.trim().trim_matches('/')
}

/// `ntPathFromTableAndEntry` in packages/shared-core/src/settings-schema.ts.
pub fn nt_path(table: &str, entry: &str) -> String {
    format!("/{}/{}", trim_slashes(table), trim_slashes(entry))
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RequestTopics {
    pub request: String,
    pub state: String,
}

impl RequestTopics {
    pub fn new(table: &str, entry: &str) -> Self {
        let base = nt_path(table, entry);
        Self {
            request: format!("{base}/Request"),
            state: format!("{base}/State"),
        }
    }
}

pub trait Wire: Clone + PartialEq {
    fn to_value(&self) -> Value;
    fn from_value(v: &Value) -> Option<Self>;
}

impl Wire for f64 {
    fn to_value(&self) -> Value {
        Value::Double(*self)
    }
    fn from_value(v: &Value) -> Option<Self> {
        v.as_f64()
    }
}

impl Wire for bool {
    fn to_value(&self) -> Value {
        Value::Bool(*self)
    }
    fn from_value(v: &Value) -> Option<Self> {
        v.as_bool()
    }
}

impl Wire for String {
    fn to_value(&self) -> Value {
        Value::String(self.clone())
    }
    fn from_value(v: &Value) -> Option<Self> {
        v.as_str().map(str::to_owned)
    }
}

/// How close a reported double must be to count as the robot's echo.
pub const CONFIRM_EPS: f64 = 0.005;

pub fn approx_eq(a: &f64, b: &f64) -> bool {
    (a - b).abs() < CONFIRM_EPS
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Policy {
    /// On disconnect, `forget` the Request topic so the link does not re-send
    /// it to a rebooted robot (aim trim).
    pub forget_on_disconnect: bool,
    /// Drop a pending request the robot has not echoed after this long
    /// (auto selection: 1.5 s).
    pub pending_timeout_us: Option<i64>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Pending<T> {
    pub value: T,
    pub since_us: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RequestStatus {
    Disconnected,
    /// Nothing requested; the robot's own value applies.
    Idle {
        robot_known: bool,
    },
    Waiting,
    Confirmed,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct UpdateEvents {
    pub connected: bool,
    pub disconnected: bool,
    pub confirmed: bool,
    pub timed_out: bool,
}

/// One Request/State pair. `held` is an override kept across reconnects and
/// re-published on each (intake speed, the chosen auto); `pending` is the
/// last publish the robot has not echoed yet.
#[derive(Clone, Debug)]
pub struct RequestState<T: Wire> {
    pub topics: RequestTopics,
    pub policy: Policy,
    confirms: fn(&T, &T) -> bool,
    held: Option<T>,
    pending: Option<Pending<T>>,
    was_connected: bool,
    pub publishes: u32,
    pub last_published: Option<Value>,
    pub publish_error: Option<String>,
}

impl<T: Wire> RequestState<T> {
    pub fn new(topics: RequestTopics, policy: Policy, confirms: fn(&T, &T) -> bool) -> Self {
        Self {
            topics,
            policy,
            confirms,
            held: None,
            pending: None,
            was_connected: false,
            publishes: 0,
            last_published: None,
            publish_error: None,
        }
    }

    /// A stored override (persisted settings), published on the next connect.
    pub fn with_held(mut self, held: Option<T>) -> Self {
        self.held = held;
        self
    }

    pub fn held(&self) -> Option<&T> {
        self.held.as_ref()
    }

    pub fn pending(&self) -> Option<&Pending<T>> {
        self.pending.as_ref()
    }

    pub fn is_pending(&self) -> bool {
        self.pending.is_some()
    }

    /// The robot's State on the current connection.
    pub fn robot(&self, link: &dyn ControlLink) -> Option<T> {
        if !link.connected() || !link.live(&self.topics.state) {
            return None;
        }
        link.value(&self.topics.state)
            .as_ref()
            .and_then(T::from_value)
    }

    pub fn robot_confirms(&self, link: &dyn ControlLink, v: &T) -> bool {
        self.robot(link).is_some_and(|r| (self.confirms)(&r, v))
    }

    /// Sets the override and publishes it.
    pub fn hold(&mut self, link: &mut dyn ControlLink, now_us: i64, v: T) {
        self.held = Some(v.clone());
        self.send(link, now_us, v);
    }

    /// Publishes a one-off request without changing the override.
    pub fn send(&mut self, link: &mut dyn ControlLink, now_us: i64, v: T) {
        self.publish(link, &v);
        self.pending = Some(Pending {
            value: v,
            since_us: now_us,
        });
    }

    /// Clears the override and any pending request, publishing `sentinel`
    /// (intake speed's -1, "use the compiled constant") when given.
    pub fn clear(&mut self, link: &mut dyn ControlLink, sentinel: Option<T>) {
        self.held = None;
        self.pending = None;
        if let Some(s) = sentinel {
            self.publish(link, &s);
        }
    }

    /// Re-publishes the override (auto selection's throttled resync).
    pub fn republish(&mut self, link: &mut dyn ControlLink) -> bool {
        match self.held.clone() {
            Some(v) => {
                self.publish(link, &v);
                true
            }
            None => false,
        }
    }

    /// Whether publishing `v` would change anything: false when it matches
    /// the pending request or, with none, what the robot reports.
    pub fn would_change(&self, link: &dyn ControlLink, v: &T) -> bool {
        let target = self
            .pending
            .as_ref()
            .map(|p| p.value.clone())
            .or_else(|| self.robot(link));
        !target.is_some_and(|t| (self.confirms)(&t, v))
    }

    /// Switches to new topics: the old Request is released and the override
    /// published on the new one. Returns whether anything changed.
    pub fn set_topics(&mut self, link: &mut dyn ControlLink, topics: RequestTopics) -> bool {
        if topics == self.topics {
            return false;
        }
        link.release(&self.topics.request);
        self.topics = topics;
        self.pending = None;
        self.republish(link);
        true
    }

    pub fn update(&mut self, link: &mut dyn ControlLink, now_us: i64) -> UpdateEvents {
        let mut ev = UpdateEvents::default();
        let connected = link.connected();
        if connected && !self.was_connected {
            ev.connected = true;
            self.republish(link);
        }
        if !connected {
            ev.disconnected = self.was_connected;
            if self.policy.forget_on_disconnect && (self.was_connected || self.pending.is_some()) {
                link.forget(&self.topics.request);
            }
            self.pending = None;
        }
        self.was_connected = connected;

        if let Some(p) = self.pending.as_ref() {
            if self.robot_confirms(link, &p.value) {
                self.pending = None;
                ev.confirmed = true;
            } else if self
                .policy
                .pending_timeout_us
                .is_some_and(|t| now_us - p.since_us > t)
            {
                self.pending = None;
                ev.timed_out = true;
            }
        }
        ev
    }

    pub fn status(&self, link: &dyn ControlLink) -> RequestStatus {
        if !link.connected() {
            return RequestStatus::Disconnected;
        }
        let target = self
            .pending
            .as_ref()
            .map(|p| &p.value)
            .or(self.held.as_ref());
        match target {
            Some(t) if self.robot_confirms(link, t) => RequestStatus::Confirmed,
            Some(_) => RequestStatus::Waiting,
            None => RequestStatus::Idle {
                robot_known: self.robot(link).is_some(),
            },
        }
    }

    /// What a control shows: the pending request, else the override, else
    /// the robot's value.
    pub fn shown(&self, link: &dyn ControlLink) -> Option<T> {
        self.pending
            .as_ref()
            .map(|p| p.value.clone())
            .or_else(|| self.held.clone())
            .or_else(|| self.robot(link))
    }

    fn publish(&mut self, link: &mut dyn ControlLink, v: &T) {
        let value = v.to_value();
        self.publishes += 1;
        self.last_published = Some(value.clone());
        self.publish_error = (!link.publish(&self.topics.request, value))
            .then(|| format!("Could not publish {}", self.topics.request));
    }
}

/// In-memory [`ControlLink`]: `up` is the connection, `values` the topics
/// that arrived on it, `published` every publish in order.
#[derive(Clone, Debug, Default)]
pub struct FakeLink {
    pub up: bool,
    pub values: HashMap<String, Value>,
    pub published: Vec<(String, Value)>,
    pub desired: HashMap<String, Value>,
    pub forgotten: Vec<String>,
    pub released: Vec<String>,
    pub fail_publish: bool,
}

impl FakeLink {
    pub fn set(&mut self, topic: &str, v: Value) {
        self.values.insert(topic.to_owned(), v);
    }

    pub fn count(&self, topic: &str) -> usize {
        self.published.iter().filter(|(t, _)| t == topic).count()
    }

    pub fn last(&self, topic: &str) -> Option<&Value> {
        self.published
            .iter()
            .rev()
            .find(|(t, _)| t == topic)
            .map(|(_, v)| v)
    }
}

impl ControlLink for FakeLink {
    fn connected(&self) -> bool {
        self.up
    }

    fn live(&self, topic: &str) -> bool {
        self.up && self.values.contains_key(topic)
    }

    fn value(&self, topic: &str) -> Option<Value> {
        self.values.get(topic).cloned()
    }

    fn publish(&mut self, topic: &str, value: Value) -> bool {
        if self.fail_publish {
            return false;
        }
        self.published.push((topic.to_owned(), value.clone()));
        self.desired.insert(topic.to_owned(), value);
        true
    }

    fn forget(&mut self, topic: &str) {
        self.forgotten.push(topic.to_owned());
        self.desired.remove(topic);
    }

    fn release(&mut self, topic: &str) {
        self.released.push(topic.to_owned());
        self.desired.remove(topic);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const REQ: &str = "/Shared/Intake/Speed/Request";
    const STATE: &str = "/Shared/Intake/Speed/State";

    fn intake(held: Option<f64>) -> RequestState<f64> {
        RequestState::new(
            RequestTopics::new("Shared", "Intake/Speed"),
            Policy::default(),
            approx_eq,
        )
        .with_held(held)
    }

    fn trim() -> RequestState<f64> {
        RequestState::new(
            RequestTopics {
                request: "/Tuning/Turret/AimTrimDeg".into(),
                state: "/AdvantageKit/NetworkInputs/Tuning/Turret/AimTrimDeg".into(),
            },
            Policy {
                forget_on_disconnect: true,
                pending_timeout_us: None,
            },
            approx_eq,
        )
    }

    fn auto_sel() -> RequestState<String> {
        RequestState::new(
            RequestTopics::new("Shared", "PathPlanner/SelectedPath"),
            Policy {
                forget_on_disconnect: false,
                pending_timeout_us: Some(1_500_000),
            },
            |a, b| a.trim().eq_ignore_ascii_case(b.trim()),
        )
    }

    fn d(v: f64) -> Value {
        Value::Double(v)
    }

    #[test]
    fn topic_paths() {
        let t = RequestTopics::new("Shared", "Intake/Speed");
        assert_eq!(t.request, REQ);
        assert_eq!(t.state, STATE);
        let t = RequestTopics::new(" /Shared/ ", "/PathPlanner/SelectedPath/");
        assert_eq!(t.request, "/Shared/PathPlanner/SelectedPath/Request");
        assert_eq!(t.state, "/Shared/PathPlanner/SelectedPath/State");
    }

    #[test]
    fn value_conversions() {
        assert_eq!(Value::Int(3).as_f64(), Some(3.0));
        assert_eq!(Value::Double(f64::NAN).as_f64(), None);
        assert_eq!(Value::Double(f64::INFINITY).as_f64(), None);
        assert_eq!(Value::String("0.4".into()).as_f64(), None);
        assert_eq!(Value::Double(0.5).nt_type(), "double");
        assert_eq!(
            String::from_value(&Value::String("A".into())),
            Some("A".into())
        );
        let j: serde_json::Value =
            serde_json::from_str(r#"[0.5, 4242, true, "B", ["a", "b"], [1], null]"#).unwrap();
        let got: Vec<_> = j.as_array().unwrap().iter().map(Value::from_json).collect();
        assert_eq!(
            got,
            vec![
                Some(Value::Double(0.5)),
                Some(Value::Int(4242)),
                Some(Value::Bool(true)),
                Some(Value::String("B".into())),
                Some(Value::StringArray(vec!["a".into(), "b".into()])),
                None,
                None,
            ]
        );
    }

    #[test]
    fn every_hold_publishes() {
        let mut link = FakeLink::default();
        let mut c = intake(None);
        c.hold(&mut link, 0, 0.42);
        c.hold(&mut link, 0, 1.0);
        c.hold(&mut link, 0, 0.0);
        assert_eq!(link.count(REQ), 3);
        assert_eq!(link.last(REQ), Some(&d(0.0)));
        assert_eq!(c.held(), Some(&0.0));
    }

    #[test]
    fn held_value_republished_on_every_connect() {
        let mut link = FakeLink::default();
        let mut c = intake(Some(0.37));
        c.update(&mut link, 0);
        assert_eq!(link.count(REQ), 0);
        link.up = true;
        assert!(c.update(&mut link, 0).connected);
        c.update(&mut link, 0);
        assert_eq!(link.count(REQ), 1);
        assert_eq!(link.last(REQ), Some(&d(0.37)));
        link.up = false;
        assert!(c.update(&mut link, 0).disconnected);
        link.up = true;
        c.update(&mut link, 0);
        assert_eq!(link.count(REQ), 2, "re-published after a reconnect");
    }

    #[test]
    fn nothing_held_publishes_nothing_on_connect() {
        let mut link = FakeLink::default();
        let mut c = intake(None);
        link.up = true;
        c.update(&mut link, 0);
        assert_eq!(link.count(REQ), 0);
    }

    #[test]
    fn clear_publishes_sentinel_and_stops_republishing() {
        let mut link = FakeLink::default();
        let mut c = intake(Some(0.6));
        c.clear(&mut link, Some(-1.0));
        assert_eq!(link.last(REQ), Some(&d(-1.0)));
        assert_eq!(c.held(), None);
        assert!(!c.is_pending());
        link.up = true;
        c.update(&mut link, 0);
        assert_eq!(
            link.count(REQ),
            1,
            "nothing held to re-publish after a clear"
        );
    }

    #[test]
    fn status_and_shown_value() {
        let mut link = FakeLink::default();
        let mut c = intake(None);
        assert_eq!(c.status(&link), RequestStatus::Disconnected);
        assert_eq!(c.shown(&link), None);
        link.up = true;
        assert_eq!(c.status(&link), RequestStatus::Idle { robot_known: false });
        link.set(STATE, d(0.5));
        assert_eq!(c.status(&link), RequestStatus::Idle { robot_known: true });
        assert_eq!(
            c.shown(&link),
            Some(0.5),
            "robot value when nothing is requested"
        );
        c.hold(&mut link, 0, 0.42);
        assert_eq!(c.status(&link), RequestStatus::Waiting);
        link.set(STATE, d(0.424));
        assert_eq!(c.status(&link), RequestStatus::Confirmed, "within 0.005");
        link.set(STATE, d(0.426));
        assert_eq!(c.status(&link), RequestStatus::Waiting, "outside 0.005");
        link.set(STATE, d(f64::NAN));
        assert_eq!(c.robot(&link), None, "non-finite State is unusable");
        assert_eq!(c.shown(&link), Some(0.42));
        link.up = false;
        assert_eq!(c.status(&link), RequestStatus::Disconnected);
    }

    #[test]
    fn held_override_stays_after_confirmation() {
        let mut link = FakeLink {
            up: true,
            ..Default::default()
        };
        let mut c = intake(None);
        c.update(&mut link, 0);
        c.hold(&mut link, 0, 0.3);
        link.set(STATE, d(0.3));
        assert!(c.update(&mut link, 0).confirmed);
        assert!(!c.is_pending());
        assert_eq!(c.held(), Some(&0.3));
        assert_eq!(c.status(&link), RequestStatus::Confirmed);
        link.set(STATE, d(0.15));
        assert_eq!(
            c.status(&link),
            RequestStatus::Waiting,
            "robot drifted off the override"
        );
    }

    #[test]
    fn publish_error_until_a_publish_succeeds() {
        let mut link = FakeLink {
            up: true,
            fail_publish: true,
            ..Default::default()
        };
        let mut c = intake(None);
        c.hold(&mut link, 0, 0.3);
        assert_eq!(
            c.publish_error.as_deref(),
            Some("Could not publish /Shared/Intake/Speed/Request")
        );
        link.fail_publish = false;
        c.hold(&mut link, 0, 0.31);
        assert_eq!(c.publish_error, None);
        assert_eq!(c.publishes, 2);
    }

    #[test]
    fn dedupe_against_pending_and_robot() {
        let mut link = FakeLink {
            up: true,
            ..Default::default()
        };
        let mut t = trim();
        link.set(&t.topics.state.clone(), d(1.5));
        assert!(
            !t.would_change(&link, &1.5),
            "already what the robot reports"
        );
        assert!(t.would_change(&link, &2.25));
        t.send(&mut link, 0, 2.25);
        assert!(
            !t.would_change(&link, &2.252),
            "within 0.005 of the pending value"
        );
        assert!(
            t.would_change(&link, &1.5),
            "the pending value wins over the robot"
        );
        assert_eq!(t.status(&link), RequestStatus::Waiting);
        assert_eq!(t.shown(&link), Some(2.25));
        link.set(&t.topics.state.clone(), d(2.25));
        assert!(t.update(&mut link, 0).confirmed);
        assert!(!t.is_pending());
        assert_eq!(t.status(&link), RequestStatus::Idle { robot_known: true });
    }

    #[test]
    fn dropped_and_forgotten_on_disconnect() {
        let mut link = FakeLink {
            up: true,
            ..Default::default()
        };
        let mut t = trim();
        let topic = t.topics.request.clone();
        t.update(&mut link, 0);
        t.send(&mut link, 0, 4.0);
        link.up = false;
        t.update(&mut link, 0);
        assert!(!t.is_pending());
        assert!(link.forgotten.contains(&topic));
        assert!(!link.desired.contains_key(&topic));
        link.up = true;
        t.update(&mut link, 0);
        assert_eq!(link.count(&topic), 1, "nothing re-sent on reconnect");
    }

    #[test]
    fn pending_times_out_or_clears_on_echo_or_disconnect() {
        let mut link = FakeLink {
            up: true,
            ..Default::default()
        };
        let mut s = auto_sel();
        let state = s.topics.state.clone();
        s.update(&mut link, 0);
        s.hold(&mut link, 0, "Stay And Shoot".into());
        assert!(!s.update(&mut link, 1_400_000).timed_out);
        assert!(s.is_pending());
        assert!(s.update(&mut link, 1_600_000).timed_out);
        assert!(!s.is_pending());
        assert_eq!(s.held().map(String::as_str), Some("Stay And Shoot"));

        s.hold(&mut link, 2_000_000, "Ball Shooter Left".into());
        link.set(&state, Value::String(" ball shooter left ".into()));
        assert!(
            s.update(&mut link, 2_100_000).confirmed,
            "case-insensitive echo"
        );

        s.hold(&mut link, 3_000_000, "Stay And Shoot".into());
        link.up = false;
        s.update(&mut link, 3_100_000);
        assert!(!s.is_pending(), "a dropped connection ends the wait");
        assert!(
            link.forgotten.is_empty(),
            "the selection keeps being published"
        );
    }

    #[test]
    fn new_topics_release_the_old_and_republish() {
        let mut link = FakeLink {
            up: true,
            ..Default::default()
        };
        let mut c = intake(Some(0.4));
        c.update(&mut link, 0);
        let next = RequestTopics::new("Other", "Intake/Speed");
        assert!(c.set_topics(&mut link, next.clone()));
        assert_eq!(link.released, vec![REQ.to_owned()]);
        assert_eq!(link.last(&next.request), Some(&d(0.4)));
        assert!(!c.set_topics(&mut link, next));
    }
}
