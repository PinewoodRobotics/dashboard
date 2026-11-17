use std::time::Instant;

use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;

use crate::input::{self, Phase, TAP_SLOP};
use crate::theme::{ACCENT, TRANSPARENT, u};

const BAR_W: f32 = 5.0;
const FLING_TAU_S: f32 = 0.325;
const MIN_FLING: f32 = 0.05;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Axis2 {
    Vertical,
    Horizontal,
}

struct ScrollState {
    handle: ScrollHandle,
    dragging: bool,
    start: f32,
    start_offset: f32,
    samples: Vec<(Instant, f32)>,
    fling: Option<(Instant, f32, f32)>,
}

/// The web's overflow scrollers with their 5 px accent bar (settings
/// constants.ts colScroll and the horizontal tab strips). The bar's
/// thickness sits beside the content. The wheel and trackpad scroll through
/// GPUI; a touch drags the content past the tap slop and flings on release;
/// a mouse drag on content never scrolls, as in a desktop browser.
#[derive(IntoElement)]
pub struct Scroll {
    id: ElementId,
    axis: Axis2,
    track: Rgba,
    always_bar: bool,
    children: Vec<AnyElement>,
    content: Option<Div>,
}

impl Scroll {
    pub fn new(id: impl Into<ElementId>, axis: Axis2) -> Self {
        Self {
            id: id.into(),
            axis,
            track: TRANSPARENT,
            always_bar: true,
            children: Vec::new(),
            content: None,
        }
    }

    pub fn track(mut self, color: Rgba) -> Self {
        self.track = color;
        self
    }

    /// overflow-auto: the bar only takes room while the content overflows.
    pub fn auto(mut self) -> Self {
        self.always_bar = false;
        self
    }

    pub fn content(mut self, content: Div) -> Self {
        self.content = Some(content);
        self
    }
}

impl ParentElement for Scroll {
    fn extend(&mut self, elements: impl IntoIterator<Item = AnyElement>) {
        self.children.extend(elements);
    }
}

fn along(axis: Axis2, p: Point<f32>) -> f32 {
    match axis {
        Axis2::Vertical => p.y,
        Axis2::Horizontal => p.x,
    }
}

fn get_offset(axis: Axis2, h: &ScrollHandle) -> f32 {
    let o = h.offset();
    -f32::from(match axis {
        Axis2::Vertical => o.y,
        Axis2::Horizontal => o.x,
    })
}

fn max_offset(axis: Axis2, h: &ScrollHandle) -> f32 {
    let m = h.max_offset();
    f32::from(match axis {
        Axis2::Vertical => m.y,
        Axis2::Horizontal => m.x,
    })
}

fn set_offset(axis: Axis2, h: &ScrollHandle, value_px: f32) {
    let v = -value_px.clamp(0.0, max_offset(axis, h).max(0.0));
    let o = h.offset();
    h.set_offset(match axis {
        Axis2::Vertical => point(o.x, px(v)),
        Axis2::Horizontal => point(px(v), o.y),
    });
}

impl RenderOnce for Scroll {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let axis = self.axis;
        let state = window.use_keyed_state(self.id.clone(), cx, |_, _| ScrollState {
            handle: ScrollHandle::new(),
            dragging: false,
            start: 0.0,
            start_offset: 0.0,
            samples: Vec::new(),
            fling: None,
        });
        let handle = state.read(cx).handle.clone();

        let mut flinging = false;
        state.update(cx, |s, _| {
            if let Some((at, v0, from)) = s.fling {
                let t = at.elapsed().as_secs_f32();
                let travel = v0 * FLING_TAU_S * (1.0 - (-t / FLING_TAU_S).exp());
                set_offset(axis, &s.handle, from + travel);
                let v = v0 * (-t / FLING_TAU_S).exp();
                let at_edge = {
                    let o = get_offset(axis, &s.handle);
                    o <= 0.0 || o >= max_offset(axis, &s.handle)
                };
                if v.abs() < MIN_FLING || at_edge {
                    s.fling = None;
                } else {
                    flinging = true;
                }
            }
        });
        if flinging {
            window.request_animation_frame();
        }

        let overflows = max_offset(axis, &handle) > 0.5;
        let show_bar = self.always_bar || overflows;

