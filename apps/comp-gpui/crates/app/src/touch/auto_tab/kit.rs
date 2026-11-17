//! The Auto tab's own pieces of PwButton (the DARK, DIALOG, ACCENT and
//! Godot-only overlay styles, with lucide icons) and the preview notes.

use std::rc::Rc;

use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;

use crate::icons::lucide;
use crate::theme::{
    ACCENT, BLACK, INTER, SELECTED_FILL, WHITE, ZINC_800, alpha, hex, touch_weight, u,
};
use crate::widgets::{OnTap, press_state, tappable};

pub const ZINC_950: Rgba = hex(0x09090b);
pub const ZINC_700: Rgba = hex(0x3f3f46);
pub const AMBER: Rgba = hex(0xfbbf24);
pub const ROSE: Rgba = hex(0xf43f5e);
pub const ROSE_TEXT: Rgba = hex(0xfb7185);
pub const RADIUS: f32 = 6.0;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Look {
    /// Text buttons (AutoSelector.tsx); `selected` is the green Selected state.
    Dark,
    Primary,
    /// Godot-only toggles that are on.
    Accent,
    Dialog,
    DialogPrimary,
    /// Over the 3D view, readable on light carpet and dark sky.
    Overlay,
    /// A fixed fill, darkened 25% while pressed (alliance toggle).
    Solid(Rgba),
}

#[derive(IntoElement)]
pub struct Btn {
    id: ElementId,
    text: Option<SharedString>,
    icon: Option<&'static str>,
    look: Look,
    font: f32,
    size: Option<(f32, f32)>,
    selected: bool,
    disabled: bool,
    on_tap: Option<OnTap>,
}

impl Btn {
    pub fn new(id: impl Into<ElementId>, look: Look) -> Self {
        let font = match look {
            Look::Dark => 34.0,
            Look::Dialog | Look::DialogPrimary => 22.0,
            _ => 16.0,
        };
        Self {
            id: id.into(),
            text: None,
            icon: None,
            look,
            font,
            size: None,
            selected: false,
            disabled: false,
            on_tap: None,
        }
    }

    pub fn text(mut self, t: impl Into<SharedString>) -> Self {
        self.text = Some(t.into());
        self
    }

    pub fn icon(mut self, name: &'static str) -> Self {
        self.icon = Some(name);
        self
    }

    pub fn font(mut self, px: f32) -> Self {
        self.font = px;
        self
    }

    pub fn size(mut self, w: f32, h: f32) -> Self {
        self.size = Some((w, h));
        self
    }

    pub fn selected(mut self, on: bool) -> Self {
        self.selected = on;
        self
    }

    pub fn disabled(mut self, on: bool) -> Self {
        self.disabled = on;
        self
    }

    pub fn on_tap(mut self, f: impl Fn(&mut Window, &mut App) + 'static) -> Self {
        self.on_tap = Some(Rc::new(f));
        self
    }
}

fn darken(c: Rgba, by: f32) -> Rgba {
    Rgba {
        r: c.r * (1.0 - by),
        g: c.g * (1.0 - by),
        b: c.b * (1.0 - by),
        a: c.a,
    }
}

impl RenderOnce for Btn {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let state = press_state(self.id.clone(), window, cx);
        let down = state.read(cx).pressed && !self.disabled;
        let mut opacity = if self.disabled { 0.5 } else { 1.0 };
        let mut fg = WHITE;
        let mut border = None;
        let bg = match self.look {
            Look::Dark => {
                if self.selected {
                    ACCENT
                } else if down {
                    ZINC_800
                } else {
                    BLACK
                }
            }
            Look::Primary => {
                fg = BLACK;
                opacity = if self.disabled {
                    0.3
                } else if down {
                    0.7
                } else {
                    1.0
                };
                ACCENT
            }
            Look::Accent => {
                fg = ACCENT;
                border = Some(ACCENT);
                SELECTED_FILL
            }
            Look::Dialog => BLACK,
            Look::DialogPrimary => ACCENT,
            Look::Overlay => {
                fg = alpha(WHITE, 0.85);
                if down {
                    Rgba {
                        r: 0.16,
                        g: 0.16,
                        b: 0.16,
                        a: 0.92,
                    }
                } else {
                    Rgba {
                        r: 0.08,
                        g: 0.08,
                        b: 0.08,
                        a: 0.78,
                    }
                }
            }
            Look::Solid(c) => {
                if down {
                    darken(c, 0.25)
                } else {
                    c
                }
            }
        };
        let weight = match self.look {
            Look::Dark | Look::Dialog | Look::DialogPrimary => 400,
            Look::Primary => 600,
            _ => 500,
        };
        let (pad_x, pad_y) = match self.look {
            Look::Dark | Look::Solid(_) => (10.0, 4.0),
            Look::Dialog | Look::DialogPrimary => (16.0, 8.0),
            Look::Primary => (32.0, 0.0),
            _ => (24.0, 0.0),
        };
        let font = self.font;
        let mut el = div()
            .id(self.id.clone())
            .flex()
            .flex_none()
            .flex_row()
            .items_center()
            .justify_center()
            .gap(u(10.))
            .bg(bg)
            .opacity(opacity)
            .font_family(INTER)
            .font_weight(touch_weight(weight))
            .text_size(u(font))
            .line_height(u(font))
            .text_color(fg)
            .whitespace_nowrap()
            .when_some(border, |d, c| d.border(u(4.)).border_color(c));
        // A fixed size is a minimum, as a Godot Control's custom_minimum_size:
        // the style's padding around the content can still widen it. The
        // overlay buttons are placed by their right edge and stay fixed.
        el = match self.size {
            Some((w, h)) if self.look == Look::Overlay => el.w(u(w)).h(u(h)),
            Some((w, h)) => el.min_w(u(w)).h(u(h)).px(u(pad_x)),
            None => el.px(u(pad_x)).py(u(pad_y)),
        };
        let el = el
            .when_some(self.icon, |d, name| d.child(lucide(name, font, fg)))
            .when_some(self.text, |d, t| d.child(t));
        tappable(el, state, self.disabled, self.on_tap)
    }
}

/// A square label on black at 72% over the scene, shrunk to its text.
pub fn note(icon: Option<&'static str>, color: Rgba, text: impl Into<SharedString>) -> Div {
    div()
        .flex()
        .flex_row()
        .flex_none()
        .items_center()
        .gap(u(6.))
        .max_w_full()
        .pl(u(8.))
        .pr(u(10.))
        .py(u(2.))
        .bg(alpha(BLACK, 0.72))
        .when_some(icon, |d, name| d.child(lucide(name, 16., color)))
        .child(
            div()
                .min_w_0()
                .font_weight(touch_weight(500))
                .text_size(u(16.))
                .line_height(u(24.))
                .text_color(color)
                .child(text.into()),
        )
}

pub fn text(
    s: impl Into<SharedString>,
    size: f32,
    weight: u16,
    color: impl Into<Hsla>,
    line_height: f32,
) -> Div {
    div()
        .font_family(INTER)
        .font_weight(touch_weight(weight))
        .text_size(u(size))
        .line_height(u(line_height))
        .text_color(color)
        .child(s.into())
}
