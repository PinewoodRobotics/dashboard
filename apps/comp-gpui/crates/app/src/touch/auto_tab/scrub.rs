//! Preview timeline (Godot's auto_scrub_bar.gd): interval commands as
//! labelled spans packed into lanes, instant commands as ticks on the track,
//! path segments as a lighter track, progress fill and knob. A press or drag
//! anywhere seeks the shared clock to the pointer (absolute, unlike the
//! slider), and claims the press so a drag on it never dismisses the tab.

use std::cell::Cell;
use std::rc::Rc;

use dash_core::playback::{AutoMechanisms, ItemKind, TimelineItem};
use gpui_kit::*;

use super::kit::ZINC_700;
use crate::autos::AutoService;
use crate::input::{self, Phase, PressWidget};
use crate::theme::{ACCENT, BLACK, INTER, WHITE, ZINC_300, ZINC_400, ZINC_800, alpha, hex, u};

pub const PAD_X: f32 = 14.0;
pub const LANE_H: f32 = 20.0;
pub const LANE_GAP: f32 = 3.0;
pub const MAX_LANES: usize = 3;
pub const TRACK_H: f32 = 10.0;
pub const KNOB_R: f32 = 11.0;
pub const TICK_HALF: f32 = 13.0;
pub const LABEL_PX: f32 = 13.0;
pub const DIAMOND: f32 = 6.0;
pub const COMPACT_LANE_H: f32 = 8.0;
pub const COMPACT_LANE_GAP: f32 = 2.0;
pub const COMPACT_TICK_HALF: f32 = 9.0;

/// auto_path_overlay.gd's colors per timeline kind; a command that never
/// runs is drawn in the no-op gray.
pub fn kind_color(kind: ItemKind, runs: bool) -> Rgba {
    if !runs {
        return hex(0x71717a);
    }
    match kind {
        ItemKind::Aim => hex(0x3b82f6),
        ItemKind::Shooter => hex(0xff9d00),
        ItemKind::Intake => hex(0x70cd35),
        ItemKind::Noop => hex(0x71717a),
        ItemKind::Other => hex(0xa600ff),
    }
}

/// `CamelCaseCommand` to "Camel Case", dropping the Command suffix and the
/// Continuous prefix.
pub fn short_name(n: &str) -> String {
    let s = n.strip_suffix("Command").unwrap_or(n);
    let s = s.strip_prefix("Continuous").unwrap_or(s);
    let mut out = String::new();
    let mut prev: Option<char> = None;
    for c in s.chars() {
        if let Some(p) = prev {
            if c.is_uppercase() && !p.is_uppercase() {
                out.push(' ');
            }
        }
        out.push(c);
        prev = Some(c);
    }
    if out.is_empty() { n.to_owned() } else { out }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Span {
    pub item: TimelineItem,
    pub lane: usize,
}

/// Where everything sits on a bar `width` design pixels wide.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ScrubLayout {
    pub duration: f64,
    pub path_ranges: Vec<(f64, f64)>,
    pub spans: Vec<Span>,
    pub ticks: Vec<TimelineItem>,
    pub lanes: usize,
}

impl ScrubLayout {
    pub fn new(m: Option<&AutoMechanisms>) -> Self {
        let Some(m) = m else {
            return Self::default();
        };
        let path_ranges = m
            .playback
            .segments
            .iter()
            .filter(|s| s.is_path())
            .map(|s| (s.t0, s.t1))
            .collect();
        let mut spans = Vec::new();
        let mut ticks = Vec::new();
        let mut lane_end: Vec<f64> = Vec::new();
        for it in &m.items {
            if it.instant {
                ticks.push(it.clone());
                continue;
            }
            let lane = match lane_end.iter().position(|&end| end <= it.t0 + 1e-6) {
                Some(l) => l,
                None => {
                    let l = lane_end.len().min(MAX_LANES - 1);
                    if l >= lane_end.len() {
                        lane_end.push(0.0);
                    }
                    l
                }
            };
            lane_end[lane] = lane_end[lane].max(it.t1);
            spans.push(Span {
                item: it.clone(),
                lane,
            });
        }
        Self {
            duration: m.duration,
            path_ranges,
            spans,
            ticks,
            lanes: lane_end.len(),
        }
    }

    pub fn height(&self, compact: bool) -> f32 {
        let lanes = self.lanes.max(1) as f32;
        if compact {
            lanes * (COMPACT_LANE_H + COMPACT_LANE_GAP) + 4.0 + COMPACT_TICK_HALF * 2.0 + 2.0
        } else {
            lanes * (LANE_H + LANE_GAP) + 6.0 + DIAMOND * 2.0 + TICK_HALF * 2.0 + 4.0
        }
    }

