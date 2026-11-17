//! F3 overlay (comp-godot ui/debug/debug_overlay.gd): the NT client's
//! diagnostics and a table of every topic the dashboard reads, with its
//! current value. F3 toggles it on the focused window; `--debug-overlay`
//! opens it at start. Until the NT client lands the rows come from the mock
//! data, under the topic names the robot publishes them on.

use std::collections::HashSet;

use dash_core::nt::NtValue;
use dash_core::request_state::Value;
use gpui_kit::*;

use crate::mock::MockData;
use crate::theme::{ACCENT, BLACK, MONO, WHITE, ZINC_400, alpha, hex, u};
use crate::widgets::{Axis2, Scroll};

const MATCH: &str = "/matchhud/state/";
const RO: &str = "/AdvantageKit/RealOutputs/";
const TYPE_W: f32 = 120.0;

pub struct TopicRow {
    pub name: String,
    pub kind: &'static str,
    pub value: Option<Value>,
    pub age_ms: Option<u128>,
}

fn row(name: impl Into<String>, kind: &'static str, value: Option<Value>) -> TopicRow {
    TopicRow {
        name: name.into(),
        kind,
        value,
        age_ms: None,
    }
}

fn dbl(v: Option<f64>) -> Option<Value> {
    v.map(Value::Double)
}

fn boolean(v: Option<bool>) -> Option<Value> {
    v.map(Value::Bool)
}