        let content = self.content.unwrap_or_else(div).children(self.children);
        let content = match axis {
            Axis2::Vertical => content.w_full().flex_none(),
            Axis2::Horizontal => content.h_full().flex_none(),
        };
        let mut area = div()
            .id(self.id.clone())
            .flex()
            .when(axis == Axis2::Vertical, |d| d.flex_col())
            .flex_1()
            .min_w_0()
            .min_h_0()
            .track_scroll(&handle)
            .child(content);
        area = match axis {
            Axis2::Vertical => area.overflow_y_scroll(),
            Axis2::Horizontal => area.overflow_x_scroll(),
        };
        let area = area.on_mouse_down(MouseButton::Left, {
            let state = state.clone();
            move |e, window, cx| {
                let p = input::pointer(Phase::Down, e.position, window);
                let rem = f32::from(window.rem_size()).max(0.0001);
                let (offset, max) = {
                    let h = &state.read(cx).handle;
                    (get_offset(axis, h) / rem, max_offset(axis, h))
                };
                if axis == Axis2::Vertical && offset > 0.0 {
                    input::note_scroll_not_at_top();
                }
                if !p.is_touch() || max <= 0.0 {
                    return;
                }
                state.update(cx, |s, _| {
                    s.fling = None;
                    s.dragging = false;
                    s.start = along(axis, p.pos);
                    s.start_offset = offset;
                    s.samples.clear();
                });
                let st = state.clone();
                input::capture(window, move |p, window, cx| {
                    let rem = f32::from(window.rem_size()).max(0.0001);
                    st.update(cx, |s, cx| {
                        let d = along(axis, p.pos) - s.start;
                        match p.phase {
                            Phase::Move => {
                                if !s.dragging && d.abs() > TAP_SLOP {
                                    s.dragging = true;
                                    s.start = along(axis, p.pos);
                                    s.start_offset = get_offset(axis, &s.handle) / rem;
                                }
                                if s.dragging {
                                    let d = along(axis, p.pos) - s.start;
                                    set_offset(axis, &s.handle, (s.start_offset - d) * rem);
                                    s.samples.push((p.at, get_offset(axis, &s.handle)));
                                    if s.samples.len() > 5 {
                                        s.samples.remove(0);
                                    }
                                    cx.notify();
                                }
                            }
                            Phase::Up => {
                                if s.dragging && s.samples.len() >= 2 {
                                    let (t0, o0) = s.samples[0];
                                    let (t1, o1) = s.samples[s.samples.len() - 1];
                                    let dt = t1.duration_since(t0).as_secs_f32();
                                    let recent = p.at.duration_since(t1).as_secs_f32() < 0.1;
                                    if dt > 0.0 && recent {
                                        s.fling = Some((Instant::now(), (o1 - o0) / dt, o1));
                                    }
                                }
                                s.dragging = false;
                                cx.notify();
                            }
                            Phase::Cancel => {
                                s.dragging = false;
                                cx.notify();
                            }
                            Phase::Down => {}
                        }
                    });
                });
            }
        });

        let bar_handle = handle.clone();
        let track = self.track;
        let bar = div().flex_none().bg(track).child(
            canvas(
                |_, _, _| {},
                move |bounds, _, window, _| {
                    let max = max_offset(axis, &bar_handle);
                    if max <= 0.5 {
                        return;
                    }
                    let view = f32::from(match axis {
                        Axis2::Vertical => bar_handle.bounds().size.height,
                        Axis2::Horizontal => bar_handle.bounds().size.width,
                    });
                    let len = f32::from(match axis {
                        Axis2::Vertical => bounds.size.height,
                        Axis2::Horizontal => bounds.size.width,
                    });
                    let thumb = (len * view / (view + max)).max(1.0);
                    let at = (get_offset(axis, &bar_handle) / max).clamp(0.0, 1.0) * (len - thumb);
                    let rect = match axis {
                        Axis2::Vertical => Bounds::new(
                            point(bounds.origin.x, bounds.origin.y + px(at)),
                            size(bounds.size.width, px(thumb)),
                        ),
                        Axis2::Horizontal => Bounds::new(
                            point(bounds.origin.x + px(at), bounds.origin.y),
                            size(px(thumb), bounds.size.height),
                        ),
                    };
                    window.paint_quad(fill(rect, ACCENT));
                },
            )
            .size_full(),
        );
        let bar = match axis {
            Axis2::Vertical => bar.w(u(BAR_W)).h_full(),
            Axis2::Horizontal => bar.h(u(BAR_W)).w_full(),
        };

        let root = div()
            .flex()
            .size_full()
            .min_w_0()
            .min_h_0()
            .child(area)
            .when(show_bar, |d| d.child(bar));
        match axis {
            Axis2::Vertical => root.flex_row(),
            Axis2::Horizontal => root.flex_col(),
        }
    }
}