    pub fn tick_half(compact: bool) -> f32 {
        if compact {
            COMPACT_TICK_HALF
        } else {
            TICK_HALF
        }
    }

    pub fn track_y(&self, height: f32, compact: bool) -> f32 {
        height - Self::tick_half(compact) - if compact { 2.0 } else { 4.0 }
    }

    pub fn t_to_x(&self, t: f64, width: f32) -> f32 {
        let (x0, x1) = (PAD_X, width - PAD_X);
        if self.duration <= 0.0 {
            return x0;
        }
        let f = (t / self.duration).clamp(0.0, 1.0) as f32;
        x0 + (x1 - x0) * f
    }

    pub fn x_to_t(&self, x: f32, width: f32) -> f64 {
        let w = width - 2.0 * PAD_X;
        if w <= 0.0 {
            return 0.0;
        }
        ((x - PAD_X) / w).clamp(0.0, 1.0) as f64 * self.duration
    }

    /// (x, y, w, h) of a span.
    pub fn lane_rect(&self, lane: usize, t0: f64, t1: f64, width: f32, compact: bool) -> [f32; 4] {
        let (h, gap) = if compact {
            (COMPACT_LANE_H, COMPACT_LANE_GAP)
        } else {
            (LANE_H, LANE_GAP)
        };
        let x0 = self.t_to_x(t0, width);
        let w = (self.t_to_x(t1, width) - x0).max(3.0);
        [x0, lane as f32 * (h + gap), w, h]
    }
}

fn rect(origin: Point<Pixels>, rem: f32, r: [f32; 4]) -> Bounds<Pixels> {
    Bounds::new(
        point(origin.x + px(r[0] * rem), origin.y + px(r[1] * rem)),
        size(px(r[2] * rem), px(r[3] * rem)),
    )
}

fn circle(
    window: &mut Window,
    origin: Point<Pixels>,
    rem: f32,
    c: (f32, f32),
    r: f32,
    color: Rgba,
) {
    window.paint_quad(quad(
        rect(origin, rem, [c.0 - r, c.1 - r, 2.0 * r, 2.0 * r]),
        px(r * rem),
        color,
        px(0.),
        TRANSPARENT_HSLA,
        BorderStyle::default(),
    ));
}

const TRANSPARENT_HSLA: Hsla = Hsla {
    h: 0.,
    s: 0.,
    l: 0.,
    a: 0.,
};

fn diamond(
    window: &mut Window,
    origin: Point<Pixels>,
    rem: f32,
    c: (f32, f32),
    r: f32,
    color: Rgba,
    outline: f32,
) {
    let at = |x: f32, y: f32| point(origin.x + px(x * rem), origin.y + px(y * rem));
    let ring = |r: f32| {
        [
            at(c.0, c.1 - r),
            at(c.0 + r, c.1),
            at(c.0, c.1 + r),
            at(c.0 - r, c.1),
        ]
    };
    let mut b = PathBuilder::fill();
    let outer = ring(r);
    b.move_to(outer[0]);
    for p in &outer[1..] {
        b.line_to(*p);
    }
    b.close();
    if outline > 0.0 {
        let inner = ring((r - outline * std::f32::consts::SQRT_2).max(0.0));
        b.move_to(inner[0]);
        for p in inner[1..].iter().rev() {
            b.line_to(*p);
        }
        b.close();
    }
    if let Ok(p) = b.build() {
        window.paint_path(p, color);
    }
}

pub struct ScrubState {
    bounds: Rc<Cell<Bounds<Pixels>>>,
}

