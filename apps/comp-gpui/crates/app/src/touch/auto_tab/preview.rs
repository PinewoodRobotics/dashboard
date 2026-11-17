//! The Auto tab's preview box (Godot's auto_preview_panel.gd, in place of
//! PathDetailPane.tsx's GIF): the stage, where the realtime 3D preview will
//! go and the web's path-overview picture stands for now, with mechanism
//! chips, the start pose check, the event feed, the Path/Field toggle,
//! reset-view and expand buttons and the auto's notes over it; then the scrub
//! bar and the transport row (play/pause, restart, time, speed, loop,
//! alliance). Everything reads and drives the shared clock in
//! [`AutoService`], so the HUD can mirror exactly what plays here.

use std::rc::Rc;
use std::time::{Duration, Instant};

use dash_core::playback::{AutoClock, StartPoseCheck, StartPoseLevel};
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;

use super::kit::{AMBER, Btn, Look, RADIUS, ZINC_950, note};
use super::scrub::{ScrubLayout, kind_color, scrub_bar, short_name};
use crate::autos::AutoService;
use crate::icons::lucide;
use crate::input::{self, Phase};
use crate::theme::{
    ACCENT, BLACK, INTER, WHITE, ZINC_300, ZINC_400, ZINC_500, ZINC_600, alpha, hex, lerp_rgba,
    tabular, touch_weight, u,
};

const RED: Rgba = hex(0xdd1111);
const BLUE: Rgba = hex(0x1111dd);
const FEED: Duration = Duration::from_millis(1800);
/// Narrower than this (the drawer is open), the speed buttons step aside.
const SPEEDS_MIN_W: f32 = 480.0;
const NO_PATH: &str = "No path: the robot stays where it starts. Its commands still run.";

/// Per-tab preview state: the camera mode, how far the view was dragged,
/// and the event feed.
pub struct PreviewState {
    pub field_camera: bool,
    pub pan: Point<f32>,
    drag_from: Option<(Point<f32>, Point<f32>)>,
    layout_for: String,
    layout: Rc<ScrubLayout>,
    last_t: f64,
    feed: Option<(String, Rgba, Instant)>,
}

impl Default for PreviewState {
    fn default() -> Self {
        Self {
            field_camera: false,
            pan: point(0.0, 0.0),
            drag_from: None,
            layout_for: String::new(),
            layout: Rc::new(ScrubLayout::default()),
            last_t: 0.0,
            feed: None,
        }
    }
}

impl PreviewState {
    /// The view was moved off its framing, so reset-view shows.
    pub fn user_moved(&self) -> bool {
        self.pan.x.abs() > 0.5 || self.pan.y.abs() > 0.5
    }

    fn reset_view(&mut self) {
        self.pan = point(0.0, 0.0);
    }
}

/// What the tab shows over the scene for the viewed auto.
pub struct Notes {
    pub robot_line: String,
    pub warning: String,
    pub start: Option<StartPoseCheck>,
}

fn speed_text(s: f64) -> String {
    if s < 1.0 {
        format!("{s:.1}x")
    } else {
        format!("{}x", s as i64)
    }
}

pub fn time_text(t: f64, duration: f64) -> String {
    format!("{t:05.2} / {duration:05.2} s")
}

fn start_color(level: StartPoseLevel) -> Rgba {
    match level {
        StartPoseLevel::Ok => ACCENT,
        StartPoseLevel::Off => AMBER,
        StartPoseLevel::Invalid => ZINC_400,
    }
}

fn chip(icon: &'static str, label: impl Into<SharedString>, color: Rgba, on: bool) -> Div {
    let c = if on { color } else { ZINC_500 };
    div()
        .flex()
        .flex_none()
        .flex_row()
        .items_center()
        .gap(u(6.))
        .pl(u(8.))
        .pr(u(10.))
        .py(u(3.))
        .border(u(2.))
        .border_color(if on { color } else { alpha(WHITE, 0.12) })
        .bg(if on {
            alpha(color, 0.28)
        } else {
            alpha(BLACK, 0.55)
        })
        .child(lucide(icon, 16., c))
        .child(
            div()
                .font_weight(touch_weight(600))
                .text_size(u(14.))
                .line_height(u(20.))
                .whitespace_nowrap()
                .text_color(if on { WHITE } else { c })
                .child(label.into()),
        )
}