/// Every topic the dashboard subscribes to or publishes (Godot
/// Topics.subscription_groups plus the Request topics), sorted by name.
pub fn topics(d: &MockData) -> Vec<TopicRow> {
    let m = &d.matchs;
    let int = |v: i64| Some(Value::Int(v));
    let b = |v: bool| Some(Value::Bool(v));
    let f = |v: f64| Some(Value::Double(v));
    let match_rows: Vec<(&str, &'static str, Option<Value>)> = vec![
        ("seq", "int", int(m.seq)),
        ("robot_time_us", "int", int(m.robot_time_us)),
        ("connected", "boolean", b(m.robot_connected)),
        ("is_red_alliance", "boolean", m.is_red_alliance.map(Value::Bool)),
        ("enabled", "boolean", b(m.enabled)),
        ("autonomous", "boolean", b(m.autonomous)),
        (
            "game_specific_message",
            "string",
            Some(Value::String(m.game_specific_message.clone())),
        ),
        ("match_phase", "int", int(m.phase as i64)),
        ("hub_status", "int", int(m.hub as i64)),
        ("header_color", "int", int(m.header as i64)),
        ("total_time_remaining_s", "double", f(m.total_time_remaining_s)),
        ("period_time_remaining_s", "double", f(m.period_time_remaining_s)),
        ("shift_time_remaining_s", "double", f(m.shift_time_remaining_s)),
        ("shift_time_with_buffer_s", "double", f(m.shift_time_with_buffer_s)),
        ("buffer_remaining_s", "double", f(m.buffer_remaining_s)),
        ("is_shooting", "boolean", b(m.is_shooting)),
        ("show_shift_indicator", "boolean", b(m.show_shift_indicator)),
        ("show_buffer", "boolean", b(m.show_buffer)),
        ("robot_pose_x_m", "double", f(d.pose.x_m)),
        ("robot_pose_y_m", "double", f(d.pose.y_m)),
        ("robot_heading_rad", "double", f(d.pose.heading_rad)),
        ("robot_pose_valid", "boolean", b(d.pose.valid)),
        ("auto_align_active", "boolean", b(d.align.active)),
        ("auto_align_distance_m", "double", f(d.align.distance_m)),
        ("auto_align_ready", "boolean", b(d.align.ready)),
        ("driver_override", "boolean", b(d.align.driver_override)),
        ("aim_mode", "int", int(m.aim as i64)),
        (
            "camera_topic",
            "string",
            d.align.camera_topic.clone().map(Value::String),
        ),
    ];
    let feed = &d.match_feed;
    let age = (!feed.clock.is_frozen() && feed.model.has_data())
        .then(|| ((feed.now_us() - feed.model.last_seq_change_us()).max(0) / 1000) as u128);
    let mut out: Vec<TopicRow> = match_rows
        .into_iter()
        .map(|(k, kind, value)| TopicRow {
            name: format!("{MATCH}{k}"),
            kind,
            age_ms: value.as_ref().and(age),
            value,
        })
        .collect();

    let r = &d.readouts;
    let p = &d.pathplanner;
    let c = &d.controls;
    let sel = &d.auto_selection.link;
    out.extend([
        row(format!("{RO}IntakeSubsystem/WristPosition"), "double", dbl(d.joints.wrist)),
        row(format!("{RO}Turret/PositionRot"), "double", dbl(d.joints.turret_rot)),
        row(
            format!("{RO}Climber/CurrentHeightMeters"),
            "double",
            dbl(d.joints.climber_height_m),
        ),
        row(format!("{RO}Turret/DistanceToTarget"), "double", dbl(r.distance_to_target_m)),
        row(format!("{RO}Shooter/RequestedVelocityRPM"), "double", dbl(r.requested_rpm)),
        row(format!("{RO}Shooter/VelocityRPM"), "double", dbl(r.velocity_rpm)),
        row(format!("{RO}Shooter/LeaderVelocityRPM"), "double", dbl(r.leader_rpm)),
        row(format!("{RO}Shooter/FollowerVelocityRPM"), "double", dbl(r.follower_rpm)),
        row(format!("{RO}Turret/PositionDeg"), "double", dbl(r.turret_position_deg)),
        row(format!("{RO}Turret/Angle"), "double", dbl(r.turret_angle)),
        row(format!("{RO}Shooter/IsSpunUp"), "boolean", boolean(r.is_spun_up)),
        row(
            format!("{RO}ShooterSubsystem/GPSAssistFeaturesEnabled"),
            "boolean",
            boolean(r.gps_assist_enabled),
        ),
        row(format!("{RO}MatchStatus/isShooting"), "boolean", boolean(r.is_shooting)),
        row(
            format!("{RO}SwerveSubsystem/AdjustingVelocity"),
            "boolean",
            boolean(d.lane.adjusting_velocity),
        ),
        row(
            format!("{RO}PathPlanner/CurrentSelectedAuto"),
            "string",
            p.current_selected_auto.clone().map(Value::String),
        ),
        row(
            format!("{RO}PathPlanner/SelectedAutoValid"),
            "boolean",
            boolean(p.selected_auto_valid),
        ),
        row(
            format!("{RO}PathPlanner/ValidNames/Autos"),
            "string[]",
            p.valid_autos.clone().map(Value::StringArray),
        ),
        row(
            format!("{RO}PathPlanner/DeployHash"),
            "string",
            p.deploy_hash.clone().map(Value::String),
        ),
    ]);
    let nt = d.nt_link.as_ref().map(|l| l.borrow());
    let request = |topic: &str, mock: Option<Value>| match &nt {
        Some(nt) => nt.desired(topic).and_then(NtValue::to_control_value),
        None => mock,
    };
    let state = |topic: &str, mock: Option<Value>| match &nt {
        Some(nt) => nt.get(topic).and_then(NtValue::to_control_value),
        None => mock,
    };
    let pairs = [
        (&sel.topics, "string", sel.request.clone().map(Value::String), sel.state.clone().map(Value::String)),
        (&c.intake.topics, "double", dbl(c.intake.request), dbl(c.intake.state)),
        (&c.aim_trim.topics, "double", dbl(c.aim_trim.request), dbl(c.aim_trim.state)),
    ];
    for (topics, kind, req, st) in pairs {
        out.push(row(topics.request.clone(), kind, request(&topics.request, req)));
        out.push(row(topics.state.clone(), kind, state(&topics.state, st)));
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

/// DebugOverlay.format_value.
pub fn format_value(v: Option<&Value>) -> String {
    match v {
        None => "-".into(),
        Some(Value::Double(x)) => format!("{x:.4}"),
        Some(Value::Int(i)) => i.to_string(),
        Some(Value::Bool(b)) => b.to_string(),
        Some(Value::String(s)) => format!("\"{s}\""),
        Some(Value::StringArray(a)) => {
            let s = format!(
                "[{}]",
                a.iter()
                    .map(|x| format!("\"{x}\""))
                    .collect::<Vec<_>>()
                    .join(", ")
            );
            if s.chars().count() <= 80 {
                s
            } else {
                s.chars().take(77).collect::<String>() + "..."
            }
        }
    }
}

pub fn header_lines(d: &MockData, topic_count: usize) -> [String; 4] {
    let nt = &d.nt;
    let dash = |s: &str| if s.is_empty() { "-".to_owned() } else { s.to_owned() };
    let rtt = if nt.rtt_us >= 0 {
        format!("{:.2} ms", nt.rtt_us as f64 / 1000.0)
    } else {
        "-".into()
    };
    let url = if nt.url.is_empty() {
        format!("{}:{}", nt.host, nt.port)
    } else {
        nt.url.clone()
    };
    let source = if d.nt_link.is_some() { "" } else { "  (mock data)" };
    [
        "NT4  F3 to close".into(),
        format!("{url}  [{}]  protocol {}", nt.state.name(), dash(&nt.protocol)),
        format!(
            "rtt {rtt}  offset {} us  server time {} us",
            nt.offset_us, nt.server_time_us
        ),
        format!(
            "topics {topic_count}  values {:.0}/s ({} total)  connects {}  reconnects {}  \
             watchdog {}/{}  last close: {}{source}",
            nt.values_per_s,
            nt.values_total,
            nt.connects,
            nt.reconnects,
            nt.connect_watchdog_fires,
            nt.liveness_fires,
            dash(&nt.last_close)
        ),
    ]
}

#[derive(Default)]
struct OpenWindows(HashSet<WindowId>);

struct Shared(Entity<OpenWindows>);

impl Global for Shared {}

fn state(cx: &mut App) -> Entity<OpenWindows> {
    if let Some(s) = cx.try_global::<Shared>() {
        return s.0.clone();
    }
    let s = cx.new(|_| OpenWindows::default());
    cx.set_global(Shared(s.clone()));
    s
}

pub fn init(cx: &mut App) {
    cx.observe_keystrokes(|e, window, cx| {
        let ks = &e.keystroke;
        if ks.key == "f3" && !ks.modifiers.modified() {
            toggle(window.window_handle().window_id(), cx);
        }
    })
    .detach();
}

pub fn toggle(id: WindowId, cx: &mut App) {
    state(cx).update(cx, |s, cx| {
        if !s.0.remove(&id) {
            s.0.insert(id);
        }
        cx.notify();
    });
}

pub fn open(id: WindowId, cx: &mut App) {
    state(cx).update(cx, |s, cx| {
        if s.0.insert(id) {
            cx.notify();
        }
    });
}

fn cell(text: impl Into<SharedString>) -> Div {
    div()
        .overflow_hidden()
        .whitespace_nowrap()
        .pr(u(12.))
        .child(text.into())
}

fn table_row(cols: [String; 5], color: Rgba) -> Div {
    let [name, kind, value, age, updates] = cols;
    div()
        .flex()
        .w_full()
        .h(u(24.))
        .items_center()
        .text_color(color)
        .child(cell(name).flex_grow(3.0).flex_basis(relative(0.)).min_w_0())
        .child(cell(kind).flex_none().w(u(TYPE_W)))
        .child(cell(value).flex_grow(2.0).flex_basis(relative(0.)).min_w_0())
        .child(cell(age).flex_none().w(u(TYPE_W)))
        .child(cell(updates).flex_none().w(u(TYPE_W)))
}

pub fn layer(data: &Entity<MockData>, window: &mut Window, cx: &mut App) -> AnyElement {
    let id = window.window_handle().window_id();
    if !state(cx).read(cx).0.contains(&id) {
        return div().into_any_element();
    }
    let d = data.read(cx);
    let rows = topics(d);
    let header = header_lines(d, rows.len());

    let mut table = Scroll::new("debug-topics", Axis2::Vertical).auto();
    table = table.child(table_row(
        [
            "Topic".into(),
            "Type".into(),
            "Value".into(),
            "Age ms".into(),
            "Updates".into(),
        ],
        ZINC_400,
    ));
    for r in rows {
        let live = r.value.is_some();
        table = table.child(table_row(
            [
                r.name,
                r.kind.into(),
                format_value(r.value.as_ref()),
                r.age_ms.map(|a| a.to_string()).unwrap_or_else(|| "-".into()),
                "-".into(),
            ],
            if live { WHITE } else { alpha(WHITE, 0.45) },
        ));
    }

    div()
        .id("debug-overlay")
        .absolute()
        .top_0()
        .left_0()
        .size_full()
        .occlude()
        .on_mouse_down(MouseButton::Left, |_, _, _| crate::input::veto_swipe())
        .p(u(24.))
        .child(
            div()
                .size_full()
                .flex()
                .flex_col()
                .gap(u(12.))
                .p(u(16.))
                .bg(hex(0x0a0a0a))
                .border(u(2.))
                .border_color(ACCENT)
                .font_family(MONO)
                .text_color(WHITE)
                .child(
                    div()
                        .flex_none()
                        .text_size(u(20.))
                        .line_height(u(26.))
                        .children(header.into_iter().map(|l| div().child(l))),
                )
                .child(
                    div()
                        .flex_grow(1.0)
                        .min_h_0()
                        .bg(BLACK)
                        .text_size(u(16.))
                        .child(table),
                ),
        )
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mock::Scenario;

    #[std::prelude::v1::test]
    fn format_value_matches_godot() {
        assert_eq!(format_value(None), "-");
        assert_eq!(format_value(Some(&Value::Double(3.14159265))), "3.1416");
        assert_eq!(format_value(Some(&Value::Int(-7))), "-7");
        assert_eq!(format_value(Some(&Value::Bool(true))), "true");
        assert_eq!(format_value(Some(&Value::String("a".into()))), "\"a\"");
        let short = Value::StringArray(vec!["a".into(), "b".into()]);
        assert_eq!(format_value(Some(&short)), "[\"a\", \"b\"]");
        let long = Value::StringArray((0..30).map(|i| format!("auto {i}")).collect());
        let s = format_value(Some(&long));
        assert_eq!(s.chars().count(), 80);
        assert!(s.ends_with("..."));
    }

    #[std::prelude::v1::test]
    fn every_topic_listed_once_and_sorted() {
        let d = MockData::new(Scenario::ShiftActive);
        let rows = topics(&d);
        assert_eq!(rows.iter().filter(|r| r.name.starts_with(MATCH)).count(), 28);
        assert_eq!(rows.len(), 28 + 3 + 10 + 1 + 4 + 6);
        assert!(rows.windows(2).all(|w| w[0].name < w[1].name));
        let camera = rows.iter().find(|r| r.name.ends_with("camera_topic")).unwrap();
        assert!(camera.value.is_none(), "the FIR robot never publishes it");
        let intake = rows
            .iter()
            .find(|r| r.name == "/Shared/Intake/Speed/State")
            .unwrap();
        assert_eq!(intake.value, Some(Value::Double(0.5)));
    }
}
