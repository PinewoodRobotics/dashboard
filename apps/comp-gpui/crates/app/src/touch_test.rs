//! Driver-station touch check (comp-godot ui/debug/touch_test.gd), opened
//! with `--touch-test` or [`open_all`] (Visual > Diagnostics > Touch Test).
//! One layer per window. On the touchscreen it takes every touch: a ring sits
//! where the app thinks each finger is, with its index and position, and
//! drags leave a trail, so a finger that is not under its ring shows an
//! offset or scaling problem at a glance. On the HUD it only counts: a touch
//! that reaches the HUD window is routed to the wrong window. Every press is
//! logged. Close (bottom right) or Escape ends the test.
//!
//! Touches arrive as `input::Pointer`s with `Source::Touch`, which today
//! means `--mouse-as-touch`; real touch ids replace the single id 0 once
//! input.rs gets GPUI touch events.

use std::collections::BTreeMap;

use gpui_kit::*;

use crate::input::{self, Phase, Pointer, Source};
use crate::theme::{self, BLACK, WHITE, ZINC_300, alpha, hex, u};
use crate::windows::ScreenKind;

pub const RING_R: f32 = 46.0;
pub const TRAIL_MAX: usize = 400;
const CLOSE_OFFSET: Point<f32> = Point { x: -220.0, y: -86.0 };
const CLOSE_SIZE: Size<f32> = Size {
    width: 196.0,
    height: 62.0,
};
const GREEN: Rgba = hex(0x70cd35);
const ROSE: Rgba = hex(0xf43f5e);
const INTER_ASCENT: f32 = 1984.0 / 2048.0;
const INTER_DESCENT: f32 = 494.0 / 2048.0;

pub fn close_rect(size: Size<f32>) -> Bounds<f32> {
    Bounds::new(
        point(size.width + CLOSE_OFFSET.x, size.height + CLOSE_OFFSET.y),
        CLOSE_SIZE,
    )
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct WindowTest {
    pub touches: BTreeMap<u64, Point<f32>>,
    pub trail: Vec<Point<f32>>,
    pub presses: u32,
    pub drags: u32,
    pub scrolls: u32,
}

impl WindowTest {
    /// Applies one pointer event; true when it ends the test.
    pub fn on_pointer(&mut self, kind: ScreenKind, size: Size<f32>, id: u64, p: &Pointer) -> bool {
        let on_close = kind == ScreenKind::Touch && close_rect(size).contains(&p.pos);
        if p.source == Source::Mouse {
            return p.phase == Phase::Up && on_close;
        }
        match p.phase {
            Phase::Down => {
                self.presses += 1;
                self.touches.insert(id, p.pos);
                self.trail.clear();
                eprintln!(
                    "touch-test: {} window press #{id} at {}, {}",
                    key(kind),
                    p.pos.x.round(),
                    p.pos.y.round()
                );
                false
            }
            Phase::Move => {
                self.drags += 1;
                self.touches.insert(id, p.pos);
                if id == 0 {
                    self.trail.push(p.pos);
                    if self.trail.len() > TRAIL_MAX {
                        let extra = self.trail.len() - TRAIL_MAX;
                        self.trail.drain(..extra);
                    }
                }
                false
            }
            Phase::Up | Phase::Cancel => {
                self.touches.remove(&id);
                on_close
            }
        }
    }
}

fn key(kind: ScreenKind) -> &'static str {
    match kind {
        ScreenKind::Hud => "hud",
        ScreenKind::Touch => "touch",
    }
}

#[derive(Default)]
pub struct TouchTest {
    pub open: bool,
    pub hud: WindowTest,
    pub touch: WindowTest,
}

impl TouchTest {
    pub fn window(&mut self, kind: ScreenKind) -> &mut WindowTest {
        match kind {
            ScreenKind::Hud => &mut self.hud,
            ScreenKind::Touch => &mut self.touch,
        }
    }
}

struct Shared(Entity<TouchTest>);

impl Global for Shared {}

fn state(cx: &mut App) -> Entity<TouchTest> {
    if let Some(s) = cx.try_global::<Shared>() {
        return s.0.clone();
    }
    let s = cx.new(|_| TouchTest::default());
    cx.set_global(Shared(s.clone()));
    s
}

pub fn open_all(cx: &mut App) {
    state(cx).update(cx, |t, cx| {
        if !t.open {
            *t = TouchTest {
                open: true,
                ..TouchTest::default()
            };
            eprintln!("touch-test: open");
            cx.notify();
        }
    });
}

pub fn close_all(cx: &mut App) {
    state(cx).update(cx, |t, cx| {
        if t.open {
            t.open = false;
            eprintln!("touch-test: closed");
            cx.notify();
        }
    });
}

fn handle(kind: ScreenKind, size: Size<f32>, p: Pointer, cx: &mut App) {
    let close = state(cx).update(cx, |t, cx| {
        if !t.open {
            return false;
        }
        cx.notify();
        t.window(kind).on_pointer(kind, size, 0, &p)
    });
    if close {
        close_all(cx);
    }
}

