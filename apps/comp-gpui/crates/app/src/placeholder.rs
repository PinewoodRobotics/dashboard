use gpui_kit::*;

use crate::theme::{INTER, ZINC_500, hex, u};

pub const VIEW3D_FILL: Rgba = hex(0x141414);

pub fn view3d(name: &str) -> Div {
    div()
        .size_full()
        .bg(VIEW3D_FILL)
        .flex()
        .items_center()
        .justify_center()
        .font_family(INTER)
        .text_size(u(18.))
        .line_height(u(27.))
        .text_color(ZINC_500)
        .child(SharedString::from(name.to_owned()))
}
