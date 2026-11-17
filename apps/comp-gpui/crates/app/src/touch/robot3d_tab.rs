use gpui_kit::*;

use super::TouchScreen;

pub fn render(
    _ts: &TouchScreen,
    _key: u64,
    _window: &mut Window,
    _cx: &mut Context<TouchScreen>,
) -> impl IntoElement {
    crate::placeholder::view3d("Robot 3D view (3D)")
}
