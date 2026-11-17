use std::time::{Duration, Instant};

use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;

use crate::icons::{sf, sf_symbol};
use crate::mock::{AimMode, HeaderColor, LinkBanner, MockData};
use crate::theme::{
    ACCENT, BLACK, BLUE, CARD, ERROR, HUD_DESIGN, INTER, MONO, ORANGE, PURPLE, SF, TOAST_BG,
    TOAST_BORDER, WHITE, YELLOW, u, weight,
};
use crate::widgets::dpx;

const FONT_TIMER_LARGE: f32 = 128.0;
const FONT_TIMER_SMALL: f32 = 64.0;
const HEADER_H: f32 = 180.0;
const SHIFT_CENTER_Y: f32 = 335.5;
const SHIFT_ICON_PX: f32 = 200.0;
const BUFFER_POS: Point<f32> = Point { x: 975.0, y: 224.0 };
const MINIMAP: Bounds<f32> = Bounds {
    origin: Point { x: 540.0, y: 480.0 },
    size: Size {
        width: 840.0,
        height: 1080.0 + 19.2 - 480.0,
    },
};
const TOAST_OFFSET: f32 = 24.0;
const TOAST_W: f32 = 356.0;
const TOAST_LIFE: Duration = Duration::from_millis(1800);
const TOAST_ANIM_S: f32 = 0.4;

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

fn mm_ss_cc(t: f64) -> (String, String) {
    let t = t.max(0.0);
    let mins = (t / 60.0).floor() as u32;
    let secs = (t % 60.0).floor() as u32;
    let cs = ((t % 1.0) * 100.0).floor() as u32;
    (format!("{mins:02}:{secs:02}"), format!(".{cs:02}"))
}

fn nn_dd(t: f64) -> (String, String) {
    let s = format!("{:.2}", t.max(0.0));
    let (int, dec) = s.split_once('.').unwrap_or((&s, "00"));
    (format!("{int:0>2}"), format!(".{dec}"))
}

/// MatchHUD.tsx.
pub struct HudScreen {
    data: Entity<MockData>,
}

impl HudScreen {
    pub fn new(data: Entity<MockData>, cx: &mut Context<Self>) -> Self {
        cx.observe(&data, |_, _, cx| cx.notify()).detach();
        Self { data }
    }
}

fn header_color(h: HeaderColor) -> Option<Rgba> {
    match h {
        HeaderColor::Hidden => None,
        HeaderColor::Green => Some(ACCENT),
        HeaderColor::Yellow => Some(YELLOW),
        HeaderColor::Purple => Some(PURPLE),
    }
}

fn aim_icon(aim: AimMode) -> (u32, Rgba) {
    match aim {
        AimMode::ShooterDisabled => (sf::AIM_DISABLED, CARD),
        AimMode::GpsAuto => (sf::AIM_GPS, BLUE),
        AimMode::ManualAiming => (sf::AIM_MANUAL, ORANGE),
    }
}

impl Render for HudScreen {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        crate::screen::fit(window, HUD_DESIGN);
        let now = Instant::now();
        let data = self.data.read(cx);
        let m = &data.matchs;
        if !m.frozen {
            window.request_animation_frame();
        }

        let mut root = div()
            .relative()
            .w(u(HUD_DESIGN.width))
            .h(u(HUD_DESIGN.height))
            .overflow_hidden()
            .bg(BLACK)
            .font_family(INTER)
            .text_color(WHITE);

        root = root.child(minimap());

