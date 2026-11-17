use gpui_kit::*;

use crate::theme::{INTER, touch_weight, u};

pub fn label(
    text: impl Into<SharedString>,
    size: f32,
    css_weight: u16,
    color: impl Into<Hsla>,
) -> Div {
    div()
        .font_family(INTER)
        .font_weight(touch_weight(css_weight))
        .text_size(u(size))
        .line_height(u(size * 1.5))
        .text_color(color)
        .child(text.into())
}

/// Text with CSS letter-spacing, which GPUI's text layout lacks: each
/// character is its own box followed by the tracking.
pub fn tracked(
    text: &str,
    size: f32,
    css_weight: u16,
    tracking_em: f32,
    line_height: f32,
    color: impl Into<Hsla> + Copy,
) -> Div {
    let gap = size * tracking_em;
    div()
        .flex()
        .flex_row()
        .font_family(INTER)
        .font_weight(touch_weight(css_weight))
        .text_size(u(size))
        .line_height(u(line_height))
        .text_color(color)
        .whitespace_nowrap()
        .children(text.chars().map(move |c| {
            let s = if c == ' ' {
                "\u{00a0}".to_string()
            } else {
                c.to_string()
            };
            div().flex_none().mr(u(gap)).child(s)
        }))
}
