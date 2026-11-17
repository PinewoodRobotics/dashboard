use std::cell::Cell;
use std::rc::Rc;

use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;

use super::{OnChange, label};
use crate::anim::Tween;
use crate::input::{self, Phase, PressWidget};
use crate::theme::{self, ACCENT, PANEL, SELECTED_FILL, WHITE, alpha, lerp_rgba, u};

#[derive(Clone)]
pub struct SliderHint {
    pub min: f32,
    pub label: SharedString,
}

struct DragState {
    dragging: bool,
    start_x: f32,
    start_value: f32,
    track: Rc<Cell<Bounds<Pixels>>>,
    green: Tween,
    fill: Option<Tween>,
}

/// CustomSlider.tsx. The value moves by the drag relative to the press, so a
/// tap changes nothing.
#[derive(IntoElement)]
pub struct Slider {
    id: ElementId,
    value: f32,
    min: f32,
    max: f32,
    step: Option<f32>,
    snap_points: Vec<f32>,
    decimals: Option<usize>,
    label: Option<SharedString>,
    value_label: Option<SharedString>,
    hints: Vec<SliderHint>,
    reversed: bool,
    disabled: bool,
    on_change: Option<OnChange<f32>>,
}

impl Slider {
    pub fn new(id: impl Into<ElementId>, value: f32) -> Self {
        Self {
            id: id.into(),
            value,
            min: 0.0,
            max: 1.0,
            step: None,
            snap_points: Vec::new(),
            decimals: None,
            label: None,
            value_label: None,
            hints: Vec::new(),
            reversed: false,
            disabled: false,
            on_change: None,
        }
    }

    pub fn range(mut self, min: f32, max: f32) -> Self {
        self.min = min;
        self.max = max;
        self
    }

    pub fn step(mut self, step: f32) -> Self {
        self.step = Some(step);
        self
    }

    pub fn snap_points(mut self, points: Vec<f32>) -> Self {
        self.snap_points = points;
        self
    }

    pub fn decimals(mut self, decimals: usize) -> Self {
        self.decimals = Some(decimals);
        self
    }

    pub fn label(mut self, label: impl Into<SharedString>) -> Self {
        self.label = Some(label.into());
        self
    }

    /// `{v}` is replaced by the formatted value.
    pub fn value_label(mut self, text: impl Into<SharedString>) -> Self {
        self.value_label = Some(text.into());
        self
    }

    pub fn hints(mut self, hints: Vec<SliderHint>) -> Self {
        self.hints = hints;
        self
    }

    pub fn reversed(mut self, reversed: bool) -> Self {
        self.reversed = reversed;
        self
    }

    pub fn disabled(mut self, disabled: bool) -> Self {
        self.disabled = disabled;
        self
    }

    pub fn on_change(mut self, f: impl Fn(f32, &mut Window, &mut App) + 'static) -> Self {
        self.on_change = Some(Rc::new(f));
        self
    }

    fn format(&self, v: f32) -> String {
        match self.decimals {
            Some(d) => format!("{v:.d$}"),
            None => {
                let s = format!("{v}");
                s.strip_suffix(".0").map(str::to_owned).unwrap_or(s)
            }
        }
    }
}

fn snap(v: f32, min: f32, step: Option<f32>, points: &[f32]) -> f32 {
    let mut r = v;
    if let Some(step) = step {
        r = ((r - min) / step).round() * step + min;
    }
    if !points.is_empty() {
        r = points.iter().copied().fold(points[0], |n, p| {
            if (p - r).abs() < (n - r).abs() { p } else { n }
        });
    }
    r
}

impl RenderOnce for Slider {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let has_snap = !self.snap_points.is_empty();
        let state = window.use_keyed_state(self.id.clone(), cx, |_, _| DragState {
            dragging: false,
            start_x: 0.0,
            start_value: 0.0,
            track: Rc::new(Cell::new(Bounds::default())),
            green: Tween::new(0.0).with_easing(theme::ease_css),
            fill: None,
        });
        let range = (self.max - self.min).max(f32::EPSILON);
        let t = ((self.value - self.min) / range).clamp(0.0, 1.0);
        let (green, fill_t, track_cell) = state.update(cx, |s, _| {
            let fill = s
                .fill
                .get_or_insert_with(|| Tween::new(t).with_easing(theme::ease_out_css));
            if has_snap {
                if (fill.target() - t).abs() > 1e-5 {
                    fill.retarget(t, theme::MOTION_SLIDER_FILL_S);
                }
            } else {
                fill.jump(t);
            }
            (s.green.value(), fill.value(), s.track.clone())
        });
        if state.read(cx).green.running() || state.read(cx).fill.is_some_and(|f| f.running()) {
            window.request_animation_frame();
        }