/// The bar for the service's preview; `layout` is the preview auto's.
pub fn scrub_bar(
    id: impl Into<ElementId>,
    svc: Entity<AutoService>,
    layout: Rc<ScrubLayout>,
    compact: bool,
    window: &mut Window,
    cx: &mut App,
) -> impl IntoElement {
    let id: ElementId = id.into();
    let state = window.use_keyed_state(id.clone(), cx, |_, _| ScrubState {
        bounds: Rc::new(Cell::new(Bounds::default())),
    });
    let bounds = state.read(cx).bounds.clone();
    let (t, playing) = {
        let c = &svc.read(cx).model.clock;
        (c.t, c.playing)
    };
    let height = layout.height(compact);
    let paint_layout = layout.clone();
    let paint_bounds = bounds.clone();

    let bar = canvas(
        move |b, _, _| paint_bounds.set(b),
        move |b, _, window, cx| {
            let rem = f32::from(window.rem_size()).max(0.0001);
            let w = f32::from(b.size.width) / rem;
            let h = f32::from(b.size.height) / rem;
            let o = b.origin;
            let l = &paint_layout;
            let ty = l.track_y(h, compact);
            for s in &l.spans {
                let r = l.lane_rect(s.lane, s.item.t0, s.item.t1, w, compact);
                let col = kind_color(s.item.kind, s.item.runs);
                let radius = if compact { 2.0 } else { 4.0 };
                let (fill_c, border) = if s.item.runs {
                    (alpha(col, 0.85), 0.0)
                } else {
                    (alpha(col, 0.18), 1.0)
                };
                window.paint_quad(quad(
                    rect(o, rem, r),
                    px(radius * rem),
                    fill_c,
                    px(border * rem),
                    col,
                    BorderStyle::default(),
                ));
                if compact {
                    continue;
                }
                let max_w = r[2] - 10.0;
                if max_w <= 24.0 {
                    continue;
                }
                let mut label = short_name(&s.item.name);
                if !s.item.note.is_empty() {
                    label = format!("{label}  ({})", s.item.note);
                }
                let text_col = if s.item.runs { BLACK } else { ZINC_300 };
                let run = TextRun {
                    len: label.len(),
                    font: Font {
                        weight: FontWeight::MEDIUM,
                        ..font(INTER)
                    },
                    color: text_col.into(),
                    background_color: None,
                    underline: None,
                    strikethrough: None,
                };
                let line =
                    window
                        .text_system()
                        .shape_line(label.into(), px(LABEL_PX * rem), &[run], None);
                let clip = rect(o, rem, [r[0] + 6.0, r[1], max_w, r[3]]);
                window.with_content_mask(Some(ContentMask { bounds: clip }), |window| {
                    let _ = line.paint(
                        point(clip.origin.x, clip.origin.y),
                        px(LANE_H * rem),
                        TextAlign::Left,
                        None,
                        window,
                        cx,
                    );
                });
            }
            let (x0, x1) = (PAD_X, w - PAD_X);
            let track = |a: f32, b: f32| [a, ty - TRACK_H * 0.5, b - a, TRACK_H];
            window.paint_quad(fill(rect(o, rem, track(x0, x1)), ZINC_800));
            for &(p0, p1) in &l.path_ranges {
                window.paint_quad(fill(
                    rect(o, rem, track(l.t_to_x(p0, w), l.t_to_x(p1, w))),
                    ZINC_700,
                ));
            }
            window.paint_quad(fill(
                rect(o, rem, track(x0, l.t_to_x(t, w))),
                alpha(ACCENT, 0.9),
            ));
            let th = ScrubLayout::tick_half(compact);
            for k in &l.ticks {
                let x = l.t_to_x(k.t0, w);
                let col = kind_color(k.kind, k.runs);
                window.paint_quad(fill(rect(o, rem, [x - 1.5, ty - th, 3.0, th * 2.0]), col));
                if !compact {
                    let outline = if k.runs { 0.0 } else { 2.0 };
                    diamond(
                        window,
                        o,
                        rem,
                        (x, ty - TICK_HALF - DIAMOND),
                        DIAMOND,
                        col,
                        outline,
                    );
                }
            }
            let kx = l.t_to_x(t, w);
            let kr = if compact { KNOB_R - 2.0 } else { KNOB_R };
            circle(window, o, rem, (kx, ty), kr, WHITE);
            circle(
                window,
                o,
                rem,
                (kx, ty),
                kr - 3.0,
                if playing { ACCENT } else { ZINC_400 },
            );
        },
    )
    .size_full();

    let seek_layout = layout.clone();
    div()
        .id(id)
        .relative()
        .w_full()
        .flex_none()
        .h(u(height))
        .child(bar)
        .on_mouse_down(MouseButton::Left, move |e, window, cx| {
            input::note_press_widget(PressWidget::Slider);
            input::veto_swipe();
            if seek_layout.duration <= 0.0 {
                return;
            }
            let rem = f32::from(window.rem_size()).max(0.0001);
            let seek = {
                let bounds = bounds.clone();
                let layout = seek_layout.clone();
                move |pos_px: f32| {
                    let b = bounds.get();
                    let w = f32::from(b.size.width) / rem;
                    let x = pos_px / rem - f32::from(b.origin.x) / rem;
                    layout.x_to_t(x, w)
                }
            };
            let t = seek(f32::from(e.position.x));
            svc.update(cx, |s, cx| {
                s.model.clock.begin_scrub();
                s.model.clock.seek(t);
                s.model.refresh();
                cx.notify();
            });
            let svc = svc.clone();
            input::capture(window, move |p, _, cx| {
                let t = seek(p.pos.x * rem);
                svc.update(cx, |s, cx| {
                    match p.phase {
                        Phase::Move => s.model.clock.seek(t),
                        Phase::Up => {
                            s.model.clock.seek(t);
                            s.model.clock.end_scrub();
                        }
                        Phase::Cancel => s.model.clock.end_scrub(),
                        Phase::Down => {}
                    }
                    s.model.refresh();
                    cx.notify();
                });
            });
        })
}

