use std::time::Instant;

use dash_core::match_model::time_format::{mm_ss_cc, nn_dd};
use dash_core::match_model::{Aim, Banner, Header, LaneToast, TOAST_DURATION_S};
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;

mod camera_overlay;
mod minimap;

use crate::icons::{sf, sf_symbol};
use crate::mock::MockData;
use crate::theme::{
    ACCENT, BLACK, BLUE, CARD, ERROR, HUD_DESIGN, INTER, MONO, ORANGE, PURPLE, SF, TOAST_BG,
    TOAST_BORDER, WHITE, YELLOW, alpha, u, weight,
};
use crate::widgets::dpx;
use crate::windows::ScreenKind;

const FONT_TIMER_LARGE: f32 = 128.0;
const FONT_TIMER_SMALL: f32 = 64.0;
const HEADER_H: f32 = 180.0;
const SHIFT_CENTER_Y: f32 = 335.5;
const SHIFT_ICON_PX: f32 = 200.0;
const BUFFER_POS: Point<f32> = Point { x: 975.0, y: 224.0 };
const TOAST_OFFSET: f32 = 24.0;
const TOAST_W: f32 = 356.0;
const TOAST_ANIM_S: f64 = 0.4;
/// Godot's Tokens.TEXT_DIM: the timers while the robot link is down or stale.
const TEXT_DIM: Rgba = alpha(WHITE, 0.45);

/// hhea ascender and descender per em, which set CSS `line-height: normal`
/// and where a baseline sits in its line box.
#[derive(Clone, Copy)]
struct Metrics {
    ascent: f32,
    descent: f32,
}

const MONO_M: Metrics = Metrics {
    ascent: 2146.0 / 2048.0,
    descent: 555.0 / 2048.0,
};
const INTER_M: Metrics = Metrics {
    ascent: 1984.0 / 2048.0,
    descent: 494.0 / 2048.0,
};
const SF_M: Metrics = Metrics {
    ascent: 1950.0 / 2048.0,
    descent: 494.0 / 2048.0,
};

struct Run {
    text: SharedString,
    family: &'static str,
    metrics: Metrics,
    size: f32,
    color: Rgba,
}

fn run(
    text: impl Into<SharedString>,
    family: &'static str,
    metrics: Metrics,
    size: f32,
    color: Rgba,
) -> Run {
    Run {
        text: text.into(),
        family,
        metrics,
        size,
        color,
    }
}

/// Inline runs of mixed fonts on one baseline, the way the web's inline spans
/// share a line: each run's line box is `normal` for its font, offset so the
/// baselines meet. Returns the row and the distance from its top to the
/// baseline.
fn baseline_row(runs: Vec<Run>) -> (Div, f32) {
    let max_ascent = runs
        .iter()
        .map(|r| r.metrics.ascent * r.size)
        .fold(0.0, f32::max);
    let row = div()
        .flex()
        .flex_row()
        .items_start()
        .children(runs.into_iter().map(move |r| {
            let line = (r.metrics.ascent + r.metrics.descent) * r.size;
            div()
                .flex_none()
                .mt(u(max_ascent - r.metrics.ascent * r.size))
                .font_family(r.family)
                .font_weight(weight(400))
                .text_size(u(r.size))
                .line_height(u(line))
                .text_color(r.color)
                .whitespace_nowrap()
                .child(r.text)
        }));
    (row, max_ascent)
}

/// MatchHUD.tsx.
pub struct HudScreen {
    data: Entity<MockData>,
    minimap: minimap::Minimap,
}

impl HudScreen {
    pub fn new(data: Entity<MockData>, cx: &mut Context<Self>) -> Self {
        cx.observe(&data, |_, _, cx| cx.notify()).detach();
        Self {
            data,
            minimap: minimap::Minimap::new(),
        }
    }
}

fn header_color(h: Header) -> Option<Rgba> {
    match h {
        Header::Hidden => None,
        Header::Green => Some(ACCENT),
        Header::Yellow => Some(YELLOW),
        Header::Purple => Some(PURPLE),
    }
}

fn aim_icon(aim: Aim) -> (u32, Rgba) {
    match aim {
        Aim::ShooterDisabled => (sf::AIM_DISABLED, CARD),
        Aim::GpsAuto => (sf::AIM_GPS, BLUE),
        Aim::ManualAiming => (sf::AIM_MANUAL, ORANGE),
    }
}

