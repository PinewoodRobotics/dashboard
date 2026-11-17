use gpui_kit::*;

use super::tracked;
use crate::theme::{BLACK, RED_400, RED_500, alpha, u};

const PILL_H: f32 = 1.0 + 6.0 + 20.0 + 6.0 + 1.0;

/// ConnectionLost.tsx.
pub fn status_pill(design: Size<f32>, text: &str) -> impl IntoElement {
    div()
        .absolute()
        .left_0()
        .top(u(design.height - 24.0 - PILL_H))
        .w(u(design.width))
        .flex()
        .justify_center()
        .child(
            div()
                .flex()
                .items_center()
                .gap(u(8.))
                .px(u(12.))
                .py(u(6.))
                .rounded(u(4.))
                .border(u(1.))
                .border_color(alpha(RED_500, 0.4))
                .bg(alpha(BLACK, 0.85))
                .child(div().flex_none().size(u(12.)).rounded_full().bg(RED_500))
                .child(tracked(text, 14., 500, 0.025, 20., RED_400)),
        )
}