#[cfg(test)]
mod tests {
    use dash_core::autos::{AutoCommands, AutoLibrary, ExportSource};

    use dash_core::playback::{AutoMechanisms, ItemKind};

    use super::{MAX_LANES, PAD_X, ScrubLayout, kind_color, short_name};
    use crate::theme::hex;

    fn mech(name: &str) -> AutoMechanisms {
        let lib = AutoLibrary::load_dir(ExportSource::BuiltIn).unwrap();
        AutoMechanisms::new(lib.get_auto(name).unwrap(), &AutoCommands::builtin())
    }

    fn near(a: f32, b: f32, what: &str) {
        assert!((a - b).abs() < 1e-3, "{what}: {a} vs {b}");
    }

    #[test]
    fn positions_are_proportional() {
        let m = mech("Climber Right Right");
        let l = ScrubLayout::new(Some(&m));
        let width = 700.0;
        let (x0, x1) = (PAD_X, width - PAD_X);
        let w = x1 - x0;
        let instants = m.items.iter().filter(|it| it.instant).count();
        let intervals = m.items.len() - instants;
        assert!(instants > 0 && intervals > 0);
        assert_eq!(l.ticks.len(), instants, "a tick per instant event");
        assert_eq!(l.spans.len(), intervals, "a span per interval event");
        for k in &l.ticks {
            near(
                l.t_to_x(k.t0, width),
                x0 + (k.t0 / m.duration) as f32 * w,
                &k.name,
            );
        }
        for s in &l.spans {
            let r = l.lane_rect(s.lane, s.item.t0, s.item.t1, width, false);
            near(r[0], x0 + (s.item.t0 / m.duration) as f32 * w, &s.item.name);
            near(
                r[0] + r[2],
                (x0 + (s.item.t1 / m.duration) as f32 * w).max(r[0] + 3.0),
                &s.item.name,
            );
        }
        assert!((l.x_to_t(l.t_to_x(5.0, width), width) - 5.0).abs() < 1e-4);
    }

    #[test]
    fn spans_pack_into_at_most_three_lanes() {
        let m = mech("Stay And Shoot");
        let l = ScrubLayout::new(Some(&m));
        assert!(l.lanes >= 1 && l.lanes <= MAX_LANES);
        for (i, a) in l.spans.iter().enumerate() {
            for b in &l.spans[..i] {
                if a.lane == b.lane && a.lane < MAX_LANES - 1 {
                    assert!(
                        a.item.t0 + 1e-6 >= b.item.t1 || b.item.t0 + 1e-6 >= a.item.t1,
                        "{} overlaps {} in lane {}",
                        a.item.name,
                        b.item.name,
                        a.lane
                    );
                }
            }
        }
    }

    #[test]
    fn heights_and_track() {
        let l = ScrubLayout {
            lanes: 2,
            ..Default::default()
        };
        assert_eq!(l.height(false), 2.0 * 23.0 + 6.0 + 12.0 + 26.0 + 4.0);
        assert_eq!(l.height(true), 2.0 * 10.0 + 4.0 + 18.0 + 2.0);
        assert_eq!(l.track_y(92.0, false), 92.0 - 13.0 - 4.0);
        assert_eq!(l.t_to_x(3.0, 300.0), PAD_X, "no duration pins to the start");
        let empty = ScrubLayout::new(None);
        assert_eq!(empty.height(false), 23.0 + 6.0 + 12.0 + 26.0 + 4.0);
    }

    #[test]
    fn short_names() {
        assert_eq!(short_name("ContinuousAimCommand"), "Aim");
        assert_eq!(short_name("IntakeDownCommand"), "Intake Down");
        assert_eq!(short_name("ShootFUELCommand"), "Shoot FUEL");
        assert_eq!(short_name("Command"), "Command");
        assert_eq!(short_name("intake"), "intake");
    }

    #[test]
    fn colors_follow_the_overlay() {
        assert_eq!(kind_color(ItemKind::Aim, true), hex(0x3b82f6));
        assert_eq!(kind_color(ItemKind::Shooter, false), hex(0x71717a));
    }
}
