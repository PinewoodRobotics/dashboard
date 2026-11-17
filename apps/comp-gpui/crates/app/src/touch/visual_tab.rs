use gpui_kit::*;

use super::{TabId, TouchScreen, tabs};

pub fn render(
    _ts: &TouchScreen,
    _key: u64,
    _window: &mut Window,
    _cx: &mut Context<TouchScreen>,
) -> impl IntoElement {
    tabs::not_ported(TabId::Visual)
}
