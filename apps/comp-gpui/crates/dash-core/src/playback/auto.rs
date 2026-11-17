use serde_json::{Map, Value};

use super::angle::{lerp, lerp_angle};
use crate::autos::field::Pose;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Alliance {
    Red,
    Blue,
}

impl Alliance {
    pub const BOTH: [Alliance; 2] = [Alliance::Red, Alliance::Blue];

    pub fn from_red(red: bool) -> Self {
        if red { Alliance::Red } else { Alliance::Blue }
    }

    pub fn is_red(self) -> bool {
        self == Alliance::Red
    }

    pub fn key(self) -> &'static str {
        match self {
            Alliance::Red => "red",
            Alliance::Blue => "blue",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Channel {
    X,
    Y,
    Heading,
    Vx,
    Vy,
    Omega,
}

impl Channel {
    pub const ALL: [Channel; 6] = [
        Channel::X,
        Channel::Y,
        Channel::Heading,
        Channel::Vx,
        Channel::Vy,
        Channel::Omega,
    ];

    pub fn key(self) -> &'static str {
        match self {
            Channel::X => "x",
            Channel::Y => "y",
            Channel::Heading => "heading",
            Channel::Vx => "vx",
            Channel::Vy => "vy",
            Channel::Omega => "omega",
        }
    }
}

/// Field-relative pose and velocity at one instant (blue-origin m, m/s, rad, rad/s).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Sample {
    pub x: f64,
    pub y: f64,
    pub heading: f64,
    pub vx: f64,
    pub vy: f64,
    pub omega: f64,
}