impl Render for HudScreen {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        crate::screen::fit(window, HUD_DESIGN);
        let data = self.data.read(cx);
        let feed = &data.match_feed;
        let m = &feed.model;
        let now_us = feed.now_us();
        if !feed.clock.is_frozen() {
            window.request_animation_frame();
        }
        let text = if m.link_ok() { WHITE } else { TEXT_DIM };

        let mut root = div()
            .relative()
            .w(u(HUD_DESIGN.width))
            .h(u(HUD_DESIGN.height))
            .overflow_hidden()
            .bg(BLACK)
            .font_family(INTER)
            .text_color(WHITE);

        root = root.child(self.minimap.render(data, Instant::now(), window));

        if m.show_shift_indicator {
            let shift = m.shift_display(now_us);
            if let Some(b) = shift.buffer {
                let (int, dec) = nn_dd(b);
                let (row, _) = baseline_row(vec![
                    run(int, MONO, MONO_M, FONT_TIMER_SMALL, text),
                    run(dec, MONO, MONO_M, FONT_TIMER_SMALL, text),
                    run(" with buffer", INTER, INTER_M, FONT_TIMER_SMALL, text),
                ]);
                root = root.child(
                    div()
                        .absolute()
                        .left(u(BUFFER_POS.x))
                        .top(u(BUFFER_POS.y))
                        .child(row),
                );
            }
            let (icon, color) = aim_icon(m.aim);
            let (int, dec) = nn_dd(shift.main);
            let space_line = (SF_M.ascent + SF_M.descent) * SHIFT_ICON_PX;
            let (row, _) = baseline_row(vec![
                run(sf::glyph(icon), SF, SF_M, SHIFT_ICON_PX, color),
                run(" ", SF, SF_M, SHIFT_ICON_PX, color),
                run(int, MONO, MONO_M, FONT_TIMER_LARGE, text),
                run(dec, MONO, MONO_M, FONT_TIMER_SMALL, text),
            ]);
            let top = SHIFT_CENTER_Y - space_line / 2.0;
            root = root.child(
                div()
                    .absolute()
                    .left_0()
                    .top(u(top))
                    .w(u(HUD_DESIGN.width))
                    .flex()
                    .justify_center()
                    .child(row),
            );
        }

        let header = header_color(m.header);
        let (mmss, cc) = mm_ss_cc(m.total_display(now_us));
        let (timer, _) = baseline_row(vec![
            run(mmss, MONO, MONO_M, FONT_TIMER_LARGE, text),
            run(cc, MONO, MONO_M, FONT_TIMER_SMALL, text),
        ]);
        let timer_line = (MONO_M.ascent + MONO_M.descent) * FONT_TIMER_LARGE;
        root = root.child(
            div()
                .absolute()
                .top_0()
                .left_0()
                .w(u(HUD_DESIGN.width))
                .h(u(HEADER_H))
                .when_some(header, |d, c| d.bg(c))
                .child(
                    div()
                        .absolute()
                        .left_0()
                        .top(u((HEADER_H - timer_line) / 2.0))
                        .w_full()
                        .flex()
                        .justify_center()
                        .child(timer),
                ),
        );

        if let Some(overlay) = camera_overlay::render(data, Instant::now(), window) {
            root = root.child(overlay);
        }

        if let Some(motion) = toast_motion(&m.toast, now_us) {
            root = root.child(lane_toast(m.toast.visible_on, motion, window));
        }

        let banner_kind = m.banner();
        if banner_kind != Banner::None {
            root = root.child(banner(banner_kind));
        }

        let data = self.data.clone();
        root = root
            .child(crate::touch_test::layer(ScreenKind::Hud, HUD_DESIGN, window, cx))
            .child(crate::debug_overlay::layer(&data, window, cx));

        div().size_full().bg(BLACK).child(root)
    }
}

/// Sonner's enter and exit around the model's toast lifetime, as (opacity,
/// lift): it slides in from when the visible span began, and a replacement
/// while it is up only changes its content and restarts the lifetime.
fn toast_motion(t: &LaneToast, now_us: i64) -> Option<(f32, f32)> {
    if t.fire_count == 0 {
        return None;
    }
    let since_fire = (now_us - t.fired_us) as f64 / 1e6;
    let p = if since_fire < TOAST_DURATION_S {
        let entered = (now_us - t.entered_us) as f64 / 1e6;
        crate::theme::ease_css((entered / TOAST_ANIM_S).min(1.0) as f32)
    } else if since_fire < TOAST_DURATION_S + TOAST_ANIM_S {
        let out = (since_fire - TOAST_DURATION_S) / TOAST_ANIM_S;
        1.0 - crate::theme::ease_css(out as f32)
    } else {
        return None;
    };
    Some((p, 1.0 - p))
}