        let fill_color = lerp_rgba(WHITE, ACCENT, green);
        let track_bg = lerp_rgba(PANEL, SELECTED_FILL, green);
        let display = self.format(self.value);
        let interpolate = |s: &str| s.replace("{v}", &display);
        let hint = {
            let mut hs = self.hints.clone();
            hs.sort_by(|a, b| b.min.total_cmp(&a.min));
            hs.into_iter()
                .find(|h| self.value >= h.min)
                .map(|h| interpolate(&h.label))
        };
        let epsilon = range * 0.005;

        let dots = self.snap_points.iter().copied().filter_map(|pt| {
            if (pt - self.min).abs() < epsilon || (pt - self.max).abs() < epsilon {
                return None;
            }
            let current = (pt - self.value).abs() < epsilon;
            let pt_t = (pt - self.min) / range;
            let in_filled = if self.reversed {
                pt_t > 1.0 - t
            } else {
                pt_t < t
            };
            let color = if in_filled { track_bg } else { fill_color };
            Some(
                div()
                    .absolute()
                    .top(relative(0.5))
                    .left(relative(pt_t))
                    .mt(u(-3.))
                    .ml(u(-3.))
                    .size(u(6.))
                    .rounded_full()
                    .bg(color)
                    .opacity(if current { 0.0 } else { 1.0 }),
            )
        });

        let mut fill = div()
            .absolute()
            .top_0()
            .bottom_0()
            .w(relative(fill_t))
            .bg(fill_color);
        fill = if self.reversed {
            fill.right_0()
        } else {
            fill.left_0()
        };

        let probe_cell = track_cell.clone();
        let track = div()
            .id(self.id.clone())
            .relative()
            .h(u(48.))
            .w_full()
            .overflow_hidden()
            .border(u(4.))
            .border_color(fill_color)
            .bg(track_bg)
            .child(
                canvas(move |b, _, _| probe_cell.set(b), |_, _, _, _| {})
                    .absolute()
                    .top_0()
                    .left_0()
                    .size_full(),
            )
            .child(fill)
            .children(dots)
            .on_mouse_down(MouseButton::Left, {
                let state = state.clone();
                let on_change = self.on_change.clone();
                let (min, max, step, points, reversed, disabled) = (
                    self.min,
                    self.max,
                    self.step,
                    self.snap_points.clone(),
                    self.reversed,
                    self.disabled,
                );
                let value = self.value;
                move |e, window, cx| {
                    input::note_press_widget(PressWidget::Slider);
                    if disabled {
                        return;
                    }
                    let start_x = input::pointer(Phase::Down, e.position, window).pos.x;
                    state.update(cx, |s, cx| {
                        s.dragging = true;
                        s.start_x = start_x;
                        s.start_value = value;
                        s.green.retarget(1.0, theme::MOTION_PRESS_S);
                        cx.notify();
                    });
                    let st = state.clone();
                    let on_change = on_change.clone();
                    let points = points.clone();
                    input::capture(window, move |p, window, cx| {
                        let rem = f32::from(window.rem_size()).max(0.0001);
                        let (start_x, start_value, width) = {
                            let s = st.read(cx);
                            (
                                s.start_x,
                                s.start_value,
                                f32::from(s.track.get().size.width) / rem,
                            )
                        };
                        match p.phase {
                            Phase::Move => {
                                if width <= 0.0 {
                                    return;
                                }
                                let dir = if reversed { -1.0 } else { 1.0 };
                                let delta = (p.pos.x - start_x) / width;
                                let v = (start_value + delta * (max - min) * dir).clamp(min, max);
                                let v = snap(v, min, step, &points);
                                if let Some(f) = on_change.as_ref() {
                                    f(v, window, cx);
                                }
                            }
                            Phase::Up | Phase::Cancel => st.update(cx, |s, cx| {
                                s.dragging = false;
                                s.green.retarget(0.0, theme::MOTION_PRESS_S);
                                cx.notify();
                            }),
                            Phase::Down => {}
                        }
                    });
                }
            });

        div()
            .flex()
            .flex_col()
            .gap(u(8.))
            .w_full()
            .when(self.disabled, |d| d.opacity(0.5))
            .when_some(self.label.clone(), |d, l| {
                d.child(label(l, 24., 500, WHITE))
            })
            .when_some(self.value_label.clone(), |d, l| {
                d.child(label(interpolate(&l), 18., 500, alpha(WHITE, 0.7)))
            })
            .child(track)
            .when_some(hint, |d, h| d.child(label(h, 16., 400, WHITE)))
    }
}
