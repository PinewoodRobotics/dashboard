use gpui_kit::*;

use super::{PanelId, TouchScreen, panels};

pub fn render(
    _ts: &TouchScreen,
    _window: &mut Window,
    _cx: &mut Context<TouchScreen>,
) -> impl IntoElement {
    panels::coming_soon(PanelId::Intake)
}