/// Text placed by its baseline, as the Godot canvas draws it.
fn text_at(x: f32, baseline: f32, px: f32, color: Rgba, s: impl Into<SharedString>) -> Div {
    div()
        .absolute()
        .left(u(x))
        .top(u(baseline - INTER_ASCENT * px))
        .whitespace_nowrap()
        .font_family(theme::INTER)
        .font_weight(theme::touch_weight(600))
        .text_size(u(px))
        .line_height(u((INTER_ASCENT + INTER_DESCENT) * px))
        .text_color(color)
        .child(s.into())
}

fn dot(c: Point<f32>, r: f32, color: Rgba) -> Div {
    div()
        .absolute()
        .left(u(c.x - r))
        .top(u(c.y - r))
        .size(u(r * 2.0))
        .rounded_full()
        .bg(color)
}

/// Window-wide listeners, so the test sees every press and drag whatever
/// lies under it.
fn listeners(kind: ScreenKind, size: Size<f32>) -> impl IntoElement {
    canvas(
        |_, _, _| {},
        move |_, _, window, _| {
            window.on_mouse_event(move |e: &MouseDownEvent, phase, window, cx| {
                if phase == DispatchPhase::Capture && e.button == MouseButton::Left {
                    handle(kind, size, input::pointer(Phase::Down, e.position, window), cx);
                }
            });
            window.on_mouse_event(move |e: &MouseMoveEvent, phase, window, cx| {
                if phase == DispatchPhase::Capture && e.pressed_button == Some(MouseButton::Left) {
                    handle(kind, size, input::pointer(Phase::Move, e.position, window), cx);
                }
            });
            window.on_mouse_event(move |e: &MouseUpEvent, phase, window, cx| {
                if phase == DispatchPhase::Capture && e.button == MouseButton::Left {
                    handle(kind, size, input::pointer(Phase::Up, e.position, window), cx);
                }
            });
            window.on_mouse_event(move |_: &ScrollEvent, phase, _, cx| {
                if phase == DispatchPhase::Capture {
                    state(cx).update(cx, |t, _| {
                        if t.open {
                            t.window(kind).scrolls += 1;
                        }
                    });
                }
            });
        },
    )
    .absolute()
    .size_0()
}

pub fn layer(kind: ScreenKind, size: Size<f32>, window: &mut Window, cx: &mut App) -> AnyElement {
    let st = state(cx);
    let focus = window.use_keyed_state("touch-test-focus", cx, |_, cx| {
        (cx.focus_handle(), false)
    });
    let t = st.read(cx);
    if !t.open {
        focus.update(cx, |f, _| f.1 = false);
        return div().into_any_element();
    }
    let w = match kind {
        ScreenKind::Hud => t.hud.clone(),
        ScreenKind::Touch => t.touch.clone(),
    };
    let (handle_focus, grabbed) = focus.read(cx).clone();
    if !grabbed {
        window.focus(&handle_focus, cx);
        focus.update(cx, |f, _| f.1 = true);
    }

    let root = div()
        .id(ElementId::Name(format!("touch-test-{}", key(kind)).into()))
        .absolute()
        .top_0()
        .left_0()
        .size_full()
        .track_focus(&handle_focus)
        .on_key_down(|e, _, cx| {
            if e.keystroke.key == "escape" {
                cx.stop_propagation();
                close_all(cx);
            }
        })
        .child(listeners(kind, size));

    match kind {
        ScreenKind::Hud => hud_layer(root, &w, size).into_any_element(),
        ScreenKind::Touch => touch_layer(root, &w, size).into_any_element(),
    }
}

fn hud_layer(root: Stateful<Div>, w: &WindowTest, size: Size<f32>) -> Stateful<Div> {
    if w.presses + w.drags == 0 {
        return root;
    }
    root.child(
        div()
            .absolute()
            .left(u(40.))
            .top(u(40.))
            .w(u(size.width - 80.0))
            .h(u(120.))
            .rounded(u(16.))
            .border(u(3.))
            .border_color(ROSE)
            .bg(Rgba {
                r: 0.3,
                g: 0.02,
                b: 0.06,
                a: 1.0,
            }),
    )
    .child(text_at(
        72.0,
        112.0,
        34.0,
        WHITE,
        format!(
            "Touch reached the HUD window: {} presses, {} drags. Use the two-process launcher.",
            w.presses, w.drags
        ),
    ))
}