/// Godot's `Color.lightened`.
fn lightened(c: Rgba, by: f32) -> Rgba {
    lerp_rgba(c, Rgba { a: c.a, ..WHITE }, by)
}

#[allow(clippy::too_many_arguments)]
pub fn render(
    key: u64,
    svc: Entity<AutoService>,
    state: Entity<PreviewState>,
    auto: &str,
    notes: Notes,
    expanded: bool,
    on_expand: Rc<dyn Fn(bool, &mut Window, &mut App)>,
    width: f32,
    window: &mut Window,
    cx: &mut App,
) -> impl IntoElement {
    if svc.read(cx).model.preview_name() != auto {
        svc.update(cx, |s, cx| {
            s.model.set_preview(auto);
            cx.notify();
        });
    }
    let image = svc.update(cx, |s, _| s.preview_image(auto));
    let (clock, frame, alliance_red, alliance_known, has_path, layout, started) = {
        let s = svc.read(cx);
        let m = s.model.preview_mechanisms().cloned();
        let has_path = m.as_ref().is_none_or(|m| m.playback.has_path());
        let st = state.read(cx);
        let same = st.layout_for == auto;
        let layout = if same {
            st.layout.clone()
        } else {
            Rc::new(ScrubLayout::new(m.as_deref()))
        };
        let c = &s.model.clock;
        let started = (same && c.playing && !c.scrubbing && c.t > st.last_t)
            .then(|| {
                m.as_ref()?
                    .items_started(st.last_t, c.t)
                    .last()
                    .map(|it| (*it).clone())
            })
            .flatten();
        (
            c.clone(),
            s.model.frame().cloned(),
            s.model.alliance_red(),
            s.model.alliance_known(),
            has_path,
            layout,
            started,
        )
    };

    let feed = state.update(cx, |st, _| {
        if st.layout_for != auto {
            st.layout_for = auto.to_owned();
            st.layout = layout.clone();
            st.feed = None;
        }
        if let Some(it) = started {
            let mut text = short_name(&it.name);
            if !it.note.is_empty() {
                text = format!("{text}  \u{b7}  {}", it.note);
            }
            st.feed = Some((
                text,
                lightened(kind_color(it.kind, it.runs), 0.35),
                Instant::now(),
            ));
        }
        st.last_t = clock.t;
        st.feed
            .as_ref()
            .filter(|(_, _, at)| at.elapsed() < FEED)
            .map(|(t, c, _)| (t.clone(), *c))
    });
    if clock.playing || feed.is_some() {
        window.request_animation_frame();
    }
    let (field_camera, pan, moved) = {
        let st = state.read(cx);
        (st.field_camera, st.pan, st.user_moved())
    };

    let picture = match image {
        Some(img_data) => img(ImageSource::Render(img_data))
            .absolute()
            .left(u(pan.x))
            .top(u(pan.y))
            .size_full()
            .object_fit(ObjectFit::Contain)
            .into_any_element(),
        None => div()
            .absolute()
            .top_0()
            .left_0()
            .size_full()
            .flex()
            .items_center()
            .justify_center()
            .text_size(u(20.))
            .text_color(ZINC_600)
            .child("No preview picture for this auto")
            .into_any_element(),
    };

    let drag_state = state.clone();
    let stage_view = div()
        .id(("auto-stage", key))
        .absolute()
        .top_0()
        .left_0()
        .size_full()
        .overflow_hidden()
        .child(picture)
        .on_mouse_down(MouseButton::Left, move |e, window, cx| {
            input::veto_swipe();
            let p = input::pointer(Phase::Down, e.position, window).pos;
            drag_state.update(cx, |s, _| s.drag_from = Some((p, s.pan)));
            let st = drag_state.clone();
            input::capture(window, move |p, _, cx| {
                st.update(cx, |s, cx| {
                    if let Some((from, pan0)) = s.drag_from {
                        s.pan = point(pan0.x + p.pos.x - from.x, pan0.y + p.pos.y - from.y);
                        cx.notify();
                    }
                    if matches!(p.phase, Phase::Up | Phase::Cancel) {
                        s.drag_from = None;
                    }
                });
            });
        });

    let aim_label = if frame
        .as_ref()
        .is_some_and(|f| f.state.aim_source == dash_core::playback::AimSource::Default)
    {
        "Aim \u{b7} default cmd"
    } else {
        "Aim"
    };
    let f = frame.as_ref().map(|f| &f.state);
    let chips = div()
        .flex()
        .flex_row()
        .gap(u(6.))
        .child(chip(
            "crosshair",
            aim_label,
            hex(0x3b82f6),
            f.is_some_and(|f| f.aim),
        ))
        .child(chip(
            "zap",
            "Shooter",
            hex(0xff9d00),
            f.is_some_and(|f| f.shooter),
        ))
        .child(chip(
            "arrow-down-to-line",
            "Intake",
            hex(0x70cd35),
            f.is_some_and(|f| f.rollers),
        ));
    let start_chip = notes.start.map(|c| {
        let col = start_color(c.level);
        let icon = if c.level == StartPoseLevel::Ok {
            "circle-check"
        } else {
            "crosshair"
        };
        note(Some(icon), col, c.text())
    });
    let feed_box = feed.map(|(text, color)| {
        div()
            .flex_none()
            .px(u(10.))
            .py(u(2.))
            .bg(alpha(BLACK, 0.75))
            .font_weight(touch_weight(600))
            .text_size(u(16.))
            .line_height(u(24.))
            .whitespace_nowrap()
            .text_color(color)
            .child(text)
    });
    let top_left = div()
        .absolute()
        .left(u(8.))
        .top(u(8.))
        .flex()
        .flex_col()
        .items_start()
        .gap(u(6.))
        .child(chips)
        .children(start_chip)
        .children(feed_box);

    let cam_state = state.clone();
    let camera_button = Btn::new(("auto-camera", key), Look::Overlay)
        .text(if field_camera { "Field" } else { "Path" })
        .icon(if field_camera { "map" } else { "route" })
        .font(16.)
        .size(96., 40.)
        .on_tap(move |_, cx| {
            cam_state.update(cx, |s, cx| {
                s.field_camera = !s.field_camera;
                s.reset_view();
                cx.notify();
            })
        });
    let expand_button = Btn::new(("auto-expand", key), Look::Overlay)
        .icon(if expanded { "minimize-2" } else { "maximize-2" })
        .font(20.)
        .size(40., 40.)
        .on_tap(move |window, cx| on_expand(!expanded, window, cx));
    let reset_state = state.clone();
    let reset_button = Btn::new(("auto-reset-view", key), Look::Overlay)
        .icon("locate-fixed")
        .font(20.)
        .size(40., 40.)
        .on_tap(move |_, cx| {
            reset_state.update(cx, |s, cx| {
                s.reset_view();
                cx.notify();
            })
        });
    let top_right = |d: Div, right: f32| d.absolute().top(u(8.)).right(u(right));

    let notes_col = div()
        .absolute()
        .left(u(8.))
        .right(u(8.))
        .bottom(u(8.))
        .flex()
        .flex_col()
        .items_start()
        .gap(u(6.))
        .when(!notes.warning.is_empty(), |d| {
            d.child(note(Some("triangle-alert"), AMBER, notes.warning.clone()))
        })
        .when(!has_path, |d| d.child(note(None, ZINC_300, NO_PATH)))
        .when(!notes.robot_line.is_empty(), |d| {
            d.child(note(None, ZINC_400, notes.robot_line.clone()))
        });

    let stage = div()
        .relative()
        .flex_1()
        .min_h_0()
        .child(stage_view)
        .child(notes_col)
        .child(top_left)
        .child(top_right(div(), 56.).child(camera_button))
        .child(top_right(div(), 8.).child(expand_button))
        .when(moved, |d| {
            d.child(top_right(div(), 160.).child(reset_button))
        });

    let scrub = scrub_bar(
        ("auto-scrub", key),
        svc.clone(),
        layout.clone(),
        expanded,
        window,
        cx,
    )
    .into_any_element();

    let s1 = svc.clone();
    let play = Btn::new(("auto-play", key), Look::Primary)
        .icon(if clock.playing { "pause" } else { "play" })
        .font(20.)
        .size(48., 40.)
        .on_tap(move |_, cx| {
            s1.update(cx, |s, cx| {
                s.note_tab_drawn();
                s.model.clock.toggle();
                s.model.refresh();
                cx.notify();
            })
        });
    let s2 = svc.clone();
    let restart = Btn::new(("auto-restart", key), Look::Dark)
        .icon("skip-back")
        .font(20.)
        .size(44., 40.)
        .on_tap(move |_, cx| {
            s2.update(cx, |s, cx| {
                s.model.clock.seek(0.0);
                s.model.refresh();
                cx.notify();
            })
        });
    let time = div()
        .when(!expanded, |d| d.flex_1())
        .min_w_0()
        .overflow_hidden()
        .text_ellipsis()
        .whitespace_nowrap()
        .font_family(INTER)
        .font_features(tabular())
        .font_weight(touch_weight(500))
        .text_size(u(16.))
        .line_height(u(24.))
        .text_color(ZINC_300)
        .child(time_text(clock.t, clock.duration));
    let speeds = (width >= SPEEDS_MIN_W).then(|| {
        AutoClock::SPEEDS.iter().map(|&sp| {
            let s = svc.clone();
            let on = (clock.speed - sp).abs() < 1e-9;
            Btn::new(
                SharedString::from(format!("auto-speed-{key}-{sp}")),
                if on { Look::Accent } else { Look::Dark },
            )
            .text(speed_text(sp))
            .font(16.)
            .size(48., 40.)
            .on_tap(move |_, cx| {
                s.update(cx, |s, cx| {
                    s.model.clock.set_speed(sp);
                    cx.notify();
                })
            })
        })
    });
    let s3 = svc.clone();
    let looping = Btn::new(
        ("auto-loop", key),
        if clock.looping {
            Look::Accent
        } else {
            Look::Dark
        },
    )
    .icon("repeat")
    .font(20.)
    .size(44., 40.)
    .on_tap(move |_, cx| {
        s3.update(cx, |s, cx| {
            let on = !s.model.clock.looping;
            s.model.clock.set_loop(on);
            cx.notify();
        })
    });
    let s4 = svc.clone();
    let mut alliance = Btn::new(
        ("auto-alliance", key),
        Look::Solid(if alliance_red { RED } else { BLUE }),
    )
    .text(if alliance_red { "Red" } else { "Blue" })
    .font(16.)
    .size(80., 40.)
    .disabled(alliance_known)
    .on_tap(move |_, cx| {
        s4.update(cx, |s, cx| {
            s.model.toggle_manual_alliance();
            cx.notify();
        })
    });
    if alliance_known {
        alliance = alliance.icon("lock");
    }

    let mut row = div()
        .flex()
        .flex_row()
        .items_center()
        .gap(u(6.))
        .child(play)
        .child(restart)
        .child(time);
    let mut scrub_slot = Some(scrub);
    if expanded {
        row = row.child(div().flex_1().min_w_0().children(scrub_slot.take()));
    }
    let row = row
        .children(speeds.into_iter().flatten())
        .child(looping)
        .child(alliance);
    let controls = div()
        .flex()
        .flex_col()
        .gap(u(6.))
        .pl(u(8.))
        .pr(u(8.))
        .pt(u(6.))
        .pb(u(8.))
        .children(scrub_slot)
        .child(row);

    div()
        .size_full()
        .flex()
        .flex_col()
        .rounded(u(RADIUS))
        .overflow_hidden()
        .bg(ZINC_950)
        .child(stage)
        .child(controls)
}
