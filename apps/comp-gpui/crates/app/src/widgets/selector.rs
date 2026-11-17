use std::cell::Cell;
use std::rc::Rc;

use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;

use super::{OnChange, label};
use crate::anim::Tween;
use crate::icons::{sf, sf_symbol};
use crate::input::{self, Phase, PressWidget};
use crate::theme::{self, ACCENT, PANEL, SELECTED_FILL, WHITE, u};

const ITEM: f32 = 80.0;
const BORDER_W: f32 = 4.0;
const STRIDE: f32 = ITEM - BORDER_W;
const SYMBOL_PX: f32 = 36.0;
const DRAG_PX: f32 = 4.0;

#[derive(Clone)]
pub struct SelectorOption {
    pub symbol: u32,
    pub filled: Option<u32>,
    pub hint: Option<SharedString>,
}

impl SelectorOption {
    pub fn new(symbol: u32) -> Self {
        Self {
            symbol,
            filled: None,
            hint: None,
        }
    }

    pub fn filled(mut self, symbol: u32) -> Self {
        self.filled = Some(symbol);
        self
    }

    pub fn hint(mut self, hint: impl Into<SharedString>) -> Self {
        self.hint = Some(hint.into());
        self
    }
}

struct SelState {
    dragging: bool,
    moved: bool,
    start_x: f32,
    start_index: usize,
    delta: f32,
    strip: Rc<Cell<Bounds<Pixels>>>,
    x: Tween,
    shown_index: Option<usize>,
}

/// CustomSelector.tsx.
#[derive(IntoElement)]
pub struct Selector {
    id: ElementId,
    options: Vec<SelectorOption>,
    index: usize,
    label: Option<SharedString>,
    on_change: Option<OnChange<usize>>,
}

impl Selector {
    pub fn new(id: impl Into<ElementId>, options: Vec<SelectorOption>, index: usize) -> Self {
        Self {
            id: id.into(),
            options,
            index,
            label: None,
            on_change: None,
        }
    }

    pub fn label(mut self, label: impl Into<SharedString>) -> Self {
        self.label = Some(label.into());
        self
    }

    pub fn on_change(mut self, f: impl Fn(usize, &mut Window, &mut App) + 'static) -> Self {
        self.on_change = Some(Rc::new(f));
        self
    }
}

/// The web's on/off selector (VisualTab.tsx Backdrop Blur).
pub fn toggle(id: impl Into<ElementId>, on: bool, off_hint: &str, on_hint: &str) -> Selector {
    Selector::new(
        id,
        vec![
            SelectorOption::new(sf::TOGGLE_OFF).hint(off_hint.to_owned()),
            SelectorOption::new(sf::TOGGLE_ON).hint(on_hint.to_owned()),
        ],
        on as usize,
    )
}

fn x_to_index(x: f32, count: usize) -> usize {
    ((x / STRIDE).round().max(0.0) as usize).min(count.saturating_sub(1))
}

fn square(i: usize) -> Div {
    div()
        .absolute()
        .top_0()
        .left(u(i as f32 * STRIDE))
        .size(u(ITEM))
        .flex()
        .items_center()
        .justify_center()
}

impl RenderOnce for Selector {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let count = self.options.len().max(1);
        let index = self.index.min(count - 1);
        let max_x = (count - 1) as f32 * STRIDE;
        let state = window.use_keyed_state(self.id.clone(), cx, |_, _| SelState {
            dragging: false,
            moved: false,
            start_x: 0.0,
            start_index: index,
            delta: 0.0,
            strip: Rc::new(Cell::new(Bounds::default())),
            x: Tween::new(index as f32 * STRIDE),
            shown_index: Some(index),
        });
        let green_x = state.update(cx, |s, _| {
            if s.dragging {
                (s.start_index as f32 * STRIDE + s.delta).clamp(0.0, max_x)
            } else {
                if s.shown_index != Some(index) {
                    s.shown_index = Some(index);
                    s.x.retarget(index as f32 * STRIDE, theme::MOTION_OVERLAY_S);
                }
                s.x.value()
            }
        });
        if state.read(cx).x.running() {
            window.request_animation_frame();
        }
        let dragging = state.read(cx).dragging;
        let display_index = if dragging {
            x_to_index(green_x, count)
        } else {
            index
        };
        let hint = self.options.get(display_index).and_then(|o| o.hint.clone());
        let total = ITEM + (count - 1) as f32 * STRIDE;

