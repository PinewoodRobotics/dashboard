//! IntakeSpeedPanel.tsx + AimTrimSection.tsx (comp-godot intake_panel.gd):
//! the intake override slider with its status line and Reset, then under a
//! 2 px rule the reversed aim trim slider (+-10 deg in 0.25 steps), Center
//! and the ten shooter readouts, all in the drawer's vertical scroll.

use dash_core::controls::{AimTrim, Controls};
use gpui_kit::*;

use super::{TouchScreen, panels};
use crate::icons::lucide;
use crate::mock_link;
use crate::theme::{HAIRLINE, INTER, MONO, OUTLINE, WHITE, ZINC_400, touch_weight, u};
use crate::widgets::{Axis2, Button, ButtonStyle, Scroll, Slider};

const SPEED_LABEL: &str = "{v} — duty cycle sent to the intake motor";
const TEXT_PX: f32 = 14.0;
const TEXT_LINE: f32 = 20.0;

struct Shown {
    speed: f64,
    speed_status: String,
    trim: f64,
    trim_status: String,
    connected: bool,
    readouts: Vec<(&'static str, String)>,
}

fn small(text: impl Into<SharedString>, color: impl Into<Hsla>) -> Div {
    div()
        .font_family(INTER)
        .font_weight(touch_weight(400))
        .text_size(u(TEXT_PX))
        .line_height(u(TEXT_LINE))
        .text_color(color)
        .child(text.into())
}

fn caption(text: &'static str, icon: &'static str, icon_first: bool) -> Div {
    let icon = lucide(icon, 16., ZINC_400);
    let text = small(text, ZINC_400).whitespace_nowrap();
    let row = div().flex().items_center().gap(u(4.));
    if icon_first {
        row.child(icon).child(text)
    } else {
        row.child(text).child(icon)
    }
}

fn readout_cell(label: &'static str, value: String) -> Div {
    div()
        .flex_1()
        .min_w_0()
        .flex()
        .items_baseline()
        .justify_between()
        .gap(u(8.))
        .py(u(2.))
        .border_b(u(1.))
        .border_color(HAIRLINE)
        .child(small(label, ZINC_400).whitespace_nowrap())
        .child(small(value, WHITE).font_family(MONO).whitespace_nowrap())
}

fn readout_grid(rows: Vec<(&'static str, String)>) -> Div {
    let mut grid = div().flex().flex_col().gap(u(4.)).w_full();
    let mut it = rows.into_iter();
    while let Some((l, v)) = it.next() {
        let mut line = div().flex().gap(u(16.)).w_full().child(readout_cell(l, v));
        line = match it.next() {
            Some((l2, v2)) => line.child(readout_cell(l2, v2)),
            None => line.child(div().flex_1()),
        };
        grid = grid.child(line);
    }
    grid
}

pub fn render(
    ts: &TouchScreen,
    _window: &mut Window,
    cx: &mut Context<TouchScreen>,
) -> impl IntoElement {
    let shown = mock_link::view(ts.data.read(cx), |c, link| Shown {
        speed: c.intake.slider_value(link),
        speed_status: c.intake.status_line(link),
        trim: c.trim.slider_value(link),
        trim_status: c.trim.status_line(link),
        connected: c.trim.connected(link),
        readouts: c.readouts(link),
    });
    let data = ts.data.clone();
    let act = move |f: fn(&mut Controls, &mut mock_link::MockLink, f64)| {
        let data = data.clone();
        move |v: f64, cx: &mut App| mock_link::act(&data, cx, move |c, l| f(c, l, v))
    };
    let set_speed = act(|c, l, v| {
        c.intake.set_speed(l, v);
    });
    let reset = act(|c, l, _| c.intake.reset(l));
    let set_trim = act(|c, l, v| {
        c.trim.set_trim(l, v);
    });
    let center = act(|c, l, _| {
        c.trim.center(l);
    });

    let speed = Slider::new("intake-speed", shown.speed as f32)
        .label("Speed")
        .range(0.0, 1.0)
        .step(0.01)
        .decimals(2)
        .value_label(SPEED_LABEL)
        .on_change(move |v, _, cx| set_speed(v as f64, cx));

    let trim = Slider::new("aim-trim", shown.trim as f32)
        .label("Aim Trim")
        .range(-AimTrim::LIMIT_DEG as f32, AimTrim::LIMIT_DEG as f32)
        .step(AimTrim::STEP_DEG as f32)
        .reversed(true)
        .format_value(|v| AimTrim::format(v as f64))
        .value_label("{v}")
        .disabled(!shown.connected)
        .on_change(move |v, _, cx| set_trim(v as f64, cx));

    let aim_section = div()
        .flex()
        .flex_col()
        .gap(u(16.))
        .w_full()
        .border_t(u(2.))
        .border_color(OUTLINE)
        .pt(u(20.))
        .child(
            div()
                .flex()
                .flex_col()
                .gap(u(4.))
                .w_full()
                .child(trim)
                .child(
                    div()
                        .flex()
                        .justify_between()
                        .w_full()
                        .child(caption("Aim left", "chevron-left", true))
                        .child(caption("Aim right", "chevron-right", false)),
                ),
        )
        .child(small(shown.trim_status, ZINC_400))
        .child(
            Button::new("aim-center", "Center (0°)", ButtonStyle::OutlineBlock)
                .disabled(!shown.connected)
                .on_tap(move |_, cx| center(0.0, cx)),
        )
        .child(readout_grid(shown.readouts));

    div()
        .flex()
        .flex_col()
        .items_start()
        .p(u(16.))
        .size_full()
        .child(panels::title("Intake Speed"))
        .child(
            div().mt(u(16.)).w_full().flex_1().min_h_0().child(
                Scroll::new("intake-scroll", Axis2::Vertical)
                    .content(div().flex().flex_col().gap(u(20.)).pr(u(10.)))
                    .child(speed)
                    .child(small(shown.speed_status, ZINC_400))
                    .child(
                        Button::new("intake-reset", "Reset", ButtonStyle::OutlineBlock)
                            .on_tap(move |_, cx| reset(0.0, cx)),
                    )
                    .child(aim_section),
            ),
        )
}