/// Sonner's default toast metrics and motion with the web Toaster's classes
/// (components/ui/sonner.tsx, MatchHUD.tsx).
fn lane_toast(on: bool, (shown, lift): (f32, f32), window: &Window) -> impl IntoElement {
    let color = if on { ACCENT } else { ERROR };
    let height = 16.0 * 2.0 + 19.5 + 2.0;
    let icon = if on {
        "sonner/success.svg"
    } else {
        "sonner/error.svg"
    };
    let shadow: Hsla = crate::theme::alpha(BLACK, 0.1).into();
    div()
        .absolute()
        .left(u(TOAST_OFFSET))
        .top(u(TOAST_OFFSET - lift * height))
        .w(u(TOAST_W))
        .opacity(shown)
        .flex()
        .items_center()
        .gap(u(6.))
        .p(u(16.))
        .rounded(u(8.))
        .border(u(1.))
        .border_color(TOAST_BORDER)
        .bg(TOAST_BG)
        .shadow(vec![
            BoxShadow::new(px(0.), dpx(window, 10.), shadow)
                .blur_radius(dpx(window, 15.))
                .spread_radius(dpx(window, -3.)),
            BoxShadow::new(px(0.), dpx(window, 4.), shadow)
                .blur_radius(dpx(window, 6.))
                .spread_radius(dpx(window, -4.)),
        ])
        .text_color(color)
        .text_size(u(13.))
        .line_height(u(19.5))
        .child(
            div()
                .flex_none()
                .ml(u(-3.))
                .mr(u(4.))
                .size(u(16.))
                .child(svg().path(icon).size(u(16.)).text_color(color)),
        )
        .child(
            div()
                .flex()
                .items_center()
                .gap(u(8.))
                .child(sf_symbol(sf::LANE_ALIGNMENT, 16.8, color).line_height(u(16.8)))
                .child(
                    div()
                        .font_weight(weight(500))
                        .child(format!("Lane Alignment {}", if on { "ON" } else { "OFF" })),
                ),
        )
}

fn banner(kind: Banner) -> impl IntoElement {
    crate::widgets::status_pill(HUD_DESIGN, kind.text())
}

#[cfg(test)]
mod tests {
    use dash_core::match_model::{Header, LaneToast};
    use dash_core::request_state::Value;

    use super::{header_color, toast_motion};

    #[test]
    fn header_colors_and_visibility() {
        let want = [
            (0, None),
            (1, Some(0x70cd35)),
            (2, Some(0xffd900)),
            (3, Some(0xa600ff)),
            (7, None),
        ];
        for (v, rgb) in want {
            let got = header_color(Header::from_value(&Value::Int(v)));
            assert_eq!(got, rgb.map(crate::theme::hex), "header_color {v}");
        }
    }

    #[test]
    fn toast_enters_once_and_exits_after_its_lifetime() {
        const S: i64 = 1_000_000;
        let mut t = LaneToast::default();
        assert_eq!(toast_motion(&t, 0), None);
        t.observe(false, 0);
        t.observe(true, 10 * S);
        assert_eq!(toast_motion(&t, 10 * S), Some((0.0, 1.0)), "starts hidden");
        assert_eq!(
            toast_motion(&t, 10 * S + 600_000),
            Some((1.0, 0.0)),
            "entered by 0.4 s"
        );
        t.observe(false, 11 * S);
        assert_eq!(
            toast_motion(&t, 11 * S),
            Some((1.0, 0.0)),
            "a replacement while up does not re-enter"
        );
        assert_eq!(toast_motion(&t, 12 * S + 790_000), Some((1.0, 0.0)));
        let (shown, _) = toast_motion(&t, 13 * S).unwrap();
        assert!(shown > 0.0 && shown < 1.0, "exiting after 1.8 s: {shown}");
        assert_eq!(
            toast_motion(&t, 13 * S + 200_001),
            None,
            "gone after the exit"
        );
    }
}