fn touch_layer(root: Stateful<Div>, w: &WindowTest, size: Size<f32>) -> Stateful<Div> {
    let close = close_rect(size);
    let trail = w.trail.iter().skip(1).map(|p| dot(*p, 3.0, alpha(GREEN, 0.5)));
    let rings = w.touches.iter().map(|(i, p)| {
        div()
            .child(dot(*p, RING_R, alpha(GREEN, 0.35)))
            .child(dot(*p, 6.0, WHITE))
            .child(text_at(
                p.x + RING_R + 8.0,
                p.y - 8.0,
                24.0,
                WHITE,
                format!("#{i}  {}, {}", p.x.round(), p.y.round()),
            ))
    });
    root.occlude()
        .bg(alpha(BLACK, 0.82))
        .on_mouse_down(MouseButton::Left, |_, _, _| input::veto_swipe())
        .children(trail)
        .children(rings)
        .child(text_at(
            32.0,
            52.0,
            28.0,
            WHITE,
            "Touch test: rings must sit under your fingertips, also in the corners and while dragging.",
        ))
        .child(text_at(
            32.0,
            92.0,
            24.0,
            ZINC_300,
            format!(
                "Window {} x {} px.  Presses {}, drag events {}, fingers down {}.",
                size.width.round(),
                size.height.round(),
                w.presses,
                w.drags,
                w.touches.len()
            ),
        ))
        .child(
            div()
                .absolute()
                .left(u(close.origin.x))
                .top(u(close.origin.y))
                .w(u(close.size.width))
                .h(u(close.size.height))
                .rounded(u(10.))
                .border(u(2.))
                .border_color(alpha(WHITE, 0.4))
                .bg(Rgba {
                    r: 0.1,
                    g: 0.1,
                    b: 0.1,
                    a: 1.0,
                }),
        )
        .child(
            text_at(close.origin.x, close.origin.y + 42.0, 28.0, WHITE, "Close")
                .w(u(close.size.width))
                .flex()
                .justify_center(),
        )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    const TOUCH: Size<f32> = Size {
        width: 1920.0,
        height: 515.0,
    };

    fn ev(phase: Phase, x: f32, y: f32, source: Source) -> Pointer {
        Pointer {
            phase,
            pos: point(x, y),
            source,
            at: Instant::now(),
        }
    }

    fn touch(w: &mut WindowTest, kind: ScreenKind, phase: Phase, x: f32, y: f32) -> bool {
        w.on_pointer(kind, TOUCH, 0, &ev(phase, x, y, Source::Touch))
    }

    #[std::prelude::v1::test]
    fn close_sits_bottom_right() {
        let r = close_rect(TOUCH);
        assert_eq!((r.origin.x, r.origin.y), (1700.0, 429.0));
        assert_eq!((r.size.width, r.size.height), (196.0, 62.0));
    }

    #[std::prelude::v1::test]
    fn touches_count_and_trail() {
        let mut w = WindowTest::default();
        for (x, y) in [(40.0, 40.0), (1880.0, 40.0), (40.0, 475.0)] {
            assert!(!touch(&mut w, ScreenKind::Touch, Phase::Down, x, y));
            assert!(!touch(&mut w, ScreenKind::Touch, Phase::Up, x, y));
        }
        assert_eq!(w.presses, 3);
        assert!(w.touches.is_empty());
        touch(&mut w, ScreenKind::Touch, Phase::Down, 300.0, 300.0);
        for i in 1..=24 {
            touch(&mut w, ScreenKind::Touch, Phase::Move, 300.0 + i as f32 * 50.0, 300.0);
        }
        assert_eq!(w.presses, 4);
        assert!(w.drags >= 20);
        assert_eq!(w.touches.len(), 1, "a finger still down keeps its ring");
        assert_eq!(w.trail.len(), 24);
        touch(&mut w, ScreenKind::Touch, Phase::Up, 1500.0, 300.0);
        assert!(w.touches.is_empty());
        touch(&mut w, ScreenKind::Touch, Phase::Down, 10.0, 10.0);
        assert!(w.trail.is_empty(), "a new press starts a new trail");
    }

    #[std::prelude::v1::test]
    fn trail_keeps_the_last_points() {
        let mut w = WindowTest::default();
        touch(&mut w, ScreenKind::Touch, Phase::Down, 0.0, 0.0);
        for i in 0..(TRAIL_MAX + 50) {
            touch(&mut w, ScreenKind::Touch, Phase::Move, i as f32, 0.0);
        }
        assert_eq!(w.trail.len(), TRAIL_MAX);
        assert_eq!(w.trail[0].x, 50.0);
    }

    #[std::prelude::v1::test]
    fn close_ends_the_test_on_the_touchscreen_only() {
        let mut w = WindowTest::default();
        touch(&mut w, ScreenKind::Touch, Phase::Down, 1800.0, 470.0);
        assert!(touch(&mut w, ScreenKind::Touch, Phase::Up, 1800.0, 470.0));
        let mut hud = WindowTest::default();
        touch(&mut hud, ScreenKind::Hud, Phase::Down, 1800.0, 470.0);
        assert!(!touch(&mut hud, ScreenKind::Hud, Phase::Up, 1800.0, 470.0));
        assert_eq!(hud.presses, 1, "the HUD counts misrouted touches");
    }

    #[std::prelude::v1::test]
    fn mouse_only_closes() {
        let mut w = WindowTest::default();
        let m = |phase, x, y| ev(phase, x, y, Source::Mouse);
        assert!(!w.on_pointer(ScreenKind::Touch, TOUCH, 0, &m(Phase::Down, 300.0, 300.0)));
        assert!(!w.on_pointer(ScreenKind::Touch, TOUCH, 0, &m(Phase::Up, 300.0, 300.0)));
        assert_eq!(w.presses, 0, "the mouse is not a touch");
        assert!(w.on_pointer(ScreenKind::Touch, TOUCH, 0, &m(Phase::Up, 1800.0, 470.0)));
    }
}