        let base = self.options.iter().enumerate().map(|(i, o)| {
            square(i)
                .bg(PANEL)
                .border(u(BORDER_W))
                .border_color(WHITE)
                .child(sf_symbol(o.symbol, SYMBOL_PX, WHITE))
        });
        let greens = self.options.iter().enumerate().map(|(i, o)| {
            square(i).child(sf_symbol(o.filled.unwrap_or(o.symbol), SYMBOL_PX, ACCENT))
        });
        let mask = div()
            .absolute()
            .top_0()
            .left(u(green_x))
            .size(u(ITEM))
            .overflow_hidden()
            .child(
                div()
                    .absolute()
                    .top_0()
                    .left(u(-green_x))
                    .w(u(total))
                    .h(u(ITEM))
                    .child(
                        div()
                            .absolute()
                            .top_0()
                            .left(u(green_x))
                            .size(u(ITEM))
                            .bg(SELECTED_FILL)
                            .border(u(BORDER_W))
                            .border_color(ACCENT),
                    )
                    .children(greens),
            );

        let on_change = self.on_change.clone();
        let probe = state.read(cx).strip.clone();
        let strip = div()
            .id(self.id.clone())
            .relative()
            .flex_none()
            .w(u(total))
            .h(u(ITEM))
            .child(
                canvas(move |b, _, _| probe.set(b), |_, _, _, _| {})
                    .absolute()
                    .top_0()
                    .left_0()
                    .size_full(),
            )
            .children(base)
            .child(mask)
            .on_mouse_down(MouseButton::Left, move |e, window, cx| {
                input::note_press_widget(PressWidget::Selector);
                let x = input::pointer(Phase::Down, e.position, window).pos.x;
                state.update(cx, |s, cx| {
                    s.dragging = true;
                    s.moved = false;
                    s.start_x = x;
                    s.start_index = index;
                    s.delta = 0.0;
                    cx.notify();
                });
                let st = state.clone();
                let on_change = on_change.clone();
                input::capture(window, move |p, window, cx| match p.phase {
                    Phase::Move => st.update(cx, |s, cx| {
                        s.delta = p.pos.x - s.start_x;
                        if s.delta.abs() > DRAG_PX {
                            s.moved = true;
                        }
                        cx.notify();
                    }),
                    Phase::Up => {
                        let rem = f32::from(window.rem_size()).max(0.0001);
                        let target = st.update(cx, |s, cx| {
                            s.dragging = false;
                            s.shown_index = None;
                            let raw = (s.start_index as f32 * STRIDE + s.delta).clamp(0.0, max_x);
                            cx.notify();
                            if s.moved {
                                s.x.jump(raw);
                                x_to_index(raw, count)
                            } else {
                                let left = f32::from(s.strip.get().origin.x) / rem;
                                (((p.pos.x - left) / STRIDE).floor().max(0.0) as usize)
                                    .min(count - 1)
                            }
                        });
                        if let Some(f) = on_change.as_ref() {
                            f(target, window, cx);
                        }
                    }
                    Phase::Cancel => st.update(cx, |s, cx| {
                        s.dragging = false;
                        s.shown_index = None;
                        cx.notify();
                    }),
                    Phase::Down => {}
                });
            });

        div()
            .flex()
            .flex_col()
            .gap(u(8.))
            .when_some(self.label, |d, l| d.child(label(l, 24., 500, WHITE)))
            .child(strip)
            .when_some(hint, |d, h| d.child(label(h, 16., 400, WHITE)))
    }
}
