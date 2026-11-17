use std::rc::Rc;

use gpui_kit::*;

use super::OnTap;
use crate::input::{self, Phase, TAP_SLOP};

#[derive(Default)]
pub struct PressState {
    pub pressed: bool,
    tap_ready: bool,
    start: Point<f32>,
}

pub fn press_state(
    id: impl Into<ElementId>,
    window: &mut Window,
    cx: &mut App,
) -> Entity<PressState> {
    window.use_keyed_state(id, cx, |_, _| PressState::default())
}

/// Tap semantics shared by every pressable: the press shows while the
/// pointer stays within the tap slop, and the tap fires on release over the
/// element, so a swipe that starts on it never presses it.
pub fn tappable(
    el: Stateful<Div>,
    state: Entity<PressState>,
    disabled: bool,
    on_tap: Option<OnTap>,
) -> Stateful<Div> {
    let down_state = state.clone();
    el.on_mouse_down(MouseButton::Left, move |e, window, cx| {
        if disabled {
            return;
        }
        let start = input::pointer(Phase::Down, e.position, window).pos;
        down_state.update(cx, |s, cx| {
            *s = PressState {
                pressed: true,
                tap_ready: false,
                start,
            };
            cx.notify();
        });
        let st = down_state.clone();
        input::capture(window, move |p, _, cx| {
            st.update(cx, |s, cx| {
                match p.phase {
                    Phase::Move => {
                        let d = point(p.pos.x - s.start.x, p.pos.y - s.start.y);
                        if s.pressed && (d.x * d.x + d.y * d.y).sqrt() > TAP_SLOP {
                            s.pressed = false;
                        }
                    }
                    Phase::Up => {
                        s.tap_ready = s.pressed;
                        s.pressed = false;
                    }
                    Phase::Cancel => {
                        s.tap_ready = false;
                        s.pressed = false;
                    }
                    Phase::Down => {}
                }
                cx.notify();
            });
        });
    })
    .on_mouse_up(MouseButton::Left, move |_, window, cx| {
        let ready = state.update(cx, |s, _| std::mem::take(&mut s.tap_ready));
        if ready {
            if let Some(f) = on_tap.as_ref() {
                f(window, cx);
            }
        }
    })
}

pub fn on_tap(f: impl Fn(&mut Window, &mut App) + 'static) -> Option<OnTap> {
    Some(Rc::new(f))
}