impl Sample {
    pub fn pose(&self) -> Pose {
        Pose::new(self.x, self.y, self.heading)
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Segment {
    /// "path" or "hold".
    pub kind: String,
    pub name: String,
    pub t0: f64,
    pub t1: f64,
    pub max_velocity_mps: Option<f64>,
}

impl Segment {
    pub fn is_path(&self) -> bool {
        self.kind == "path"
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct AutoEvent {
    pub name: String,
    /// "command", "marker", "zone_marker" or "noop".
    pub kind: String,
    pub t0: f64,
    pub t1: f64,
    /// "self", "deadline", "auto_end", ...
    pub end_reason: String,
    pub source: String,
    pub registered: bool,
    pub trigger_bound: bool,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct AutoWarning {
    pub code: String,
    pub name: String,
    pub message: String,
}

#[derive(Clone, Debug, Default, PartialEq)]
struct Channels([Vec<f64>; 6]);

impl Channels {
    fn get(&self, c: Channel) -> &[f64] {
        &self.0[c as usize]
    }
}

/// One exported auto (`data/autos/<name>.json`): poses on a fixed dt grid for
/// both alliances plus its timeline. Sampling is a pure function of t.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct AutoPlayback {
    pub name: String,
    pub folder: String,
    pub dt: f64,
    pub duration_s: f64,
    pub nominal_duration_s: f64,
    pub auto_length_s: f64,
    pub ends_by_itself: bool,
    pub sample_count: usize,
    pub paths: Vec<String>,
    pub segments: Vec<Segment>,
    pub events: Vec<AutoEvent>,
    pub warnings: Vec<AutoWarning>,
    start_pose: Option<[Pose; 2]>,
    end_pose: Option<[Pose; 2]>,
    channels: Option<[Channels; 2]>,
}

fn num(v: Option<&Value>) -> Option<f64> {
    v.and_then(Value::as_f64).filter(|f| f.is_finite())
}

fn text(v: Option<&Value>) -> String {
    match v {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Null) | None => String::new(),
        Some(other) => other.to_string(),
    }
}

fn flag(v: Option<&Value>) -> bool {
    match v {
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_f64().is_some_and(|f| f != 0.0),
        _ => false,
    }
}

fn pose3(v: &Value) -> Pose {
    let a = v.as_array().map(Vec::as_slice).unwrap_or(&[]);
    let at = |i: usize| a.get(i).and_then(Value::as_f64).unwrap_or(0.0);
    Pose::new(at(0), at(1), at(2))
}

fn side(alliance: Alliance) -> usize {
    match alliance {
        Alliance::Red => 0,
        Alliance::Blue => 1,
    }
}

impl AutoPlayback {
    /// Why `d` cannot be played back, or "" when it can. `from_value` trusts
    /// its input, so every export goes through this first.
    pub fn validate(d: &Value) -> String {
        let Some(d) = d.as_object() else {
            return "not a JSON object".into();
        };
        for k in ["dt", "duration_s"] {
            if !num(d.get(k)).is_some_and(|v| v >= 0.0) {
                return format!("bad {k}");
            }
        }
        if num(d.get("dt")).unwrap() <= 0.0 {
            return "bad dt".into();
        }
        for k in ["segments", "events", "warnings"] {
            if d.get(k).is_some_and(|v| !v.is_array()) {
                return format!("bad {k}");
            }
        }
        let list = |k: &str| {
            d.get(k)
                .and_then(Value::as_array)
                .map(Vec::as_slice)
                .unwrap_or(&[])
        };
        for e in list("events") {
            if !e.is_object() || num(e.get("t0")).is_none() || num(e.get("t1")).is_none() {
                return "bad event".into();
            }
        }
        for s in list("segments") {
            if !s.is_object() || num(s.get("t1")).is_none() {
                return "bad segment".into();
            }
        }
        for w in list("warnings") {
            if !w.as_object().is_some_and(|w| w.contains_key("code")) {
                return "bad warning".into();
            }
        }
        let samples = d.get("samples").and_then(Value::as_object);
        let has_path = samples.is_some_and(|s| s.get("red").is_some_and(|v| !v.is_null()));
        if !has_path {
            return String::new();
        }
        let samples = samples.unwrap();
        let mut n: Option<usize> = None;
        for alliance in Alliance::BOTH {
            let s = alliance.key();
            let Some(raw) = samples.get(s).and_then(Value::as_object) else {
                return format!("no {s} samples");
            };
            for c in Channel::ALL {
                let k = c.key();
                let Some(a) = raw
                    .get(k)
                    .and_then(Value::as_array)
                    .filter(|a| !a.is_empty())
                else {
                    return format!("missing {s} samples: {k}");
                };
                let want = *n.get_or_insert(a.len());
                if a.len() != want {
                    return format!("{s} {k} has {} samples, expected {want}", a.len());
                }
                if a.iter().any(|v| num(Some(v)).is_none()) {
                    return format!("non-numeric {s} {k} sample");
                }
            }
            for k in ["start_pose", "end_pose"] {
                let pose = d
                    .get(k)
                    .and_then(Value::as_object)
                    .and_then(|p| p.get(s))
                    .and_then(Value::as_array);
                if !pose.is_some_and(|p| p.len() == 3 && p.iter().all(|v| num(Some(v)).is_some())) {
                    return format!("bad {k}");
                }
            }
        }
        String::new()
    }

    pub fn from_value(d: &Value) -> AutoPlayback {
        let empty = Map::new();
        let d = d.as_object().unwrap_or(&empty);
        let list = |k: &str| {
            d.get(k)
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default()
        };
        let duration_s = num(d.get("duration_s")).unwrap_or(0.0);
        let mut p = AutoPlayback {
            name: text(d.get("name")),
            folder: text(d.get("folder")),
            dt: num(d.get("dt")).unwrap_or(0.02),
            duration_s,
            nominal_duration_s: num(d.get("nominal_duration_s")).unwrap_or(duration_s),
            auto_length_s: num(d.get("auto_length_s")).unwrap_or(20.0),
            ends_by_itself: flag(d.get("ends_by_itself")),
            paths: list("paths").iter().map(|v| text(Some(v))).collect(),
            segments: list("segments")
                .iter()
                .map(|s| Segment {
                    kind: text(s.get("type")),
                    name: text(s.get("name")),
                    t0: num(s.get("t0")).unwrap_or(0.0),
                    t1: num(s.get("t1")).unwrap_or(0.0),
                    max_velocity_mps: num(s.get("max_velocity_mps")),
                })
                .collect(),
            events: list("events")
                .iter()
                .map(|e| AutoEvent {
                    name: text(e.get("name")),
                    kind: text(e.get("kind")),
                    t0: num(e.get("t0")).unwrap_or(0.0),
                    t1: num(e.get("t1")).unwrap_or(0.0),
                    end_reason: text(e.get("end_reason")),
                    source: text(e.get("source")),
                    registered: flag(e.get("registered")),
                    trigger_bound: flag(e.get("trigger_bound")),
                })
                .collect(),
            warnings: list("warnings")
                .iter()
                .map(|w| AutoWarning {
                    code: text(w.get("code")),
                    name: text(w.get("name")),
                    message: text(w.get("message")),
                })
                .collect(),
            ..Default::default()
        };
        let poses = |k: &str| {
            d.get(k).and_then(Value::as_object).map(|o| {
                [
                    pose3(o.get("red").unwrap_or(&Value::Null)),
                    pose3(o.get("blue").unwrap_or(&Value::Null)),
                ]
            })
        };
        p.start_pose = poses("start_pose");
        p.end_pose = poses("end_pose");
        let samples = d.get("samples").and_then(Value::as_object);
        let channels = |alliance: Alliance| {
            let raw = samples?.get(alliance.key())?.as_object()?;
            Some(Channels(Channel::ALL.map(|c| {
                raw.get(c.key())
                    .and_then(Value::as_array)
                    .map(|a| a.iter().map(|v| v.as_f64().unwrap_or(0.0)).collect())
                    .unwrap_or_default()
            })))
        };
        if let (Some(red), Some(blue)) = (channels(Alliance::Red), channels(Alliance::Blue)) {
            p.sample_count = red.get(Channel::X).len();
            p.channels = Some([red, blue]);
        }
        p
    }

    pub fn parse(text: &str) -> Result<AutoPlayback, String> {
        let v: Value =
            serde_json::from_str(text).map_err(|e| format!("not valid JSON, line {}", e.line()))?;
        match Self::validate(&v) {
            why if why.is_empty() => Ok(Self::from_value(&v)),
            why => Err(why),
        }
    }

    pub fn has_path(&self) -> bool {
        self.sample_count > 0
    }

    /// Until the auto ends by itself, otherwise the whole auto period, since
    /// its never-ending commands run until then.
    pub fn timeline_s(&self) -> f64 {
        let end = if self.ends_by_itself {
            self.nominal_duration_s
        } else {
            self.auto_length_s
        };
        end.max(self.duration_s)
    }

    pub fn start_pose(&self, alliance: Alliance) -> Option<Pose> {
        self.start_pose.map(|p| p[side(alliance)])
    }

    pub fn end_pose(&self, alliance: Alliance) -> Option<Pose> {
        self.end_pose.map(|p| p[side(alliance)])
    }

    /// Clamped to [0, duration_s]; None when the auto has no path.
    pub fn sample(&self, t: f64, alliance: Alliance) -> Option<Sample> {
        if self.sample_count == 0 {
            return None;
        }
        let ch = &self.channels.as_ref()?[side(alliance)];
        let u = t.clamp(0.0, self.duration_s) / self.dt;
        let i = (u.floor().max(0.0) as usize).min(self.sample_count - 1);
        let j = (i + 1).min(self.sample_count - 1);
        let f = if j != i {
            (u - i as f64).clamp(0.0, 1.0)
        } else {
            0.0
        };
        let at = |c: Channel| {
            let a = ch.get(c);
            if c == Channel::Heading {
                lerp_angle(a[i], a[j], f)
            } else {
                lerp(a[i], a[j], f)
            }
        };
        Some(Sample {
            x: at(Channel::X),
            y: at(Channel::Y),
            heading: at(Channel::Heading),
            vx: at(Channel::Vx),
            vy: at(Channel::Vy),
            omega: at(Channel::Omega),
        })
    }

    pub fn sample_pose(&self, t: f64, alliance: Alliance) -> Option<Pose> {
        self.sample(t, alliance).map(|s| s.pose())
    }

    pub fn sample_at(&self, index: usize, alliance: Alliance) -> Pose {
        let ch = &self.channels.as_ref().expect("auto has samples")[side(alliance)];
        Pose::new(
            ch.get(Channel::X)[index],
            ch.get(Channel::Y)[index],
            ch.get(Channel::Heading)[index],
        )
    }

    pub fn channel(&self, c: Channel, alliance: Alliance) -> &[f64] {
        self.channels
            .as_ref()
            .map_or(&[], |ch| ch[side(alliance)].get(c))
    }

    /// Events whose interval contains t; instant events only at their own time.
    pub fn events_at(&self, t: f64) -> Vec<&AutoEvent> {
        self.events
            .iter()
            .filter(|e| {
                e.t0 <= t && (t < e.t1 || (e.t0 == e.t1 && super::angle::is_equal_approx(t, e.t0)))
            })
            .collect()
    }

    pub fn segment_at(&self, t: f64) -> Option<&Segment> {
        self.segments
            .iter()
            .find(|s| t <= s.t1)
            .or(self.segments.last())
    }

    pub fn warning_codes(&self) -> Vec<&str> {
        let mut out: Vec<&str> = Vec::new();
        for w in &self.warnings {
            if !out.contains(&w.code.as_str()) {
                out.push(&w.code);
            }
        }
        out
    }
}