        if m.show_shift_indicator {
            let (main, buffer) = m.shift_display(now);
            if let Some(b) = buffer {
                let (int, dec) = nn_dd(b);
                let (row, _) = baseline_row(vec![
                    run(int, MONO, MONO_M, FONT_TIMER_SMALL, WHITE),
                    run(dec, MONO, MONO_M, FONT_TIMER_SMALL, WHITE),
                    run(" with buffer", INTER, INTER_M, FONT_TIMER_SMALL, WHITE),
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
            let (int, dec) = nn_dd(main);
            let space_line = (SF_M.ascent + SF_M.descent) * SHIFT_ICON_PX;
            let (row, _) = baseline_row(vec![
                run(sf::glyph(icon), SF, SF_M, SHIFT_ICON_PX, color),
                run(" ", SF, SF_M, SHIFT_ICON_PX, color),
                run(int, MONO, MONO_M, FONT_TIMER_LARGE, WHITE),
                run(dec, MONO, MONO_M, FONT_TIMER_SMALL, WHITE),
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
        let (mmss, cc) = mm_ss_cc(m.total_display(now));
        let (timer, _) = baseline_row(vec![
            run(mmss, MONO, MONO_M, FONT_TIMER_LARGE, WHITE),
            run(cc, MONO, MONO_M, FONT_TIMER_SMALL, WHITE),
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

        if let Some(toast) = data.lane_toast.as_ref() {
            let mut age = now.saturating_duration_since(toast.shown_at);
            if m.frozen {
                age = age.min(Duration::from_secs_f32(TOAST_ANIM_S));
            }
            let total = TOAST_LIFE + Duration::from_secs_f32(TOAST_ANIM_S);
            if age < total {
                window.request_animation_frame();
                root = root.child(lane_toast(toast.on, age, window));
            }
        }

        if data.banner != LinkBanner::None {
            root = root.child(banner(data.banner));
        }

        div().size_full().bg(BLACK).child(root)
    }
}

/// MiniMap3D.tsx's frame around the 3D placeholder.
fn minimap() -> impl IntoElement {
    let fill = crate::placeholder::VIEW3D_FILL;
    div()
        .absolute()
        .left(u(MINIMAP.origin.x))
        .top(u(MINIMAP.origin.y))
        .w(u(MINIMAP.size.width))
        .h(u(MINIMAP.size.height))
        .child(
            canvas(
                |_, _, _| {},
                move |b, _, window, _| {
                    let rx = b.size.width * 0.3;
                    let ry = b.size.height * 0.3;
                    let (l, t) = (b.origin.x, b.origin.y);
                    let (r, btm) = (l + b.size.width, t + b.size.height);
                    let mut path = PathBuilder::fill();
                    path.move_to(point(l, btm));
                    path.line_to(point(l, t + ry));
                    arc(
                        &mut path,
                        point(l + rx, t + ry),
                        rx,
                        ry,
                        std::f32::consts::PI,
                        1.5 * std::f32::consts::PI,
                    );
                    path.line_to(point(r - rx, t));
                    arc(
                        &mut path,
                        point(r - rx, t + ry),
                        rx,
                        ry,
                        1.5 * std::f32::consts::PI,
                        2.0 * std::f32::consts::PI,
                    );
                    path.line_to(point(r, btm));
                    path.close();
                    if let Ok(p) = path.build() {
                        window.paint_path(p, fill);
                    }
                },
            )
            .absolute()
            .top_0()
            .left_0()
            .size_full(),
        )
        .child(
            div()
                .absolute()
                .top_0()
                .left_0()
                .size_full()
                .flex()
                .items_center()
                .justify_center()
                .text_size(u(18.))
                .line_height(u(27.))
                .text_color(crate::theme::ZINC_500)
                .child("Minimap (3D)"),
        )
}

fn arc(path: &mut PathBuilder, c: Point<Pixels>, rx: Pixels, ry: Pixels, from: f32, to: f32) {
    const STEPS: usize = 24;
    for i in 1..=STEPS {
        let a = from + (to - from) * i as f32 / STEPS as f32;
        path.line_to(point(c.x + rx * a.cos(), c.y + ry * a.sin()));
    }
}

/// Sonner's default toast metrics and motion with the web Toaster's classes
/// (components/ui/sonner.tsx, MatchHUD.tsx).
fn lane_toast(on: bool, age: Duration, window: &Window) -> impl IntoElement {
    let color = if on { ACCENT } else { ERROR };
    let a = age.as_secs_f32();
    let life = TOAST_LIFE.as_secs_f32();
    let (shown, lift) = if a < life {
        let p = crate::theme::ease_css((a / TOAST_ANIM_S).min(1.0));
        (p, 1.0 - p)
    } else {
        let p = crate::theme::ease_css(((a - life) / TOAST_ANIM_S).min(1.0));
        (1.0 - p, p)
    };
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

fn banner(kind: LinkBanner) -> impl IntoElement {
    crate::widgets::status_pill(HUD_DESIGN, kind.text())
}
